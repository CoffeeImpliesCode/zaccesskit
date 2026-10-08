# 31 — The C ABI of `zaccesskit`

The package installs `include/zaccesskit.h` and the `zaccesskit` library.
`build.zig:86-102` selects static linkage by default.
`-Dlinkage=dynamic` selects dynamic linkage.
Both routes honor the selected target and optimization mode.
`zig build test-c` links and runs the offline C11 consumer.
This step checks runtime calls and ownership, not declarations alone.

**Scope.** The exported C surface, its ownership contract, the header artefact and the verification that backs both. The Zig module layout, the adapter interface and the milestone order belong to `docs/30-port-design.md` and `docs/40-plan.md`.

**Proof labels.** `source reading at a pinned revision` is text at the named revision. `exercised compilation` is a build that reached the check on the named target and mode. `runtime observation` is one binary on one toolchain. **No build, test, gate or formatter was run in this repository for this document.**

---

## 1. The pin

**Compiler: Zig 0.16.0**, named in one file. `build.zig.zon:11` reads `.minimum_zig_version = "0.16.0"`, and `build.zig:10-14` repeats it for a build-script reader. A manifest floor is not a supported compiler and is not proof the package builds.

| | Repository | Revision | Version |
|---|---|---|---|
| Core | `github.com/AccessKit/accesskit` | `466e24e252103f4d82bd6fbab98141b551e46e0c` | `accesskit` 0.25.1 |
| C bindings | `github.com/AccessKit/accesskit-c` | `8b6ed37c20ed4c59390e253407983333053662ba` | `accesskit-c` 0.23.1 |

`accesskit-c/Cargo.toml` pins `accesskit = "0.25.1"` by version, so the header was generated against that core (source reading at a pinned revision, `Cargo.toml` at the accesskit-c revision). **The ABI is `accesskit-c/include/accesskit.h` at the second revision.** The core supplies the types; the header also holds three entry points the core crate lacks, so it is not a subset of the core.

**Artifact kind: both.** The C surface consists of `include/zaccesskit.h` and the exported library symbols.
The native Zig surface is `dep.module("zaccesskit")`, registered at `build.zig:75-84`.
`docs/30-port-design.md` owns the native contract.
Zig consumers use typed errors, explicit allocators, optional values, and `deinit`.
C consumers use flat functions, sentinels, and the boundary allocator.

**The supported consumer surface**, bounded by what a C consumer reaches through the shipped header: **496** function declarations, **444** on a Linux target and 52 behind a platform guard; **18** enums carrying **270** variants; **40** laid-out structs; **18** forward-declared opaque structs; **4** function-pointer typedefs; **2** scalar typedefs; **1** exported data object. The two function counts came two ways that agree: `grep -oE 'accesskit_[a-z_0-9]+\(' include/accesskit.h | sort -u | wc -l` returns 496 directly, and a C preprocessor declaration count returns 444. The four function-pointer typedefs never enter that grep, because each is written with the name inside parentheses, as `typedef struct accesskit_tree_update *(*accesskit_tree_update_factory)(`.

```text
Evidence: The header declares 496 functions, 444 visible on a Linux target and 52 behind `#if` guards, and defines 18 enums, 40 laid-out structs, 18 opaque structs, 4 function-pointer typedefs, 2 scalar typedefs and 1 data object.
Subject:  AccessKit/accesskit-c @ 8b6ed37c20ed4c59390e253407983333053662ba
Source:   include/accesskit.h
Reads as: A declaration census at one revision. It says nothing about whether the symbols link, whether any is correct, or whether another target agrees.
```

A supported C consumer includes one header, names those types, calls the functions its target exposes, reads every reachable struct field, supplies its own `userdata` beside each callback, and releases what the header says it must release. It does **not** reach the tree model's Zig types, the property table, the update codec, a platform registration mechanism, or any symbol the header does not name. Those are internal seams: a `pub` declaration no header line exposes is not on the C surface, and neither is a helper reachable only by relative import.

**The build ladder, at the rungs actually reached.** Manifest floor **reached** (`build.zig.zon:11`). Declared target **reached** (`build.zig:47`). Configured CI **not reached**: no workflow file and no `.github` directory exists. Reached build **not reached for the C ABI**: the library ships two value declarations and two tests, and no `include/zaccesskit.h` exists yet. Observed run **not reached**: no binary exists. The strongest true statement about the compiler is therefore a version-scoped declaration, and section 6 is a plan whose steps have not run.

---

## 2. The shape of the ABI

### 2.1 Record A: the flat 496-function shape, and no vtable

**Priority:** give a C adapter author upstream's entry points, so existing C adapter code reaches this library with no rewrite. **Constraint:** the ABI is a symbol contract, not a call contract. All 58 platform functions are concrete exported names, 52 behind a guard; a struct of function pointers would turn all 58 into slots and put a `size_t` slot index into a published contract.

```text
Evidence: The header defines no struct of function pointers; `vtable` occurs zero times in it, and a search over the whole `accesskit-c` checkout for `vtable` returns nothing. The seam is four function-pointer typedefs plus concrete per-platform constructors and methods for five platforms, with no mechanism for registering a sixth.
Subject:  AccessKit/accesskit-c @ 8b6ed37c20ed4c59390e253407983333053662ba
Source:   include/accesskit.h
Reads as: A bounded negative search at one revision. It establishes that no vtable exists and that a C caller has no registration seam. It establishes no reason for the absence and no intent about adding one.
```

**Decision:** reproduce the flat shape, add no vtable, and state the gap in one header sentence. **Cost imposed on consumers:** none. Every name, arity and signature matches upstream, so upstream's two example programs compile with only the library name changed. **Counterchoice:** a platform adapter vtable genuinely wins when the port must serve a platform upstream does not, because a sixth adapter becomes one struct literal instead of 58 new exported symbols, five new build paths and a new soname; and it wins when the only adapter author is a Zig program, because a vtable maps onto a Zig interface and a flat function set does not. The second does not apply, because the product includes the C ABI; the first does not apply today, because upstream ships no adapter for the platform this port targets first and that adapter is pure AT-SPI over D-Bus. **Grade and origin:** taste · analyst-inferred. No commit body, pull request or comment at either pinned revision states a reason and this document supplies none. **What would flip it:** a written requirement from a named C consumer.

### 2.2 Record B: typed Zig errors behind C nulls

**Priority:** keep the house rule that an API declares its own error set, without inventing a C error type upstream does not have. **Constraint:** the C signatures are fixed by the header. A `char *` getter returns `char *`, a `void` setter returns `void`, and there is no register for a status code.

```text
Evidence: The header defines no error enum, no status code and no error-returning function; a search for `accesskit_error` and `ACCESSKIT_ERROR` returns nothing. The failure signals are a null pointer, `has_value == false`, a `false` return, and process abort. The crate compiles with `panic = "abort"`.
Subject:  AccessKit/accesskit-c @ 8b6ed37c20ed4c59390e253407983333053662ba
Source:   Cargo.toml
Reads as: A source reading of the panic setting and of the header's declaration surface. It establishes that no error type exists and that an abort is the strongest upstream failure. It gives no abort-site count and claims nothing about which are reachable from valid input.
```

**Decision:** every exported function keeps the upstream C signature exactly, the Zig implementation behind it declares a narrow explicit error set, and the export is the single point where the two meet. A fragment, not a program:

```zig
fn labelZig(gpa: std.mem.Allocator, node: *const Node) error{OutOfMemory}![]const u8 {
    return node.label_storage.dupe(gpa);
}

export fn accesskit_node_label(node: *const accesskit_node) callconv(.c) [*c]u8 {
    return labelZig(declared_allocator(), node) catch null;
}
```

Six rules. The `catch` at an `export` is the only place an error becomes a sentinel; below it an error is a value and every `errdefer` runs. `null` from a string getter means the property is absent, and an allocation failure records a tag and returns `null` too, with the header naming the accessor that separates them. `false` from a predicate means the predicate answered no, because no predicate allocates. `has_value == false` means absent and nothing else. A `void` function has nowhere to put a failure, so it either cannot fail or takes a caller precondition. No `unreachable` stands for an allocation failure in any mode. **B2, the diagnostic channel:** the port adds `accesskit_last_error()`, returning a thread-local tag that every export clears on entry and sets on the failing path, valid until the next call on the same thread.

**Cost imposed on consumers:** one optional symbol and one optional enum; a consumer that never reads the accessor compiles and runs unchanged. **Counterchoice:** keep `null` ambiguous and document it as covering both, which genuinely wins in the common setting: a shim that only asks "is this label set?" and treats allocation failure as a process-level event, which is what a small adapter does and what upstream forces. The port declines that setting, because a two-meaning `null` is a documented review finding, and accepts the cost. **Grade and origin:** taste · analyst-inferred. The channel is this project's design; upstream states no position and none is attributed to it.

### 2.3 Record C: the allocator at a boundary whose signatures have no room

**Priority:** keep the house rule that an allocator is a parameter and never a global wherever a signature has room for one. **Constraint:** no C signature has room. `accesskit_node_new` takes a role, `accesskit_tree_update_with_focus` takes a node id, every string getter takes a node pointer, `accesskit_string_free` takes one `char *`.

```text
Evidence: `accesskit_node_new`, both `accesskit_tree_update_with_*` constructors, `accesskit_tree_info_new` and `accesskit_custom_action_new` each allocate and each return a handle from a signature naming no allocator. Each of the 21 string getters allocates a fresh `char *`. `accesskit_node_custom_actions` allocates a pointer array and deep-copies every action. No signature in the header mentions an allocator.
Subject:  AccessKit/accesskit-c @ 8b6ed37c20ed4c59390e253407983333053662ba
Source:   include/accesskit.h
Reads as: A source reading of the signature list at that revision. It establishes that no allocator parameter exists. It says nothing about where allocations come from inside the library or how many there are.
```

**Decision, in two halves.** The **Zig layer** takes `gpa: std.mem.Allocator` first on every allocating function, every handle stores the allocator it was created with, and every teardown releases through the stored allocator. The **C layer** reads one declared slot, set by a new `accesskit_set_allocator(alloc, free, context)`. That slot is declared, not reached for: it has a name, a documented default, a documented scope and exactly one writer, which is the labelled form of the distinction in `io.md` topic 12. The default is the C allocator. Only the `*_new` family, the 31 string-returning functions, the 7 `*_debug` functions and the custom-actions getter and its free need an injected allocator.

**Cost imposed on consumers:** a consumer that wants the library's memory from its own arena installs two function pointers once; a consumer that does nothing gets the C allocator and must still release only through the `*_free` functions, because calling `free` on a library pointer is not part of the contract. **Counterchoice:** widening the C signatures so every allocating entry point takes an allocator genuinely wins when the sole consumer is a Zig program using the C surface as an intermediate, or when the library must run under a hard memory ceiling that only a counting allocator honours. The port declines it, because it breaks every existing C caller at once and the house rule is delete rather than deprecate, so a widened signature cannot ship beside the old one. **Grade and origin:** obligation · house-rule, applied where the rule cannot reach unaided. The two-half split is my judgment; the rule is the project's, from `AGENTS.md` section 2.

### 2.4 Record D: the exported symbol prefix

**Priority:** let a C consumer drop this library into an application that already links upstream, and let the header, the linker and the library agree on one spelling. **Constraint:** upstream exports `accesskit_*` and nothing else, this package is named `zaccesskit`, and a prefix is the cheapest part of an ABI to change later and the most expensive to change now. **Decision: keep `accesskit_`.** A migrating consumer must not have to touch 496 call sites; the prefix is part of the export list the header implies, so renaming it means the port can no longer export upstream's names and a binary linking both cannot be built; and the package name is a Zig identifier a C consumer never sees. The artefact is `libzaccesskit.so` and the header is `zaccesskit.h`.

**Cost imposed on consumers:** a consumer that greps for `accesskit_` finds the symbols, one that greps for `zaccesskit_` finds only the artefact name. **Counterchoice:** renaming every symbol to `zaccesskit_` genuinely wins when one process links two accessibility libraries and the upstream prefix would collide, or when a downstream distribution insists that a shipped library not export another project's namespace. The second is a real requirement for some distributors and is a licensing and trademark question, not a technical one. The cost is that every existing C consumer recompiles against a different header and relinks every object. The port declines both and records that a distributor needing the rename can get it from a version script without a source change. **Grade and origin:** taste · analyst-inferred. Nothing at either pinned revision states a reason for the prefix.

### 2.5 Record E: aggregates passed and returned by value

**Priority:** make a C caller of `accesskit_affine_inverse` get the value it gets from upstream, on every target the port claims. **Constraint, measured from the header on 2026-10-05:** **103** declarations return a struct by value, 102 of them on a Linux target and 1 behind `_WIN32` (`accesskit_windows_adapter_handle_wm_getobject`, returning `accesskit_opt_lresult`). `accesskit_last_error` is not one of the 103: it returns `accesskit_error`, a bare-tag C enum, not a struct. **42** declarations take at least one aggregate by value, **58** aggregate parameters in all, across **9** types; **28** both return and take by value. Those are the figures by value, and by value is what this record is about. The larger figures — 57 declarations, 77 parameters, 11 types, 31 on both sides, 105 returning — are **by value plus by pointer** and are recorded here only so a reader who meets them elsewhere knows what they are: 444 declarations, 449 parameters and 22 types cross a struct by pointer, which is a different ABI fact, because only the address is contract. Nine return `accesskit_affine` at 48 bytes and align 8, which is past the aggregate return budget on the x86-64 System V convention, so the result travels through a hidden pointer and every named argument shifts. `accesskit_affine_inverse` takes one 48-byte aggregate and returns another; `accesskit_affine_mul` takes two and returns one. Sections 9.3 and 9.4 record the correction and the reconciliation with `docs/40`.

```text
Evidence: A masked lexical scan of `include/zaccesskit.h` on 2026-10-05, cross-checked against `cc -E -P` on the same file: 498 unique declarations, of which 103 return a `struct accesskit_*` by value, 42 take at least one such aggregate by value, 58 aggregate parameters in all across 9 types, and 28 both return and take by value. A separate scan of the same declarations classifying *pointers to* structs gives 444 declarations, 449 parameters and 22 types. Nine return `accesskit_affine` by value and eleven return `accesskit_rect`. The method, the per-type censuses and the derivation of the superseded 57 / 77 / 11 / 31 / 105 figures are in `docs/40-capi-build-map.md` sections 1.2 and 3.4. The upstream header `accesskit-c/include/accesskit.h` at `8b6ed37c20ed4c59390e253407983333053662ba` is **not in this tree**, so no upstream figure is claimed here; the earlier `104 / 57 / 77 / 11 / 31` reading came from the same pointer-blind classifier and is withdrawn rather than restated. An `extern struct` has in-memory layout matching the C ABI for the target, and `export` makes a function externally visible and makes it use the C ABI.
Subject:  AccessKit/accesskit-c @ 8b6ed37c20ed4c59390e253407983333053662ba
Source:   include/zaccesskit.h (the pinned upstream header at the named revision is not vendored in this tree)
Reads as: A text count of the declarations, which establishes that they exist and how many. It establishes no register assignment and no lowering behaviour. The Zig sentences are read from `doc/langref.html` at `ziglang/zig @ 24fdd5b7a4c1c8b5deb5b56756b9dbc8e08c86a8, stable-0.16`; they settle layout and the convention of an exported function, and say nothing about aggregate classification, hidden return pointers or stack layout.
```

**What this cannot settle.** How Zig 0.16.0 lowers an `extern fn` or `export fn` returning an `extern struct` of 48 bytes is not established here. The installed toolchain ships `lib/` and the `zig` binary but not the compiler's `src/`, so the ABI classifier and the per-architecture generators cannot be cited from this checkout. `docs/19-geometry-and-text.md` section 2.3 records the register assignment as an explicit inference and says it was not verified.

**Decision:** every by-value aggregate on this boundary is an `extern struct` in Zig, never a plain `struct` and never a `packed struct`. The choice is load-bearing for the convention and not only for the layout: a plain `struct` is free to reorder, and `docs/19` measured `packed struct` at align 16 for the 16-byte and 32-byte geometry types. The port does not rely on that difference being harmless to a classifier. **Cost imposed on consumers:** none; a C consumer cannot observe this. **Counterchoice:** a hand-written C shim owning the 48-byte affine entry points genuinely wins in one setting: if Zig 0.16.0 lowers a 48-byte aggregate return wrongly for a target in the cross matrix, the C compiler's convention is correct by definition. The cost is real: nine return sites and seven affine parameter sites move to C, the header grows a second set of declarations, and the artefact becomes a rung-4 shim, which `AGENTS.md` section 1.3 forbids unless a written cause names it. The cause would be a compiler defect this document has not observed, so the shim is declined as the default and named as the fallback; check 5 in section 6 decides. **Grade and origin:** obligation on the layout half, which `docs/19` measured; taste · analyst-inferred on the shim fallback, because no compile has tested the lowering on any target.

---

## 3. Ownership and teardown, call by call

One row per ownership category. The last column carries the sentence identifier from section 4.4, so the table and the header cannot drift apart.

| # | Category | Owner after the call | Who must call what | Once | A second call |
|---|---|---|---|---|---|
| 1 | An aggregate returned by value: all 103 declarations that return a struct by value, including the 12 whose interior pointer borrows | The caller, outright. It borrows nothing | Nothing | Read as often as it likes | Reading again is fine. Nothing to release twice |
| 2 | `accesskit_node_ids` from the 8 node-id-list getters; `accesskit_lengths` from the 2 byte-slice getters; `accesskit_opt_coords` from the 2 float-slice getters. In all three `values` borrows | The node owns the array; the caller owns the returned struct | Nothing | As row 1 | Releasing `values` frees storage the node still owns |
| 3 | The array or `char *` a setter receives, with or without a length | The caller, before and after | Nothing. The setter copies | n/a | n/a. The input is never retained |
| 4 | The `char *` a string getter returns | The caller | `accesskit_string_free` | Once | Double free |
| 5 | `accesskit_custom_action` from `accesskit_custom_action_new` | The caller | `accesskit_custom_action_free`, unless ownership passes to row 6 | Once | Double free |
| 6 | `accesskit_custom_action` passed to `accesskit_node_push_custom_action` | The node | Nobody. `accesskit_node_free` releases it | Once per action | Releasing it after the push frees memory the node owns |
| 7 | The array and every action in `accesskit_node_set_custom_actions` | The caller. The node deep-copies both | Each action with `accesskit_custom_action_free`, the array itself | Once each | Double free |
| 8 | `accesskit_node` from `accesskit_node_new`, and `accesskit_tree_update` from its two constructors | The caller | The matching `*_free`, unless ownership passes to row 9 | Once | Double free |
| 9 | `accesskit_node` passed to `accesskit_tree_update_push_node` | The tree update | Nobody. `accesskit_tree_update_free` releases it and every node still held | Once per node | Releasing it after the push frees memory the update owns |
| 10 | The `accesskit_tree_info` passed to `accesskit_tree_update_set_tree_info` | The tree update | Nobody, and the caller must not release it | Once per tree info | A second call with the same pointer dereferences consumed storage |
| 11 | A tree info already on an update, when `set_tree_info` runs twice or `clear_tree_info` runs | The update, until it is released | Nobody | n/a | Both calls are valid; the first tree info goes with the update or the second set |
| 12 | The opaque `accesskit_tree_update` that the tree-update factory returns | The library owns the transferred handle | Nobody. Conversion consumes it on success and error | Once | Never return the same owning pointer twice. Existing platform null-factory behavior remains unchanged |
| 13 | The opaque `accesskit_tree_update` that the activation handler returns | The library owns each nonnull transferred handle | Nobody. `null` means "no tree". An unused nonnull payload is discarded | Once | Never return the same owning pointer twice |
| 14 | The `accesskit_action_request` the action handler receives | The callback, by transfer | `accesskit_action_request_free`, before returning | Once | Double free |
| 15 | The `char *` at `request->data.value.value` when the tag is `ACCESSKIT_ACTION_DATA_VALUE` | The request | Nobody separately | Once, with row 14 | Double free of the string |
| 16 | Every `*_free`: 17, counted at `8b6ed37` — 1 node, 1 tree-info, 1 tree-update, 2 custom-action, 1 action-request, 1 string, 10 platform | Nobody, after the call | The matching free function | Once | Double free. `null` terminates the process |
| 17 | Every `*_queued_events` handle, 4 of them | The caller, until raised | The matching `*_queued_events_raise`, which also releases it | Once | Use after free |
| 18 | The `void *` from the 5 object-returning platform accessors | The platform object. Ownership does not transfer | Nobody | n/a | Reading after the platform releases the object follows the platform's rule |
| 19 | The `class_name` for the macOS focus forwarder | The caller | Nobody. The library reads the bytes and keeps its own copy | n/a | n/a. Upstream's comment says the opposite and is wrong. Section 5.3 |

**Why row 1 is not row 2.** They look alike and they are different categories, so the header must not use one sentence for both. A value returned by aggregate borrows nothing and the caller has no duty; row 2 carries a keep-alive duty instead. Conflating them produces either a free of node storage or a leaked keep-alive. **Where the port adds words upstream has none:** rows 2, 7, 10, 14, 15, 17 and 19. Each becomes one sentence in section 4.4.

```text
Evidence: The 8 node-id-list getters return `struct accesskit_node_ids` by value and their setters carry only "Caller is responsible for freeing values." No comment states that a returned array borrows from the node, and no free function exists for `accesskit_node_ids`, `accesskit_lengths` or `accesskit_opt_coords`. `accesskit_tree_update_set_tree_info` carries no comment. `accesskit_action_request_free` does not mention the `char *` in the union. The four `*_queued_events_raise` comments each say only that memory is also freed. Against that, `accesskit_tree_update_set_tree_info` dereferences the raw pointer and moves the value into the update, `Drop for action_data` calls `accesskit_string_free` on the `Value` variant, `accesskit_custom_actions_free` calls `Vec::from_raw_parts` with `length` as the capacity, `array_setter` copies the caller's slice and never releases it, and `to_box` carries `assert!(!ptr.is_null())`.
Subject:  AccessKit/accesskit-c @ 8b6ed37c20ed4c59390e253407983333053662ba
Source:   include/accesskit.h, src/common.rs, src/lib.rs
Reads as: A source reading of the header comments and of five declarations in two bindings files, at one revision. It establishes the documentation gaps and what those declarations do to memory. It establishes no thread safety, no other target, no claim about what a caller observes after an abort, and no promise that upstream keeps these bodies.
```

### 3.1 Callback handle conversion and metadata

`boundary.CTreeUpdate` names the opaque C handle, not `schema.TreeUpdate`.
All five adapters consume this handle through `tree_update.LiveMetadataOwners.consume`.
Conversion releases the outer handle through its captured allocator on success and error.
Native adapter apply methods receive `schema.TreeUpdate` after conversion.

Conversion moves the `NodeEntry` array without allocation or copying only when the allocator-domain helper proves the same domain.
Known stateless standard allocators and C ABI registered allocator pairs permit that proof.
The known stateless providers in Zig 0.16.0 are `c_allocator`, `page_allocator`, and `smp_allocator`.
`allocation.sameDomain` takes one options struct with source and destination allocators.
Conversion must not compare an undefined allocator context pointer.
For unknown custom vtables, conversion migrates the array without reading the context pointer.
Different initialized stateful contexts also require array migration.
Migration changes only the array allocator, not each node's property allocator.
Conversion retains the owning tree-info storage while the native tree borrows it.

Three fixed owner slots cover committed, working, and incoming metadata.
`TreeState.info` and `next_state.info` are the two possible native borrowers.
`SubtreeState` has only root and focus fields. It has no metadata borrower.
After each update attempt, including errors, the adapter prunes owners by nonempty storage identity.
Equal text does not imply equal storage.
The adapter destroys the native tree before the retained metadata owners.

Unix keeps factory-before-activation order.
It discards a nonnull activation payload that does not replace the committed tree.
macOS retains metadata in its reference-counted `Context`.
Queued events keep that context alive after adapter destruction.
These contracts do not claim native platform execution or Unix bus delivery.

The C artifact requires LLVM on Zig 0.16.0. `build.zig` sets `.use_llvm = true` for that artifact only.
The self-hosted x86 Debug backend failed five linked-C geometry result checks.
The LLVM Debug C artifact passed all 1676 checks with zero failures.
This backend selection does not fix the PowerPC64 C ABI limit.
[Issue #5](https://github.com/CoffeeImpliesCode/zaccesskit/issues/5) records the Zig 0.17 migration check before that limit can change.

### 3.2 Empty C arrays

`marshal.cArrayToSlice` returns an empty slice before it dereferences a zero-length C pointer.
Eligible setters accept `NULL, 0`.
This rule covers eight node-id lists, two byte lists, two coordinate lists, and custom actions.
The setter still copies nonempty input.
This rule does not permit a null pointer with a nonzero length.
An owning custom-action getter result needs its matching free, including an empty result.

---

## 4. The header as an authored artefact

### 4.0 A data-carrying enum is the largest ABI risk on this boundary

**The two classes the header already separates.** 18 enums and 270 variants, counted from the header at the pin. The header draws the line itself, by aliasing 17 of the 18 and not the eighteenth.

| Class | Enums | Variants | Zig form |
|---|---|---|---|
| **Bare tag.** `enum NAME { … }` with no base under C, `: uint8_t` under C++, and `typedef uint8_t NAME;` under `#ifndef __cplusplus` | 17 | 262 | `enum(u8)` |
| **Payload-carrying.** `typedef enum accesskit_action_data_Tag { … }` with no alias, the first member of `accesskit_action_data` | 1 | 8 | `extern struct` with a tag field and an `extern union` payload |

| Bare-tag enum | Declared | Alias | Variants | Bare-tag enum | Declared | Alias | Variants |
|---|---|---|---|---|---|---|---|
| `accesskit_action` | 64 | 149 | 22 | `accesskit_role` | 278 | 485 | 182 |
| `accesskit_aria_current` | 152 | 166 | 7 | `accesskit_scroll_hint` | 492 | 505 | 6 |
| `accesskit_auto_complete` | 169 | 179 | 3 | `accesskit_scroll_unit` | 512 | 529 | 2 |
| `accesskit_has_popup` | 182 | 194 | 5 | `accesskit_sort_direction` | 532 | 542 | 3 |
| `accesskit_invalid` | 203 | 213 | 3 | `accesskit_text_align` | 545 | 556 | 4 |
| `accesskit_list_style` | 216 | 232 | 6 | `accesskit_text_decoration_style` | 559 | 571 | 5 |
| `accesskit_live` | 235 | 245 | 3 | `accesskit_text_direction` | 574 | 585 | 4 |
| `accesskit_orientation` | 248 | 263 | 2 | `accesskit_toggled` | 588 | 598 | 3 |
| | | | | `accesskit_vertical_offset` | 601 | 610 | 2 |

The 18th, `accesskit_action_data_Tag` at line 1009, has 8 variants, no alias, and heads the only anonymous union in the header.

```text
Evidence: 17 enums are declared as `enum NAME { … }` followed under `#ifndef __cplusplus` by `typedef uint8_t NAME;`, and one, `accesskit_action_data_Tag`, is declared as `typedef enum … { … }` with no alias. `accesskit_action_data` is the only anonymous union: a `tag` member followed by eight anonymous structs. The 17 aliased enums carry 262 variants and the tag enum carries 8. The core declares `#[repr(C)] pub enum ActionData` with those eight payload variants including `Value(Box<str>)`, and the bindings declare a `#[repr(C)]` mirror with `Value(*mut c_char)`, a `Drop` that releases that string, and a `From` implementation that converts variant by variant.
Subject:  AccessKit/accesskit-c @ 8b6ed37c20ed4c59390e253407983333053662ba
Source:   include/accesskit.h, and accesskit/src/lib.rs at AccessKit/accesskit @ 466e24e252103f4d82bd6fbab98141b551e46e0c
Reads as: A text count of the declarations at those revisions. It establishes the split, the line numbers and the variant counts. It says nothing about how any compiler sizes an enum with no fixed base, and `repr(C)` on a data-carrying enum is a Rust guarantee this document has not measured on any target.
```

**A trap inside the bare class that the port's header must close.** The alias is `uint8_t` while the enumerator names belong to a separate, unbased `enum`. Two C types, two sizes, measured on this host: `sizeof(enum accesskit_action)` is 4 and `sizeof(accesskit_action)` is 1. The type comment in section 4.4.2 closes it.

**The layout rule, stated so it can be checked.** The Zig form must satisfy three conditions against the C struct: `@sizeOf` equal; `@alignOf` equal, so `sizeof(T) % @alignOf(T) == 0` for an array; and the tag at offset 0 with every payload member at or after the first offset satisfying its own alignment. The assertions a conformance test carries, as text to write rather than a program, are below, with the measured numbers.

```zig
comptime {
    // A C enum with no fixed base has an implementation-defined size, so the port
    // pins it and the test pins the pin.
    std.debug.assert(@sizeOf(ActionDataTag) == 4);
    std.debug.assert(@alignOf(ActionDataTag) == 4);
    // The payload covers the largest and the strictest member.
    std.debug.assert(@sizeOf(ActionDataPayload) == 32);
    std.debug.assert(@alignOf(ActionDataPayload) == 8);
    // Tag first, payload second.
    std.debug.assert(@offsetOf(ActionData, "tag") == 0);
    std.debug.assert(@offsetOf(ActionData, "payload") == 8);
    std.debug.assert(@sizeOf(ActionData) == 40);
    std.debug.assert(@alignOf(ActionData) == 8);
    // The enclosing optional and request.
    std.debug.assert(@offsetOf(OptActionData, "has_value") == 0);
    std.debug.assert(@offsetOf(OptActionData, "value") == 8);
    std.debug.assert(@sizeOf(OptActionData) == 48);
    std.debug.assert(@offsetOf(ActionRequest, "data") == 32);
    std.debug.assert(@sizeOf(ActionRequest) == 80);
    std.debug.assert(@sizeOf([4]ActionData) == 160);
}
```

**What is measured and what is not reached.** Two probes, both outside this repository, both recorded so a reader can rebuild them. The scratch tree was removed after the run. The C probe compiled the **real** `include/accesskit.h` at the pinned revision with `cc -std=c11 -O0`, `cc (SUSE Linux) 15.3.0`, x86-64 Linux: **runtime observation**. The Zig probe declared the candidate form `extern struct { tag: c_uint, payload: ActionDataPayload }`, where `ActionDataPayload` is an `extern union` of the 8 payload members, and printed the numbers from a running binary at Zig 0.16.0 in Debug: **exercised compilation plus runtime observation**. Both reported the same values: the tag enum 4/4, the action data 40/8 with the tag at 0 and every payload member at 8, the optional action data 48/8 with `has_value` at 0 and `value` at 8, the action request 80/8 with `data` at 32, `[4]` of the action data at 160, and `c_uint` 4/4. The Zig probe also reported a bare `extern union` at 32/8 and a `union(enum)` at 40/8.

| Assertion | Status |
|---|---|
| Every `@sizeOf`, `@alignOf` and `@offsetOf` above | measured on this host by both probes |
| `[4]` at 160, so no tail padding | measured |
| `ActionDataTag` at 4, the tag being `c_uint` | measured here, and the number most likely to move |
| The same numbers through the conformance test, on a foreign row, or in another optimize mode | **not reached.** No `include/zaccesskit.h` and no conformance test exist yet; both probes ran on the host in Debug |
| That Zig lowers a `union(enum)` differently from the C struct | **not established.** `union(enum)` measured 40/8 here, the same number. A coincidence, and the reference states no C layout for `union(enum)` |

That last row is why this is the largest risk and not a routine one: a reviewer who measured only the size would ship `union(enum)` and rely on a coincidence. `packed struct` is not an option. For the geometry types the reason is measured elsewhere: Zig 0.16.0 rejects `packed structs cannot contain fields of type '[6]f64'`. For this type the reason is structural rather than measured, because a packed struct discards the padding that puts the payload at offset 8, and the port has not measured a packed struct around an `extern union`. That is recorded as unmeasured, not as a refusal.

**Record F: the representation of a data-carrying enum.** **Priority:** keep the C bytes identical to upstream, so a C consumer's action handler reads `request->data.value.value` and it works. **Constraint:** Zig has no construct that is a `repr(C)` data-carrying enum. `extern union` has no tag, `union(enum)` has a tag and no C layout, and the port must pin the tag width because the C tag enum has no fixed base. **Decision:** two representations and one hand-written conversion at the boundary. The Zig core keeps `union(enum)`, which is honest and matches on variants cheaply; the C boundary type is `extern struct { tag: c_uint, payload: ActionDataPayload }` with `payload` an `extern union`; one conversion function per direction, exactly as the bindings crate already does. **Cost imposed on consumers:** nothing. The C bytes and the C source are unchanged, and the port pays one conversion pair, one pinned tag width and eleven assertions. **Counterchoice:** exposing a pointer-free Zig tagged union at the boundary too genuinely wins when the payload set grows, because a `union(enum)` is one new field while an `extern union` and its eleven assertions must all be edited. The port declines it, because a boundary type must have the C layout by construction and `union(enum)` is measured here only by coincidence. **A second counterchoice:** rejecting the data-carrying shape and splitting the API, so the C surface carries a tag plus separate scalar parameters, genuinely wins when the payload set is volatile enough that adding a variant is a wire break anyway, because a consumer can never read a member the tag does not name. It costs every existing C consumer a rewrite of its action handler, and the house rule is delete rather than deprecate. **Grade and origin:** obligation on the layout half, which the probes measured on one host; taste · analyst-inferred on the choice of two representations, because no Zig 0.16.0 build in this repository has reached either.

### 4.1 The shim conclusion this section re-opens

`docs/22-zig-build-surface.md` section 3.7 lists four constructs that force a hand-written C shim: a bitfield in a public struct, a variadic export, a macro a C consumer needs at compile time, and a macro the translator cannot render. None occurs in `accesskit.h`, so that document concluded no shim is needed. That was right about the four it checked and it generalised without checking a fifth. Aggregate passing was never examined, and section 2.5 shows it is not rare. **The declaration half is answered**, because `translate-c` carries all 496 declarations. **The convention half is open**, because nothing settles how Zig 0.16.0 lowers a 48-byte aggregate. Check 5 in section 6 decides, and record E names the fallback.

This document does not edit `docs/22-zig-build-surface.md`, because this run's file boundary forbids it. The correction for that document's owner is: replace the section 3.7 conclusion with a statement that the four checked constructs are absent, that aggregate passing was not among them, and that the shim decision is open pending check 5.

```text
Evidence: The standard library carries a commented-out `getEmittedH` call with the Zig issue number above it, `InstallArtifact.Options` still has an `h_dir` field, and nothing ever sets `emitted_h`. `Step.Compile.installHeader` exists, takes a source path and a destination relative path, and adds the installation to the include tree.
Subject:  ziglang/zig @ 24fdd5b7a4c1c8b5deb5b56756b9dbc8e08c86a8, stable-0.16
Source:   lib/std/Build/Step/InstallArtifact.zig
Reads as: A source reading of the standard library at the 0.16.0 tag. It establishes that there is no working generated-header route and that a checked-in header installs. It says nothing about a future Zig release, and no build in this repository called either function.
```

### 4.2 Record G: how the header lives

**Priority:** give one artefact a C consumer includes, that the Zig side can be checked against, and this repository can answer for. **Constraint:** `-femit-h` is broken on Zig 0.16.0 and the standard library's fallback is commented out, so there is no toolchain-supported generated header; the zero-Rust rule forbids cbindgen, which is how upstream produced its header; and `AGENTS.md` section 3.1 permits a checked-in hand-written header or one generated by a Zig comptime generator under `tools/`. **Decision:** `include/zaccesskit.h` is checked in, hand written, and installed with `Step.Compile.installHeader`; the Zig `extern struct` declarations are also hand written; a conformance test keeps the two in step. Three options and their costs. **A, hand-written and checked in:** the header is correct on its own or it is wrong, and nothing in the build catches the difference; the mitigation is the sweep in section 4.3. **B, one comptime declaration table with two emitters:** drift is impossible by construction, but the table is a second description of the ABI a reviewer must read before either artefact, plus two emitters, plus generated `.zig` the house disfavours. **C, a generated header from a comptime generator under `tools/`:** the header becomes a build output, is not reviewable as source, and is a third artefact in the tree. **Cost imposed on consumers:** none; both surviving options install one header at one include path. **Counterchoice:** option B genuinely wins when the surface is large enough that 496 hand-written declarations and 40 hand-written layouts are two places to update for every change, and when both artefacts are consumed by third parties who cannot see each other. The port declines it for a specific reason rather than a general one: the Zig declarations need not be hand-written at all if the sweep is the enforcer, so option A ships one artefact fewer. The choice flips if the conformance test is deleted, and section 8 records that as a named condition rather than an open question. **Grade and origin:** taste · analyst-inferred, under the constraint that the toolchain has no generated-header route. The prohibition on cbindgen is the project's own rule, from `AGENTS.md` section 1.2.

### 4.3 Record H: the rule that keeps the header and the Zig types in step

**Priority:** make a disagreement between the shipped header and the Zig declarations a build failure rather than a run-time defect. **Constraint:** the two artefacts cannot be derived from one another in the shipped module, because a shipped module must not run `zig translate-c` on every consumer's build, so nothing in the compiler ties them together and a wrong field order is invisible until a C caller reads a field and gets a different number. **Decision:** the header-parity sweep, at the name-paired full-sweep grade, in the test module only. One list, `pub const sweep`, is the single home of what to check. The test module alone does `@cImport` of `include/zaccesskit.h`; the shipped module never compiles C. The sweep walks the list by reflection, so a struct the list forgets is a build failure rather than silence.

| Kind | Compared | Why not less |
|---|---|---|
| Struct | Every field by **name** and its own `@offsetOf`, plus whole-type `@sizeOf` and `@alignOf` | Position pairing misses a same-size field swap |
| Scalar | `@sizeOf`, `@alignOf`, signedness, integer versus float | A size-only check accepts `u32` against `i32` |
| Enum | Each enumerator reconstructed from the upstream prefix plus the field name | A tag count misses a renumbering |
| Function | Arity and full signature, parameter by parameter | Arity alone misses a swapped pair |
| Callback typedef | Signature-deep | A name-only check misses a changed parameter |
| Opaque handle | Identity and alignment only | No layout exists to compare |

Four exclusions make it a check rather than a ritual, and each is a refusal to guess: a declaration the classifier cannot place is a compile error; an expectation whose name matches no rule is a compile error; a self-check runs, because a sweep that matched nothing is otherwise indistinguishable from one that matched everything; and the four `translate-c` hazards are pinned at **zero**, so a future change introducing one fails the build until someone raises the count deliberately. The aggregate count from record E is not pinned at zero, because 42 declarations cross a struct by value today; it is pinned as a number the sweep must cover, and the self-check catches a regression in that coverage. The by-pointer figure — 444 declarations — is not swept against the calling convention at all, because a pointer crosses as an address and no register assignment depends on the pointee's layout.

**What it proves:** that the hand-written Zig declarations and the shipped header agree, on the target and configuration the test ran, over the declarations the list names, paired by name. **What it does not prove:** that the foreign code ran; that every declaration was analysed, since a declaration no reached path references is never analysed; that the aggregate convention agrees, because a sweep compares layout and a register assignment is not layout; portability to another target or compiler. **A better candidate, and why this one is still chosen:** a C fixture that `static_assert`s every size and offset and links the shipped library proves more, because it uses the C compiler's own answers, and it exists as check 3 in section 6. It cannot replace the sweep, because it runs only when the test runs and a sweep is the cheaper thing to extend when a field is added. **Cost imposed on consumers:** none. **Counterchoice:** no sweep at all genuinely wins when the ABI is small enough that one reviewer reads both artefacts on every commit and the package has no test step. That is not this package. **Grade and origin:** obligation, carried from the four-grade table in `special-cases.md` recipe 1. This document chose the grade; the recipe states the mechanisms and what each misses.

### 4.4 The sentences the header carries

Every block below is the text to ship, on the declaration named by the marker in front of it. Each answers a row of the consumer checklists in `documentation.md` section 3. Method row 4 is the one a signature cannot carry: an error union names the failure, not the residue, so every failure path states what survives.

#### 4.4.1 The file block

```c
/**
 * Copyright 2023 The AccessKit Authors. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (found in the LICENSE-APACHE
 * file) or the MIT license (found in the LICENSE-MIT file), at your option.
 *
 * Portions of the role list and of the role descriptions derive from Chromium.
 * See LICENSE.chromium and NOTICE.md.
 *
 * `zaccesskit` is a pure Zig port of AccessKit and this header is its whole C
 * surface. Include it, link `zaccesskit`, and call the functions below. Zig 0.16.0.
 * The declarations behind a platform guard are absent elsewhere.
 */

/*
 * This header declares no platform registration mechanism. The library links the
 * platform adapters it ships, and a C caller cannot supply one. A caller that needs
 * a platform this library does not ship must build its own tree and use the Zig
 * surface instead.
 *
 * Every handle here is owned by the caller until a `push` or a `set` transfers it, a
 * `*_free` releases it, or it is handed to a callback. The tables in section 3 of
 * `docs/31-c-abi-design.md` name which is which for every function.
 *
 * Every `void` function either cannot fail or takes its failure as a precondition on
 * the arguments. There is no status code and no exception channel, and this library
 * does not check preconditions at run time.
 *
 * Several hundred functions take or return a struct by value, and nine return a
 * 48-byte `accesskit_affine`. That is a property of the calling convention, not only
 * of the layout: such a value is classified, then passed in registers or on the
 * stack, and a caller built against a different classification corrupts its own
 * stack rather than receiving a wrong number. A consumer that compiles this header
 * with a C compiler and links the library built by the same Zig toolchain version has
 * a matching convention by construction. A consumer that hand-writes the prototypes
 * does not.
 *
 * `accesskit_last_error()` reports the failure tag from the most recent call on the
 * calling thread. Every function clears the tag on entry and sets it on the failing
 * path, so read it immediately after the call that failed. A `null` or `false`
 * return with `ACCESSKIT_ERROR_NONE` means the property was absent, not that an
 * allocation failed.
 */
```

```text
Evidence: The shipped upstream header opens with an AccessKit Authors notice naming the Apache and MIT files. A search for `The Chromium Authors` across the bindings checkout returns the licence file alone, so no Chromium or Flutter copyright line appears in the header, although the header embeds role prose taken from a BSD-3-Clause source file in the core repository.
Subject:  AccessKit/accesskit-c @ 8b6ed37c20ed4c59390e253407983333053662ba
Source:   include/accesskit.h
Reads as: A source reading of the notice block plus one bounded search. It establishes that upstream ships an Apache-or-MIT notice and no Chromium notice. It reaches no legal conclusion; `docs/21-licensing.md` sections 3.6 and 5.4 own that, and a notice block with no shipped files is not compliance.
```

#### 4.4.2 Type comments

```c
/* every one of the 23 `accesskit_opt_*` structs */
/**
 * An optional value. `has_value` is false when the property is absent; read
 * `value` only when it is true. The port writes a zero value into `value` in the
 * false case, so a reader who ignores the flag reads a defined zero rather than
 * uninitialised storage. That is a diagnostic aid, not a contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one needs
 * no release, and no operation invalidates the other copy.
 */
/* `accesskit_tree_id` */
/**
 * A 128-bit identifier for a tree, as a UUID in big-endian byte order.
 * `ACCESSKIT_TREE_ID_ROOT` is the all-zero identifier. This type is copied by value
 * in every signature that uses it, so no release is owed.
 */
/* every one of the 17 bare-tag enums, `accesskit_action` shown */
/**
 * An `ACCESSKIT_ACTION_*` value.
 *
 * Spell the type `accesskit_action`, never `enum accesskit_action`. The bare enum
 * has no fixed base and no fixed size, while the typedef is one byte. A struct that
 * spells the bare name has a different layout from this header.
 *
 * The first enumerator is 0 and the values are contiguous. They are wire values: the
 * serialised role and action numbers are the enumerator numbers, so reordering or
 * renumbering this list changes the wire format.
 */
/* `accesskit_action_data_Tag` */
/**
 * The discriminant of `accesskit_action_data`.
 *
 * This enum has no `uint8_t` alias and no fixed base, so its size is set by the C
 * compiler. Do not spell this type in a struct; use `accesskit_action_data`.
 */
/* `accesskit_action_data` */
/**
 * The payload of one action request.
 *
 * Read `tag` first. Every other member is a union, so at most one member is
 * meaningful at a time and reading a member the tag does not name is undefined
 * behaviour. The `value` member is a `char *` owned by the enclosing
 * `accesskit_action_request`; the caller never receives or releases it separately.
 */
```

#### 4.4.3 Method comments

```c
/* the 12 getters whose returned struct carries a borrowing pointer, table row 2 */
/**
 * Returns the node identifiers for `children`.
 *
 * `values` points into storage this node owns: the node must stay alive and its
 * child list unmodified for as long as the caller reads `values`. There is no
 * function to release `values`, because the caller does not own it. An unset
 * property gives `length == 0` with a non-null `values`.
 */
/* the 21 string getters and the 7 `*_debug` functions, table row 4 */
/**
 * Returns a copy of the `label` property, or `null` when the property is unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to `free`, and
 * never release a string this library did not return. A `null` return covers two
 * cases, the property being unset and the copy not fitting in memory;
 * `accesskit_last_error` tells them apart. Nothing survives the second case.
 */
/* `accesskit_tree_update_set_tree_info`, table row 10. This is a gap upstream */
/**
 * Attaches `tree` to the update. Takes ownership of `tree`.
 *
 * The caller must not release `tree` after this call and must not pass it again. A
 * second call with the same pointer is a use-after-free, because the first call
 * consumed it. Passing `null` stores no tree info, the same state as
 * `accesskit_tree_update_clear_tree_info`; this one does not abort on `null`.
 */
/* `accesskit_action_request_free`, table row 15. This is a gap upstream */
/**
 * Releases the request and everything it owns, exactly once.
 *
 * When `request->data.has_value` is true and `request->data.value.tag` is
 * `ACCESSKIT_ACTION_DATA_VALUE`, this releases the `char *` at
 * `request->data.value.value` as well. Do not release that string separately.
 */
```

The remaining families carry the same shape with the names swapped, so only their
variable text differs.

- **`accesskit_node_new` and the four other constructors, table row 8.** "Returns a new node with `role` set, or `null` when the allocation failed. The caller owns the node and releases it with `accesskit_node_free`, once, unless ownership passes to `accesskit_tree_update_push_node`. Call `accesskit_last_error` after a `null` return. Nothing is allocated on the failure path."
- **`accesskit_node_free` and every other `*_free`, table row 16.** "Releases the node and every string it owns. The allocator that created it is not released. The node is unusable after this call and a second call on the same pointer is a double free. Passing `null` terminates the process."
- **The 8 array setters and the 4 slice setters, table row 3.** "Copies `length` identifiers from `values` into the node. Nothing is retained. `values` may be `null` when `length` is 0 and must not be `null` otherwise. The caller keeps ownership of the array. On success `children` is exactly the copied identifiers. There is no failure path, so nothing partial can survive."
- **The 21 string setters and their `_with_length` variants, table row 3.** "Copies `length` bytes from `value` into the node. Nothing is retained. `value` need not be null-terminated. A byte string is stored up to the first null byte, because a value holding one cannot come back out of a `char *` getter without losing its tail. The caller keeps the buffer. There is no failure path."
- **`accesskit_node_push_custom_action` and `accesskit_tree_update_push_node`, table rows 6 and 9.** "Appends `action` to the node's custom action list. Takes ownership of `action`. The caller must not release `action` after this call and must not pass it again. There is no failure path, so the list is never left half-appended."
- **`accesskit_node_custom_actions` and `accesskit_custom_actions_free`, table row 7.** "Returns a deep copy of the node's custom actions, or `null` when the allocation failed. An empty list has `length == 0`, never a `null` result. Release the result with `accesskit_custom_actions_free`, once. That function releases the array, every action in it, and the outer struct. Nothing in the returned value borrows from the node, so the node may be released first."
- **`accesskit_node_set_custom_actions`, table row 7.** "Copies every action in the array into the node. Takes ownership of nothing. The caller keeps the array and every action in it, releases each action with `accesskit_custom_action_free`, and releases the array itself afterwards. There is no failure path."
- **The four `*_queued_events_raise` functions, table row 17.** "Raises the queued events and releases the handle. Memory is also freed when calling this function. The handle is unusable after this call. A second call on the same pointer is a use-after-free, and passing `null` terminates the process. Calling this function is the only way to release the handle."
- **`accesskit_tree_update_factory`.** "Builds one tree update. Must not return `null`; returning `null` terminates the process. Ownership of a returned update transfers to the library, which releases it after delivery. The library calls this on its own thread, not the thread that installed it. `userdata` must stay valid until the adapter is released."
- **`accesskit_activation_handler_callback`.** "Returns a tree update, or `null` when the platform has no tree to give. A `null` return is an ordinary answer, not a failure, and the library keeps nothing. Ownership of a non-null result transfers to the library, which releases it. This matches `accesskit_tree_update_factory` except that `null` is allowed here, and the two are documented the same way on purpose."
- **`accesskit_action_handler_callback`, table row 14.** "Called when the platform asks the application to perform `request`. Ownership of `request` transfers to this callback. Release it with `accesskit_action_request_free` before returning, on every path out of the callback. Forgetting it leaks the request and, when `request->data.value.tag` is `ACCESSKIT_ACTION_DATA_VALUE`, the string it holds. The library calls this on the platform's own thread; it states so for Linux, iOS, tvOS and the Windows subclassing adapter, and says nothing for macOS, Android and the plain Windows adapter."
- **`accesskit_deactivation_handler_callback`.** "Called when the platform deactivates accessibility. Takes no argument and returns nothing. Runs on the same thread as the activation handler for the same adapter, and `userdata` is passed through unchanged and must stay valid until the adapter is released."
- **The 5 object-returning platform accessors, table row 18.** "Returns a pointer to the accessibility element at the point, or `null` when none. Ownership of the pointer is not transferred. The returned object belongs to the platform view. Its lifetime is the platform's own and this library does not extend it."
- **`accesskit_macos_add_focus_forwarder_to_window_class_with_length`, table row 19.** "Adds a focus forwarder to an `NSWindow` subclass. `class_name` is `length` bytes and is not null-terminated. This function reads `class_name` and keeps its own copy. The caller keeps ownership of the buffer and must not release it after this call. The function cannot be undone, so the library must stay loaded for the life of the process and should be linked statically into the main executable."
- **`accesskit_set_allocator`, record C.** "Installs the allocator every exported function in this library uses. Call it once, before any other function in this header. `alloc` and `free` must stay valid until the process exits. This library calls them from whatever thread made the allocation, so both must be thread-safe. Passing `null` for either restores the default C allocator. Passing `null` for `context` passes `null` back to both functions on every call."

#### 4.4.4 Field comments: the unit, and the meaning of each `null`

The header names no unit for any numeric field, and a `null` that stands for two conditions is a defect. Each row below is the sentence to ship.

| # | Field or return | Sentence to ship |
|---|---|---|
| U1 | Every `size_t length` in a setter or in a returned array | "An element count, not a byte count." |
| U2 | `accesskit_lengths.values` | "UTF-8 encoded character lengths in bytes, one per character, in text order." |
| U3 | `accesskit_opt_coords.values` | "Character positions or widths in logical pixels from the start of the text, one per character, in text order." |
| U4 | `accesskit_rect`, `accesskit_point`, `accesskit_vec2`, `accesskit_size`, `accesskit_affine` | "Logical, device-independent pixels. The y axis grows downwards, so `y0` is the top edge and `y1` the bottom edge. `accesskit_affine._0` is row-major with an implicit last row of `0 0 1`." |
| U5 | `accesskit_color` | "Each component is an integer in `0..=255`. Alpha 255 is fully opaque." |
| U6 | `accesskit_text_position.character_index` | "A count of UTF-8 characters, not bytes and not UTF-16 code units." |
| U7 | `accesskit_opt_index.value` and every index setter | "A count, not an index into any table this header defines." |
| U8 | `accesskit_text_decoration.style` | "`ACCESSKIT_TEXT_DECORATION_STYLE_SOLID` is the default when the property is absent." |
| N1 | The 31 `char *` getters | "A `null` return means the property is unset or the copy could not be allocated. `accesskit_last_error` tells the two apart." |
| N2 | The 5 constructors | "Returns `null` only when the allocation failed." |
| N3 | `accesskit_node_custom_actions` | "Returns `null` only when the allocation failed. An empty list has `length == 0`." |
| N4 | `accesskit_string_free`, every `*_free` | "Passing `null` terminates the process." |
| N5 | `accesskit_tree_update_set_tree_info` | "Passing `null` stores no tree info, the same state as `accesskit_tree_update_clear_tree_info`." |
| N6 | `accesskit_activation_handler_callback` | "A `null` return is an ordinary answer, not a failure." |
| N7 | `accesskit_tree_update_factory` | "Must not return `null`; returning `null` terminates the process." |
| N8 | The 11 `*_update_if_active` | "Returns `null` when the adapter is not active. Build nothing and do not raise events." |
| N9 | The 7 `*_debug` | "Returns `null` when the text could not be built." |
| N10 | The 5 object-returning platform accessors | "Returns `null` when there is no such object." |
| N11 | Every array setter's `values` | "`values` may be `null` when `length` is 0 and must not be `null` otherwise." |

---

## 5. What the port refuses to reproduce

### 5.1 The six recorded upstream ABI breaks

| Release | Break, verbatim | Port |
|---|---|---|
| 0.18.0, 2025-12-10 | "Make `accesskit_custom_action` an opaque type" | adopt |
| 0.17.0, 2025-07-18 | "Remove `NodeClassSet`" | adopt |
| 0.16.0, 2025-04-24 | "Rename the `StaticText` role to `Label`" | adopt |
| earlier, pre-move | "Rename `accesskit_builder_set_text_selection` to `accesskit_node_builder_set_text_selection`" | adopt |
| earlier, pre-move | "Rename `hierarchical_level` to `level`" | adopt |
| earlier, pre-move | "Rename `Checked` to `Toggled`; drop `ToggleButton` role" | adopt |

```text
Evidence: The changelog records six explicit ABI breaks. A search of the pinned header finds no `accesskit_builder`, no `ACCESSKIT_ROLE_STATIC_TEXT`, no `ACCESSKIT_ROLE_TOGGLE_BUTTON` and no `NodeClassSet`, and `ACCESSKIT_ROLE_LABEL` appears at line 286.
Subject:  AccessKit/accesskit-c @ 8b6ed37c20ed4c59390e253407983333053662ba
Source:   CHANGELOG.md, include/accesskit.h
Reads as: A source reading of a changelog and a bounded search of the header. It establishes that each break's post-state is the state of the pinned header. It establishes no reason for any break, no rate of future change, and no compatibility promise between releases.
```

**All six outcomes are adopted, and none is declined.** Each is already the shape of the pinned header, so declining one would mean inventing a divergence with no named consumer and no evidence behind it. Declining the 0.16.0 role rename would renumber a wire value; declining the 0.18.0 opacity change would expose a layout the header no longer describes; declining the 0.17.0 removal would add a type that does not exist. Stating that plainly is the honest answer, and an invented decline would be a fabricated one.

**What the port refuses alongside them**, three refusals about practice rather than about a break outcome. **One: no alias and no deprecation window for any of the six.** The house rule is delete rather than deprecate, and upstream shipped no alias either. **Two: no `0.X` soname discipline.** Upstream holds its soname at `0.X`, so a within-`0.X` break ships without a soname change; the port derives the soname from `LibraryOptions.version`, whose `.major` becomes the `lib*.so.N` name, so a break that changes the ABI changes the soname. **Three: no abort on an interior null byte.** Upstream's `char *` getter panics when a stored string holds an interior null; the sentence in section 4.4.3 stores a byte string up to the first null instead, so the value round-trips and the abort disappears. This is the one place the port's behaviour differs from upstream on a path a caller can reach, and it is a strict improvement, since upstream's panic is a defect by this project's own definition.

### 5.2 What the port adds, and the limits that do not occur today

Three additive changes and no signature changes: `accesskit_error` with `accesskit_last_error()` (record B2), `accesskit_set_allocator` (record C), and the eleven sentence additions across the header that close the gaps in section 3. The two new functions are the only two names a C consumer must learn that upstream does not have, and both are optional.

Four `translate-c` limits force a hand-written C shim, and all four are absent from the pinned header, so they stay forward-looking rules rather than work: a bitfield in a public struct, which `translate-c` demotes to `opaque {}` with every field lost; a variadic export, which `translate-c` declares and Zig cannot define; a macro a C consumer needs at compile time, which becomes a Zig `inline fn` that is not a symbol; and a macro the translator cannot render, which becomes a `@compileError` no build script can work around. The fifth limit is aggregate passing, and it is not in this list because it is not a shim limit: `translate-c` translates every aggregate signature correctly. What is unproved is that Zig's own lowering of the definition agrees, which is record E and check 5.

### 5.3 The upstream comment that is wrong and is not copied

`accesskit_macos_add_focus_forwarder_to_window_class_with_length` is documented as `Caller is responsible for freeing class_name`, while its parameter is `const char *` and the implementation reads the bytes as a slice without releasing anything. It is the only such comment in the header. The sentence in section 4.4.3 replaces it with the true rule, and table row 19 carries the ownership category.

```text
Evidence: The header documents `accesskit_macos_add_focus_forwarder_to_window_class_with_length` as "Caller is responsible for freeing `class_name`", while its parameter is `const char *`, and the implementation reads the bytes as a slice and passes them on without releasing anything. It is the only such comment in the header.
Subject:  AccessKit/accesskit-c @ 8b6ed37c20ed4c59390e253407983333053662ba
Source:   include/accesskit.h, src/macos.rs
Reads as: A source reading of one comment and one function at that revision. It establishes that the comment contradicts the parameter type and the body. It establishes no consequence for any consumer, and it says nothing about whether a consumer has been harmed by the wrong comment.
```

### 5.4 What a C consumer must recompile for

A C consumer recompiles when a struct field is added, removed, reordered or retyped; when a function is added, removed, or changes arity or signature; when a declarator changes value in any of the 18 enums, which the role comment says are wire values; or when a header sentence changes in a way that changes what a caller must do, which no machine check covers and which is review. Checks 1 and 2 catch the first three. The port also changes the soname when a break changes an existing signature or layout.

**The stability promise this port declines to make.** Upstream does not promise byte stability for this header, and six recorded breaks in its own enumerated history say so. The port does not promise it either. What the port does promise is narrower and checkable: the declarations in `include/zaccesskit.h` at a named revision are the contract, the layout and signature checks in section 6 hold at that revision on the targets section 6 names, and a change that breaks one of them fails the build rather than shipping. That is a promise about a revision, not about a range.

---

## 6. Verification

Five checks separate declarations, layout, linked calls, callback ownership, and target calling conventions.
`docs/50-verification.md` records their observed results and limits.
`build.zig` installs the selected C library and header.
The `test-c` step links the real offline C11 consumer.
The native `test` step also runs that consumer.
The Linux `cross-test` step runs it through the selected target runner.
The module and library honor target and optimization options.
Native Debug and ReleaseSafe test shards keep their fixed modes.
No check in this section claims native platform object attachment or bus delivery.

| # | Check | Proves | Does not prove |
|---|---|---|---|
| 1 | Header-parity sweep, name-paired, in the test module only | the Zig declarations and the shipped header agree, by name and offset, over the sweep list, on the target and mode that ran | execution, analysis of unreferenced declarations, the calling convention, other targets |
| 2 | The comptime layout floor | the geometry and action-data numbers hold at compile time in every mode that builds | any other layout, any other target |
| 3 | The linked offline C11 consumer with selected static or dynamic linkage | the compiled C calls reach the real library and check results and release counts | native platform object attachment or untested targets |
| 4 | An owning opaque handle across a callback | conversion consumes the captured allocator handle and retains borrowed metadata for the native tree | native accessibility object behavior |
| 5 | The aggregate convention, native and under `qemu_user` for `powerpc64-linux` | that Zig and C agree on how each aggregate class is passed and returned, on an x86-64 and a big-endian row | any other ABI, or that a defect outside these classes is absent |

**Checks 1 and 2.** Check 1 is the sweep of record H, section 4.3, with its four exclusions and its four hazard counts pinned at zero. Check 2 is the `comptime` block of section 4.0 plus the six geometry assertions `docs/19` records. A `comptime` assertion is evaluated in every optimize mode, so check 2 covers Debug, ReleaseSafe, ReleaseFast and ReleaseSmall at once, which no run-time `std.debug.assert` does. Both are **exercised compilation** once they run. What they will not establish, restated because it is the point of the exclusions: not that the foreign code ran, and not that a declaration no reached path references was ever analysed.

**Check 3, the C fixture.** A C file compiled with `cc`, linked against the shared library the build emits, and run. It carries `_Static_assert` lines for every struct size and offset the header promises, and one call of each shape across the boundary: an aggregate return of each class, a `void` setter, a borrowing getter, an owning getter with its free, a consume-and-raise handle, a callback round trip, and one `accesskit_last_error` read after an induced failure. **Exercised compilation plus runtime observation** once it runs. **What it proves that check 1 does not:** the C compiler's own answers, so a Zig-side mistake that happens to agree with a wrong Zig-side expectation still fails. **What it does not prove:** completeness, and the correctness of the logic behind each call.

**Check 5, the aggregate convention and the big-endian row.** This is the check that decides record E, and the cross matrix is what makes it worth running. `cross-test.profile.sh` carries `powerpc64-linux` as its only big-endian row, and that row exists because it is the one that catches a byte-order or a register-assignment assumption that x86-64 hides. The fixture calls, from C, one function per aggregate class: a 16-byte two-double return (`accesskit_point_to_vec2`), a 32-byte four-double return (`accesskit_rect_new`), a 48-byte six-double return (`accesskit_affine_inverse`), a 48-byte argument with a 48-byte return (`accesskit_affine_mul`), the 16-byte `accesskit_tree_update_get_tree_id` return, and each of the 12 `accesskit_opt_*` returns. It runs the same binary natively and under `qemu_user` for the foreign rows. A sweep that only compares offsets passes on both rows while the call still corrupts the stack, because a register assignment is not a field offset. **Runtime observation on each row that runs**, and nothing about a row that does not.

**Check 4, the opaque handle across a callback, and why it does not close the gap.** `translate-c` carries `opaque {}` perfectly. What it does not carry is a layout rule: nothing tells a Zig consumer which fields the C side promises to keep. That is a documentation obligation, and the honest test of it is a round trip, not a layout comparison. The test that can be written: a C fixture constructs an `accesskit_node`, pushes it into a tree update through a Zig `tree_update_factory` callback, receives it back through the same callback, and reads a field out. **Marked unproven until it runs.** It proves identity, alignment and reachability across the boundary. It does not prove any promise about which fields survive, because nothing states one, and this document does not add one.

**The risks are concentrated, and that shapes the checks.** The core crate's source contains no `async`, no `.await`, no `Box<dyn`, no `unsafe` and no `Arc<`; the bindings crate contains no `async`, no `.await`, no `Box<dyn` and no `Arc<`, and 61 occurrences of `unsafe`. So the constructs that make a boundary risky sit outside the core, and a conformance suite for this C ABI must not assume the whole port shares them.

```text
Evidence: The core crate's source contains no `async`, no `.await`, no `Box<dyn`, no `unsafe` and no `Arc<`. The bindings crate's source contains no `async`, no `.await`, no `Box<dyn` and no `Arc<`, and 61 occurrences of `unsafe`.
Subject:  AccessKit/accesskit @ 466e24e252103f4d82bd6fbab98141b551e46e0c, and accesskit-c @ 8b6ed37c20ed4c59390e253407983333053662ba
Source:   accesskit/src/, src/
Reads as: A bounded text count over two directory trees at those revisions. It establishes where those constructs occur and where they do not, in those two trees. It says nothing about the adapter crates, which the count did not read, and it counts occurrences rather than classifying them.
```

**What cannot be verified here.** Everything above is a plan, and this record
carries no run for any of it. What it cannot establish is unchanged in kind: that
the port compiles, that any check reaches, that the C header and the Zig
declarations agree, that the aggregate convention matches, because no call has
crossed a boundary, that `union(enum)` and `extern struct` differ, because only
the sizes were measured, that any layout holds on a foreign target, or that any
notice obligation is satisfied. One ground in the sentence above is false now,
and it is the load-bearing one. Both artefacts exist, so whether the C header and
the Zig declarations agree is now a question about two files that are both on
disk. Nothing in this record answers it. The only facts this document establishes
by measurement remain the two probe results in section 4.0, each labelled with
its toolchain, its host and its single configuration.

---

## 7. Cost imposed on consumers

What a C consumer holds, pays or must know that they did not before, in the order a consumer meets it.

**1. Two names change, and no symbol changes.** The header is `zaccesskit.h` rather than `accesskit.h` and the library is `libzaccesskit.so` rather than `libaccesskit.so`. The include line and the link line both change; the 496 symbols keep their `accesskit_` spelling, so no call site changes. A consumer migrating from upstream edits two lines.

**2. The error shape is new, and it is optional.** A `null` from a string getter now covers two conditions where it covered one, separated by a call the consumer chooses to make. A consumer that only tests `!= NULL` sees upstream's exact behaviour and pays nothing. A consumer that must distinguish them reads one thread-local immediately after the call, and must read it before making another call, because the next call clears it. That ordering rule is new knowledge.

**3. The allocator is new, and it is also optional.** A consumer that does nothing gets the C allocator and the contract that library memory is released only through `accesskit_string_free` and the `*_free` functions, never through `free`. That rule is new, and it applies to every allocation the library makes. A consumer that wants its own arena calls `accesskit_set_allocator` once, before anything else, and must supply two thread-safe function pointers that stay valid until the process exits.

**4. The header is the largest cost.** The consumer must recompile against `zaccesskit.h` rather than a header it may already have cached, and the header states eleven things upstream leaves unstated: that a returned array borrows from its node, that `accesskit_tree_update_set_tree_info` consumes its argument, that `accesskit_action_request_free` also releases the string inside the union, that a `_queued_events_raise` call consumes its handle, that a custom-actions setter copies rather than takes, and the rest of section 3. A consumer written against the upstream header that trusted the upstream comments has code that reads correctly and frees incorrectly. The port header makes that code visibly wrong, which is the point and also the cost.

**5. Three byte-string behaviours differ from upstream.** A `_with_length` setter stores up to the first null byte rather than aborting later at the getter. A byte-slice setter copies, so a consumer that mutates its buffer after the call sees no difference. And `accesskit_string_free` rejects anything the library did not return, so a consumer that had been freeing library strings with `free` must stop.

**What the port does not charge.** No new call is required at run time. No callback signature changed. No struct grew. No symbol was renamed. No consumer must write an allocator if it does not want one, and none must read an error tag if it does not want one.

---

## 8. What is unknown

Eight items, each naming the thing that would settle it. None is invented.

1. **Whether Zig 0.16.0 lowers a 48-byte aggregate return the way a C compiler does on any target.** Settled by check 5 in section 6. The installed toolchain ships no compiler `src/`, so the answer cannot be read from source here.
2. **Whether the action-data tag width is 4 bytes on every target in the matrix.** Measured on one host with one compiler, and a C enum with no fixed base leaves the number to the compiler. Settled by checks 1 and 3 on each foreign row, plus the pinned `@sizeOf` that fails the build when a target disagrees.
3. **Whether the action-data and request layouts hold on a big-endian target.** The `accesskit_tree_id` member is 16 bytes in big-endian UUID order, so the byte order inside the struct is the struct's own and the field order is unchanged. Settled by check 1 on `powerpc64-linux`.
4. **What an opaque handle passed across a callback promises.** Nothing in this repository states it and no machine check covers it. Section 6 describes the round-trip test that could be written and marks it unproven until it runs. Settled by that test plus a written promise; this document declines to write the promise, because a promise with no consumer to reach it prices the reader for a case that cannot arrive.
5. **Whether the house gate can be extended to cover a C-ABI conformance step.** `zig-gate` runs ten stages and none compiles a C consumer. `docs/40-plan.md` owns the gate lines. Settled by a gate line naming the step, the target and the runner.
6. **What a C consumer does about the two release trains.** This port pins one revision of each repository, so the question does not arise inside the port; it arises only if a consumer also links upstream's own `libaccesskit`, which record D forbids by keeping one prefix per process. Settled by the version-script decision such a distributor would have to write.
7. **Whether the conformance sweep reaches every declaration.** The self-check in record H catches a sweep that matched nothing. It cannot catch a declaration never added to `pub const sweep`. Settled by a count: the sweep asserts that the number of declarations it checked equals a literal, and the literal is raised when a declaration is added. That assertion is part of check 1 and has not been written.
8. **Whether any C consumer exists at all.** No consumer has been named, surveyed or contacted, and this document names none. Every cost in section 7 is priced against the two example programs upstream ships, which is a real consumer shape but not a commitment from anyone. Settled by a written requirement from a named consumer, which is also the condition record A names for changing its decision.

**What is not on this list.** The layout of the five geometry types and the optional rectangle is not unknown: `docs/19` measured it two ways and section 4.0 repeats the numbers with their labels. The absence of a vtable is not unknown: a bounded search settled it at the pinned revision. The absence of a C error type is not unknown: a bounded search settled it. The six upstream ABI breaks are not unknown: the changelog enumerates them and the pinned header shows each post-state. Those are findings with evidence, and leaving them here would misrepresent a completed search as a pending one.

---

## 9. Corrections

Four claims in this document and in the shipped header were measured on
2026-10-05, and each is corrected below. `docs/40-capi-build-map.md` holds the
measurements: section 1.2 and section 3.4 for the aggregate census, section 7.1
for the language modes, and the note under section 8 for the `*_free` count.
Section 9.3 is the odd one out: it corrects a correction, because 9.3's own
first replacement was wrong in the same direction as the error it was fixing.

### 9.1 The `*_free` count, section 3 row 16

**Was:** "2 node, 2 tree-info, 1 tree-update, 2 custom-action, 1 action-request,
1 string, 10 platform", which is 19 functions.

**Now:** 17, counted at `8b6ed37`. The header declares `accesskit_string_free` at
2824, `accesskit_custom_action_free` at 5006, `accesskit_custom_actions_free` at
5068, `accesskit_node_free` at 5128, `accesskit_tree_info_free` at 5157,
`accesskit_tree_update_free` at 5294, `accesskit_action_request_free` at 5372, and
10 platform free functions between 5720 and 6436. Upstream declares the same 17
under the same names, so this was a counting error in this document and not a
divergence in the port. An implementer who followed the old row wrote a second
`accesskit_node_free` and a second `accesskit_tree_info_free`, and the link fails on
both.

### 9.2 The conformance claim in the header preamble

**Was:** "ABI claim: C11, against a library built by Zig 0.16.0. The conformance
section at the end of this file states the layout the two agree on."

**Now:** the same sentence plus what the other two language modes do. Parsed as C11
with `-Wall -Wextra -Wpedantic`, the header is clean. Parsed as C99 with the same
flags, gcc gives 10 `-Wpedantic` diagnostics and clang gives 9
`-Wc11-extensions`. Parsed as C++17, g++ gives 8 and clang++ 16 under
`-Wgnu-anonymous-struct`. Every one of those diagnostics comes from
`accesskit_action_data` at lines 1621-1649, whose payload union uses the anonymous
struct extension eight times. Both compilers accept the extension as a warning and
C11 is the mode this library targets, so the union is not restructured. The counts
are measurements on one host with gcc 15.3.0 and clang 19.1.7, which the header
names so a reader can tell a different compiler apart from a different header.

### 9.3 The aggregate figures, section 2.5

**Was, twice, and both corrections were wrong in the same direction.** The
figures this section first carried — **103** returning by value, **42** taking at
least one, **58** parameters across **9** types, **28** on both sides — were
right. They were then replaced here with **105**, **57**, **77** across **11**
types and **31**, on the strength of `docs/40-capi-build-map.md` section 1.2,
which reported those as a measured divergence from this document. The divergence
was `docs/40`'s own classifier: it classified a parameter or a return as "by
value" whenever the type text *named* a struct, without looking at whether the
declarator carried a `*`. Every one of the five replacement figures is that
error, and the arithmetic closes exactly in `docs/40` section 3.4.

**Now, re-measured on 2026-10-05 against `include/zaccesskit.h`:** **103**
declarations return a struct by value, **42** take at least one aggregate by
value, **58** aggregate parameters across **9** types, **28** both return and
take by value. The original figures stand. What the port adds is two
declarations, `accesskit_set_allocator`, which returns `void`, and
`accesskit_last_error`, which returns the C enum `accesskit_error` — neither is
a struct by value, so neither moves any figure here. Excluding every
`accesskit_opt_*` from the parameter set changes nothing, because no optional is
ever passed by value; and no by-value parameter sits behind a preprocessor
guard, since the same 42 / 58 / 9 falls out of the 446 declarations a Linux
build sees.

### 9.4 The reconciliation with `docs/40`, and the two marginal cases

**Which document was right.** On the by-value parameter split, this document was
right and `docs/40` was wrong; on the by-value return count, this document's
original 103 was right and both its own 105 and the 105 adopted here were
wrong. Being the older document is not by itself a reason to suspect it, and
being corrected three times today is not by itself a reason to keep the
corrections; what settles it is that re-running the classifier against the
header returns 42 / 58 / 9 / 28 and 103 with no interpretation left over.

**The classification itself, which is the part that matters for section 6.2.** A
struct passed by value crosses the boundary in a register or on the stack, so
its size, layout and alignment are contract, and a caller built with a different
classification corrupts its own stack. A struct passed by pointer crosses as an
address; only the address is contract. Measured separately: **42 declarations,
58 parameters, 9 types** by value; **444 declarations, 449 parameters, 22
types** by pointer; **16 declarations in both sets**, listed in `docs/40`
section 1.2. `rect` is the most frequent by-value parameter at 10 across 9
declarations, and 15 `rect` parameters cross by pointer, so fifteen of the
misattributed entries were `rect` and the type whose classification carries the
most weight was the one the old classifier got wrong most often.

**The two marginal cases `docs/40` section 3.4 named, each resolved against the
header.**

- **`custom_actions` — deleted.** `accesskit_node_custom_actions` at
  `include/zaccesskit.h:5094` returns `struct accesskit_custom_actions *`, a
  pointer, and takes `const struct accesskit_node *`. The type occurs in exactly
  two positions in the header — that return and the
  `accesskit_custom_actions_free` parameter at line 5083 — and in neither is it a
  value. It is not a by-value type at all.
- **`tree_id` — kept, and it was never marginal.**
  `accesskit_tree_update_get_tree_id` at `include/zaccesskit.h:5357` returns
  `struct accesskit_tree_id` by value and is inside the 103;
  `accesskit_node_set_tree_id` at 2819 and `accesskit_tree_update_set_tree_id` at
  5364 pass `accesskit_tree_id` by value and are inside the 42 and the 58. It was
  counted correctly the whole time, and describing it as an edge case invited
  exactly the doubt it did not need.

**Downstream.** `docs/40` sections 1.2, 3.4, 4 row 1 and 6.2 and this document's
sections 2.5 and 9.3 carry the corrected figures. Three places outside both
documents quote the wrong ones and are reported rather than edited, because this
run's file boundary forbids them: `src/capi/tree_info.zig:42-54`, whose module
doc quotes 105, 104 and 103 and names `custom_actions` and `tree_id` as the two
marginal cases; `docs/45-plan-status.md:232-233` and `:480-481`, which state
"105 declarations return an aggregate by value while 77 parameters across 57
declarations pass one". `src/capi/tree_update.zig:501-503` cites section 1.2 for
`accesskit_tree_id` crossing by value, and that citation is correct under the
corrected figures and needs no change.
