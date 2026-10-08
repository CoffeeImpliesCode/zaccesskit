# 24b. Translation checklist, recorded rejections, and inherited rules

Consumed by `docs/30-port-design.md`. The sibling construct table and the input
contract live in `docs/24-rust-idiom-mapping.md`. This file does not repeat
them.

## 0. How to use this file

Path prefixes follow `docs/24-rust-idiom-mapping.md` §0.1. Three appear here.

| Short name | Absolute path |
|---|---|
| `TR` | `~/translate-rust` (read only) |
| `ZSTD` | Zig 0.16.0 standard library, pinned |
| `AK` | `/tmp/scratch/accesskit` |

Every source record cited below is dated research or a dated design proposal.
None states what the translator supports today. A port may differ from any of
them, and where it differs it must say so beside the citation.

## 1. The intermediate representation as a port checklist

Pick one translated function. Put the Rust original and the Zig output side by
side. Walk the rows. Each row names one decision the data model records, so a
reader answers pass or fail. A fail does not always mean the Zig is wrong. It
means the port decided something without recording it. Record it.

The IR contract is lossless but gated: every node carries identity, position
and type, and every unsupported form is an explicit marker
(`TR/notes/design/data-model.md:26-47`).

### 1.1 Identity and position

| # | Check | Pass | Fail |
|---|---|---|---|
| 1 | Decl has an id and a span | Span recorded next to the emitted Zig decl | No span, so no diagnostic can point at the Rust source |
| 2 | Body expressions have spans | Every emitted statement maps back to one Rust span | One hand-written helper with no recorded source |
| 3 | Every expression carries a resolved type, or an explicit unknown | `ty` is filled or explicitly null | Type guessed from reading the Zig |
| 4 | Span convention is uniform | One convention on every node: 1-based line and col, end exclusive | Mixed conventions inside one function |
| 5 | Node names are valid Zig identifiers | `if_else`, `loop_`, `try_`, `return_`, `while_`, `for_`, `break_`, `continue_` | A node named `try`, `r#else` or `loop` |

Sources: `TR/notes/design/data-model.md:36-38`,
`TR/notes/design/data-model/exprs-patterns.md:34-53`,
`TR/notes/design/data-model/exprs-patterns.md:62-66`.

### 1.2 Names, paths and visibility

| # | Check | Pass | Fail |
|---|---|---|---|
| 6 | Rename decided once | One recorded rename, reused at every use | Two spellings for the same entity |
| 7 | Zig keyword as an identifier is escaped | `fn` emits as `@"fn"` | `fn` left bare, so the file does not parse |
| 8 | Rename only on a real collision in the Zig target container | Nested-scope shadow kept, sibling collision renamed | Every shadow renamed, or a collision left unrenamed |
| 9 | Visibility reduced per item | `pub(crate)`, `pub(super)` and `pub(in path)` reduce conservatively to `pub` or private | A `pub(crate)` fn emitted as `pub`, widening the API |
| 10 | `pub use` materializes an alias | `pub const helper = util.helper;` in the exporting file | Re-export dropped, so the public surface shrinks |
| 11 | Inline module folded flat, file split named explicitly | Inline decls sit in the parent file; a file module has a named `@import` | Module body lost, or `@import` guessed from a mod table |
| 12 | Path resolved, not re-read at emit | Each path resolves to one entity id | Emitted path text re-parsed by hand |

Sources: `TR/notes/design/data-model/crate-graph.md:259-279`,
`TR/notes/design/data-model/crate-graph.md:134-138`,
`TR/notes/design/data-model/crate-graph.md:172-187`,
`TR/notes/design/data-model/crate-graph.md:115-126`,
`TR/notes/design/data-model/crate-graph.md:252-257`.

### 1.3 Signature and types

| # | Check | Pass | Fail |
|---|---|---|---|
| 13 | Receiver erased to an explicit param | `self: Self` for owned, `*const Self` for `&self`, `*Self` for `&mut self` | A Zig method with no first parameter, or the wrong pointer constness |
| 14 | Unsafe and async markers retained | `is_unsafe`, `is_async` recorded on the fn | Flags dropped, so an unsafe block reads as safe |
| 15 | Unit and never types mapped | `()` becomes `void`, `!` becomes `noreturn`, `char` becomes `u21` | `()` emitted as an empty struct |
| 16 | `Option`, `Result`, `Box`, `str`, collections are dedicated type nodes | Each one is a distinct node, not a bare path | `Option` carried as a path, so the emitter re-derives std identity |
| 17 | `Result<T, E>` becomes `E!T` only when `E` is finite | Finite set becomes an error union | Infinite error type forced into `anyerror` without a marker |
| 18 | `&str` and `String` map to the right Zig string forms | `&str` becomes `[]const u8`; `String` becomes `std.ArrayList(u8)` | `std.ArrayListUnmanaged(T)`, deprecated in 0.16 |
| 19 | `repr` honored | `repr(C)` becomes `extern struct`, `repr(packed)` becomes `packed struct`, `repr(transparent)` becomes a single-field struct | `repr(C)` struct emitted as a plain `struct`, so the layout breaks |
| 20 | Enum shape chosen per variant set | C-like becomes `enum(uN)`, data-carrying becomes `union(enum)`, recursive field becomes a pointer | A data enum forced into `enum(uN)` with the payload dropped |
| 21 | `non_exhaustive` gets a catch-all | A synthetic `else` arm on every switch over the enum | Switch without `else`, so an unseen tag hits `corruptSwitch` |
| 22 | FFI forms distinct | `extern "C" fn` becomes `extern fn`; `#[no_mangle]` becomes `export fn`; `system` becomes `callconv(.winapi)` | A C entry point emitted without `export`, so the symbol is missing |

Sources: `TR/notes/design/data-model/items-types.md:99-112`,
`TR/notes/design/data-model/items-types.md:262-271`,
`TR/notes/design/data-model/items-types.md:285-317`,
`TR/notes/design/data-model/items-types.md:66-69`,
`TR/notes/design/data-model/items-types.md:83-87`,
`TR/notes/design/data-model/items-types.md:148-157`.

### 1.4 Generics

| # | Check | Pass | Fail |
|---|---|---|---|
| 23 | Type and const params become comptime | `comptime T: type`, `comptime N: usize` | A runtime type parameter, so the Zig cannot resolve the body |
| 24 | Method comptime params follow `self` | `self` first, comptime params after | Comptime param before `self`, so the call does not type check |
| 25 | Where-clauses and bounds not emitted | Bounds kept for diagnostics only | A `where` clause turned into a runtime check |
| 26 | Lifetimes erased at emit, kept for diagnostics | No lifetime parameter in the Zig signature; the Rust annotation stays in the record | An `'a` parameter that Zig cannot name |
| 27 | One generic decl, no body duplication | One declaration; each use site records its instantiation | A hand-copied body per type argument |

Sources: `TR/notes/design/data-model/items-types.md:214-238`.

### 1.5 Body: expressions

| # | Check | Pass | Fail |
|---|---|---|---|
| 28 | Overflow mode decided per arithmetic op | `+` for checked, `+%` for wrapping, `+\|` for saturating | A bare `+` where Rust release wraps, so the value differs |
| 29 | Compound assignment carries the same mode | `+=` maps to `+=`, `+%=` or `+\|=` on the same decision as row 28 | `+=` emitted as `+` while `+` was emitted as `+%` |
| 30 | Shift width and signedness respected | Arithmetic shift on signed, logical on unsigned | One shift operator for both |
| 31 | `&&` and `\|\|` keep short-circuit | Zig `and` and `or`, not `&` and `\|` | Bitwise operators, so the right side always runs |
| 32 | Call kind chosen per call | Free, associated and constructor calls render differently | Every call rendered as a free call |
| 33 | Method call names its receiver mode | `x.m(a)` becomes `x.m(x, a)` with the right pointer type | Method call with an implicit first argument that Zig cannot supply |
| 34 | `?` becomes `try`; `unwrap` and `expect` become `orelse unreachable` | Recognized by the resolved callee, not by name | `.unwrap()` left as a method call on a type that has no such method |
| 35 | `Option` scrutinee uses optional capture | `if (opt) \|v\|`, not a `switch` over an optional | A `switch` on an optional, which is not a tagged union |
| 36 | `else if` linearized | One `if`/`else` chain with no dangling else | A nested `if` inside an `else` without braces |
| 37 | Labelled block and labelled break preserved | `:blk` label on the block, `break :blk` on every exit | A labelled loop exit turned into a bare `break` that leaves the wrong block |
| 38 | Loop iterable kind recorded | Range, slice, zip and enumerate each map to the matching Zig `for` shape | Zip emitted as a range, so the pairing is lost |
| 39 | Multi-value `for` index comes last | `for (a, 0..) \|x, i\|` | Index bound first, which swaps the capture names |
| 40 | Literal keeps raw text and decoded value | Source spelling preserved; base, suffix and sign recorded | Only the decoded number, so the emitted base or suffix is a guess |
| 41 | Block tail expression is the block value | Final expression without `;` is the return value | The tail dropped or forced to unit |
| 42 | Struct update syntax handled | `..base` either expanded field by field or refused with a marker | Fields silently missing from the literal |

Sources: `TR/notes/design/data-model/exprs-patterns.md:285-330`,
`TR/notes/design/data-model/exprs-patterns.md:230-274`,
`TR/notes/design/data-model/exprs-patterns.md:161-226`,
`TR/notes/design/data-model/exprs-patterns.md:126-148`,
`TR/notes/design/data-model/exprs-patterns.md:331-343`,
`TR/notes/design/data-model/exprs-patterns.md:513-530`.

### 1.6 Statements and patterns

| # | Check | Pass | Fail |
|---|---|---|---|
| 43 | Every binding carries an explicit bind mode | Value, shared ref or mutable ref decided before emit | An implicit ref the emitter re-derives |
| 44 | Mutable-ref binding uses a pointer capture | `\|*x\|` | `\|x\|`, which captures by value and copies |
| 45 | Or-pattern collapses into one arm | One arm, several prongs | Two arms that duplicate the body |
| 46 | Range and literal prongs stay integer or char | Only `int` and `char` prongs emitted | A string literal prong, which is not a valid switch prong |
| 47 | Guard sits on the arm, not the pattern | `guard` is an arm field | Guard modeled as a pattern kind |
| 48 | Wildcard becomes `else` | `else` prong for `_` | `_` copied into the Zig switch, which takes `else` |
| 49 | Refutable `let` becomes `if let` or `let else` | `let Some(v) = x else ...;` | A refutable `let` emitted as a plain capture that can fail at runtime |

Sources: `TR/notes/design/data-model/exprs-patterns.md:347-408`,
`TR/notes/design/data-model/exprs-patterns.md:411-437`,
`TR/notes/design/data-model/exprs-patterns.md:527`.

### 1.7 Ownership, drop and allocator

| # | Check | Pass | Fail |
|---|---|---|---|
| 50 | Value site classified | `move`, `copy` or `move_drop` recorded per value node | No classification, so re-read legality is unknown |
| 51 | Borrow kind per parameter | Owned, shared, mutable, slice-const or slice-mut, with the Zig type frozen from the Rust signature | Shared borrow emitted as `T` by value, so the callee copies |
| 52 | Aliasing edges recorded after lifetime erasure | `lifetime_uses` holds the aliasing edges | Lifetimes deleted and the risk deleted with them |
| 53 | Drop strategy is the scoped one | `defer` only, by value, on scope exit | An alive flag invented for a path that does not need one |
| 54 | Drop order matches Rust | Fields drop in declaration order; the Zig `defer`s are written in reverse because `defer` is LIFO | Defer written in declaration order, so the last field is released first |
| 55 | Error path releases too | `errdefer` in every error-returning scope | `defer` only, so the error return leaks |
| 56 | Every allocation has an allocator source | `param`, `field`, `global_arena` or `none` recorded per allocating construct | A call to `allocator.alloc` with no source, so the signature hides the change |
| 57 | Allocator param added where the function allocates | Leading `allocator: std.mem.Allocator` param on each allocating fn | Allocator created inside the function, or a global used silently |
| 58 | Move across a function boundary carries an allocator | The value names an allocator owner, or the site is refused | A heap value returned with no owner, so it dangles |
| 59 | Aliasing risk marked | `alias_mut`, `borrow_outlives_owner`, `returned_dangling` or `copy_alias` marker at the site | A `&mut` uniqueness claim Zig does not enforce, unmarked |
| 60 | Comment severity always emits | `// UNSOUND: <message>` at the site | A marker in the record with nothing in the Zig |
| 61 | Assert severity survives ReleaseFast | `if (!cond) @panic(...)`, not `std.debug.assert` | A bare `assert`, which is elided in ReleaseFast |

Sources: `TR/notes/design/data-model/ownership-mem.md:41-100`,
`TR/notes/design/data-model/ownership-mem.md:106-137`,
`TR/notes/design/data-model/ownership-mem.md:146-195`,
`TR/notes/design/data-model/ownership-mem.md:199-230`,
`TR/notes/design/data-model/ownership-mem.md:300-314`.

### 1.8 Refusals

| # | Check | Pass | Fail |
|---|---|---|---|
| 62 | Unsupported form carries a reason | Marker names the form and the reason | A construct dropped with no note |
| 63 | Unknown attribute survives | Kept as raw text and emitted as a comment | `#[serde(...)]`-style attribute silently lost |
| 64 | Derived or generated members accounted for | Every derived member is hand-written in the Zig, or the type is marked unsupported | A type that lost a trait the Rust had |
| 65 | Stripped-source dump refused | A dump with stripped items is refused as not lossless | A partial dump accepted as complete |
| 66 | Span end convention pinned, not assumed | One convention chosen and applied | A convention assumed from one sample node |

Sources: `TR/notes/design/data-model.md:39-41`,
`TR/notes/design/data-model.md:86-90`,
`TR/notes/design/data-model/items-types.md:174-204`,
`TR/notes/design/data-model/rustdoc-json-mapping.md:46`,
`TR/notes/design/data-model/rustdoc-json-mapping.md:146-160`.

## 2. Recorded rejections

These are decisions the records already made. A hand port does not reopen one
without new evidence. When the port departs from a row, it must say so and
name the evidence.

### 2.1 Architecture records

| Rejected | Reason | Record |
|---|---|---|
| `dyn Trait` as a v1 form | No Zig vtable. Needs a hand-built `{ptr, vtable}` pair | `TR/notes/design/data-model/items-types.md:374` |
| `Rc`, `Arc`, `RefCell`, `Cell`, `Mutex` in v1 | The ownership and arena layer is not built | `TR/notes/design/data-model/ownership-mem.md:293-295`, `:310` |
| Path-sensitive drop via an alive flag in v1 | Only the scoped `defer` form is built | `TR/notes/design/data-model/ownership-mem.md:139-142`, `:290` |
| Custom iterators and closures in v1 | Each adapter needs its own state-machine lowering | `TR/notes/design/data-model/exprs-patterns.md:518-523` |
| `async` and `await` in v1 | A rewrite, not a translation | `TR/notes/design/data-model/items-types.md:378` |
| Derive and proc macros beyond `assert!`, `panic!`, `println!` | Needs Rust-toolchain pre-expansion | `TR/notes/design/data-model/items-types.md:379` |
| `catch_unwind` | Impossible. Redesign to an error return | `TR/notes/design/data-model/items-types.md:380` |
| Associated types, GATs, HRTB, supertraits | No Zig analogue | `TR/notes/design/data-model/items-types.md:381` |
| Emitting a `where` clause | Bounds are duck-typed and kept only as diagnostics | `TR/notes/design/data-model/items-types.md:382` |
| Workspace and dependency graph in v1 | Every crate becomes its own project | `TR/notes/design/data-model/crate-graph.md:454-456` |
| The `cfg` matrix in v1 | Selection depends on target and features, orthogonal to the graph | `TR/notes/design/data-model/crate-graph.md:457-459` |
| A `std` crate | The v1 prelude model is `no_std`. A `std` crate is refused whole | `TR/notes/design/data-model/crate-graph.md:441` |
| Pre-folding `pub use` into a duplicate decl | The `UseDecl` must survive so the export walk stays honest | `TR/notes/design/data-model/crate-graph.md:176-179` |
| Dropping an unknown attribute | Unknown attributes survive as comments at emit | `TR/notes/design/data-model.md:89-90` |
| Any silent omission | Every unsupported form carries an explicit marker with a reason | `TR/notes/design/data-model.md:39-41` |
| Re-solving the allocator model the way Roc did | The IR records an allocator per construct instead | `TR/notes/design/data-model/ownership-mem.md:189-195` |

### 2.2 `features-actionable.md`

| Rejected | Reason | Record |
|---|---|---|
| `enum(uN)` for a data-carrying enum | Payload variants need `union(enum)` | `TR/notes/design/architecture/features-actionable.md:25`, `:29-34` |
| An error set for a payload-carrying error type | Zig error sets hold no payload. A tagged union wrapper is used instead | `TR/notes/design/architecture/features-actionable.md:143`, `:187-209` |
| A match guard as a `switch` prong | A Zig prong holds no runtime expression. The match becomes `if`/`else if` | `TR/notes/design/architecture/features-actionable.md:260` |
| Keeping Rust `async fn` as async in Zig | The synchronous baseline is the default. `std.Io` injection is the second strategy | `TR/notes/design/architecture/features-actionable.md:343-353` |
| Relying on `switch` exhaustiveness for `non_exhaustive` | Zig `switch` is strictly exhaustive. A synthetic `else` prong is mandatory | `TR/notes/design/architecture/features-actionable.md:136-137` |

### 2.3 `pkg-dep-macros.md`

| Rejected | Reason | Record |
|---|---|---|
| Shipping expanded compiler derive boilerplate | It generates hundreds of lines of `core::fmt::Formatter` code. Native Zig members are synthesized instead | `TR/notes/design/architecture/pkg-dep-macros.md:347`, `:480-482` |
| Deep directory nesting for `foo/mod.rs` | `foo/mod.rs` normalizes to `foo.zig`. Nested `foo/bar.zig` is kept | `TR/notes/design/architecture/pkg-dep-macros.md:484-486`, `:232-242` |
| Textual macro expansion as the IR source | Hygiene failure, comment loss, span corruption | `TR/notes/design/architecture/pkg-dep-macros.md:319-330` |
| A wildcard re-export passthrough | Zig 0.16 has no wildcard re-export. The symbol table expands it | `TR/notes/design/architecture/pkg-dep-macros.md:260-274` |

### 2.4 `runtime-traits.md`

| Rejected | Reason | Record |
|---|---|---|
| Pure inline syntax for language primitives | Unbounded duplication or compiler intrinsics. Every prior art uses a runtime shim | `TR/notes/design/architecture/runtime-traits.md:18-25` |
| Bare `anytype` for a generic parameter | No constraint error when the bound is missing. Explicit `(comptime T: type, param: T)` plus a verify function | `TR/notes/design/architecture/runtime-traits.md:640-642` |
| Secondary vtable adapter tables for supertrait upcasting | Allocation and indirection. The supertrait vtable is a concrete child field | `TR/notes/design/architecture/runtime-traits.md:644-646` |
| Emitting `debug_assert!(pred())` directly | The predicate still runs in a release build. It is wrapped in a `builtin.mode` check | `TR/notes/design/architecture/runtime-traits.md:287-309`, `:648-650` |
| One flat method namespace per struct | A Zig container cannot hold two declarations with the same identifier. Trait impls move to `TraitName_TypeName` | `TR/notes/design/architecture/runtime-traits.md:562-575` |

### 2.5 `structure-memory.md`

| Rejected | Reason | Record |
|---|---|---|
| A context-object allocator | Obscures what a function needs and couples the code to a transpiler runtime struct | `TR/notes/design/architecture/structure-memory.md:201-203`, `:223` |
| An implicit global or thread-local allocator | Hidden state. An explicit parameter or a struct-stored allocator is used | `TR/notes/design/architecture/structure-memory.md:487-489` |
| An allocator parameter on a pure function | A strict `no_alloc` default. Only a function that allocates gains the parameter | `TR/notes/design/architecture/structure-memory.md:491-493` |
| FIFO drop order for local variables | Rust drops locals in reverse declaration order. `defer` at the binding gives LIFO | `TR/notes/design/architecture/structure-memory.md:277-281`, `:495-497` |
| `defer` alone on a fallible initialization | A `try` return skips the normal `defer`. Each acquisition needs its own `errdefer` | `TR/notes/design/architecture/structure-memory.md:291-297` |

### 2.6 `approaches.md`

| Rejected | Reason | Record |
|---|---|---|
| `rustc_driver` as the architecture | A permanent nightly pin. The IR schema follows HIR | `TR/notes/research/approaches.md:86`, `:93` |
| `cargo expand` as ground truth | Lossy text expansion. Hygiene, comments, and spans are not preserved | `TR/notes/research/approaches.md:124` |
| Committing to `rustc_driver` for v1 | Held back as a v6 escape hatch only | `TR/notes/research/approaches.md:398` |
| The FFI boundary as the primary strategy | No inlining across the seam, two allocators, two string types, hand-written ABI structs. Kept as the v4 growth path | `TR/notes/research/approaches.md:170`, `:391` |
| Translating the whole crate graph | The transitive closure reaches `tokio`, `serde`, and `syn` | `TR/notes/research/approaches.md:210`, `:216` |

The recommended architecture is the hybrid dialect of
`TR/notes/research/approaches.md:354`: option (e), a named dialect as a
contract, with the rest left untranslated.

## 3. Contradictions and superseded records

Every record below carries the same 2026-08-18 design date or the 2026-08-17
research date. None of them is current coverage. Where two disagree, the row
names the one that governs and why.

### 3.1 The only explicit supersession

`TR/notes/design/data-model.md:202-209` supersedes open decision 1 for v2 and
later. The rustdoc JSON sidecar is a v0 and v1 stopgap. The stated endgame is a
self-contained Zig producer: tree-sitter reads the source and a Zig inference
engine fills the types. The design record cites a plan for that work and marks
it local-only, so it is absent from this checkout. **Governing:** the
superseding note, `data-model.md:202`, because it is the only record that
claims to override.

### 3.2 Disagreements between records

| Question | Side A | Side B | Governing |
|---|---|---|---|
| Plain `+` and `*` in a match-guard body | Checked operators. Plain `x * 2` becomes `x * 2`: `TR/notes/design/architecture/features-actionable.md:650`, with the same default at `TR/notes/design/data-model.md:197` | Wrapping operators. Plain `x * 2` becomes `x *% 2`: same file, `:279-281` | Side A. Side B breaks the rule the same note states later in its own quality rules, and it is the exact class `TR/notes/research/prior-work.md:135` names. The mini crate confirms the rule holds where it counts: `TR/test/crates/mini/src/util.rs:4` is `v.wrapping_add(1)` and its golden at `features-actionable.md:404` is `+%`. |
| Default integer overflow mode | `checked` as the consensus default with a crate header override: `TR/notes/design/data-model.md:187-188`, `:197` | Undecided, with the sidecar free to say nothing: `TR/notes/design/data-model/exprs-patterns.md:583-589` | Side A. It is the spine record and it fixes a default. Side B is the open question that Side A answers. |
| `&self` on a small struct | Always `self: *const Self`: `TR/notes/design/data-model/exprs-patterns.md:255-258`, `TR/notes/design/data-model/ownership-mem.md:69-75` | `self: *const Self` "or `self: Self` for small scalar types": `TR/notes/design/architecture/structure-memory.md:107` | Side A. The fnv golden keeps the pointer on a one-field struct: `features-actionable.md:472-476` emits `finish(self: *const FnvHasher)`. The size exception would change the ABI. |
| `async fn` | Refused, an explicit unsupported marker: `TR/notes/design/data-model.md:171`, `TR/notes/design/data-model/items-types.md:378` | Lowered to a synchronous function that runs to completion: `TR/notes/design/architecture/features-actionable.md:344-345` | Side A for v1. Side B is a strategy for a later version. The `std.Io` capability claim at `features-actionable.md:341` still holds: `ZSTD/std/Io.zig` and `ZSTD/std/Io/` exist in the pinned 0.16.0 tree. |
| The name of the list type | `std.ArrayList`, unmanaged form, `AlignedManaged` is deprecated: `TR/notes/design/data-model/items-types.md:314-315` | `std.ArrayListUnmanaged(T)`: `TR/notes/design/architecture/features-actionable.md:637` | Side A, against the pinned tree. `ZSTD/std/std.zig:58-59` marks `ArrayListUnmanaged` "Deprecated; use `ArrayList`", and `ZSTD/std/array_list.zig:15-16` marks `AlignedManaged` deprecated. `structure-memory.md:323` agrees with side A. |
| Shape of the id type | Dense IR-local `u32`, renumbered: `TR/notes/design/data-model.md:31-33`, `TR/notes/design/data-model/crate-graph.md:203` | `struct { krate: u32, local: u32 }`: `TR/notes/design/data-model/items-types.md:27`; `u64` "minted by the sidecar": `TR/notes/design/data-model/exprs-patterns.md:35` | Side A. The renumbering rule is stated twice more, at `TR/notes/design/data-model/rustdoc-json-mapping.md:26` and `:57`, and it forbids a sidecar-minted id. |
| Shape of the visibility enum | Five values, with `in_path: []const u8`: `TR/notes/design/data-model.md:76-78`, `crate-graph.md:141-148` | Three values, `pub`, `crate_`, `priv_`: `TR/notes/design/data-model/items-types.md:30` | Side A. The five-value mapping is written out field by field at `rustdoc-json-mapping.md:104-116`. `items-types.md:30` drops `super_restricted` and `in_path`. |
| Path to `hex` sources | `lib.rs` and `error.rs`: `TR/notes/design/architecture/features-actionable.md:499` | `src/lib.rs` and `src/error.rs` on disk | The tree. `TR/test/crates/hex/src/lib.rs` and `TR/test/crates/hex/src/error.rs`. The note omitted the `src/` prefix. |
| Shape of the IR document | Per-crate JSON, `crate-<name>.json`: `TR/notes/design/data-model.md:155` | One document per axis, `crate-graph.json`, with `fns` and sibling tables: `TR/notes/design/data-model/crate-graph.md:383-413` | Neither. Both are drafts and they disagree. A hand port needs no IR, so the port records the shape once and cites which note it followed. |
| Where the allocator comes from | Thread `.param` from the start: `TR/notes/design/data-model.md:189-190`, `:199` | One scoped arena owned by the entry point: `TR/notes/design/data-model/ownership-mem.md:184-187`, open at `:350-354` | Side A. It is the consensus default. Side B is the question side A answers, and side B itself calls the arena "a lie for real `no_std` crates" at `:352-353`. |

### 3.3 Records that are absent from this checkout

`TR/AGENTS.md:3` warns that the notes describe private agent-notes and
archived records, and that their original paths need not be present.
`TR/notes/README.md` warns the same way at `:110-117`.

- `TR/agent-notes` is a symlink to `~/.agents/agent-notes`. The
  target is not on this machine. Nothing in that tree could be cited.
- The source-model and type-inference plan named at
  `TR/notes/design/data-model.md:207` is marked local-only and is not in the
  tree.
- The P1 JSON-boundary implementation plan named at
  `TR/notes/design/data-model/rustdoc-json-mapping.md:19` is marked local-only
  and is not in the tree.
- `TR/notes/design/data-model/rustdoc-json-mapping.md:21` grounds itself in
  `src/fixtures/model/mini-rustdoc.json`. That directory does not exist. The
  script `TR/tools/sidecar/rustdoc-json.sh` does exist, and the fixture that
  `TR/AGENTS.md:7` names, `TR/test/mini-rustdoc.json`, does exist. The note
  points at a path the tree no longer has.

Every record indexed in `TR/notes/README.md` is otherwise present. I listed
`notes/**` and matched the index row by row: 4 research notes, 2 top-level
design notes, 5 data-model detail notes, 4 architecture detail notes.

### 3.4 Searches that found nothing more

- `supersed|archived|obsolete|no longer|overrul|contradict|reverses` over
  `TR/notes/`, `TR/README.md`, and `TR/AGENTS.md` returned one hit, the
  supersession at `data-model.md:202`, plus the warnings at `AGENTS.md:3`
  and `AGENTS.md:10`.
- `reject|refus|we do not|not supported|no zig|instead of|rather than|abandon`
  over the four architecture notes returned the rows already in section 2 and
  no rejection that section 2 omits.

No record carries a retraction. Every design note opens with the same banner
saying it records a proposal, not coverage
(`TR/notes/design/data-model.md:1-5`, repeated in each sibling).

## 4. What the AccessKit port inherits

Ordered by how much damage getting the rule wrong would cause. The first four
produce a wrong value with no trace. The rest produce leaks, use-after-free,
or a wrong public surface.

1. **No silent omission.** Every construct the port cannot map becomes an
   explicit marker with a reason. Nothing is dropped quietly.
   `TR/notes/design/data-model.md:39-41`.
2. **Decide the integer overflow mode per operator, once.** Rust panics on
   overflow in debug and wraps in release. Zig `+` traps and `+%` wraps. A
   wrong choice computes a different number and still passes a smoke test. The
   default is `checked`, declared in one place for the port.
   `TR/notes/design/data-model/exprs-patterns.md:285-303`,
   `TR/notes/design/data-model.md:187-188`, `:197`.
3. **Never emit a bare `std.debug.assert` for a predicate with a cost.** The
   call is elided in release, but the argument still runs. The one
   `debug_assert!` in AccessKit production code sits in a text-range path at
   `AK/adapters/windows/src/text.rs:86`. A grep for `assert!(` and
   `debug_assert!(` over `AK` returns test bodies only outside that line.
   `TR/notes/design/architecture/runtime-traits.md:287-309`, `:648-650`.
4. **An `assert_unreachable` marker must be `if (!cond) @panic(...)`.** A
   `std.debug.assert` vanishes in ReleaseFast and takes the check with it.
   `TR/notes/design/data-model/ownership-mem.md:226-228`.
5. **The allocator is always explicit.** No global, no thread-local. An
   allocating function gains a leading `allocator: std.mem.Allocator`
   parameter. A construct whose allocator cannot be sourced is refused, not
   guessed. `TR/notes/design/architecture/structure-memory.md:487-489`,
   `TR/notes/design/data-model/ownership-mem.md:300-309`.
6. **A pure function gains no allocator parameter.** The default is `no_alloc`.
   Adding the parameter to every signature is a call-graph-wide change.
   `TR/notes/design/architecture/structure-memory.md:491-493`.
7. **Drop order is not free.** Locals use `defer` at the binding so Zig's LIFO
   order matches Rust's reverse-declaration order. Struct fields drop in
   declaration order inside `deinit`. Writing the defers in declaration order
   reverses the sequence. `TR/notes/design/architecture/structure-memory.md:277-289`,
   `TR/notes/design/data-model/ownership-mem.md:130-137`.
8. **`errdefer` after every fallible acquisition.** A `try` return skips the
   normal `defer`, so a partial build leaks without it.
   `TR/notes/design/architecture/structure-memory.md:291-297`.
9. **`&T` becomes `*const T` and `&mut T` becomes `*T`, always.** The
   small-struct copy exception at `structure-memory.md:107` loses here: the
   fnv golden keeps the pointer on a one-field struct at
   `features-actionable.md:472-476`. A copy changes aliasing and the ABI.
10. **The loss of the borrow checker is marked, never assumed away.** Zig
    does not enforce `&mut` uniqueness, and a borrow that outlives its owner
    is invisible to a release build. Mark the site.
    `TR/notes/design/data-model/ownership-mem.md:199-230`.
11. **Assume the input compiles, and report wrong output, not missing
    checks.** The input has already passed the Rust borrow checker. The
    finding that matters is a value that computes wrong on valid code.
    `TR/AGENTS.md:12-20`.
12. **`?` becomes `try`. `unwrap` and `expect` are decided by the resolved
    callee, never by the method name.** A name-based rule catches a
    user method called `unwrap` and misses a renamed standard method.
    `TR/notes/design/data-model/exprs-patterns.md:331-343`,
    `TR/notes/design/architecture/features-actionable.md:222-224`.
13. **Visibility reduces conservatively and never widens.** A `pub(crate)`
    item stays out of the package root. Zig has two visibility levels, so the
    reduction is a decision that must be written down per item.
    `TR/notes/design/data-model/crate-graph.md:134-138`,
    `TR/notes/design/architecture/structure-memory.md:75-81`.
14. **An unknown attribute survives as a comment.** An attribute the port does
    not read may carry a layout or ABI promise.
    `TR/notes/design/data-model.md:89-90`,
    `TR/notes/design/data-model/items-types.md:195-196`.
15. **An FFI boundary is a last resort, not an answer.** No `extern "C"`, no
    `extern "union"`, no hand-written ABI struct, and no Rust toolchain. The
    records keep the seam for what cannot be translated
    (`TR/notes/research/approaches.md:170`, `:391`). The port is stricter.
    Zig standard library, then a Zig package pinned in `build.zig.zon`, then
    `translate-c`, and a C shim only with a named reason.
