# 24. Rust idiom mapping for the zaccesskit port

Consumed by `docs/30-port-design.md`. The sibling document is
`docs/25-r2z-oracle-and-promotion.md`.

## 0. Scope, sources, and path prefixes

This document transfers the rules that `translate-rust` recorded while mapping
Rust to Zig, and checks each rule against the real AccessKit source. It does
not claim that `translate-rust` supports any Rust shape. Only the recorded
files below carry authority, and most of them are dated research, not current
coverage.

### 0.1 Reference trees

| Short name | Absolute path | Pin |
|---|---|---|
| `TR` | `~/translate-rust` | read only, never built |
| `AK` | `/tmp/scratch/accesskit` | commit `466e24e252103f4d82bd6fbab98141b551e46e0c`, version 0.25.1 |
| `AKC` | `/tmp/scratch/accesskit-c` | commit `8b6ed37c20ed4c59390e253407983333053662ba`, version 0.23.1 |
| `ZSTD` | `/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/std` | Zig 0.16.0 |

Every citation in this document uses one of those four prefixes, for example
`TR/notes/research/idiom-mapping.md:89`. Append the prefix and the line number
to the absolute path to resolve it.

### 0.2 Evidence rules used here

| Marker | Meaning |
|---|---|
| `path:line` | Observed directly in the cited file on the date of writing. |
| `[INFERENCE]` | Not directly observed. Derived by reasoning from cited facts. |

The source trees below were read but not modified. No build, test, formatter,
or linter ran against any of them.

### 0.3 Files that were not present

`TR/AGENTS.md:3` warns that some indexed records may be archived and absent
from the checkout. Every record that `TR/notes/README.md` indexes is present
except one tree:

- `TR/agent-notes/` is empty. `TR/AGENTS.md:3` names it as the place for
  accumulated working records. Nothing in it could be cited.

---

## 1. The input contract

### 1.1 The contract, quoted

From `TR/AGENTS.md:12-20`:

> - **Assume the input crate compiles.** The contract is valid Rust in, faithful
>   Zig out. There is no borrow checker and none is planned: Rust's is a
>   compile-time guarantee, so anything reaching this translator has already had
>   it, and Zig and C are equally permissive about aliasing. A probe round found
>   that two simultaneous `&mut` borrows translate to compiling Zig with a
>   meaningless value — that is out of scope by decision, not an open gap. Do not
>   report borrow-rule violations, or the same class of input a target language
>   would also accept, as findings. What does count is wrong output for code that
>   is valid, especially when it compiles and computes the wrong value.

From `TR/README.md:24-30`:

> ## Input contract
>
> The input crate is assumed to compile. The contract is valid Rust in, faithful
> Zig out. Rust has already checked borrowing, so this translator does not include
> a borrow checker. Invalid Rust borrow patterns are outside the input contract;
> wrong output for valid Rust is a defect, including output that compiles but
> computes the wrong value.

The pipeline the contract governs is recorded at `TR/README.md:34-38`:

```text
Rust source -> tree-sitter -> frontend -> canonical RustIr -> ZigAST
            -> staged package validation -> the generated package's own
               `zig build test` -> atomic promotion
```

`TR/README.md:20-22` records that crate translation reads Rust source directly
and runs neither Cargo nor rustc. This matters for the port, which forbids a
Rust toolchain entirely.

### 1.2 What a reviewer is entitled to demand

A reviewer may demand all of the following for any single function of the port.

| Demand | Source of the demand |
|---|---|
| The Zig output must compute the same value as the Rust source for every input the source accepts. | `TR/AGENTS.md:19-20` |
| A value that differs only in allocation count, call order without observable effect, or internal representation does not count as wrong. | `[INFERENCE]` from `TR/AGENTS.md:19-20` |
| Every public Rust item has a direct Zig counterpart, recorded one by one. | Port philosophy, this effort |
| Every construct the emitter cannot lower carries an explicit refusal, never a silent omission. | `TR/notes/design/data-model.md:39-41` |
| Every undocumented Rust attribute survives in the output as a comment or a recorded marker. | `TR/notes/design/data-model/items-types.md:195-196` |
| The output compiles under the pinned Zig with no source in the target language left behind. | Port philosophy, this effort |

The refusal rule is the load-bearing one. `TR/notes/design/data-model.md:39-41`
states the model is "Lossless but gated" and that "finite unsupported forms are
first-class `Unsupported` nodes with a reason — never silent omission".
`TR/notes/design/data-model/exprs-patterns.md:531-534` repeats it as the rule
for the expression layer. The shipped translator enforces it in code:
`TR/src/ir/validate.zig:48-51` declares the four refusal errors
`UnsupportedExternalNominalType`, `UnsupportedExpression`, `UnsupportedPattern`,
and `UnsupportedType`, and `TR/src/ir/validate.zig:2491-2497` shows that a
marker with a reason string is turned into `error.UnsupportedExpression`
rather than passed through. `TR/README.md:304-308` states that this is not an
exemption: "wrong output for valid Rust is a defect wherever it appears".

### 1.3 What is out of scope

| Out of scope | Source |
|---|---|
| Invalid Rust that does not compile. | `TR/AGENTS.md:12-14` |
| A borrow checker, in any form, on the output side. | `TR/AGENTS.md:13-14` |
| Borrow-rule violations as review findings. | `TR/AGENTS.md:17-19` |
| Any class of input the target language would also accept. | `TR/AGENTS.md:18-19` |
| Complete Rust semantics. "Nothing here promises general Rust support or complete Rust semantics." | `TR/README.md:312-314` |
| Standalone source trait declarations. `TR/README.md:311-313` records them as unsupported. | `TR/README.md:311-313` |
| Translating dependency crates. Cargo dependencies enter the IR as metadata only. | `TR/README.md:310-311` |
| Build scripts. "Build scripts are not executed." | `TR/README.md:285-286` |
| Coverage claims drawn from a fixture list. "Read 'translates' as 'this fixture translates', never as 'this shape of Rust translates'." | `TR/README.md:322-323` |

### 1.4 The two-`&mut` probe finding, and what a hand port does instead

The recorded probe finding is at `TR/AGENTS.md:15-17`:

> A probe round found that two simultaneous `&mut` borrows translate to compiling
> Zig with a meaningless value — that is out of scope by decision, not an open gap.

The scope decision is sound for a mechanical translator. It stops being sound
for a hand port, because the port has no emitter to blame and no differential
test harness to catch it. The mechanism behind the finding is recorded at
`TR/notes/research/idiom-mapping.md:349-353`:

> - Borrowing rules *disappear* — the translator emits `*T`/`[]const T` but there is no
>   compiler to enforce aliasing. Document the translated ownership contract; Zig returns
>   `error.OutOfMemory`/runtime UB where Rust would have refused to compile.
> - `&mut T` (unique borrow) → `*T`; the translator must not introduce aliasing that Zig
>   would allow but Rust forbade. This is a *correctness* risk, not a compile error.

The record's own warning is that this is a correctness risk, not a compile
error. `TR/notes/design/data-model/ownership-mem.md:20-30` restates it: the IR
cannot represent borrow checking, so it must record enough usage to flag points
where Zig's runtime checks do not reproduce Rust's borrow safety. The flag is
`UnsoundMarker` at `TR/notes/design/data-model/ownership-mem.md:207-223`, with
categories `alias_mut`, `borrow_outlives_owner`, `returned_dangling`,
`copy_alias`, and `interior_mut`, and severities `comment`,
`assert_unreachable`, and `redesign_required`. The emitter contract is at
`TR/notes/design/data-model/ownership-mem.md:225-229`.

What a hand port must do instead, in order:

| Step | Action | Why |
|---|---|---|
| 1 | Thread `io: std.Io` and every allocator as an explicit parameter on every function that needs one. House rule, `~/ozai/AGENTS.md:59-63`. | Makes the hidden input visible in the signature, so two live `&mut` aliases cannot appear by accident. |
| 2 | Make shared mutable state a parameter of the function that reads it, never a capture. House rule, `ozai/AGENTS.md:69-70`. | A captured `*T` inside a closure hides the aliasing that the Rust signature made illegal. |
| 3 | Split every state machine into a pure function over decoded input and a loop that drives it. House rule, `ozai/AGENTS.md:65-68`, `:71-72`. | A pure step has one caller-visible state value, so an alias shows up as a wrong state value in a test. |
| 4 | Record every place that replaces a Rust borrow guarantee with a runtime flag, as an explicit comment or assertion in the port. `TR/notes/design/data-model/ownership-mem.md:225-229`. | The translator had an IR field for this. A hand port has only a comment. |
| 5 | Assert the claim with a recorded fixture, not with a live `cargo` run. | Port philosophy forbids a Rust toolchain. |

Step 5 needs one recorded fixture per replaced guarantee. The record supplies
the shape of such a check at `TR/notes/design/data-model/ownership-mem.md:6.2`
and at `TR/notes/design/data-model/ownership-mem.md:225-229`. The house rule
that a claim without a fixture is unverified is at `ozai/AGENTS.md:89-91`.

---

## 2. The construct table

This is the centre of the document. One row per Rust construct. The columns
are:

| Column | Content |
|---|---|
| Rust form | The construct, with a real example from the AccessKit source. |
| Zig form | What the translator emits, per the record or the translator source. |
| Evidence | A `path:line` in the record, in the translator, or in a checked-in golden file. |
| Verdict | `applies`, `does not apply`, or `applies with caveat` for AccessKit. |
| AccessKit evidence | A `path:line` in AccessKit, accesskit-c, or the Zig standard library. |
| Caveat | What a hand port must decide that the rule does not decide. |

The verdict `does not apply` is used only where the construct is absent from
every AccessKit tree examined. That is a useful result: the rule is not
inherited by this port.

### 2.1 Functions, methods, and declarations

| Rust form | Zig form | Evidence | Verdict | AccessKit evidence | Caveat |
|---|---|---|---|---|---|
| Free function `fn f(a: T) -> R` | Top-level `pub fn f(a: T) R` | `TR/notes/research/idiom-mapping.md:24-59`; golden `TR/test/golden/zig_src/fnv/src/root.zig:120` `pub fn FnvHashMap(comptime K: type, comptime V: type) type {` and `:125` | applies | `AK/accesskit/src/geometry.rs:139-146` `pub fn is_nan(&self) -> bool` inside an `impl` | none |
| Method `fn f(&self)` | `pub fn f(self: *const Self) R` | `TR/notes/research/idiom-mapping.md:89-91`; `TR/notes/design/data-model/items-types.md:110-112`; golden `TR/test/golden/zig_src/fnv/src/root.zig:101` | applies | `AK/accesskit/src/lib.rs:1858-1860` `pub fn role(&self) -> Role` | `TR/notes/design/architecture/structure-memory.md:107` hedges with "or `self: Self` for small scalar types". The translator does not take that hedge; see section 6, row 6. |
| Method `fn f(&mut self)` | `pub fn f(self: *Self) R` | same three paths; golden `TR/test/golden/zig_src/fnv/src/root.zig:106` | applies | `AK/accesskit/src/lib.rs:1862-1864` `pub fn set_role(&mut self, value: Role)` | An unchecked `*Self` is where the two-`&mut` gap lands. See section 1.4. |
| Consuming method `fn f(self)` | `pub fn f(self: Self) R` | `TR/notes/research/idiom-mapping.md:90-91` | applies | `AK/accesskit/src/lib.rs:353-355` `fn mask(self) -> u32` | Zig copies `Self` on entry, so a consuming receiver silently becomes a copying one. AccessKit's `mask` is `Copy`, so no damage here. `AK/accesskit/src/lib.rs:3305-3321` has non-`Copy` receivers elsewhere. |
| Associated function, no receiver | `pub fn name(args) Ret` in the same container | `TR/notes/research/idiom-mapping.md:92-93`; golden `TR/test/golden/zig_src/fnv/src/root.zig:90` | applies | `AK/accesskit/src/lib.rs:1827-1833` `pub fn new(role: Role) -> Self` | Zig `init` is the house convention (`ozai/AGENTS.md:46`). Do not keep the Rust name `new`. |
| `pub const fn` | `pub fn` evaluated at comptime | `[INFERENCE]` from `TR/notes/research/idiom-mapping.md:205-208` | applies | `AK/accesskit/src/geometry.rs:53-55` `pub const fn new(c: [f64; 6]) -> Affine`; `AK/accesskit/src/geometry.rs:59-61` `pub const fn scale(s: f64) -> Affine` | Call sites that used `Affine::IDENTITY` in a `const` context need the Zig side to stay comptime-evaluable. |
| Associated constant | Container-level `pub const NAME: T = ...` | `[INFERENCE]` from `TR/notes/research/idiom-mapping.md:114-119` | applies | `AK/accesskit/src/geometry.rs:26` `pub const IDENTITY: Affine = Affine::scale(1.0)`; `AK/accesskit/src/lib.rs:749` `pub const ROOT: Self = Self(Uuid::nil())` | `Uuid::nil()` is a foreign call. It must become a byte literal in Zig. |
| Inherent `impl` block | Methods fold into the emitted `struct` container | `TR/notes/design/data-model/items-types.md:144-146`; `TR/notes/design/architecture/structure-memory.md:101-136` | applies | `AK/accesskit/src/lib.rs:352-388` `impl Action`; `AK/accesskit/src/lib.rs:1856-1907` `impl Node`; `AK/accesskit/src/lib.rs:822-826` `impl Flag` | AccessKit uses many separate `impl` blocks for one type. Zig needs one container. Merge them. |
| `impl Trait for LocalType` | Trait methods folded into the struct, or namespaced | `TR/notes/design/data-model/items-types.md:145-146`; `TR/notes/design/architecture/runtime-traits.md:569-608` | applies with caveat | `AK/accesskit/src/lib.rs:731-735` `impl fmt::Debug for NodeId`; `AK/accesskit/src/lib.rs:1836-1854` `impl Clone for Node`; `AKC/src/common.rs:693-697` `impl CastPtr for custom_action` | The record leaves the split open (`TR/notes/design/data-model/items-types.md:392-395`). Resolve it in `docs/30-port-design.md` before writing code. |
| `impl` for an operator trait | Named methods on the type. Zig has no operator overloading. | `TR/notes/research/idiom-mapping.md:61-99` has no operator rule. The gap is visible in the goldens: `TR/test/golden/zig_src/fnv/src/root.zig:101-112` emits only `finish` and `write`. | applies with caveat | `AK/accesskit/src/geometry.rs:253-260` `impl Add<Vec2> for Point`; `AK/accesskit/src/geometry.rs:191-205` `impl Mul<Affine> for f64`; `AK/accesskit/src/geometry.rs:643` `impl Div<f64> for Size` | No honest Zig form. See section 3, item 13. |
| `impl` for `From`/`Into` | Named conversion functions, or a comptime `to`/`from` pair | `[INFERENCE]` from `TR/notes/research/idiom-mapping.md:92-93` | applies with caveat | `AK/accesskit/src/geometry.rs:239-251` `impl From<(f64, f64)> for Point` and `impl From<Point> for (f64, f64)`; `AK/accesskit/src/lib.rs:717-729` `impl From<NodeIdContent> for NodeId` | `Into` in argument position has no Zig form. See section 3, item 3. |
| Type alias `pub type Tree = TreeInfo` | `pub const Tree = TreeInfo;` | `TR/notes/design/data-model/items-types.md:124-130` | applies with caveat | `AK/accesskit/src/lib.rs:3178-3179` `#[deprecated(note = "Use TreeInfo instead")] pub type Tree = TreeInfo;` | The construct is present but deprecated upstream. The port must delete it, per `ozai/AGENTS.md:51-52` and `ozai/AGENTS.md:190-192`. See section 3.18. |

### 2.2 Types

| Rust form | Zig form | Evidence | Verdict | AccessKit evidence | Caveat |
|---|---|---|---|---|---|
| Named-field struct | `pub const T = struct { ... }` | `TR/notes/research/idiom-mapping.md:61-99` | applies | `AK/accesskit/src/lib.rs:1107-1113` `pub struct Node { role: Role, actions: u32, ... }` | Rust fields are private by default. Zig fields are private too, so no change. |
| Tuple struct, newtype | `struct { field: T }`, accessed as a field not a tuple | `TR/notes/design/data-model/items-types.md:66` "tuple fields → positional `field_0..N`" | applies with caveat | `AK/accesskit/src/lib.rs:715` `pub struct NodeId(pub NodeIdContent)`; `AK/accesskit/src/geometry.rs:22` `pub struct Affine([f64; 6])` | The golden uses `@"0"`: `TR/test/golden/zig_src/fnv/src/root.zig:102` `return self.@"0";`. The record says `field_0`. Pick one and record it. |
| `#[repr(transparent)]` | Single-field `extern struct`, or the inner type plus free functions | `TR/notes/research/idiom-mapping.md:691-692`; `TR/notes/design/data-model/items-types.md:67-69` | applies with caveat | `AK/accesskit/src/lib.rs:714-715` `#[repr(transparent)] pub struct NodeId(pub NodeIdContent)`; `AK/accesskit/src/lib.rs:744-745` `#[repr(transparent)] pub struct TreeId(pub Uuid)`; `AKC/src/common.rs:1227-1228` `#[repr(transparent)] pub struct tree_update_factory_userdata(pub *mut c_void)` | `TreeId` is transparent over a foreign type that is itself transparent. Two levels of layout must be pinned. See section 3, item 2. |
| `#[repr(C)]` struct | `extern struct` | `TR/notes/research/idiom-mapping.md:94-97`; `TR/notes/design/data-model/items-types.md:67` | applies | `AK/accesskit/src/lib.rs:833-839` `#[repr(C)] pub struct Color`; `AK/accesskit/src/geometry.rs:211-217` `#[repr(C)] pub struct Point`; `AKC/src/common.rs:207-210` `#[repr(C)] pub struct tree_id { pub bytes: [u8; 16] }` | A plain `struct` does not give the C ABI. Use `extern struct` everywhere the type crosses the C boundary. |
| `#[repr(C)]` struct holding a `#[repr(u8)]` enum | `extern struct` with a field of type `enum(u8)` | `TR/notes/research/idiom-mapping.md:684-685`; `TR/notes/research/idiom-mapping.md:153-154` | applies with caveat | `AK/accesskit/src/lib.rs:846-850` `#[repr(C)] pub struct TextDecoration { pub style: TextDecorationStyle, pub color: Color }` with `TextDecorationStyle` at `AK/accesskit/src/lib.rs:674-675` `#[repr(u8)]` | The struct layout depends on the enum's backing integer. Both must be pinned and asserted with a `comptime` size check (`ozai/AGENTS.md:38-40`). |
| C-like enum `#[repr(u8)]` | `enum(u8)` | `TR/notes/research/idiom-mapping.md:106-113`; `TR/notes/research/idiom-mapping.md:153-154` | applies | `AK/accesskit/src/lib.rs:61-62` `#[repr(u8)] pub enum Role`; `AK/accesskit/src/lib.rs:288-289` `#[repr(u8)] pub enum Action` | The record says Zig enum tags are always lowercase (`TR/notes/research/idiom-mapping.md:143-144`). The golden does not do that. See section 6, row 7. |
| Enum with a `#[default]` arm | The zero-valued tag, or a `default()` fn | `TR/notes/design/data-model/items-types.md:185-193` has no `#[default]` row. `[INFERENCE]` | applies | `AK/accesskit/src/lib.rs:63-64` `#[default] Unknown,` inside `pub enum Role` | `Unknown` is discriminant 0. A Zig `enum` cannot carry a default, so `Role` needs a `pub fn default() Role` or a documented zero value. |
| Data-carrying enum | `union(enum)` | `TR/notes/research/idiom-mapping.md:116-121`; golden `TR/test/golden/zig_src/compat/src/root.zig:1252-1256` | applies | `AK/accesskit/src/lib.rs:856-886` `enum PropertyValue` with `NodeIdVec(Vec<NodeId>)`, `String(String)`, `Affine(Box<Affine>)`, `TreeId(TreeId)` | A unit variant becomes a `void` payload. The golden shows `Other: void` at `TR/test/golden/zig_src/compat/src/root.zig:1256`. |
| `#[repr(C)]` data-carrying enum | No honest Zig form | not in the record | applies with caveat | `AK/accesskit/src/lib.rs:3304-3321` `#[repr(C)] pub enum ActionData`; `AKC/src/common.rs:1069-1082` `#[repr(C)] pub enum action_data` | See section 3, item 1. This is the single highest-risk ABI item. |
| Private enum | Same as a public one | `TR/notes/design/data-model/crate-graph.md:141-148` | applies | `AK/accesskit/src/lib.rs:800-801` `#[repr(u8)] enum Flag`; `AK/accesskit/src/lib.rs:892-893` `enum PropertyId`; `AK/accesskit/src/lib.rs:855-856` `enum PropertyValue` | Rust has no `pub(crate)`-free privacy for types at module scope other than plain private. Zig matches. |
| `Option<T>` | `?T` | `TR/notes/research/idiom-mapping.md:276-279`; `TR/notes/design/data-model/items-types.md:290-292` | applies | `AK/accesskit/src/lib.rs:358` `fn n(value: u8) -> Option<Self>`; `AK/accesskit/src/lib.rs:3173` `pub toolkit_name: Option<String>`; `AK/accesskit/src/lib.rs:3332` `pub data: Option<ActionData>` | A `match` on an `Option` cannot become a `switch`, because a Zig optional is not a union. The record says so at `TR/notes/research/idiom-mapping.md:277-279` and `TR/notes/research/idiom-mapping.md:389-390`. |
| `Result<T, E>` with a finite `E` | `E!T` | `TR/notes/research/idiom-mapping.md:280-281` | applies with caveat | `AK/accesskit/src/lib.rs:732-734` `-> fmt::Result`, where `fmt::Result` is a unit struct, not an error set | The rule binds the port, but not through this line. `[INFERENCE]` `fmt::Result` has no variants, so it is not an error set. Every fallible signature in AccessKit takes its error type from an external crate, for example `zbus::Result<()>` at `AK/adapters/unix/src/context.rs:173`, so the port defines its own error sets. |
| `Result<T, E>` where `E` carries data | `union(enum) { ok: T, err: E }` | `TR/notes/design/architecture/features-actionable.md:187-209`; golden `TR/test/golden/zig_src/hex/src/error.zig:23-36` | applies with caveat | `AKC/src/common.rs:1084-1090` `impl Drop for action_data` frees `Self::Value` on drop, so the error arm owns memory | The golden keeps the Rust name: `TR/test/golden/zig_src/hex/src/error.zig:26` `InvalidHexCharacter: struct { c: u21, index: usize },`. Drop on a tagged union needs a hand-written `deinit`. |
| `?` operator | `try` | `TR/notes/research/idiom-mapping.md:281`; `TR/notes/design/data-model/exprs-patterns.md:331` | applies | `AK/accesskit/src/lib.rs:2814` `let _ = $map.next_value::<IgnoredAny>()?;` | `try` needs an error union. A function that had no error set gains one. |
| `Vec<T>` | `std.ArrayList(T)` unmanaged, `.empty`, explicit allocator | `TR/notes/research/idiom-mapping.md:481`; `TR/notes/research/idiom-mapping.md:469-471` | applies | `AK/accesskit/src/lib.rs:1073` `values: Vec<PropertyValue>`; `AK/accesskit/src/lib.rs:3229` `pub nodes: Vec<(NodeId, Node)>` | The record rejects the managed `ArrayList`: `TR/notes/research/idiom-mapping.md:469-471`. Confirm against `ZSTD/array_list.zig:569`. |
| `&[T]`, `&mut [T]` | `[]const T`, `[]T` | `TR/notes/research/idiom-mapping.md:311`; `TR/notes/design/data-model/items-types.md:269` | applies | `AK/accesskit/src/lib.rs:1076` `fn value_at(values: &[PropertyValue], index: u8) -> &PropertyValue`; `AK/accesskit/src/lib.rs:1671` `(set_length_vec_property, Vec<u8>, LengthVec)` | A slice carries its length, so an unchecked index becomes a panic, not memory corruption, under `ReleaseSafe`. `ZSTD/debug.zig:237-240` confirms `runtime_safety` is true only in `.Debug` and `.ReleaseSafe`. |
| `[T; N]` | `[N]T` | `TR/notes/research/idiom-mapping.md:217`; `TR/notes/design/data-model/items-types.md:282` | applies | `AK/accesskit/src/geometry.rs:22` `pub struct Affine([f64; 6])`; `AK/accesskit/src/lib.rs:1062` `struct PropertyIndices([u8; PropertyId::Unset as usize])` | See section 3, item 19 for the enum-driven array length. |
| `String` | `std.ArrayList(u8)` unmanaged, or `[]u8` plus a length | `TR/notes/research/idiom-mapping.md:444-446`; `TR/notes/design/data-model/items-types.md:314-315` | applies | `AK/accesskit/src/lib.rs:763` `pub description: String`; `AK/accesskit/src/lib.rs:860` `String(String)` | Every `String` field forces a `deinit`. The record's allocator map is at `TR/notes/research/idiom-mapping.md:498-501`. |
| `&str` | `[]const u8` | `TR/notes/research/idiom-mapping.md:445-446`; `TR/notes/design/data-model/items-types.md:311` | applies | `AK/accesskit/src/lib.rs:1671` a `&[u8]` property getter; `AK/accesskit/src/lib.rs:735` in `write!(f, "#{}", self.0)` | A Rust `&str` is never null-terminated, so a `&str` crossing the C ABI must not become a `[:0]const u8`. See `TR/notes/research/idiom-mapping.md:466-468`. |
| `Box<str>` | `[]u8` with an allocator, or `[:0]const u8` for C | `TR/notes/research/idiom-mapping.md:315` | applies with caveat | `AK/accesskit/src/lib.rs:3307` `Value(Box<str>)`; `AKC/src/common.rs:1072` `Value(*mut c_char)` | AccessKit-c already chose the C form. The core and the C binding disagree on representation. See section 7, item 13. |
| `Box<T>` | `*T` with `allocator.create` and `defer allocator.destroy` | `TR/notes/research/idiom-mapping.md:315`; `TR/notes/design/data-model/ownership-mem.md:170-175` | applies | `AK/accesskit/src/lib.rs:881` `Affine(Box<Affine>)`; `AK/accesskit/src/lib.rs:883` `TextSelection(Box<TextSelection>)` | A `Box` inside a `union(enum)` payload needs a recursive `deinit`. The record's example is at `TR/notes/design/architecture/structure-memory.md:378-396`. |
| `&T`, `&mut T` | `*const T`, `*T` | `TR/notes/research/idiom-mapping.md:311`; `TR/notes/design/data-model/ownership-mem.md:68-84` | applies with caveat | `AK/accesskit/src/lib.rs:1116` `fn get<'a>(&self, values: &'a [PropertyValue], id: PropertyId) -> &'a PropertyValue`; `AKC/src/lib.rs:136` `pub(crate) fn ref_from_ptr<'a, F, T>(from: *const F) -> &'a T` binds the returned lifetime to nothing, so the result may dangle; `AKC/src/lib.rs:206` `pub(crate) fn debug_repr_from_ptr<F, T>(value: *const F) -> *mut c_char` is the same shape | The lifetime on `get` comes from `values`. The lifetime on `ref_from_ptr` is unconstrained, which is the record's `returned_dangling` category at `TR/notes/design/data-model/ownership-mem.md:211`. Zig cannot express either. See section 3, item 3 and section 7, item 1. |
| Raw pointer `*const T`, `*mut T` | `[*]allowzero align(1) const T` and `[*]allowzero align(1) T` | `TR/README.md:240-247`; `TR/notes/research/idiom-mapping.md:649-657` | applies | `AKC/src/common.rs:87` `pub extern "C" fn $c_getter(node: *const node) -> *const $getter_result`; `AKC/src/common.rs:152` `pub values: *const $ffi_type` | The translator's form makes a null address representable and makes `==` read addresses. The record says so at `TR/README.md:240-243`. |
| `unsafe` block | No keyword. The whole function is on the hook. | `TR/notes/research/idiom-mapping.md:654-655` | applies | `AKC/src/common.rs:167-169` `unsafe { slice::from_raw_parts(...) }`; `AKC/src/common.rs:264` `unsafe { CStr::from_ptr(value) }` | Absent from the core and from `adapters/unix`: `grep -rc unsafe` over `AK/adapters/unix/src/*.rs` returns 0. Present in the platform adapters, first at `AK/adapters/windows/src/subclass.rs:45`, whose `:44` is the `extern "system"` signature above it. |
| Tuple `(f64, f64)` | Anonymous struct, or two named fields | `TR/notes/design/data-model/items-types.md:282` "tuples→anonymous structs" | applies with caveat | `AK/accesskit/src/geometry.rs:241` `fn from(v: (f64, f64)) -> Point`; `AK/accesskit/src/lib.rs:3229` `pub nodes: Vec<(NodeId, Node)>` | The record's `evaluate_pair` example uses `@"0"` and `@"1"`: `TR/notes/design/architecture/features-actionable.md:275-276`. A tuple in a `Vec` needs a two-field struct in Zig. |
| `char` | `u21` | `TR/notes/design/data-model/items-types.md:270-271` | applies | `AKC/src/common.rs:264-267` `CStr::from_ptr(value)` then `.to_string_lossy()` | The golden shows the mapping: `TR/test/golden/zig_src/hex/src/error.zig:26` `InvalidHexCharacter: struct { c: u21, index: usize },`. Confirm the codepoint type against `ZSTD/unicode.zig:12`. |
| `PhantomData<T>` | Zero-size field, or omit and document | no record rule | applies | `AK/adapters/unix/src/executor.rs:41` `phantom: PhantomData<&'a ()>,` | Carries a lifetime with no runtime size. In Zig, drop the field and document the borrow. |
| Generic type parameter | `comptime T: type`, declared first | `TR/notes/research/idiom-mapping.md:186-198`; `TR/notes/design/data-model/items-types.md:224-226` | applies | `AK/accesskit/src/lib.rs:2885-2888` `fn visit_map<V>(self, mut map: V) -> Result<Self::Value, V::Error>`; `AKC/src/common.rs:21` `pub struct ActionHandlerWrapper<H: ActionHandler + Send>(Mutex<H>);` | The record puts comptime params after `self` in methods: `TR/notes/research/idiom-mapping.md:216-217`. |
| Generic function with bounds | `comptime T: type` plus a comptime `@hasDecl` check | `TR/notes/design/architecture/runtime-traits.md:377-408` | applies with caveat | `AK/adapters/unix/src/executor.rs:46-50` `fn spawn<T: Send + 'static>(&self, future: impl Future<Output = T> + Send + 'static, ...)` | `Send` and `'static` are auto traits with no Zig equivalent. The record flags this at `TR/notes/research/idiom-mapping.md:258-261`. |
| `where` clause | Not emitted. Kept for diagnostics. | `TR/notes/design/data-model/items-types.md:224-226`; `TR/notes/research/idiom-mapping.md:211-213` | applies | `AK/accesskit/src/lib.rs:2822-2825` `fn serialize<S>(...) -> Result<S::Ok, S::Error> where S: Serializer` | Duck typing loses the bound. AccessKit's `S::Ok` and `S::Error` are associated types on the bound. See the associated-types row. |
| `impl Trait` in argument position | No direct form. Take the concrete type. | `TR/notes/design/data-model/items-types.md:6` lists no `impl Trait` node | applies with caveat | `AK/accesskit/src/lib.rs:1264` `fn $method(&mut self, id: PropertyId, value: impl Into<$type>)`; `AK/adapters/unix/src/adapter.rs:196` `pub fn update_if_active(&mut self, update_factory: impl FnOnce() -> TreeUpdate)` | See section 3, item 3. `impl Trait` hides the type from the caller. |
| Const generic `[T; N]` | `comptime N: usize` | `TR/notes/research/idiom-mapping.md:200-208` | does not apply | No `const N: usize` generic parameter in `AK/accesskit/src/lib.rs`, `AK/accesskit/src/geometry.rs`, or `AKC/src/*.rs`. `[INFERENCE]` from the absence of the token. | none |
| Associated type `type Output = T;` | An extra comptime parameter, or a witness struct | `TR/notes/research/idiom-mapping.md:258-261` | applies with caveat | `AK/accesskit/src/geometry.rs:157` `type Output = Point;`; `AK/adapters/unix/src/executor.rs:137` `type Output = T;`; `AKC/src/common.rs:693-694` `type RustType = CustomAction;`; `AK/accesskit/src/lib.rs:2878` `type Value = Properties;` | Four distinct associated types in one codebase. Each needs its own Zig shape. The record lists associated types as having no direct analogue. |
| Trait declaration, object-safe | `anyopaque` plus a fn-pointer struct | `TR/notes/research/idiom-mapping.md:245-256`; `TR/notes/design/architecture/runtime-traits.md:419-469` | applies with caveat | `AK/accesskit/src/lib.rs:3336-3359` `pub trait ActivationHandler`; `AK/accesskit/src/lib.rs:3362-3373` `pub trait ActionHandler`; `AK/accesskit/src/lib.rs:3376-3385` `pub trait DeactivationHandler`; `AK/adapters/atspi-common/src/callback.rs:11` `pub trait AdapterCallback` | All four take only `&mut self` methods. That is the one shape a Zig fn-pointer table reproduces exactly. |
| Trait object `Box<dyn T>`, `Arc<dyn T + Send + Sync>` | `{ ptr: *anyopaque, vtable: *const VTable }` | `TR/notes/research/idiom-mapping.md:251-256`; `TR/notes/design/architecture/runtime-traits.md:430-468` | applies with caveat | `AK/adapters/unix/src/adapter.rs:84` `action_handler: Arc<dyn ActionHandlerNoMut + Send + Sync>`; `AK/adapters/unix/src/adapter.rs:249-251` `activation_handler: Box<dyn ActivationHandler + Send>`; `AK/adapters/atspi-common/src/context.rs:38` `action_handler: Arc<dyn ActionHandlerNoMut + Send + Sync>` | The record calls this the hardest tier and the first v1 blocker: `TR/notes/research/idiom-mapping.md:270-272`, `:731-732`. |
| `dyn` upcast through a supertrait | Nested vtable plus `@fieldParentPtr` | `TR/notes/design/architecture/runtime-traits.md:504-557` | applies with caveat | `AKC/src/lib.rs:113` `pub(crate) trait BoxCastPtr: CastPtr + Sized {` is a supertrait. None of the four core traits declares one: `AK/accesskit/src/lib.rs:3336`, `:3362`, `:3376`, and `AK/adapters/atspi-common/src/callback.rs:11`. | Only accesskit-c needs it, and only for its own pointer-cast helper. See section 3.9 for why a function-pointer struct is still the better shape. |
| HRTB `for<'a> F: FnOnce(G<'a>) -> T` | No direct form | `TR/notes/research/idiom-mapping.md:258-261` | applies with caveat | `AK/adapters/atspi-common/src/node.rs:1818` `for<'a> F: FnOnce(RwLockReadGuard<'a, AppContext>) -> Result<T>,` | The higher-ranked lifetime is load-bearing: the callback is generic over every guard lifetime. |

### 2.3 Expressions and control flow

| Rust form | Zig form | Evidence | Verdict | AccessKit evidence | Caveat |
|---|---|---|---|---|---|
| `match` on integers | `switch` with literal prongs and `else` | `TR/notes/research/idiom-mapping.md:359-400`; `TR/notes/design/architecture/features-actionable.md:233-256` | applies | `AK/accesskit/src/lib.rs:362-386` a 22-arm `match value { 0 => Some(Action::Click), ..., _ => None }` | The golden match form is at `TR/test/golden/zig_src/compat/src/root.zig:1271-1274`. |
| `match` on a data-carrying enum | `switch` with payload capture | `TR/notes/research/idiom-mapping.md:116-121`, `:400-407`; golden `TR/test/golden/zig_src/compat/src/root.zig:1252-1256` | applies | `AK/accesskit/src/lib.rs:2796-2803` `match &$self.values[$index as usize]`; `AKC/src/common.rs:1096-1105` an 8-arm `match data` | The emitted payload capture name is `__r2z_match_payload`: `TR/test/golden/zig_src/hex/src/error.zig:38`. |
| `match` on `Option` | `if (opt) \|v\| { } else { }`, not a `switch` | `TR/notes/research/idiom-mapping.md:277-279`, `:389-390` | applies | `AKC/src/common.rs:89-92` `match node.$getter() { Some(value) => ..., None => ptr::null() }` | A Zig optional is not a union, so `switch` cannot take one. |
| `match` with an or-pattern | Several prongs to one body, or one `blk` with breaks | `TR/notes/design/data-model/exprs-patterns.md:404` | applies | `AK/accesskit/src/lib.rs:1046-1057` `match (self, source) { (Self::TextSelection(dest), Self::TextSelection(source)) => ..., (dest, source) => ... }` | The two arms bind the same names with different types. The final arm copies. |
| `match` on a tuple of places | Destructuring is manual, field by field | `TR/notes/research/idiom-mapping.md:394-396`; `TR/notes/design/data-model/exprs-patterns.md:350-352` | applies | `AK/accesskit/src/lib.rs:1046-1057` `match (self, source)` where `self` is `&mut Self` and `source` is `&Self` | Two different mutability levels in one scrutinee. Zig has no destructuring pattern. |
| Match ergonomics, `match &e` with non-reference patterns | Auto-deref is made explicit before emit | `TR/notes/design/data-model/exprs-patterns.md:349-352`; `TR/notes/research/prior-work.md:32` | applies with caveat | `AK/accesskit/src/lib.rs:2796-2803` arms bind `PropertyValue::$variant(value)` while the scrutinee is `&PropertyValue` | The bound `value` is a pointer, not the payload. Getting this wrong gives a pointer where a value is expected. |
| `match` with a guard | Nested `if` inside a labelled block | `TR/notes/research/idiom-mapping.md:391`; `TR/notes/design/architecture/features-actionable.md:259-285` | applies | `AK/accesskit/src/lib.rs:1090-1092` `.all(\|(&own, &other_index)\| { ... })` is a predicate, not a guard; no guarded `match` arm exists in `AK/accesskit/src/lib.rs` | The record defers guard emission: `TR/notes/design/data-model/exprs-patterns.md:515-516`. The golden shows the labelled-block form: `TR/test/golden/zig_src/compat/src/root.zig:1263-1270` `__r2z_value_block_1`. |
| `if let Some(v) = e` | `if (e) \|v\| { } else { }` | `TR/notes/research/idiom-mapping.md:383`; `TR/notes/design/architecture/features-actionable.md:289` | applies | `AK/accesskit/src/lib.rs:1291-1293` `if let PropertyValue::$variant(v) = self.properties.get_mut(...) { v.push(item); }` | The binding is a mutable borrow through a `get_mut` return. The borrow ends at the arm. |
| `let ... else` | `const x = e orelse return;` | `TR/notes/research/idiom-mapping.md:384-385` | applies with caveat | Absent from the core, `AK/accesskit/src/geometry.rs` and `AKC/src/*.rs`, all confirmed by grep. Present in the adapters: `AK/adapters/unix/src/atspi/interfaces/cache.rs:201`, `:217`, `:250`; `AK/adapters/android/src/adapter.rs:176`; `AK/example_common/src/lib.rs:237`. | The rule maps directly. The destructuring forms at `cache.rs:201` need manual field lowering first. |
| `while let Some(v) = e` | `while (e) \|v\| { }`, with a fixed trip count | `TR/notes/research/idiom-mapping.md:359-400` has no `while let` row | applies with caveat | `AK/accesskit/src/lib.rs:390-399` `while let Some(variant) = Action::n(i) { ...; i += 1; }` | The trip count is bounded by the enum size, 22. State the bound in Zig, per `ozai/AGENTS.md:41-42`. |
| Closure, no capture | A struct with a `call` method, or a plain function | `TR/notes/research/idiom-mapping.md:408-425`; `TR/notes/design/data-model/exprs-patterns.md:447-468` | applies | `AKC/src/unix.rs:78` `adapter.update_if_active(\|\| *box_from_ptr(update_factory(update_factory_userdata)))` | A zero-capture closure becomes a plain `fn` in Zig. The record says rust2zig emits a struct; a plain `fn` is smaller. `[INFERENCE]` |
| Closure taking `FnOnce` | No direct form | `TR/notes/research/idiom-mapping.md:431-433`; `TR/notes/design/data-model/items-types.md:377` | applies with caveat | `AK/adapters/unix/src/adapter.rs:196` `pub fn update_if_active(&mut self, update_factory: impl FnOnce() -> TreeUpdate)` | `FnOnce` consumes its capture. In Zig the callee takes a pointer and the caller owns the storage. The lifetime must be stated. |
| `matches!(v, Pattern::X)` | `switch` with one prong, or a bool-returning predicate | `TR/notes/research/idiom-mapping.md:589-595` rules on `assert!` and `panic!` only | applies | `AK/accesskit/src/lib.rs:1131-1133` `if matches!(value, PropertyValue::None) { *value = default; }` | `matches!` is a macro. See the macros table. |
| Iterator chain, two adapters | `for` with the Zig multi-object form | `TR/notes/research/idiom-mapping.md:428-430`; `TR/notes/design/data-model/exprs-patterns.md:216-222` | applies | `AK/accesskit/src/lib.rs:1088-1089` `self.indices.0.iter().zip(other.indices.0.iter())`; `AK/accesskit/src/lib.rs:2833` `self.indices.0.iter().copied().enumerate()` | `enumerate` maps to `for (slice, 0..) \|e, i\|` with the index last in Zig. |
| Iterator chain ending in `.collect()` | Explicit append into an `ArrayList` | `TR/notes/research/idiom-mapping.md:413-420`; `TR/notes/design/data-model/exprs-patterns.md:476-492` | applies | `AKC/src/common.rs:786-789` `values.iter().map(\|action\| BoxCastPtr::to_mut_ptr(action.clone())).collect()`; `AKC/src/common.rs:820-825` `slice::from_raw_parts(...).iter().map(...).collect::<Vec<CustomAction>>()` | Both need an allocator and an explicit error path. |
| Hand-written `impl Iterator` or `impl Future` | An explicit state machine | `TR/notes/research/idiom-mapping.md:434-436`; `TR/notes/design/data-model/exprs-patterns.md:441-497` | applies with caveat | `AK/adapters/unix/src/executor.rs:136-158` `impl<T> Future for Task<T>` with `fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output>` | This is the shape the port must not reproduce. See section 3, item 7. |
| `loop { }` | A `while (true)` with a stated non-termination claim | `TR/notes/design/data-model/exprs-patterns.md:207`; `ozai/AGENTS.md:41-42` | applies with caveat | `AK/adapters/unix/src/context.rs:176-180` `async move { loop { session_bus_copy.executor().tick().await; } }`; `AK/adapters/unix/src/context.rs:197-210` `loop { select! { ... } }` | Two unbounded loops. The house rule requires an explicit non-termination assertion. |
| Labelled block `blk:` | `:label` plus `break :label` | `TR/notes/design/data-model/exprs-patterns.md:163-168`; `TR/notes/research/prior-work.md:36` | applies | No labelled block in the core. `[INFERENCE]` from the absence of a `'a: {` pattern. | The record notes that rust2zig emits every label as `blk`: `TR/notes/research/prior-work.md:36`. The golden uses unique labels: `TR/test/golden/zig_src/compat/src/root.zig:1263`. |
| `panic!`, `unreachable!` | `@panic`, `unreachable` | `TR/notes/research/idiom-mapping.md:518-520`; golden `TR/test/golden/zig_src/compat/src/root.zig:1304` | applies | `AK/accesskit/src/lib.rs:3387` and the `#[cfg(test)]` modules use `assert!` and `assert_eq!`; `AK/adapters/unix/src/executor.rs:115` `.expect("async_task::Task is none")` | `assert!` maps to `std.debug.assert`, which is elided in `ReleaseFast`: `ZSTD/debug.zig:237-240`. |
| Integer `+`, `-`, `<<` | Explicit mode per operation | `TR/notes/design/data-model/exprs-patterns.md:283-303`; `TR/notes/research/idiom-mapping.md:537-539` | applies with caveat | `AK/accesskit/src/lib.rs:354` `1 << (self as u8)`; `AK/accesskit/src/lib.rs:824` `1 << (self as u8)`; `AK/accesskit/src/lib.rs:1127` `self.indices.0[id as usize] = index as u8;` | Rust panics on overflow in debug and wraps in release. `Flag` has 18 variants, so `1 << 17` is the largest mask and fits in `u32`. Assert that with a `comptime` check. |

### 2.4 Ownership, sharing, and concurrency

| Rust form | Zig form | Evidence | Verdict | AccessKit evidence | Caveat |
|---|---|---|---|---|---|
| `Arc<T>` | A hand-rolled refcount wrapper over `std.atomic` | `TR/notes/research/idiom-mapping.md:316-317`; `TR/notes/design/data-model/ownership-mem.md:318-338` | applies with caveat | `AK/adapters/unix/src/adapter.rs:126` `state: Arc<Mutex<AdapterState>>`; `AK/adapters/atspi-common/src/context.rs:36-39` four `Arc<RwLock<...>>` fields; `AK/adapters/unix/src/atspi/bus.rs:35` `desktop: Arc<OnceLock<ObjectRefOwned>>` | Neither `Rc` nor `Arc` exists as a generic in Zig std. The record says so at `TR/notes/research/idiom-mapping.md:316-317`. |
| `Rc<T>` | A non-atomic refcount wrapper | `TR/notes/research/idiom-mapping.md:316-317` | applies with caveat | `AK/adapters/macos/src/context.rs:37` `pub(crate) action_handler: Rc<dyn ActionHandlerNoMut>`; `:58`, `:60`, `:70`; `AK/adapters/macos/src/node.rs:1342`; `AK/adapters/macos/src/event.rs:46`, `:111`, `:116`; `AK/adapters/ios/src/context.rs:38`; `AK/adapters/ios/src/node.rs:459`. Absent from the core, from `AK/adapters/unix`, from `AK/adapters/atspi-common` and from `AKC/src/*.rs`, confirmed by grep. | macOS and iOS use `Rc` where the Unix path uses `Arc`. The port needs a non-atomic wrapper as well as an atomic one, or it must justify why one adapter's handler can be single-threaded. |
| `Mutex<T>` | `std.Thread.Mutex` plus a checked `*T` | `TR/notes/research/idiom-mapping.md:318-319`; `TR/notes/design/data-model/ownership-mem.md:294` | applies with caveat | `AK/adapters/unix/src/adapter.rs:175` `let mut state = self.state.lock().unwrap();`; `AK/adapters/atspi-common/src/context.rs:21` `pub struct ActionHandlerWrapper<H: ActionHandler + Send>(Mutex<H>);` | `.lock().unwrap()` turns a poisoned lock into a panic. Zig locks fail with an error. The error set changes. |
| `RwLock<T>` | Two `std.Thread.Mutex` values, or a reader-count lock | no record rule. `[INFERENCE]` | applies with caveat | `AK/adapters/atspi-common/src/context.rs:37` `tree: RwLock<Tree>`; `:39` `root_window_bounds: RwLock<WindowBounds>`; `:68-88` guard-returning accessors | The record lists `Mutex`/atomics as deferred: `TR/notes/design/data-model/ownership-mem.md:295`. |
| `OnceLock<T>`, `Once` | A one-time init flag, or an `init` that the caller calls once | `TR/notes/research/idiom-mapping.md:318-319` covers `Cell` and `RefCell` only | applies with caveat | `AK/adapters/unix/src/context.rs:33-34` `static APP_CONTEXT: OnceLock<Arc<RwLock<AppContext>>> = OnceLock::new();` and `static MESSAGES: OnceLock<Sender<Message>>` | Process-global mutable state. It breaks the house rule that logic never reads a global: `ozai/AGENTS.md:60-63`. |
| `Weak<T>` | A weak refcount wrapper | `TR/notes/research/idiom-mapping.md:316-317` | applies with caveat | `AK/adapters/atspi-common/src/node.rs:1806` `app_context: Weak<RwLock<AppContext>>`; `AK/adapters/atspi-common/src/node.rs:23` imports `Weak` | A weak reference can be dead. `upgrade_context` at `AK/adapters/atspi-common/src/node.rs:729` returns `Result<Arc<Context>>`. The Zig form needs the same failure path. |
| `Cell<T>`, `RefCell<T>` | `*T`, plus explicit borrow flags for `RefCell` | `TR/notes/research/idiom-mapping.md:318-319` | applies with caveat | `AK/adapters/macos/src/context.rs:20` `pub(crate) struct ActionHandlerWrapper<H: ActionHandler>(RefCell<H>);`; `:36`, `:38`; `AK/adapters/macos/src/subclass.rs:41`; `AK/adapters/ios/src/context.rs:21`, `:37`, `:39`, `:40`; `AK/adapters/windows/src/subclass.rs:41` a bare `Cell<bool>`. Absent from the core and from `AK/adapters/unix`, confirmed by grep. | Each `RefCell` is a runtime borrow flag the port must reproduce explicitly. The record defers `RefCell` to a later stage: `TR/notes/design/data-model/ownership-mem.md:294`. |
| `static mut` | A file-scope `var` | `TR/notes/design/data-model/items-types.md:120-122` "static→`var` (`mut` flag; `static mut` interior mutability is v1-gated" | does not apply | No `static mut` in any AccessKit tree examined. `[INFERENCE]` from the absence of the token. | none |
| `Drop` trait impl | `defer` and `errdefer` | `TR/notes/research/idiom-mapping.md:315`; `TR/notes/design/data-model/ownership-mem.md:104-134` | applies with caveat | `AK/accesskit/src/lib.rs:2685-2688` uses `core::slice`; `AKC/src/common.rs:1084-1090` `impl Drop for action_data` frees `Self::Value`; `AK/adapters/unix/src/adapter.rs:240-244` `impl Drop for Adapter`; `AK/adapters/unix/src/executor.rs:125-134` `impl<T> Drop for Task<T>` aborts a join handle | Path-sensitive drop has no Zig form. The record defers it: `TR/notes/design/data-model/ownership-mem.md:290`. |
| Field drop order | Declaration order, written out in `deinit` | `TR/notes/design/architecture/structure-memory.md:282-289` | applies | `AKC/src/common.rs:759-781` `custom_actions` frees each element then the array | Local `defer` is LIFO. Field cleanup is FIFO. Mixing them silently changes order. |
| `unsafe impl Send`, `unsafe impl Sync` | No form. It is a promise the type system checked. | `TR/notes/research/idiom-mapping.md:654-655` | applies with caveat | `AKC/src/common.rs:1139` `unsafe impl Send for FfiActivationHandlerUserdata {}`; `:1176`, `:1204`, `:1230` | Three separate marker impls over `*mut c_void`. In Zig the promise becomes a comment plus a single-threaded ownership argument. |
| `Send`, `Sync` bounds | No form. Zig has no auto traits. | `TR/notes/research/idiom-mapping.md:258-261` | applies with caveat | `AK/adapters/unix/src/executor.rs:46-48` `T: Send + 'static` and `impl Future<Output = T> + Send + 'static` | The bound carried the design. Losing it silently makes a function look callable from a thread it is not. |
| `async fn` | A function that takes `io` and returns a value | `TR/notes/research/idiom-mapping.md:547-587`; `TR/notes/design/architecture/features-actionable.md:343-353` | applies with caveat | `AK/adapters/unix/src/atspi/bus.rs:39` `pub(crate) async fn new(...)`; `AK/adapters/unix/src/context.rs:169-173` `async fn run_event_loop(executor: &Executor<'_>, session_bus: Connection, rx: Receiver<Message>)`; `AK/adapters/unix/src/atspi/bus.rs:183` `async fn register_interface<T>(&self, path: &str, interface: T) -> Result<bool>` | The record says the structure of an async program differs fundamentally: `TR/notes/research/idiom-mapping.md:567-569`. |
| `.await` | A call that takes `io` and blocks the thread until ready | `TR/notes/research/idiom-mapping.md:552-554`; `ZSTD/Io.zig:1240` `pub fn async`, `:1261` `pub fn concurrent` | applies with caveat | `AK/adapters/unix/src/atspi/bus.rs:45` `BusProxy::new(session_bus).await?`; `AK/adapters/unix/src/context.rs:178` `session_bus_copy.executor().tick().await;` | A plain `.await` on a computation becomes a direct call. Only I/O sites need the scheduler. |
| `async move { }` block | A spawned task that takes `io` | `TR/notes/research/idiom-mapping.md:560-564` | applies with caveat | `AK/adapters/unix/src/context.rs:175-182` `executor.spawn(async move { loop { ... .await } }, "accesskit_session_bus_task")` | The task never finishes. In Zig the same shape needs an explicit termination claim. |
| `futures::select!` over two streams | No direct form. It is a rewrite. | `TR/notes/research/idiom-mapping.md:579-581` | applies with caveat | `AK/adapters/unix/src/context.rs:197-210` `loop { select! { change = changes.next() => ..., message = messages.next() => ... } }`; `AK/adapters/unix/src/context.rs:12` imports `select` from `futures_util` | The record names `select!` and `join!` as forms with no analogue. See section 3, item 6. |
| Channel `async_channel::Sender`/`Receiver` | An explicit queue structure | `TR/notes/research/idiom-mapping.md:547-587` has no channel row | applies with caveat | `AK/adapters/unix/src/adapter.rs:11-14` `use async_channel::Sender;` and `use std::sync::{Arc, Mutex};`; `AK/adapters/unix/src/adapter.rs:22-24` `messages: Sender<Message>`; `AK/adapters/unix/src/context.rs:172` `rx: Receiver<Message>` | AccessKit chooses the channel per feature: `AK/adapters/unix/src/adapter.rs:15` swaps in `tokio::sync::mpsc::UnboundedSender` under `#[cfg(feature = "tokio")]`. The port must pick one. |
| `#[cfg(...)]`, `#[cfg_attr(...)]` | `comptime` target checks, or a build option | `TR/notes/design/data-model/items-types.md:185-193`; `TR/notes/design/architecture/pkg-dep-macros.md:47-63` | applies | `AK/accesskit/src/lib.rs:11` `#![cfg_attr(not(any(feature = "pyo3", feature = "schemars")), no_std)]`; `AK/accesskit/src/lib.rs:47-60` five stacked `cfg_attr` on `Role`; `AK/adapters/unix/src/executor.rs:51-59` and `:64-76` branch on `feature = "tokio"` | AccessKit's feature set is `enumn`, `pyo3`, `serde`, `schemars`: `AK/accesskit/Cargo.toml:25-29`. The port needs a narrower set. |
| `#[deprecated]` | Nothing. Delete the item. | `ozai/AGENTS.md:51-52` | applies | `AK/accesskit/src/lib.rs:3178-3179` `#[deprecated(note = "Use TreeInfo instead")] pub type Tree = TreeInfo;` | The port must not reproduce the alias. See section 3, item 18. |

### 2.5 Macros and derives

| Rust form | Zig form | Evidence | Verdict | AccessKit evidence | Caveat |
|---|---|---|---|---|---|
| `macro_rules!` | No macro system. The expansion is hand-written. | `TR/notes/research/idiom-mapping.md:589-595` "Zig has **no macro system at all**"; `TR/notes/research/idiom-mapping.md:629-632` calls it a hard-block | applies | `AK/accesskit/src/lib.rs:1170-1220` `flag_methods!`; `:1222-1233` `option_ref_type_getters!`; `:1235-1246` `slice_type_getters!`; `:1248-1259` `copy_type_getters!`; `:1261-1269` `owned_type_setters!`; `:1271-1279` `copy_type_setters!`; `:1281-1297` `vec_type_methods!`; `:1299-1317` `property_methods!`; `:1319-1332` `vec_property_methods!`; `:1778-1824` `unique_enum_property_methods!` | Ten macro definitions generate most of the `Node` API. Each expansion is a direct Zig function. See section 3, item 11. |
| `macro_rules!` that expands into an `impl` block | One emitted container with all the methods | `TR/notes/design/data-model/items-types.md:144-146` | applies | `AK/accesskit/src/lib.rs:1172` the macro body opens `impl Node {`; `AK/accesskit/src/lib.rs:1224` opens `impl PropertyIndices {` | The expansions target two different types. Two Zig containers, not ten. |
| Nested `macro_rules!` invocation | Hand-written calls between the emitted functions | `TR/notes/design/architecture/pkg-dep-macros.md:484-486` | applies | `AK/accesskit/src/lib.rs:1283-1285` `vec_type_methods!` calls `slice_type_getters!` inside its own body; `AK/accesskit/src/lib.rs:1321-1324` `vec_property_methods!` calls `property_methods!` | The nesting is only in the macro body. In Zig it is ordinary call order. |
| Macro that captures doc attributes `$($(#[$doc:meta])* ...)` | Doc comments are written out | `TR/notes/design/architecture/pkg-dep-macros.md:334-341` | applies | `AK/accesskit/src/lib.rs:1300` the matcher captures `$($(#[$doc:meta])* ($id:ident, ...))+`; the invocation carries the doc text at `AK/accesskit/src/lib.rs:2680` | The doc text is real content. It must be reproduced, not dropped. |
| Macro that captures a type fragment `$type:ty` | Nothing. Each expansion names its concrete type. | `[INFERENCE]` | applies | `AK/accesskit/src/lib.rs:1671` `(set_length_vec_property, Vec<u8>, LengthVec)`; `AK/accesskit/src/lib.rs:2002` `(set_string_property, String, String)` | The fragment hides the type at the definition site. The port must resolve it per invocation. |
| `#[derive(Clone, Copy)]` | Nothing for `Copy`. An explicit deep copy for `Clone`. | `TR/notes/research/idiom-mapping.md:602-603`; `TR/notes/design/architecture/pkg-dep-macros.md:349-367` | applies | `AK/accesskit/src/lib.rs:47` `#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]` on `Role`; `AK/accesskit/src/lib.rs:1836-1854` a hand-written `impl Clone for Node` because `Node` is not `Copy` | The record notes that a `clone` body is emitted as a real Zig fn: `TR/notes/design/data-model/ownership-mem.md:297`. |
| `#[derive(Debug)]` | A `format` method, or `formatDebug` | `TR/notes/research/idiom-mapping.md:602-614`; `TR/README.md:92-95` | applies | `AK/accesskit/src/lib.rs:2753-2791` a hand-written `impl fmt::Debug for Node` | The golden routes Debug through `formatDebug`: `TR/README.md:93-95`. |
| `impl Display` / `write!` | A `format` method taking `*std.Io.Writer` | `TR/notes/design/architecture/pkg-dep-macros.md:369-389`; golden `TR/test/golden/zig_src/hex/src/error.zig:35-36` | applies with caveat | `AK/accesskit/src/lib.rs:731-735` `impl fmt::Debug for NodeId { fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result { write!(f, "#{}", self.0) } }` | A `format` body that needs an allocator is refused: `TR/README.md:96-101`. Audit every `format` body for allocation before writing it. |
| `#[derive(PartialEq, Eq, Ord, PartialOrd, Hash)]` | An `eql` fn, or `std.meta.eql`; comparison methods for the rest | `TR/notes/research/idiom-mapping.md:602-603`; `TR/notes/design/architecture/pkg-dep-macros.md:415-428`, `:444-458` | applies | `AK/accesskit/src/lib.rs:1084-1094` a hand-written `impl PartialEq for Properties` that compares through an index table, not field by field | The hand-written form is not a field comparison. A derived `eql` would be wrong here. |
| `#[derive(Default)]` | A `default_value` const or an `init` | `TR/notes/design/architecture/pkg-dep-macros.md:430-442` | applies | `AK/accesskit/src/lib.rs:1102` `#[derive(Default, PartialEq)] pub struct Node`; `AK/accesskit/src/lib.rs:1829-1832` uses `..Default::default()` struct-update syntax | Struct-update syntax is deferred in the record: `TR/notes/design/data-model/exprs-patterns.md:526`. |
| `#[derive(Serialize, Deserialize)]` | No Zig form. Not a property of the data type. | `TR/notes/research/idiom-mapping.md:602-603` covers only Debug, Clone, PartialEq | applies | `AK/accesskit/src/lib.rs:2820-2871` `impl Serialize for Properties`; `:2876-3006` a hand-written `Visitor` impl; `:3009-3034` `impl<'de> Deserialize<'de>` | The `Visitor` pattern is not transliterable. The port needs its own serializer or none. Decide in `docs/30-port-design.md`. |
| `#[derive(JsonSchema)]` | No Zig form | not in the record | applies | `AK/accesskit/src/lib.rs:3036-3160` `impl JsonSchema for Properties` over 120 lines | Feature `schemars` only: `AK/accesskit/Cargo.toml:25-29`. The port does not need it. |
| `#[derive(enumn::N)]` | No Zig form. A from-integer conversion | not in the record | applies | `AK/accesskit/src/lib.rs:48` `#[cfg_attr(feature = "enumn", derive(enumn::N))]`; the manual fallback at `AK/accesskit/src/lib.rs:357-387` | The fallback exists because the macro would break the C header. AccessKit says so at `AK/accesskit/src/lib.rs:360-361`. The port takes the fallback shape. |
| `#[pyclass]` | No Zig form | not in the record | applies | `AK/accesskit/src/lib.rs:52-60` a five-line `pyclass(module = "accesskit", rename_all = "SCREAMING_SNAKE_CASE", eq, from_py_object)` | Feature `pyo3` only. Out of scope for the port. |
| `assert!`, `assert_eq!` | `std.debug.assert`; `try std.testing.expectEqual` | `TR/notes/research/idiom-mapping.md:518-519`, `:532-536`; `TR/notes/research/prior-work.md:135` | applies with caveat | `AK/accesskit/src/lib.rs:1201` `assert!(!node.$getter());`; `AK/accesskit/src/lib.rs:2559` and `:2572` `assert!(node.transform().is_none());` | `std.debug.assert` is elided in `ReleaseFast`: `ZSTD/debug.zig:237-240`. Emit `if (!cond) @panic(...)` where the check must survive. The record says so at `TR/notes/research/idiom-mapping.md:536`. |

### 2.6 FFI, module layout, and visibility

| Rust form | Zig form | Evidence | Verdict | AccessKit evidence | Caveat |
|---|---|---|---|---|---|
| `extern "C" fn` declaration | `extern fn` | `TR/notes/research/idiom-mapping.md:667-677`, `:680-682` | applies | `AKC/src/common.rs:394` `pub extern "C" fn accesskit_node_set_role(node: *mut node, value: Role)` | Zig gives `extern` the C convention by default. |
| `#[no_mangle] pub extern "C" fn` | `export fn` | `TR/notes/research/idiom-mapping.md:672-676` | applies | `AKC/src/common.rs:393` `#[unsafe(no_mangle)]` above the definition; also `:510-511`, `:1128-1131` | The name is the contract. It must match the header byte for byte. |
| `extern "system" fn` | `callconv(.winapi)` | `TR/notes/research/idiom-mapping.md:689-690`; `ZSTD/os/windows.zig:4184` `pub const THREAD_START_ROUTINE = fn (LPVOID) callconv(.winapi) DWORD;` | applies | `AK/adapters/windows/src/subclass.rs:44` `extern "system" fn wnd_proc(window: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT` | Windows only. The callconv must be on every crossing function. |
| Exported `static` | `export const` | `[INFERENCE]` from `TR/notes/research/idiom-mapping.md:672-676` | applies | `AKC/src/common.rs:226-227` `#[unsafe(no_mangle)] pub static ACCESSKIT_TREE_ID_ROOT: tree_id = tree_id { bytes: [0; 16] };` | An exported constant, not an exported variable. |
| `Option<extern "C" fn(...)>` | `?*const fn (...) callconv(.c)` | `TR/notes/research/idiom-mapping.md:690` covers varargs; the optional-fn-pointer form is not in the record. `[INFERENCE]` | applies | `AKC/src/common.rs:1133-1135` `pub type ActivationHandlerCallback = Option<extern "C" fn(userdata: *mut c_void) -> *mut tree_update>;`; also `:1171-1172`, `:1200`, `:1233-1234` | AccessKit pairs an unwrapped alias with the `Option` alias so the stored field is not optional but the constructor is. Keep that split or drop it. |
| Opaque handle `pub struct node { _private: [u8; 0] }` | `opaque {}` or a zero-size `extern struct` | not in the record. `[INFERENCE]` | applies | `AKC/src/common.rs:689-691` `pub struct custom_action { _private: [u8; 0], }`; `AKC/src/unix.rs:17-19` `pub struct unix_adapter { _private: [u8; 0] }` | This is the shape a hand-written C shim needs. See section 7, item 4. |
| `#[repr(C)]` slice struct `{ length: usize, values: *const T }` | `extern struct { length: usize, values: [*]const T }` | `AKC/src/common.rs:149-153`; `TR/notes/research/idiom-mapping.md:649-651` | applies | `AKC/src/common.rs:150-153` the `slice_struct!` macro body; `AKC/src/common.rs:759-763` `pub struct custom_actions { pub length: usize, pub values: *mut *mut custom_action }` | The length and the pointer must agree. The record's raw-pointer form is at `TR/README.md:240-247`. |
| Opaque enum tag through C | `enum(u8)` plus a checked from-int | `TR/notes/design/architecture/features-actionable.md:56-69` | applies | `AKC/include/accesskit.h:72` `ACCESSKIT_ACTION_CLICK,` inside the generated enum | The header is the recorded artifact. Keep it in `docs/50-verification.md` as a golden. |
| `mod foo;` file module | `const foo = @import("./foo.zig");` | `TR/notes/research/idiom-mapping.md:50-51`; `TR/notes/design/architecture/structure-memory.md:52-69`; golden `TR/test/golden/zig_src/multimod/src/root.zig:24` `const foo = @import("./foo.zig");` | applies | `AK/accesskit/src/lib.rs:34` `mod geometry;`; `AKC/src/lib.rs:16-17` `mod common;` `mod geometry;` | The golden binds a private child without `pub`. A re-exported child does take `pub`, at `TR/test/golden/zig_src/multimod/src/root.zig:31`. |
| Nested module directory | Relative hops computed per file | `TR/notes/design/architecture/pkg-dep-macros.md:212-256`; golden `TR/test/golden/zig_src/compat/src/support/child.zig:19-20` | applies | `AK/adapters/unix/src/atspi/mod.rs:1` a nested module behind `mod atspi;` | The record computes hops explicitly at `TR/notes/design/architecture/pkg-dep-macros.md:248-256`. |
| `#[path = "..."]` module | One file per path, name taken from the path | `TR/README.md:130-132`; golden `TR/test/golden/zig_src/multimod/src/root.zig:31` `pub const custom_pub = @import("./custom_pub.zig");` | applies | No `#[path]` in the AccessKit trees examined. `[INFERENCE]` | The rule is recorded from a fixture, not from AccessKit. |
| `pub use path::Name;` | `pub const Name = path.Name;` | `TR/notes/research/idiom-mapping.md:48-49`; `TR/notes/design/data-model/crate-graph.md:172-187` | applies | `AK/accesskit/src/lib.rs:32` `pub use uuid::Uuid;`; `AKC/src/lib.rs:51` `pub use common::*;` | Zig has no re-export. Each name must be re-declared. |
| Glob `pub use geometry::{Affine, Point, Rect, Size, Vec2};` | Five separate `pub const` lines | `TR/notes/design/architecture/pkg-dep-macros.md:258-274`; `TR/notes/design/data-model/crate-graph.md:174-179` | applies | `AK/accesskit/src/lib.rs:35` `pub use geometry::{Affine, Point, Rect, Size, Vec2};`; `AKC/src/lib.rs:49-73` six glob and single re-exports | The record expands a glob by symbol-table query: `TR/notes/design/architecture/pkg-dep-macros.md:260-261`. The port does it by hand, once. |
| `pub` | `pub` | `TR/notes/design/architecture/structure-memory.md:77` | applies | `AK/accesskit/src/lib.rs:62` `pub enum Role` | none |
| `pub(crate)` | `pub` in the file, not re-exported at the package root | `TR/notes/design/architecture/structure-memory.md:78` | applies | `AK/adapters/unix/src/adapter.rs:80` `pub(crate) enum AdapterState`; `AK/adapters/unix/src/executor.rs:35` `pub(crate) struct Executor<'a>` | The matrix is at `TR/notes/design/architecture/structure-memory.md:71-81`. |
| private, no modifier | No `pub` | `TR/notes/design/architecture/structure-memory.md:81` | applies | `AK/accesskit/src/lib.rs:1108` `role: Role,` a private field; `AK/accesskit/src/lib.rs:801` `enum Flag` | Zig does not enforce it either. `TR/README.md:89-90` says so. |
| `#![allow(non_camel_case_types)]` | Naming is decided by the port, not by the source | `ozai/AGENTS.md:45-47` | applies | `AKC/src/lib.rs:13` `#![allow(non_camel_case_types)]` | AccessKit-c must stay snake_case for C. The core can move to `camelCase`. Decide once, in `docs/31-c-abi-design.md`. |

---

## 3. The constructs that have no honest Zig form

Each item below has the same shape: what Rust does, what Zig cannot do, what
the translator did, and what a hand port should do instead. The translator
column is empty where no rule exists. An empty cell is a finding.

### 3.1 `#[repr(C)]` data-carrying enum

**What Rust does.** `AK/accesskit/src/lib.rs:3304-3321` declares
`#[repr(C)] pub enum ActionData` with eight payload variants, including
`Value(Box<str>)` at `:3307`. `AKC/src/common.rs:1069-1082` declares the C
mirror `#[repr(C)] pub enum action_data` with `Value(*mut c_char)` at `:1072`.

**What Zig cannot do.** `extern union` has no tag. `union(enum)` has a tag but
Zig does not give it a C layout. The record says Zig `enum` is the C-like tag
type and `union(enum)` adds payloads: `TR/notes/research/idiom-mapping.md:101-104`.

**What the translator did.** Nothing. There is no `#[repr(C)]` data-carrying
enum rule in `TR/notes/research/idiom-mapping.md`. The nearest rule is
`TR/notes/research/idiom-mapping.md:684-685`, which maps a `repr(C)` enum to
`enum(uN)`, and that only holds for a fieldless enum.

**What a hand port should do instead.** Keep the tagged union for the core,
because AccessKit's own code matches on it at `AK/accesskit/src/lib.rs:2796-2803`.
Give the C binding its own flat struct with an explicit discriminant field and
one optional payload, and write the conversion in both directions by hand. The
recorded precedent is `AKC/src/common.rs:1094-1107`, which already converts
`ActionData` to `action_data` variant by variant. Assert both sides with a
recorded fixture that checks size and each discriminant value.

### 3.2 `#[repr(transparent)]` over a foreign type

**What Rust does.** `AK/accesskit/src/lib.rs:744-745` is
`#[repr(transparent)] pub struct TreeId(pub Uuid)`. `Uuid` is a foreign type
from the `uuid` crate: `AK/accesskit/Cargo.toml:23`. The layout contract is
that `TreeId` and `Uuid` share one layout, which accesskit-c relies on at
`AKC/src/common.rs:212-218` with `bytes: *id.0.as_bytes()`.

**What Zig cannot do.** Zig has no attribute that asserts a one-field struct is
layout-identical to its field. An `extern struct` with one field gets a C
layout, but nothing pins the foreign type's layout.

**What the translator did.** `TR/notes/research/idiom-mapping.md:691-692` maps
`#[repr(transparent)]` to a single-field struct. It does not address a
transparent wrapper over a foreign type.

**What a hand port should do instead.** Do not mirror the wrapper. Make the
Zig `TreeId` an `extern struct` holding `[16]u8` directly, which is what the C
header already does at `AKC/src/common.rs:207-210`. Add a
`comptime assert(@sizeOf(TreeId) == 16)` and a byte-order test. Record the
conversion from and to the core `TreeId` as an explicit function pair, following
`AKC/src/common.rs:212-224`.

### 3.3 Lifetimes on references, and `impl Trait` in argument position

**What Rust does.** `AK/accesskit/src/lib.rs:1116` is
`fn get<'a>(&self, values: &'a [PropertyValue], id: PropertyId) -> &'a PropertyValue`.
The returned reference borrows `values`, not `self`. Separately,
`AK/accesskit/src/lib.rs:1264` is
`fn $method(&mut self, id: PropertyId, value: impl Into<$type>)`, and
`AK/adapters/unix/src/adapter.rs:196` is
`pub fn update_if_active(&mut self, update_factory: impl FnOnce() -> TreeUpdate)`.

**What Zig cannot do.** Zig has no lifetime parameters. The record says
"lifetimes erased" at `TR/notes/research/idiom-mapping.md:310-312` and again at
`TR/notes/design/data-model/ownership-mem.md:94-96`. An `impl Trait` argument
has no Zig form either, because Zig resolves the parameter type at the
callsite and the caller would have to name it.

**What the translator did.** It erased lifetimes and refused the forms it could
not lower. `TR/src/ir/validate.zig:1671` refuses an unsupported type and
`:1694` refuses an unresolved external nominal type.

**What a hand port should do instead.** For the lifetime case, the function
`get` takes `self: *const PropertyIndices` and `values: []const PropertyValue`
and returns `*const PropertyValue`. The borrow relationship that Rust encoded
in `'a` becomes a documented statement: the result points into `values` and
not into `self`. That statement is only checkable by reading, so a recorded
fixture must exercise the case where the two disagree. For `impl Trait`, name
the concrete type at the call site. If the argument must accept more than one
type, take a `*const fn` plus a context pointer, which is the record's own
recommendation for the general case at `TR/notes/research/idiom-mapping.md:266-268`.

### 3.4 The borrow checker

**What Rust does.** It rejects two simultaneous `&mut` borrows at compile time.
`TR/AGENTS.md:15-17` records the probe result: two simultaneous `&mut` borrows
translate to compiling Zig with a meaningless value.

**What Zig cannot do.** Zig has no borrow checker. The record says so at
`TR/notes/research/idiom-mapping.md:307-312` and `TR/notes/research/prior-work.md:143`.
`TR/notes/research/prior-work.md:123` records that in the Roc rewrite, two real
use-after-free defects in Zig's error reporting "would have been caught" by
Rust's borrow checker.

**What the translator did.** It declared the gap out of scope by decision:
`TR/AGENTS.md:13-14`. It kept an `UnsoundMarker` in the IR to flag the
remaining points: `TR/notes/design/data-model/ownership-mem.md:207-223`.

**What a hand port should do instead.** Section 1.4 gives five steps. The
AccessKit-specific exposure is at `AK/adapters/unix/src/adapter.rs:176-188`,
which holds a `MutexGuard` across a `match` over three state variants, and at
`AK/adapters/atspi-common/src/context.rs:36-39`, where four lockable fields
are shared through an `Arc`. Both are testable only if the state value is a
parameter. Make it one.

### 3.5 `Drop` with path-sensitive behaviour

**What Rust does.** `AK/adapters/unix/src/executor.rs:125-134` is
`impl<T> Drop for Task<T>`, and its body runs only under
`#[cfg(feature = "tokio")]`, where it takes the handle and aborts it.
`AKC/src/common.rs:1084-1090` is `impl Drop for action_data`, which frees the
owned pointer in exactly one variant.

**What Zig cannot do.** `defer` and `errdefer` run unconditionally on scope
exit. The record says path-sensitive destruction needs an alive flag:
`TR/notes/research/idiom-mapping.md:431` and
`TR/notes/design/data-model/ownership-mem.md:123-126`.

**What the translator did.** It kept `defer_only` in v1 and gated the alive flag
out: `TR/notes/design/data-model/ownership-mem.md:139-142`, `:290`.
`TR/README.md:230-238` records the shipped bound: it is a syntactic scan of the
callable body, and a binding the scan cannot account for stays unreleased
rather than risking a second free.

**What a hand port should do instead.** For the tagged-union error case, write
one `deinit` that switches on the tag and frees only the owning arm, following
the record's shape at `TR/notes/design/architecture/structure-memory.md:378-396`.
For the task-abort case, do not model it as a destructor. Give the task an
explicit `cancel(self: *Task) void` and an explicit `detach(self: Task) void`,
then make the caller choose. The Rust version hides that choice in a drop
implementation. The record shows the zig shape at
`AK/adapters/unix/src/executor.rs:112-122`, which already has a `detach`.

### 3.6 `select!` over two fused streams

**What Rust does.** `AK/adapters/unix/src/context.rs:197-210` runs
`loop { select! { change = changes.next() => ..., message = messages.next() => ... } }`
over a fused property-change stream and a fused channel receiver. The import is
`AK/adapters/unix/src/context.rs:12`, which pulls `select` from `futures_util`.
The two inputs are pinned at `:186` and `:192`.

**What Zig cannot do.** There is no stream-select combinator. The record names
`tokio::select!` and `futures::join!` as forms that "stop having direct
analogues; that's a rewrite, not a transliteration":
`TR/notes/research/idiom-mapping.md:579-581`.

**What the translator did.** Nothing. `TR/notes/design/data-model/items-types.md:378`
lists async with an executor as out of scope, with the reason "rewrite, not
translation".

**What a hand port should do instead.** Rewrite the loop as a state machine
over one enum of ready events, which is the house rule at
`ozai/AGENTS.md:65-68`. Keep the bus-status stream and the message queue as two
separate producers that both push into one ready queue, then have one `while`
drain it. The pure step takes `(event, state)` and returns the next state.
That is the structure the record recommends for a network stack at
`TR/notes/research/prior-work.md:143`.

### 3.7 `Pin`, `Poll`, and a hand-written `Future`

**What Rust does.** `AK/adapters/unix/src/executor.rs:136-158` is
`impl<T> Future for Task<T>` with
`fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output>`.
`Poll` is itself an enum with a payload, and `Self::Output` is an associated
type.

**What Zig cannot do.** Zig has no `Pin`, no `Poll`, and no future trait. The
record says the whole `Future`, `Pin` and executor machinery has no 1:1 mapping:
`TR/notes/research/idiom-mapping.md:567-569`, `:571-575`.

**What the translator did.** Nothing. The record's stated fallback is a plain
function that takes `io` and performs one I/O call:
`TR/notes/research/idiom-mapping.md:576-578`.

**What a hand port should do instead.** Do not port the executor. The port
runs on `zio`, so `Task` and `Executor` are not AccessKit API for the Zig side.
What must be reproduced is the effect, not the machinery: a background task
that keeps the D-Bus connection ticking while the message loop runs. Make that
one zio task, give it a name, and assert that the loop still makes progress
with the task present. Record that assertion as a fixture.

### 3.8 Process-global `OnceLock` state

**What Rust does.** `AK/adapters/unix/src/context.rs:33-34` declares
`static APP_CONTEXT: OnceLock<Arc<RwLock<AppContext>>>` and
`static MESSAGES: OnceLock<Sender<Message>>`, initialised by
`get_or_init_app_context` at `:43-45`. A second global sits at
`AK/adapters/unix/src/atspi/bus.rs:35`, `desktop: Arc<OnceLock<ObjectRefOwned>>`.

**What Zig cannot do.** Nothing forbids it, but it defeats the house rule that
`io` is threaded explicitly and never global, and the rule that logic never
reads a clock, environment, or working directory:
`ozai/AGENTS.md:59-63`.

**What the translator did.** It recorded the Rust assumption as a hazard and
institutionalized the opposite: `TR/notes/design/data-model/ownership-mem.md:146-154`
says Rust assumes one implicit global allocator while Zig threads an explicit
one, and `:189-195` says the model does not re-solve this and
institutionalizes the Zig side instead.

**What a hand port should do instead.** Pass the context as a parameter. Every
function that today calls `get_or_init_messages()` or `get_or_init_app_context()`
takes the sender and the context instead. The call sites are enumerable:
`AK/adapters/unix/src/adapter.rs:139` and `:208`. This is the single change that
makes the adapter deterministically drivable, and `docs/18-testing-strategy.md:433`
already records that zio 0.18.0 has no virtual clock, so a hidden global cannot
be substituted in a test either.

### 3.9 `Arc<dyn Trait + Send + Sync>`

**What Rust does.** `AK/adapters/unix/src/adapter.rs:84` stores
`action_handler: Arc<dyn ActionHandlerNoMut + Send + Sync>` inside a data-carrying
enum. `AKC/src/common.rs:1139` adds `unsafe impl Send for FfiActivationHandlerUserdata {}`
over a raw `*mut c_void`, which is how a C userdata pointer is made movable
across threads.

**What Zig cannot do.** Zig has no fat pointers and no auto traits. The record
states this twice: `TR/notes/research/idiom-mapping.md:262-264` and
`TR/notes/design/data-model/items-types.md:374`.

**What the translator did.** It was excluded from v1 as the first blocker:
`TR/notes/research/idiom-mapping.md:270-272`, `:731-732`. The design record
nevertheless specifies the synthesis: a `{ ptr, vtable }` record at
`TR/notes/design/architecture/runtime-traits.md:430-468`, and it admits that
hand-writing a vtable per trait "diverges from Zig norms":
`TR/notes/research/idiom-mapping.md:265-267`.

**What a hand port should do instead.** Use the record's alternative, which it
names itself: pass a struct of function pointers explicitly, the way
`std.mem.Allocator` does. For `ActionHandler` the port needs one method,
`do_action`. Define a struct with a `*anyopaque` context and a single function
pointer. That is `TR/notes/research/idiom-mapping.md:266-268` applied. The
`Send + Sync` bound becomes a documented single-thread ownership argument on
the context, plus a test that drives the call from one thread only.

### 3.10 Unbounded loops

**What Rust does.** `AK/adapters/unix/src/context.rs:176-180` is
`async move { loop { session_bus_copy.executor().tick().await; } }`, and
`:197-210` is the outer event `loop`. Neither has an exit condition.

**What Zig cannot do.** Nothing forbids it, but the house rule requires loops
to have fixed upper bounds and event loops to assert non-termination:
`ozai/AGENTS.md:41-42`.

**What the translator did.** It emitted the loops and nothing more. Its
emitter does carry loop-exit analysis for loops that carry a value:
`TR/src/backend/zig/emit.zig:2177-2186`.

**What a hand port should do instead.** Keep the loops, because they are
correct, and add the claim. Put an explicit non-termination assertion at the
top of each and a named counter with a fixed ceiling that fails the test rather
than the process. This is cheap and it is the only way a hang shows up as a
test failure.

### 3.11 `macro_rules!` that generates `impl` blocks

**What Rust does.** `AK/accesskit/src/lib.rs:1170-1220` defines `flag_methods!`,
whose body opens `impl Node {` at `:1172` and generates a getter, a setter and
a clearer per flag. Nine more macro definitions follow, up to
`:1319-1332` `vec_property_methods!`, which nests another macro at `:1321`.
`AK/accesskit/src/lib.rs:1778-1824` defines `unique_enum_property_methods!`,
which generates `impl` blocks and a `#[cfg(test)] mod` per property.

**What Zig cannot do.** Zig has no macro system. The record says so without
qualification at `TR/notes/research/idiom-mapping.md:591-592`.

**What the translator did.** It refused. `TR/README.md:283-284` records the
`fletcher` fixture refusing `quickcheck!` with `ExternalMacroSourceUnavailable`.
`TR/README.md:285-286` records `crc16` refusing a generated include with
`BuildScriptArtifactUnavailable`, and states that build scripts are not
executed. The record's design alternative was to expand macros in a rustc
sidecar first: `TR/notes/design/architecture/pkg-dep-macros.md:476-478`.

**What a hand port should do instead.** Expand by hand, once, and keep the
expansion in the repository as real Zig. Count the generated surface first, so
the cost is known: `AK/accesskit/src/lib.rs:1451`, `:1671`, `:2001-2006`, and
`:2521-2546` are the invocation sites. Each generated method is one Zig
function inside one container. The house rule against needless abstraction
(`ozai/AGENTS.md:192-193`) forbids replacing the expansion with a comptime
generator, because the expanded form is what a reviewer can check.

### 3.12 Derive macros for serialization

**What Rust does.** `AK/accesskit/src/lib.rs:47-60` stacks six derives on
`Role`: `Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash`,
then conditional `enumn::N`, `Serialize`, `Deserialize` and `JsonSchema`, then a
five-argument `pyclass`. `AK/accesskit/src/lib.rs:2876-3006` is a 130-line
hand-written `Visitor` implementation.

**What Zig cannot do.** Nothing derives anything. The record says derive has no
direct Zig idiom at `TR/notes/research/idiom-mapping.md:602-603`.

**What the translator did.** It desugared the simple ones by hand:
`TR/notes/design/architecture/pkg-dep-macros.md:345-458` covers `Clone`,
`Debug`, `PartialEq`, `Default` and `Hash`. The golden shows the `Debug` route:
`TR/test/golden/zig_src/hex/src/error.zig:35-36` is
`pub fn format(self: *const FromHexError, f: *std.Io.Writer) std.Io.Writer.Error!void`.
`TR/README.md:92-95` records that Debug goes through `formatDebug` and Display
through `format`.

**What a hand port should do instead.** Keep only the derives the port
actually needs. `Debug` maps to `formatDebug`. `Clone` maps to an explicit
`clone` that takes an allocator, following
`TR/notes/design/architecture/pkg-dep-macros.md:349-367`. The serde,
schemars, pyo3 and enumn derives are feature-gated at
`AK/accesskit/Cargo.toml:25-29`, so the port drops them and says so in
`docs/30-port-design.md`. Audit every `format` body for allocation first, since
an allocating one is refused: `TR/README.md:96-101`.

### 3.13 Operator overloading

**What Rust does.** `AK/accesskit/src/geometry.rs:253-260` is
`impl Add<Vec2> for Point` with `type Output = Point`. `:191-205` is
`impl Mul<Affine> for f64`, where the foreign type is the left operand.
`:643` is `impl Div<f64> for Size`, and `:602` is
`impl MulAssign<f64> for Size`.

**What Zig cannot do.** Zig has no operator overloading. There is no rule in
the record, which is itself the finding.

**What the translator did.** Nothing. The goldens show no operator method on
any emitted type, for example `TR/test/golden/zig_src/fnv/src/root.zig:101-112`.

**What a hand port should do instead.** Name each operation. `Point` gets
`addVec2`, `subVec2`, `addTuple`, `subPoint`. `Size` gets `mulScalar`,
`divScalar`, `addSize`, `subSize`. `Affine` gets `mulPoint`, `mulAffine`.
Keep the Zig names in `camelCase` per `ozai/AGENTS.md:45-46`. Every call site in
the core and in accesskit-c must move with the name. The name collision rule at
`TR/notes/design/architecture/runtime-traits.md:562-608` applies: an inherent
name keeps the container slot and a trait name gets a namespace.

### 3.14 Standard macros other than `assert!` and `panic!`

**What Rust does.** `AK/accesskit/src/lib.rs:1131` uses `matches!`,
`:3395` and `:3397` use `assert_eq!`, and `:2806-2818` `deserialize_property!`
is a local macro over a `match`. `AK/accesskit/src/lib.rs:174` shows that
AccessKit itself declined to use a macro for the same reason the record gives:
"we can't use a macro as it would break C bindings header file generation",
at `:360-361`.

**What Zig cannot do.** No macros. `TR/notes/research/idiom-mapping.md:594-595`
records that rust2zig supports only `assert_eq!`, `panic!` and `println!`.

**What the translator did.** `TR/README.md:283-284` records a refusal for an
external macro. `TR/notes/design/data-model/exprs-patterns.md:524-525` records
`format!` and `concat!` as deferred.

**What a hand port should do instead.** `matches!(v, T::X)` becomes a `switch`
with one prong. `assert_eq!` becomes `try std.testing.expectEqual` in a test
and `std.debug.assert` plus an `==` comparison in library code. Note the
ReleaseFast gap: `ZSTD/debug.zig:237-240` shows `runtime_safety` is false in
`.ReleaseFast`.

### 3.15 Higher-ranked trait bounds

**What Rust does.** `AK/adapters/atspi-common/src/node.rs:1818` is
`for<'a> F: FnOnce(RwLockReadGuard<'a, AppContext>) -> Result<T>,`.

**What Zig cannot do.** Zig has no higher-ranked bounds. The record lists HRTB
among the forms with no direct analogue at `TR/notes/research/idiom-mapping.md:258-261`.

**What the translator did.** It refused. `TR/notes/design/data-model/items-types.md:381`
lists associated types, GATs, HRTB and supertraits together as having no Zig
analogue.

**What a hand port should do instead.** Split the function. Take the lock in
the caller, pass a plain `*const AppContext` to the callback, and let the
callback return a plain value. That removes the rank and the guard type. The
call site is one function, `AK/adapters/atspi-common/src/node.rs:1810`.

### 3.16 `catch_unwind`

**What Rust does.** Converts a panic into a `Result`. Not present in any
AccessKit tree examined. `[INFERENCE]` from the absence of the token.

**What Zig cannot do.** Zig panics are not catchable. The record says it at
`TR/notes/research/idiom-mapping.md:521-522` and calls it a hard block at
`:543-545` and `:743`.

**What the translator did.** It refused and recorded the reason as a redesign:
`TR/notes/design/data-model/items-types.md:380` "impossible; redesign to
error-return".

**What a hand port should do instead.** Nothing. The construct is absent, so
the port never meets it. Keep the refusal recorded so a later reader does not
re-open it.

### 3.17 The `Visitor` pattern

**What Rust does.** `AK/accesskit/src/lib.rs:2876-3006` implements
`Visitor<'de>` for `PropertiesVisitor` with `type Value = Properties` and a
`visit_map<V>(self, mut map: V)` method that loops over a `MapAccess`.
`AK/accesskit/src/lib.rs:3009-3034` implements `Deserialize<'de>`.

**What Zig cannot do.** Zig has no visitor trait and no deserializer framework.
There is no rule in the record.

**What the translator did.** Nothing. Serialization is not in the record's
vocabulary at all.

**What a hand port should do instead.** Decide in `docs/30-port-design.md`
whether the port needs a wire format. If it does, write one explicit decoder
over decoded input, following the house rule at `ozai/AGENTS.md:65-68`, and
drive every variant from a comptime sweep over the enumerable domain
(`ozai/AGENTS.md:79-81`). If it does not, the port ships no serializer and
`docs/30-port-design.md` says so.

### 3.18 Deprecated aliases and glob re-exports

**What Rust does.** `AK/accesskit/src/lib.rs:3178-3179` is
`#[deprecated(note = "Use TreeInfo instead")] pub type Tree = TreeInfo;`.
`AK/accesskit/src/lib.rs:35` is `pub use geometry::{Affine, Point, Rect, Size, Vec2};`.

**What Zig cannot do.** Zig has no `pub use` and no deprecation attribute. The
record says `pub use` has no direct equivalent at
`TR/notes/research/idiom-mapping.md:48-49`.

**What the translator did.** It re-declares each exported name:
`TR/notes/design/data-model/crate-graph.md:174-179`. Glob expansion by
symbol-table query is specified at
`TR/notes/design/architecture/pkg-dep-macros.md:260-274`.

**What a hand port should do instead.** Delete `Tree`. The house rule is
explicit at `ozai/AGENTS.md:51-52` and `ozai/AGENTS.md:190-192`. For the glob,
write out five explicit `pub const` lines. The port also has a naming decision
the record does not cover: `AKC/src/lib.rs:13` suppresses `non_camel_case_types`
because the C names are fixed, while the core may move to `camelCase`. Fix
that in `docs/31-c-abi-design.md`.

### 3.19 Array length taken from an enum discriminant

**What Rust does.** `AK/accesskit/src/lib.rs:1062` is
`struct PropertyIndices([u8; PropertyId::Unset as usize])`, and `:1066` is
`Self([PropertyId::Unset as u8; PropertyId::Unset as usize])`. The array length
is a cast of an enum variant to `usize`, so the index table is exactly one
entry longer than the property count.

**What Zig cannot do.** An array length must be a comptime value. Here it is,
because the enum tag is comptime, so the direct form works.

**What the translator did.** The record's array rule is at
`TR/notes/design/data-model/items-types.md:276-277`, which allows a literal
length or a generic index. It does not cover an enum-derived length.

**What a hand port should do instead.** Declare the enum with an explicit
`Unset = <count>` tag, then write `indices: [PropertyId.count]u8`. Add
`comptime assert(PropertyId.count == <the number of property variants>)`,
which is the house rule at `ozai/AGENTS.md:38-40`. The count is observable
from `AK/accesskit/src/lib.rs:893-1009`, where `PropertyId` ends at `Unset`.

### 3.20 A reference to a unit enum variant

**What Rust does.** `AK/accesskit/src/lib.rs:1076-1082` is
`fn value_at(values: &[PropertyValue], index: u8) -> &PropertyValue`, whose
first branch is `&PropertyValue::None` and whose second is
`&values[index as usize]`. The first branch borrows an expression that has no
storage in the source. Rust lifts it to static storage by constant promotion.
`[INFERENCE]` on the promotion mechanism, which is a language rule and not
observed here. The observable fact is that the function compiles and returns a
valid reference from both branches.

**What Zig cannot do.** `&PropertyValue.none` needs an addressable lvalue. Zig
has no promotion of a temporary into static storage.

**What the translator did.** Nothing. The record's slice and reference rows at
`TR/notes/research/idiom-mapping.md:333-339` cover borrows, not promotion.

**What a hand port should do instead.** Declare one file-scope constant,
`const none_value: PropertyValue = .none;`, and return `&none_value` from that
branch. Then assert the two branches agree, because a caller must not be able
to tell which one produced the reference. That assertion is the observable
check: build a `Node`, set no properties, read a property, and compare the
returned pointer against `&none_value`.

---

## 4. The intermediate representation as a port checklist

The data-model notes define what a lossless representation of a Rust crate
must record. A hand port has no representation, so a reviewer cannot inspect an
intermediate. The checklist below turns each recorded field into an observable
question about one translated Zig function.

Three constraints shape it:

- The model is lossless and gated. `TR/notes/design/data-model.md:39-41` says
  unsupported forms are first-class markers with a reason, never silent
  omissions. Every check below therefore asks either "is this decided?" or
  "is this recorded as undecided?".
- Every node carries a span. `TR/notes/design/data-model.md:36-38`. A span is
  what turns a defect report into a file and line, and a hand port has no other
  index.
- Reserved words are renamed. `TR/notes/design/data-model/exprs-patterns.md:62-66`
  makes valid Zig identifiers a hard rule for every discriminant. The same rule
  applies to every emitted name: `TR/notes/research/idiom-mapping.md:56-57`
  records the `@"name"` escape.

Apply the checklist to one function at a time. A function passes when every
answer is observable in the Zig source, not when it is observable in a comment.

### 4.1 Identity and provenance

| # | Question a reviewer asks | Observable test | Rule source |
|---|---|---|---|
| 1 | Does every declaration carry a stable identity? | Each item maps to exactly one Zig declaration. Two Rust items must not collapse into one Zig function. | `TR/notes/design/data-model.md:31-35` |
| 2 | Does every node carry a source span? | Every emitted function names its Rust origin in a doc comment or an annotation. | `TR/notes/design/data-model.md:36-38` |
| 3 | Does every node carry a resolved type? | Every local binding in the Zig output has an explicit type where the Rust source has one. | `TR/notes/design/data-model/exprs-patterns.md:48-52` |
| 4 | Is the enclosing scope recorded? | A nested item is emitted inside the container that owns it, not at file scope. | `TR/notes/design/data-model.md:70-71` |
| 5 | Is an alias recorded as an alias rather than a duplicate definition? | A `use` or re-export produces an assignment line, never a second body. | `TR/notes/design/data-model.md:72-73`; `TR/notes/design/data-model/crate-graph.md:174-179` |
| 6 | Is a keyword collision escaped? | Any emitted name that is a Zig keyword is written `@"name"`. | `TR/notes/research/idiom-mapping.md:56-57`; `TR/test/golden/zig_src/fnv/src/root.zig:102` uses `@"0"` |
| 7 | Is every attribute preserved? | Every `#[...]` on the Rust item appears in the Zig source as a comment, a naming convention, or a comptime assertion. No attribute is dropped. | `TR/notes/design/data-model/items-types.md:195-196`; `TR/notes/design/data-model.md:88-90` |
| 8 | Is an unknown attribute marked unknown rather than acted on? | An attribute the port does not understand is a comment, never a silent behaviour change. | `TR/notes/design/data-model/items-types.md:82-83`, the `known` flag |
| 9 | Is the exported surface computed rather than assumed? | Every `pub` item is reachable from the package root. Every private item is not. | `TR/notes/design/data-model/crate-graph.md:154-166` |

### 4.2 Declarations

| # | Question a reviewer asks | Observable test | Rule source |
|---|---|---|---|
| 10 | Is the struct layout decided? | Each Rust struct is a `struct`, an `extern struct`, or a `packed struct`, and the choice follows the `repr` attribute. | `TR/notes/design/data-model/items-types.md:57-69` |
| 11 | Is tuple-struct position resolved? | Each tuple field becomes a named field with the position recorded. | `TR/notes/design/data-model/items-types.md:66` |
| 12 | Is the enum kind decided? | A fieldless Rust enum is an `enum(N)`. A data-carrying Rust enum is a `union(enum)`. No Rust enum becomes a plain Zig `union`. | `TR/notes/research/idiom-mapping.md:182`; `TR/notes/design/data-model/items-types.md:83-87` |
| 13 | Is the enum backing integer pinned? | A `#[repr(uN)]` enum has an explicit `enum(uN)` with the same `N`. | `TR/notes/research/idiom-mapping.md:153-154`; `TR/notes/design/data-model/items-types.md:83` |
| 14 | Is a unit variant a `void` payload? | A Rust unit variant is a `void`-typed field, and its construction site passes an explicit void value. | `TR/notes/research/idiom-mapping.md:148-149`; `TR/test/golden/zig_src/compat/src/root.zig:1256` |
| 15 | Is `#[non_exhaustive]` recorded? | Each such enum has an `else` prong at every switch, or the port records that the enum has no external constructors. | `TR/notes/design/data-model/items-types.md:85-87` |
| 16 | Is the receiver mode explicit? | Each method's first parameter states its own kind: `*const Self`, `*Self`, or `Self`. No method relies on an implicit receiver. | `TR/notes/design/data-model/items-types.md:110-112` |
| 17 | Is the async flag recorded even when not emitted? | An `async fn` is either given `io` and a plain return, or is listed as not ported. | `TR/notes/design/data-model/items-types.md:102-104` |
| 18 | Is the unsafe flag recorded? | An `unsafe fn` is marked in the Zig source, because Zig has no keyword for it. | `TR/notes/research/idiom-mapping.md:654-655`; `TR/notes/design/data-model/items-types.md:111-112` |
| 19 | Is the unit return mapped to `void`? | A Rust `()` return is Zig `void`, and a Rust unit statement is a no-op. | `TR/notes/design/data-model/exprs-patterns.md:87` |
| 20 | Is an `impl` split decided? | Each Rust `impl` block lands in one Zig container. A trait impl is either folded or namespaced, and the choice is the same for every method of that trait. | `TR/notes/design/data-model/items-types.md:144-146`; `TR/notes/design/architecture/runtime-traits.md:569-608` |
| 21 | Is a trait declaration's shape decided? | Each trait becomes either a comptime duck-typed contract or a function-pointer struct. The choice is recorded per trait. | `TR/notes/research/idiom-mapping.md:229-256` |
| 22 | Is an `extern` block's ABI recorded? | Each FFI declaration carries its calling convention. A Windows entry point uses `callconv(.winapi)`. | `TR/notes/design/data-model/items-types.md:151-153`; `TR/notes/research/idiom-mapping.md:689-690` |

### 4.3 Generics and monomorphisation

| # | Question a reviewer asks | Observable test | Rule source |
|---|---|---|---|
| 23 | Are generic parameters comptime? | Each Rust type parameter is `comptime T: type`, declared before runtime parameters. | `TR/notes/research/idiom-mapping.md:215-217` |
| 24 | Are const generics comptime? | Each Rust `const N: usize` is `comptime N: usize`. | `TR/notes/research/idiom-mapping.md:200-208` |
| 25 | Are method comptime parameters placed after `self`? | A generic method takes `self` first, then its comptime parameters, so the callsite can infer them. | `TR/notes/research/idiom-mapping.md:216-217`; `TR/notes/design/data-model/items-types.md:224-225` |
| 26 | Are lifetimes erased but recorded? | No lifetime parameter appears in the Zig signature. The borrow it constrained is stated in a doc comment. | `TR/notes/design/data-model/items-types.md:221`, `:226` |
| 27 | Is a `where` clause retained but not emitted? | The Zig signature has no bound syntax. The bound's meaning is either checked by a `comptime` assertion or recorded as unportable. | `TR/notes/research/idiom-mapping.md:211-213`; `TR/notes/design/data-model/items-types.md:224-226` |
| 28 | Is each instantiation a record, not a copied body? | One generic Zig function serves every instantiation. No body is duplicated per callsite. | `TR/notes/design/data-model.md:42-44`; `TR/notes/design/data-model/items-types.md:228-238` |
| 29 | Is an associated type given a concrete Zig form? | Each associated type is either an extra comptime parameter or a comptime-known projection, and the choice is recorded. | `TR/notes/research/idiom-mapping.md:258-261` |

### 4.4 Types

| # | Question a reviewer asks | Observable test | Rule source |
|---|---|---|---|
| 30 | Is every type node given a Zig form? | Each Rust type in the signature maps to one Zig type with no unresolved name. | `TR/notes/design/data-model/items-types.md:247-256` |
| 31 | Is `Option<T>` an optional, not a union? | A Rust `Option` in a signature is `?T`. | `TR/notes/research/idiom-mapping.md:276-279` |
| 32 | Is a finite `Result` an error union? | A Rust `Result<T, E>` with a finite `E` is `E!T`, and `E` is written out as an explicit error set. | `TR/notes/research/idiom-mapping.md:280-281`; `TR/notes/design/data-model/items-types.md:293-295` |
| 33 | Is a payload-carrying error a tagged union? | A Rust `Result` whose error carries data is `union(enum) { ok, err }`, not an error union. | `TR/notes/design/architecture/features-actionable.md:187-209`; `TR/test/golden/zig_src/hex/src/error.zig:23` |
| 34 | Is `Box<T>` a pointer with a recorded owner? | Each `Box` is a `*T` allocated by a named allocator, with a matching release in the same function or a documented owner. | `TR/notes/design/data-model/items-types.md:296-299`; `TR/notes/design/data-model/ownership-mem.md:170-175` |
| 35 | Is `&str` a slice, not a sentinel slice? | A Rust `&str` is `[]const u8`. A sentinel `[:0]const u8` appears only at a C boundary. | `TR/notes/research/idiom-mapping.md:445-446`, `:466-468` |
| 36 | Is `char` a codepoint, not a byte? | A Rust `char` is `u21`. | `TR/notes/design/data-model/items-types.md:270-271`; `TR/test/golden/zig_src/hex/src/error.zig:26` |
| 37 | Is `()` mapped to `void` and `!` to `noreturn`? | A Rust unit type is `void`. A Rust never type is `noreturn`. | `TR/notes/design/data-model/items-types.md:270-271` |
| 38 | Is a raw pointer given the right size class? | A Rust `*const T` is `[*]allowzero align(1) const T`, so a null address is representable and `==` reads addresses. | `TR/README.md:240-247`; `TR/notes/research/idiom-mapping.md:649-657` |
| 39 | Is a slice pointee ordered comparison refused? | No Zig expression compares the addresses of two raw pointers to an unsized pointee. | `TR/README.md:243-245` |
| 40 | Is a tuple given field names? | Each Rust tuple becomes an anonymous or named struct, and each member is accessed by field. | `TR/notes/design/data-model/items-types.md:282`; `TR/notes/design/architecture/features-actionable.md:275-276` |
| 41 | Is an owned string given an allocator? | Each Rust `String` maps to an unmanaged list plus a named allocator, never a global. | `TR/notes/research/idiom-mapping.md:444-458`, `:469-471` |

### 4.5 Expressions and patterns

| # | Question a reviewer asks | Observable test | Rule source |
|---|---|---|---|
| 42 | Is the call kind explicit? | A free call, an associated call and a constructor produce three different Zig forms, and each callsite uses the right one. | `TR/notes/design/data-model/exprs-patterns.md:234-244` |
| 43 | Is the receiver mode explicit at each method call? | Each callsite passes the receiver as `Self`, `*const Self`, or `*Self`, matching the declaration. | `TR/notes/design/data-model/exprs-patterns.md:249-258` |
| 44 | Is `?` a `try` on an error union only? | Each Rust `?` is a Zig `try`, and the enclosing function returns an error union. | `TR/notes/design/data-model/exprs-patterns.md:331` |
| 45 | Is `unwrap` and `expect` a deliberate panic? | Each Rust `unwrap` is `catch unreachable` or `orelse unreachable`. Each is counted, because each is a new panic path. | `TR/notes/research/idiom-mapping.md:281`; `TR/notes/design/architecture/features-actionable.md:222-224` |
| 46 | Is the overflow mode explicit per arithmetic operation? | Each Rust `+`, `-`, `*`, `<<` and `>>` is one of `+`, `+%`, `-\|`, `@addWithOverflow`, never left to the build mode. | `TR/notes/design/data-model/exprs-patterns.md:283-303`; `TR/notes/research/idiom-mapping.md:537-539` |
| 47 | Is a `match` on an `Option` lowered to an `if` capture? | No Zig `switch` has an optional as its operand. | `TR/notes/research/idiom-mapping.md:277-279`, `:389-390` |
| 48 | Is a `match` guard lowered to a labelled block? | Each guarded arm is a `blk` with `break :blk`, not a `switch` prong. | `TR/notes/research/idiom-mapping.md:391`; `TR/test/golden/zig_src/compat/src/root.zig:1263-1270` |
| 49 | Are match ergonomics made explicit before emit? | Every binding in a `match` over a reference has its deref count written out in the Zig source. | `TR/notes/design/data-model/exprs-patterns.md:349-352`; `TR/notes/research/prior-work.md:32` |
| 50 | Are or-patterns collapsed into one arm? | A Rust `a \| b` arm becomes one Zig arm or two prongs to one body, not a duplicated body. | `TR/notes/design/data-model/exprs-patterns.md:404` |
| 51 | Is a binding mode recorded? | Each pattern binding states whether it captures by value, by const pointer, or by mutable pointer. | `TR/notes/design/data-model/exprs-patterns.md:374-383` |
| 52 | Is the `for` kind decided? | Each Rust `for` is a range, a slice, a multi-object, an enumerate, or is recorded as unported. | `TR/notes/design/data-model/exprs-patterns.md:216-222` |
| 53 | Is an iterator chain lowered to a loop? | No Zig expression reproduces a Rust adapter chain. Each chain is an explicit `for`. | `TR/notes/research/idiom-mapping.md:413-420`; `TR/notes/design/data-model/exprs-patterns.md:476-492` |
| 54 | Is a closure given a capture list? | Each closure names every captured variable and how it is captured. | `TR/notes/design/data-model/exprs-patterns.md:453-467` |
| 55 | Is a labelled break preserved? | Each labelled `break` and `continue` carries its label in the Zig source. | `TR/notes/design/data-model/exprs-patterns.md:224-225` |
| 56 | Is struct-update syntax resolved? | Each `..base` is expanded into explicit field assignments. It is not emitted as Zig syntax, which has none. | `TR/notes/design/data-model/exprs-patterns.md:526` |

### 4.6 Ownership, allocation, and safety

| # | Question a reviewer asks | Observable test | Rule source |
|---|---|---|---|
| 57 | Is every value classified as move, copy, or move-and-drop? | The port records the classification for each local that owns storage. | `TR/notes/design/data-model/ownership-mem.md:39-58` |
| 58 | Is a borrow shape recorded per parameter? | Each parameter is owned, shared, mutable, or a slice, and the Zig type matches. | `TR/notes/design/data-model/ownership-mem.md:69-84` |
| 59 | Is every allocation sourced? | Every `alloc`, `create` and `dupe` names its allocator parameter. No allocation reaches a global. | `TR/notes/design/data-model/ownership-mem.md:146-176`; `ozai/AGENTS.md:33-35` |
| 60 | Is a pure function free of allocator parameters? | A function with no allocation has no allocator parameter. | `TR/notes/design/architecture/structure-memory.md:161-179`, `:491-493` |
| 61 | Is the drop plan written out? | Each owning type has a `deinit`, and its fields are released in Rust declaration order. | `TR/notes/design/architecture/structure-memory.md:282-289`; `TR/notes/design/data-model/ownership-mem.md:129-137` |
| 62 | Is every fallible acquisition protected? | Each acquisition is followed by `defer` for the success path and `errdefer` for the failure path. | `TR/notes/design/architecture/structure-memory.md:291-316` |
| 63 | Is each replaced borrow guarantee marked? | Every place where Rust's guarantee is now only a runtime flag carries an explicit comment or assertion. | `TR/notes/design/data-model/ownership-mem.md:225-229` |
| 64 | Is each unsafe category answered? | `alias_mut`, `borrow_outlives_owner`, `returned_dangling`, `copy_alias` and `interior_mut` each have an answer: comment, guard, or refusal. | `TR/notes/design/data-model/ownership-mem.md:207-223` |
| 65 | Is a transferred owner tracked? | A value handed to a caller is released exactly once, and the callsite shows the handoff. | `TR/README.md:230-238` |
| 66 | Is `unreachable` a claim with a reason? | Each `unreachable` names the case that makes it impossible. | `ozai/AGENTS.md:82-84` |

### 4.7 Refusal and preservation

| # | Question a reviewer asks | Observable test | Rule source |
|---|---|---|---|
| 67 | Is every unported form named? | Each Rust construct with no Zig form appears in the port's own refusal list with its reason. | `TR/notes/design/data-model.md:39-41`; `TR/notes/design/data-model/exprs-patterns.md:531-534` |
| 68 | Is each refusal recorded with a suggested stage? | Each refusal carries the version or milestone in which it could be revisited. | `TR/notes/design/data-model/exprs-patterns.md:335` |
| 69 | Is a deferred node present but refused? | The schema admits the node so the port can grow, and the emitter refuses it loudly rather than guessing. | `TR/notes/design/data-model/exprs-patterns.md:441-445`, `:493-497` |
| 70 | Are doc comments preserved? | Every Rust `///` and `//!` reaches the Zig source on the matching declaration. | `TR/README.md:86-87`; `TR/notes/design/architecture/pkg-dep-macros.md:334-341` |
| 71 | Is the ownership contract stated where a consumer needs it? | The module-level comment states how to import the module, what it borrows, and what it returns by pointer. | `TR/README.md:86-91`; `TR/test/golden/zig_src/fnv/src/root.zig:60-63` |
| 72 | Is an inherent method that collides with a protocol hook renamed, and is every caller updated? | The collision is resolved once and no callsite keeps the old name. | `TR/README.md:94-96` |

### 4.8 What the checklist cannot check

Three of the recorded fields have no observable form in a hand port, and a
reviewer should say so rather than pretend otherwise.

| Field | Why it has no observable form | What to require instead |
|---|---|---|
| `Instantiation.zig_suffix` at `TR/notes/design/data-model/items-types.md:232-234` | Zig memoizes per identical type, so a translator needs a mangled name only to tell instantiations apart in its own tables. A hand port has no such table. | A `comptime` type-name test per generic declaration, asserting the emitted function name is stable. |
| `Ownership.moved_across_boundary` at `TR/notes/design/data-model/ownership-mem.md:55-56` | The flag exists so an emitter can suppress a second drop. A hand port writes the release once and has no emitter to suppress. | A leak-checked test per public entry point, under `std.testing.checkAllAllocationFailures` or its equivalent. `TR/README.md:224-226` records the translator's equivalent check. |
| `Node.span` at `TR/notes/design/data-model/exprs-patterns.md:39-43` | The span drives diagnostics inside the translator. A hand port's diagnostics come from the compiler. | A comment on each function naming its Rust origin, so a defect report can be routed without a search. |

---

## 5. Recorded rejections

These are decisions the records already made. A hand port does not reopen one
without new evidence, and "it is easier the other way" is not new evidence.
The last column says whether the rejection binds this port, partly binds it,
or was overtaken later. Section 6 gives the evidence for the overtaken rows.

### 5.1 Architectures rejected before any code was written

| Rejected | Reason recorded | Evidence | Binds this port? |
|---|---|---|---|
| Option (a), full translation driven by rustc internals | The nightly pin is permanent and rustc master is under constant development. Effort was rated very high at six to twelve months for one developer. | `TR/notes/research/approaches.md:66-96`, the effort table at `:90-94` | Yes, and it is the port's founding constraint. No `rustc`, no `cargo`, no build script, no `cbindgen`. |
| Option (c), an FFI seam between translated and untranslated code | No inlining across the boundary, two build systems, two allocators, two string types, and every complex type becomes a hand-rolled binding. A `HashMap<String, Vec<u8>>` is a 200-line FFI struct by hand. | `TR/notes/research/approaches.md:138-181`, the cons at `:170` | Yes. The port forbids an FFI shim that forwards into Rust. |
| Option (d), translate the whole crate graph | A Rust crate's transitive closure contains `tokio`, `serde` and `syn`. Translating all of it is years of work. The record calls it impossible for any crate depending transitively on `tokio`, `async-trait`, or `proc-macro2`/`syn`/`quote` as actual logic. | `TR/notes/research/approaches.md:184-224`, the verdict at `:216` | Yes. The port enumerates modules, not crates. |
| `cargo expand` as ground truth for macro expansion | The cargo-expand README calls it "a debugging aid only. There should be no expectation that the expanded code can be compiled successfully, nor that if it compiles then it behaves the same as the original code." | `TR/notes/research/approaches.md:124` | Yes, and the port goes further: no Cargo at all. |
| Pre-expanding macros in a rustc sidecar before IR lowering | Accepted at the time as the decision, with the recorded tradeoff that it "increases dependency on the Rust compiler sidecar". | `TR/notes/design/architecture/pkg-dep-macros.md:476-478` | Superseded. See section 6, row 2. |
| Syntax-only tooling as the front end | Every surviving translator uses a real front end with type information. The dead projects all stopped at hand-rolled tokenizers. | `TR/notes/research/prior-work.md:129` | Partly. The port reads Rust source and must resolve types itself, which is the cost. |
| Whole-language scope | The record's pattern of failure is universal: tokenizer plus all-languages attempts die in weeks. c2z scoped itself to "libraries that follow the *C with classes* coding style". | `TR/notes/research/prior-work.md:137` | Yes. The port names a module list, not "a library". |
| Keeping `cargo test` as a differential oracle against `zig test` | Recommended as "the cornerstone" of verification at the time. | `TR/notes/research/approaches.md:255-259`, `:319-326` | Superseded for this port. See section 6, row 3. |

### 5.2 Rust constructs rejected as out of the v1 dialect

Every row is an explicit `Unsupported` marker with a reason, never a silent
omission. `TR/notes/design/data-model/items-types.md:370-382` is the table.

| Rejected form | Reason recorded | Evidence | Binds this port? |
|---|---|---|---|
| `dyn Trait` and heterogeneous trait objects | No Zig vtable. The record calls it hard, and the first v1 blocker, and notes that no existing transpiler provides the elaboration. | `TR/notes/research/idiom-mapping.md:270-272`, `:731-732`; `TR/notes/design/data-model/items-types.md:374` | No. The port may use a function-pointer struct instead, which the record itself suggests at `TR/notes/research/idiom-mapping.md:266-268`. |
| `Rc`, `Arc`, `Cell`, `RefCell`, `Mutex` interior mutability | They need an ownership and arena layer that the translator only partly delivered. | `TR/notes/research/idiom-mapping.md:733-735`; `TR/notes/design/data-model/ownership-mem.md:293-295`, `:310` | No, for the same reason. But see section 7, item 5. |
| Path-sensitive `Drop`, the alive-flag strategy | The `defer` elaboration is only partial. The record keeps `defer_only` and gates the rest. | `TR/notes/research/idiom-mapping.md:356-357`; `TR/notes/design/data-model/ownership-mem.md:139-142`, `:290` | Partly. The port may use explicit `cancel` and `detach` methods instead. |
| Custom iterators, `FnMut` closures, `move` closures | Each needs a per-adapter state-machine lowering. The record says so twice. | `TR/notes/research/idiom-mapping.md:736-737`; `TR/notes/design/data-model/items-types.md:377` | Partly. The port lowers chains to explicit loops, which the record endorses. |
| `async` and `await` composed with an executor | It is "a rewrite, not a translation". | `TR/notes/research/idiom-mapping.md:738-739`; `TR/notes/design/data-model/items-types.md:378` | No. The port runs on `zio`, which supplies the scheduler. |
| `catch_unwind` | Impossible. It signals a redesign, not a translation. | `TR/notes/research/idiom-mapping.md:543-545`, `:743`; `TR/notes/design/data-model/items-types.md:380` | Yes, as a record. The construct is absent from AccessKit. |
| Associated types, GATs, HRTB, supertraits | No Zig analogue. Each needs a manual elaboration. | `TR/notes/research/idiom-mapping.md:258-261`; `TR/notes/design/data-model/items-types.md:381` | Yes, as a record. Section 3.9 and section 3.15 give the replacements. |
| Emitting a `where` clause | Bounds are not emitted. Zig checks them by duck typing at the instantiation. | `TR/notes/research/idiom-mapping.md:211-213`; `TR/notes/design/data-model/items-types.md:382` | Yes. Use a `comptime` assertion instead. `TR/notes/design/architecture/runtime-traits.md:387-403` is the shape. |
| Emitting a match guard in v1 | The lowering was known but not shipped. A non-null guard is a hard parse error carrying `Unsupported`. | `TR/notes/design/data-model/exprs-patterns.md:515-516`, `:519-520` | No. Section 3 gives the labelled-block form and the golden shows it. |
| `format!`, `concat!`, and the `std::fmt` macro surface | Format specifiers are type-driven and the record could not type them. | `TR/notes/design/data-model/exprs-patterns.md:524-525` | Partly. The port writes `format` bodies by hand. |
| Struct-update syntax, `..base` | Deferred. Zig has no equivalent form. | `TR/notes/design/data-model/exprs-patterns.md:526` | No. Expand into explicit assignments. |
| A `let` whose pattern is refutable and is not a `let-else` | The sidecar must lower it to an `if let` first. | `TR/notes/design/data-model/exprs-patterns.md:527` | No. Lower it by hand. |
| `#[cfg(...)]` target filtering in the v1 dialect | Owned by the crate graph, and out of the item subset. | `TR/notes/design/data-model/items-types.md:193` | No. The port uses `comptime` target checks. |
| A harness-owned global arena as the allocator source | Listed as open, then resolved against: the consensus default is to thread the allocator parameter from the start, "avoids v2 signature rewrites". | `TR/notes/design/data-model.md:190`, consensus at `:199` | Yes. `ozai/AGENTS.md:33-35` says the same. |
| An allocator hidden in a context parameter | The record labels it a downside: "Obscures function requirements, couples code to a transpiler runtime struct, violates Tiger Style." | `TR/notes/design/architecture/structure-memory.md:201-203` | Yes. `ozai/AGENTS.md:59-63` says the same. |
| `anyerror` as the fallback for a non-finite error type | The record leaves it open and notes that it is coarse and loses the set. | `TR/notes/design/data-model/items-types.md:402-404` | Yes. `ozai/AGENTS.md:33-35` forbids `anyerror` in an API. |
| Ordering comparison of raw pointers to an unsized pointee | Refused. `==`, `!=` and the four orderings are admitted only on thin raw pointers, not on a slice pointee. | `TR/README.md:243-245` | Yes, as a rule. |
| A `Display` body that needs an allocator | Neither native hook asks its caller for an allocator, so an allocating body is refused rather than emitted without one. | `TR/README.md:96-101` | Yes. Audit every `format` body. |
| Managed `std.ArrayList`, the allocator-storing form | Deprecated in Zig 0.16. Emit unmanaged with `.empty` and an explicit allocator. | `TR/notes/research/idiom-mapping.md:469-471`, confirmed at `ZSTD/array_list.zig:569` | Yes. |
| Mapping a Rust enum to a bare Zig `union` | The record is explicit: "Do NOT map Rust's `enum` to `union`". A payload-carrying enum maps to `union(enum)`. | `TR/notes/research/idiom-mapping.md:182` | Yes. |
| A `switch` on an `Option` | Zig optionals are not unions, so a `match` on `Option` becomes an `if` with an optional capture. | `TR/notes/research/idiom-mapping.md:277-279` | Yes. |
| Pre-folding `pub use` into a duplicate declaration | The record keeps the `UseDecl` so the model knows which name is an alias. | `TR/notes/design/data-model/crate-graph.md:174-179` | Yes. Emit an assignment. |
| Standalone source trait declarations | Listed as unsupported in the shipped state. | `TR/README.md:311-313` | No. The port needs no dynamic trait solving. |
| Translating dependency crates | Cargo dependencies enter the IR as metadata only. | `TR/README.md:310-311` | Yes. `uuid` becomes bytes, not a ported crate. |
| Executing build scripts | "Build scripts are not executed." The `crc16` fixture is refused for a generated include. | `TR/README.md:285-286` | Yes. No `build.rs` in the port. |
| Bare `anytype` for a generic parameter | The record decides on explicit `comptime T: type` plus a trait check, accepting more compiler verbosity for clear errors. | `TR/notes/design/architecture/runtime-traits.md:640-642` | Yes. `ozai/AGENTS.md:33-35` requires explicit types. |
| `std.debug.assert` where a check must survive ReleaseFast | The check is elided in ReleaseFast, so the record requires `if (!cond) @panic(...)`. | `TR/notes/research/idiom-mapping.md:532-536`; `ZSTD/debug.zig:237-240` | Yes, for any invariant the port claims. |

### 5.3 Rejections that this port should copy verbatim

Four rejections are cheap to keep and expensive to rediscover. A port that
invents its own answer here will get it wrong.

| Rejection | Why copy it | Evidence |
|---|---|---|
| Every unsupported form is a first-class marker with a reason | A silently wrong value is the failure the contract names. | `TR/notes/design/data-model.md:39-41`; `TR/README.md:304-308` |
| Every item keeps a source span | It is the only index a defect report has. | `TR/notes/design/data-model.md:36-38` |
| Every discriminant string is a valid Zig identifier | It makes the mapping total and mechanical. | `TR/notes/design/data-model/exprs-patterns.md:62-66` |
| An unknown attribute survives as a comment, never a drop | Attribute semantics are a policy input. Losing one loses a contract. | `TR/notes/design/data-model/items-types.md:195-196`; `TR/notes/design/data-model.md:88-90` |

---

## 6. Contradictions and superseded records

Nine places where two records disagree, and three open questions that a later
consensus settled. Each row gives both sides, then the record that governs. A
record that has been overtaken is more useful to the port author than one
presented as current, so the superseded side is named first.

Dates come from the notes themselves. The research notes are dated 2026-08-17
at `TR/notes/README.md:15` and `:28`; the design notes are dated 2026-08-18 at
`TR/notes/README.md:79`. Both carry a banner stating they are historical:
`TR/notes/README.md:5-10` and, per note, its own first six lines.

### 6.1 Disagreements

| # | Subject | Superseded side | Governing side | Which governs and why |
|---|---|---|---|---|
| 1 | Whether the notes describe what the translator supports | `TR/notes/research/idiom-mapping.md:1-6` records research on 2026-08-17 and states that "Nothing here is a claim that `translate-rust` supports a Rust shape" | `TR/README.md:9-11` "The subset is bounded, and the boundaries below are measured, not aspirational." `TR/README.md:149-151` lists the fixtures that translate, and `:296-302` pins five refusals | The repository README. It is the only statement of current coverage, as `TR/notes/README.md:9-10` says itself. Every mapping rule in section 2 of this document is therefore evidence about a rule, not about coverage. |
| 2 | Where the semantic front end comes from | `TR/notes/design/data-model.md:180-182` makes "rustdoc JSON for v0/v1" the consensus default | `TR/notes/design/data-model.md:202-209` states that "Decision 1 supersedes for v2+" and names a tree-sitter parser plus a Zig type-inference engine, "so translate-rust depends on no Rust toolchain". `TR/README.md:20-22` records the shipped behaviour: "Crate translation reads Rust source directly; it does not run Cargo or rustc." | The same file supersedes itself, and the README confirms it. The port takes the v2 position from the start, because it is the only one compatible with no Rust toolchain. |
| 3 | Where macros are expanded | `TR/notes/design/architecture/pkg-dep-macros.md:476-478` decides to "Fully expand all declarative, derive, and procedural macros in the semantic sidecar prior to IR lowering", accepting the dependency on a rustc sidecar as the tradeoff | `TR/notes/research/idiom-mapping.md:629-632` calls macros a hard-block that "require running the Rust toolchain". `TR/README.md:283-284` records the `fletcher` fixture refused with `ExternalMacroSourceUnavailable`, and `:285-286` records that build scripts are not executed | The README. The sidecar design cannot work in a port with no rustc. Section 3.11 and 3.12 give the hand expansion. |
| 4 | How output is verified against the source | `TR/notes/research/approaches.md:255-259` and `:319-326` make `cargo test` against `zig test` the cornerstone, and `:131` records c2rust's two-phase model as the shape to copy | `TR/README.md:398-425` records `tools/rust-corpus-oracle.sh` as a separate runner with strict prerequisites, and `TR/README.md:20-22` states translation itself runs no Cargo | The README, and for this port neither side. The port may not keep `cargo` as an oracle. A recorded fixture replaces it, per `ozai/AGENTS.md:89-91`. The material belongs to `docs/25-r2z-oracle-and-promotion.md`, not here. |
| 5 | Where the allocator comes from | `TR/notes/design/data-model/ownership-mem.md:184-186` says "the preferred container is a single scoped arena owned by the entry point (`AllocatorSource.global_arena`/`.field`) so the whole no_std program frees with one `defer arena.deinit()`" | `TR/notes/design/data-model.md:190` lists the question as open, and `:199` sets the consensus default to "thread `.param` from the start where the model already threads allocators", with the reason "avoids v2 signature rewrites". `TR/notes/design/architecture/structure-memory.md:229-256` recommends a hybrid of an explicit parameter and a struct-stored allocator, never an arena owned by the harness. | The consensus at `TR/notes/design/data-model.md:199`. The arena preference in `ownership-mem.md` was written before that consensus and never updated. The port threads the allocator, per `ozai/AGENTS.md:33-35`. |
| 6 | The Zig form of a `&self` receiver | `TR/notes/design/architecture/structure-memory.md:107` hedges: "`self: *const Self` (or `self: Self` for small scalar types)" | `TR/notes/research/idiom-mapping.md:89-91` is unconditional, as is `TR/notes/design/data-model/items-types.md:110-112`. The emitted golden is unconditional: `TR/test/golden/zig_src/fnv/src/root.zig:101` is `pub fn finish(self: *const FnvHasher) u64`, and `:106` is `pub fn write(self: *FnvHasher, bytes: []const u8) void`. | The unconditional form. The hedge in `structure-memory.md` is a note-level suggestion that the emitter never implemented. Taking it would make the receiver type depend on the field types, which is a rule no caller can predict. |
| 7 | Whether Zig enum tags are lowercased | `TR/notes/research/idiom-mapping.md:143-144` states "Zig enum values are *always* lowercase by convention" | `TR/notes/design/architecture/features-actionable.md:56-64` emits `pub const HttpMethod = enum(u8) { Get = 0, ... }` with the Rust names. The golden keeps the Rust names: `TR/test/golden/zig_src/compat/src/root.zig:1252-1257` is `const OrPayload = union(enum) { A: struct { n: u8 }, ... Other: void };` | The golden. The lowercase claim in `idiom-mapping.md` is a statement about Zig style, not a mapping rule. The translator preserves Rust names, which keeps the mapping to the C header checkable by eye. `TR/README.md:92-93` confirms: "Rust names are preserved except native protocol hooks and name collisions." |
| 8 | How a Zig hash map is initialized and released | `TR/notes/research/idiom-mapping.md:492-495` shows `var h = std.StringHashMap(i32).init(gpa);` then `defer h.deinit();` then `try h.put("a", 1);` | `TR/notes/research/idiom-mapping.md:498-501`, eleven lines later, states "Every std container is allocator-parameterized: `init(gpa)`/`init(allocator)` and per-call `gpa` for growing ops", and that every mutating operation returns an error union. `TR/notes/research/idiom-mapping.md:508-511` adds that keys and values are not freed by `deinit` and the caller owns them. | The rule at `:498-501`. The example at `:492-495` is stale, written against the managed container that `:469-471` then rejects as deprecated. A port that copies the example gets a managed container that Zig 0.16 deprecates. |
| 9 | Whether a synthesized vtable may take an allocator | `TR/notes/design/architecture/runtime-traits.md:437` puts `deinit: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void = null` inside the generated `VTable` | `TR/README.md:96-101` states "Neither native hook asks its caller for an allocator, so only allocator-free formatter bodies are admitted", and refuses an allocating body with `UnsupportedAllocatingFormatter` | The README. The shipped behaviour refuses rather than widens the interface. A protocol hook that takes an allocator forces every caller to supply one. |

### 6.2 Open questions that a later consensus settled

These are not contradictions. They are recorded as open and then answered, and
the answer is what a port author should use.

| # | Question as recorded | Where it was open | Where it was settled | Answer |
|---|---|---|---|---|
| 10 | What is the default overflow mode when the front end records nothing? | `TR/notes/design/data-model/exprs-patterns.md:585-590` | `TR/notes/design/data-model.md:199`, consensus default 3 | Checked. Zig `+` panics on overflow, which matches the Rust debug intent. The port must still write the mode per operation, per `TR/notes/design/data-model/exprs-patterns.md:283-303`. |
| 11 | Is a `where` clause emitted? | `TR/notes/design/data-model/items-types.md:392-395`, and `:382` | `TR/notes/design/data-model.md:199`, consensus default 5 | Not emitted. Bounds are duck-typed and retained as diagnostics. Use a `comptime` assertion where the bound matters. |
| 12 | Does a trait-impl method fold into the struct or emit standalone? | `TR/notes/design/data-model/items-types.md:392-395` | Not settled anywhere in the checkout. `[INFERENCE]` | Still open. `docs/30-port-design.md` must decide it, because it decides whether `geometry.rs` operator methods collide with inherent names. |

### 6.3 Questions the checkout never answers

Four questions in the records have no answer here. A port author must supply one.

| # | Question | Where it is asked | Why it matters here |
|---|---|---|---|
| 13 | Do the `Option`, `Result` and `Box` nodes hold the resolved inner type, or the raw path? | `TR/notes/design/data-model/items-types.md:397-400` | Decides whether the port's representation depends on recognizing `core::option::Option` by name. |
| 14 | What is the exact split for inherent versus trait methods? | `TR/notes/design/data-model/items-types.md:392-395` | Section 3.13 depends on it. |
| 15 | How aggressive is `UnsoundMarker` emission in `ReleaseFast` against `ReleaseSafe`? | `TR/notes/design/data-model/ownership-mem.md:355-360` | The port has no marker field. It has to decide which guards are always emitted. |
| 16 | Does the port need `r2z-core`? | Not asked anywhere. The record assumes it: `TR/notes/design/architecture/runtime-traits.md:28-48` and `TR/README.md:80-84` | The port builds on `zio`, which may already cover the runtime layer. `docs/30-port-design.md` should decide whether a runtime package exists at all. |

---

## 7. What the AccessKit port inherits

Fifteen rules from section 2 that bind this port, ordered by how much damage
getting them wrong would cause. The order is by consequence, not by effort.
Items 1 to 5 produce silently wrong behaviour. Items 6 to 10 produce a wrong
shape. Items 11 to 15 produce a review finding.

| # | Inherited rule | Severity of getting it wrong | Where it bites in AccessKit | Evidence |
|---|---|---|---|---|
| 1 | The borrow guarantee is gone. Thread `io` and every allocator, and make shared state a parameter. | Silent wrong values that compile. The record's own probe found exactly this class. | `AK/adapters/unix/src/adapter.rs:176-188` holds a `MutexGuard` across a three-way `match`. `AK/adapters/atspi-common/src/context.rs:36-39` shares four lockable fields through one `Arc`. | `TR/AGENTS.md:15-17`; `TR/notes/research/idiom-mapping.md:349-353`; `ozai/AGENTS.md:59-63`, `:69-70` |
| 2 | Unbounded loops need an explicit non-termination claim and a fixed ceiling. | A hang becomes a timeout with no diagnosis. | `AK/adapters/unix/src/context.rs:176-180` is `async move { loop { ...tick().await; } }` with no exit. `AK/adapters/unix/src/context.rs:197-210` is the outer `loop { select! { ... } }`. | `ozai/AGENTS.md:41-42`; section 3.10 |
| 3 | No process-global mutable state. Pass the context. | Nothing is deterministically drivable, so nothing is testable. | `AK/adapters/unix/src/context.rs:33-34` declares two `static` `OnceLock` values. `AK/adapters/unix/src/atspi/bus.rs:35` declares `desktop: Arc<OnceLock<ObjectRefOwned>>`. | `ozai/AGENTS.md:59-63`; `TR/notes/design/data-model/ownership-mem.md:146-154`; `docs/18-testing-strategy.md:433` records that zio 0.18.0 has no virtual clock and no injectable `Io`, so a global cannot be substituted in a test |
| 4 | A `#[repr(C)]` data-carrying enum has no honest Zig form. Give the C side its own flat representation and convert by hand. | An ABI break that no compiler catches. | `AK/accesskit/src/lib.rs:3304-3321` is the core `ActionData`. `AKC/src/common.rs:1069-1082` is the C mirror, and `:1084-1090` gives it a `Drop`. | section 3.1; `TR/notes/research/idiom-mapping.md:101-104`, `:182` |
| 5 | A trait object plus auto traits has no honest Zig form. Use an explicit struct of function pointers with a context pointer. | A wrong dispatch target, or a data race the type system no longer prevents. | `AK/adapters/unix/src/adapter.rs:84` and `:89` store `Arc<dyn ActionHandlerNoMut + Send + Sync>` inside a data-carrying enum. `AK/adapters/unix/src/adapter.rs:249-251` puts `Box<dyn ActivationHandler + Send>` in an enum variant. `AKC/src/common.rs:1139` asserts `unsafe impl Send` over a raw `*mut c_void`. | `TR/notes/research/idiom-mapping.md:262-267`; section 3.9 |
| 6 | `select!`, `Pin` and a hand-written `Future` are a rewrite, not a transliteration. Restructure as a pure step over decoded input. | The event loop keeps the wrong shape and cannot be tested step by step. | `AK/adapters/unix/src/context.rs:197-210` selects over two fused streams. `AK/adapters/unix/src/executor.rs:136-158` implements `Future` with `Pin` and `Poll`. | `TR/notes/research/idiom-mapping.md:579-581`; section 3.6 and 3.7; `ozai/AGENTS.md:65-68` |
| 7 | Path-sensitive `Drop` has no Zig form. Name the operation. | A leak, or a double free. | `AK/adapters/unix/src/executor.rs:125-134` aborts a task in `drop` under one feature and does nothing under the other. `AKC/src/common.rs:1084-1090` frees one enum arm in `drop`. | `TR/notes/design/data-model/ownership-mem.md:290`; section 3.5 |
| 8 | Every allocation names its allocator, and a function with no allocation has no allocator parameter. | Leaks everywhere, or an allocator threaded through code that never allocates. | `AK/accesskit/src/lib.rs:763` a `String` field, `:860` a `String` in an enum, `:1073` a `Vec<PropertyValue>` field, `:3229` a `Vec<(NodeId, Node)>` field. | `TR/notes/design/data-model/ownership-mem.md:146-176`; `TR/notes/design/architecture/structure-memory.md:161-179`; `ozai/AGENTS.md:33-35`; section 6, row 5 |
| 9 | A macro-generated API is written out by hand, once, as real Zig. | A missing API surface that no compiler reports, because the source of the name is a macro. | `AK/accesskit/src/lib.rs:1170-1332` defines ten macros, `:1778-1824` an eleventh. The invocations are at `:1451`, `:1671`, `:2001-2006`, `:2521-2546`, `:2549` and `:2679-2682`. | `TR/notes/research/idiom-mapping.md:589-595`; `TR/README.md:283-286`; section 3.11 |
| 10 | Operator and `From` impls become named Zig functions, and every caller moves with the name. | Wrong arithmetic, or a name collision that silently picks the wrong method. | `AK/accesskit/src/geometry.rs:253-260` `impl Add<Vec2> for Point`, `:191-205` `impl Mul<Affine> for f64`, `:643` `impl Div<f64> for Size`, `:239-251` a tuple-to-struct and struct-to-tuple `From` pair. | section 3.13; `TR/notes/design/architecture/runtime-traits.md:562-608` |
| 11 | Every arithmetic operation states its overflow mode. | A wrong bit mask that no test catches, because the value still looks like a mask. | `AK/accesskit/src/lib.rs:354` and `:824` are `1 << (self as u8)`. `AK/accesskit/src/lib.rs:1127` truncates an index with `as u8`. | `TR/notes/design/data-model/exprs-patterns.md:283-303`; `TR/notes/research/idiom-mapping.md:537-539`; section 6, row 10 |
| 12 | Match ergonomics are made explicit before emit. | A pointer where a value is expected, which is a wrong value in a field or an argument. | `AK/accesskit/src/lib.rs:2796-2803` matches `&$self.values[...]` against non-reference patterns. `AK/accesskit/src/lib.rs:1046-1057` matches a `(self, source)` tuple where the two arms have different mutability. | `TR/notes/design/data-model/exprs-patterns.md:349-352`; `TR/notes/research/prior-work.md:32` |
| 13 | A Rust `char` is `u21`, and a `&str` crossing C is a length-delimited byte slice. | Invalid UTF-8 at the C boundary, or a silent truncation. | `AK/accesskit/src/lib.rs:3307` is `Value(Box<str>)`. `AKC/src/common.rs:742-744` calls `to_string_lossy()` on an incoming C string. | `TR/notes/design/data-model/items-types.md:270-271`; `TR/notes/research/idiom-mapping.md:466-468` |
| 14 | Every exported name is re-declared, because Zig has no re-export. A glob becomes one line per name. | A consumer cannot import a name that exists in Rust. | `AK/accesskit/src/lib.rs:35` is a five-name glob re-export. `AK/accesskit/src/lib.rs:32` re-exports a foreign type. `AKC/src/lib.rs:49-73` has six re-exports. | `TR/notes/research/idiom-mapping.md:48-49`; `TR/notes/design/data-model/crate-graph.md:172-187` |
| 15 | Array length and constant placement are decided explicitly, not left to the source's convenience. | A compile error, or an index table that is one entry too short. | `AK/accesskit/src/lib.rs:1062` derives the array length from `PropertyId::Unset as usize`, and `:1078` returns a reference to a unit variant from a helper whose return type makes the storage question invisible. | section 3.19 and section 3.20; `ozai/AGENTS.md:38-40` |

### 7.1 Two rules that this port does not inherit

Recorded so a later reader does not reintroduce them. Each was scoped out
because the construct is absent from every AccessKit tree, confirmed by grep
over the whole `AK` and `AKC` trees rather than over the files one row named.

| Not inherited | Why | Evidence |
|---|---|---|
| Const generics, `const N: usize` | No `const N: usize` generic parameter appears in the core, any adapter, `example_common`, or accesskit-c. A fixed-size array in AccessKit is always a concrete length. | section 2.2 |
| `static mut` | No `static mut` appears anywhere. AccessKit uses `OnceLock` for one-time state and `Arc` with a lock for shared state. | section 2.4 |

Three rules that an earlier draft of this section wrongly listed here are in
fact inherited. They were caught by grepping the whole tree rather than the
files their row named, and the rows are corrected in section 2.

| Rule | Where it does appear | Row |
|---|---|---|
| `Rc` | The macOS and iOS adapters, not the Unix path. `AK/adapters/macos/src/context.rs:37` and `AK/adapters/ios/src/context.rs:38`. | Section 2.4 |
| `RefCell` and `Cell` | The macOS, iOS and Windows adapters. `AK/adapters/macos/src/context.rs:20` and `AK/adapters/windows/src/subclass.rs:41`. | Section 2.4 |
| Supertrait upcasting through a nested vtable | `AKC/src/lib.rs:113` declares `BoxCastPtr: CastPtr + Sized`. No core trait declares a supertrait. | Section 2.2 |

---

## 8. Findings that belong to `docs/25-r2z-oracle-and-promotion.md`

That document belongs to another agent. These are the findings from this
document that belong there. They are listed, not restated.

| # | Finding | Where the evidence is |
|---|---|---|
| 1 | The record's verification method, a `cargo test` against `zig test` differential pair, is the cornerstone of `approaches.md` and is not available to this port. A recorded fixture replaces it. | Section 6, row 4 |
| 2 | The shipped translator kept `cargo` as a separate opt-in runner with strict prerequisites and refused `/tmp`, `/var/tmp` and NFS paths. The port has no runner at all. | `TR/README.md:398-425`, `:406-412` |
| 3 | The translator's own promotion gate is a good model for this port's promotion gate: a package is published only after its own test step exits zero. | `TR/README.md:34-38` |
| 4 | The port has two cross-language oracles already identified: the C header at `AKC/include/accesskit.h` and the D-Bus interface names at `AK/accesskit/src/lib.rs`. Both are recorded artifacts that can gate a promotion without a Rust toolchain. | Section 2.6 |
| 5 | The `ActionData` variant order and the `Action` numeric values are wire contracts. `AK/accesskit/src/lib.rs:362-386` hard-codes the `Action` numbering by hand for exactly this reason. A promotion check should pin both. | Section 2.2, section 3.1 |

---

## 9. What a reviewer should read first

Four places, in this order, decide whether the rest of this document is
trustworthy.

| Order | What to read | Why it decides the rest |
|---|---|---|
| 1 | Section 6, rows 1 to 4 | Four of the rules this document transfers are superseded. Reading them as current would produce a port that needs a rustc. |
| 2 | Section 1.4 | The one finding that describes a wrong-value bug the tooling cannot catch, and the five steps that answer it. |
| 3 | Section 2, the two `does not apply` verdicts, and section 7.1 | Each verdict rests on the absence of a token. One counter-example in an unread file falsifies it, and three earlier verdicts were falsified exactly that way before they were checked by grepping the whole tree rather than the files their row named. The two that survive are const generics and `static mut`. |
| 4 | Section 7, items 1 to 5 | The five rules whose failure mode is a silently wrong value rather than a compile error. |
