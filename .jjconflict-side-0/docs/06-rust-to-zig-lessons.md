# 06 — What the house already learned about Rust to Zig

Consumed by `docs/30-port-design.md`, which makes the binding architectural
decisions, and by `docs/40-plan.md`, which turns them into milestones.

## 0. How to read this document

Six projects were read. Three are Rust-to-Zig ports. One is a Rust-to-Zig
translator. Two are Zig-native and are here for the rules they record, not for
a language mapping.

| Project | Relationship to Rust | Documents read |
|---|---|---|
| `zautomerge` | Rust `automerge` 0.12.0 plus `hexane`, ported | `AGENTS.md`, `PROJECT.md`, `API.md`, `docs/plan.md`, `docs/STATUS.md`, `docs/survey/README.md` |
| `ozai` | Rust `iroh` P2P stack, ported | `AGENTS.md`, `README.md`, `TODO.md`, `docs/ARCHITECTURE.md`, `docs/DECISIONS/0001` to `0004` |
| `translate-rust` | a Rust-to-Zig translator | `AGENTS.md`, `README.md`, `notes/README.md`, `notes/research/`, `notes/design/`, `src/tree_sitter.zig` |
| `zomp` | Rust and TypeScript `omp` agent, ported | `AGENTS.md`, `HANDOFF.md`, `docs/README.md`, `docs/zomp-design.md`, `docs/BLOCKERS.md` |
| `notui` | no Rust. A Zig TUI library | `AGENTS.md`, `PORTING.md`, `ROADMAP.md`, `NEXT.md`, `HANDOFF.md`, `README.md` |
| `zig-agent-proto` | no Rust. A Zig codec built from wire specifications | `ARCHITECTURE.md`, `PROTOCOLS.md`, `SPEC-DECISIONS.md`, `HANDOFF.md`, `AGENTS.md` |

Every claim below carries a `path:line`. A claim marked `[INFERENCE]` was not
read off a file. Section 4 is the record of what failed, and it is the section
most likely to save this port money.

Line counts in section 1 come from `wc -l`, not from any document. The command
was:

```sh
for d in src test tools examples bench; do
  find $p/$d -name '*.zig' -type f -exec cat {} + 2>/dev/null | wc -l
done
```

## 1. The precedent set

| Project | What was ported | Upstream language and version | Zig | Zig lines in `src/` | Zig lines in tests and tools | Port complete? |
|---|---|---|---|---:|---:|---|
| `zautomerge` | `automerge` 0.12.0 plus the `hexane` 1.0.0-alpha.5 storage engine | Rust, commit `ddbff535407e4d28cd2a82eaf6c6add08caa3bdd` | 0.16.0 | 198 061 in 79 files | 20 463 in 18 files | No. One omission left, `Automerge::rescue` (`docs/STATUS.md:1102-1110`). Phases P0 to P9 and the bundle engine are done (`docs/STATUS.md:422-433`) |
| `ozai` | the `iroh` P2P stack | Rust. No upstream version is recorded in `README.md`, `TODO.md` or `docs/ARCHITECTURE.md` | 0.16.0 | 53 331 in 40 files | 11 356 in 16 files | No. iroh interoperability is open (`README.md:20-21`) and 0-RTT is open (`TODO.md:101-102`). The QUIC substrate is a **vendored Zig core**, not a port (`README.md:286`) |
| `translate-rust` | a Rust-to-Zig translator, not a port of one crate | Rust crates as fixtures: `wyhash` 0.4.0, `adler` 1.0.2, `xxhash-rust` 0.8.15, `rand_core` 0.5.1, and a `tree-sitter-rust` v0.24.2 grammar | 0.16.0 | 179 788 in 69 files | 11 632 in 38 files | No, and the project says so. Fourteen fixtures are pinned as refusals, each to one typed error (`README.md:281-308`) |
| `zomp` | the `omp` coding agent | Rust and TypeScript, `omp` pinned at `8ac1309bd8ad` (`docs/README.md:56`). About 205 000 lines of Rust plus 23 MB of TypeScript; the load-bearing core is `packages/agent` at 21 411 lines (`docs/zomp-design.md:18-24`) | 0.16.0 plus `zio` | 122 561 in 91 files | 295 in 1 file. Unit tests are `test` blocks inside `src/shard_*.zig` (`AGENTS.md:39-45`) | No. `zig-gate` exits 1 from four analyser sections (`AGENTS.md:207-223`) |
| `notui` | nothing. A Zig inline terminal UI toolkit | no Rust. The reference is `pi-tui`, TypeScript, inside `oh-my-pi` (`ROADMAP.md:3-7`) | 0.16.0 | 40 326 in 45 files | 4 692 in `examples/`, 1 647 in `bench/` | The library gate is green at 801/801 in Debug and ReleaseSafe (`HANDOFF.md:12-15`). The strict gate stays red on 132 triaged analyser findings (`HANDOFF.md:18-25`) |
| `zig-agent-proto` | nothing. A Zig codec over JSON-RPC, MCP, ACP and A2A | no Rust. Built from wire specifications (`SPEC-DECISIONS.md:3-5`) | 0.16.0 | 83 360 in 29 files | 2 233 in `test/`, 1 617 in `tools/` | Nothing to complete. Eleven numbered SPEC-DECISIONS are recorded (`SPEC-DECISIONS.md:17` to `:262`) |

Three lessons come out of the table before anything else.

1. **The largest port in the house is a CRDT library, not a network stack.**
   `zautomerge` carries 98k lines of Rust (`docs/plan.md:1185`) and 198k lines
   of Zig. `ozai` carries far less Rust and 53k lines of Zig because much of its
   size is a vendored Zig QUIC core it did not write. Port size tracks format
   surface, not protocol complexity.
2. **No port in the house reached "complete".** All four that had a gate have an
   open list. That is the normal end state, not a failure.
3. **Two of the six are not ports at all.** `notui` and `zig-agent-proto` are
   Zig-native. Their value to this project is the rule record in section 6 and the
   host-API decisions in section 5, not a language mapping.

## 2. Recurring translation hazards

Each row names the Zig form a house project actually used, not the form a
textbook suggests.

| Rust construct | Zig form actually used | Project | Evidence |
|---|---|---|---|
| Trait objects, `dyn Trait`, `Box<dyn T>` | A struct of function pointers, used for exactly one thing and named in the plan | `zautomerge` | `docs/plan.md:415`, worked shape at `:465-486` |
| Trait objects | A fat pointer `{ ptr: *const anyopaque, vtable: *const VTable }` with a generated `DynX.init` and `@fieldParentPtr` upcasting | `translate-rust` | `notes/design/architecture/runtime-traits.md:430-468`, `:480-502`, `:614-622` |
| Trait objects | "Becomes a vtable, not a trait object" | `ozai` | `docs/ARCHITECTURE.md:72` |
| Lifetimes, `&'a T`, `&'a mut T` | Erased to `*const T` and `*T`. The owner is named in the signature instead | `zautomerge` | `docs/plan.md:404`, ownership rule at `:639-642` |
| Lifetimes and borrows | `&T` becomes `*const T` and `&mut T` becomes `*T`. Rust's guarantees are gone and the port restates them | `translate-rust` | `notes/research/idiom-mapping.md:307-312` |
| Lifetimes | A value never carries a slice into a frame it does not own | `ozai` | `docs/ARCHITECTURE.md:118-121`, `:179-181` |
| `impl Trait` in return position | The concrete type. Named as a rule, not discussed | `zautomerge` | `docs/plan.md:414` |
| Return-position `impl Trait` with a lifetime capture | Not recorded by any house project. See section 7, trap 4 | none | no row exists, recorded here so the gap is visible |
| Builder patterns | No precedent. The nearest house rule is an options struct for two or more same-typed arguments, with callbacks last and named `<caller>_callback` | `ozai` | `AGENTS.md:47` |
| `Result<T, E>` | Named error sets plus a per-declaration union wherever the surface refuses a different set. 13 upstream error types collapsed to 3 sets and 12 named unions | `zautomerge` | `docs/plan.md:403`, `:423-459` |
| `Result<T, E>` | Explicit error sets, no `anyerror` in an API, no `_ =` discard | `ozai`, `zomp`, `notui` | `ozai/AGENTS.md:76-78`; `zomp/AGENTS.md:83`; `notui/AGENTS.md:17` |
| An `async fn` | No 1:1 mapping. A function doing one I/O call and a compute step becomes a plain function taking `io` | `translate-rust` | `notes/research/idiom-mapping.md:567-587` |
| `async fn` and a runtime | Three different answers. See section 3 | `ozai`, `zomp`, `zautomerge` | `docs/DECISIONS/0002-async-substrate.md:129-152`; `docs/zomp-design.md:32`; `docs/plan.md:421` |
| Iterators, `impl Iterator` | A struct with `next() ?Item`. An iterator is a value, not a heap object, and it allocates nothing | `zautomerge` | `docs/plan.md:413` |
| Iterator chains and `Fn` closures | Lowered to an explicit `for` loop, or a callable struct with a `call(self: @This(), ...)` method | `translate-rust` | `notes/research/idiom-mapping.md:402-441` |
| `Option<T>` | `?T`. A `match` on an `Option` cannot become a `switch`, because a Zig optional is not a union | `zautomerge`, `translate-rust` | `docs/plan.md:402`; `notes/research/idiom-mapping.md:274-279` |
| `String`, `&str`, `Cow<'a, str>` | `[]const u8` into a document arena plus an intern table. Never a `[]u8` the caller must free. `Cow` becomes `union(enum)` of borrowed and owned | `zautomerge`, `translate-rust` | `docs/plan.md:406`; `notes/research/idiom-mapping.md:443-475` |
| An unbounded string on a wire | A compile-time maximum on the field, and a refusal before any byte is written | `ozai` | `docs/ARCHITECTURE.md:233-260` |
| Closures passed as values | A callable struct, or a plain function pointer when there is no capture | `translate-rust` | `notes/research/idiom-mapping.md:408-438` |
| Callback arguments | Callbacks last in the parameter list, named `<caller>_callback` | `ozai` | `AGENTS.md:47` |
| `#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]` and friends | Hand-written. `Debug` becomes a `format` method, `Clone` a `clone` function, `PartialEq` a comparison through `std.meta.eql` | `zautomerge`, `translate-rust` | `docs/plan.md:417`; `notes/research/idiom-mapping.md:602-614` |
| Derive and proc macros | A hard block. They must be expanded by the Rust toolchain before translation, so a pure-syntax translator cannot proceed | `translate-rust` | `notes/research/idiom-mapping.md:589-632`, blocker 5 at `:740-742` |
| `macro_rules!` in the public API | None. A `log!`-style macro becomes a comptime-switchable no-op or a `std.log` call | `zautomerge` | `docs/plan.md:416` |
| `serde` derive | A hand-written encoder and decoder, written for the two shapes that need it | `zautomerge` | `docs/plan.md:417` |
| `panic!`, `unwrap`, `expect` | `unreachable` where a preceding check proves it, otherwise a real error. Never `unreachable` on parser input | `zautomerge` | `docs/plan.md:418` |
| `catch_unwind` | No equivalent. Zig panics are not catchable. It signals a redesign to an error return | `translate-rust` | `notes/research/idiom-mapping.md:521-522`, `:540` |
| `Box<T>` | `gpa.create(T)` with the caller's allocator, never the page allocator | `zautomerge` | `docs/plan.md:412` |
| `Rc<T>` | `*const T` plus an explicit lifetime owner in the signature | `zautomerge` | `docs/plan.md:409` |
| `RefCell<T>` | `*T` plus a documented invariant that nobody verifies, so each one gets a test | `zautomerge` | `docs/plan.md:410`, risk 3 at `:1161-1165` |
| `Arc<T>` | `std.atomic.Value(usize)` refcount, or an explicit shared owner. Only in the bindings phase | `zautomerge` | `docs/plan.md:411` |
| Randomness reaching the OS | A `std.Io` parameter. The document borrows it and keeps it. Nothing reaches for an ambient runtime | `zautomerge` | `docs/plan.md:421` |
| A process-global RNG and its memo map | The drawn bytes become an argument. The map becomes transport-layer state | `ozai` | `docs/ARCHITECTURE.md:195-204` |
| `BTreeMap<K, V>` | A sorted `ArrayList` plus binary search. The port uses sorted arrays, not `std.Treap` | `zautomerge` | `docs/plan.md:407` |
| `HashMap` | `std.StringHashMapUnmanaged` or `AutoHashMapUnmanaged`, used only for interning and memo tables, never on the format path | `zautomerge` | `docs/plan.md:408` |
| `Vec<T>` | `std.ArrayList(T)` unmanaged with `.empty`, and every call takes the allocator | `zautomerge`, `notui` | `docs/plan.md:405`; `notui/AGENTS.md:16` |
| `#[cfg(test)]` invariant checks | A `comptime` flag or a `slow-path` build option, so the check is a field rather than a second code path | `zautomerge` | `docs/plan.md:419`, `:442-448` |
| `#[non_exhaustive]` | A synthesized catch-all arm, because Zig has no per-variant non-exhaustiveness | `translate-rust` | `notes/research/idiom-mapping.md:134-140` |
| Generics, `<T: Trait>` | `comptime T: type` with `@hasDecl` or `@typeInfo` checks | `translate-rust` | `notes/research/idiom-mapping.md:186-223`; `notes/design/architecture/runtime-traits.md:374-410` |
| A name that collides with a Zig keyword | Emitted as `@"name"`. A required idiom, not a style choice | `translate-rust` | `notes/research/idiom-mapping.md:56-57` |
| A trait method and an inherent method with the same name | The trait impl is namespaced `Trait_Type.method`; the inherent name stays in the struct namespace | `translate-rust` | `notes/design/architecture/runtime-traits.md:562-570`, `:635` |
| `pub use` re-export | No equivalent. Each exposed name is re-declared, and aliasing one decl is the closest form | `translate-rust` | `notes/research/idiom-mapping.md:47-49` |
| A type upstream uses under two names | One name, chosen for what the value is for in Zig. The rename and its reason are recorded so a later port does not undo it | `ozai` | `docs/ARCHITECTURE.md:52-54`, `:64` |
| A method that takes `&mut self` only to cache | Takes `*Document` in Zig and the cache is explicit | `zautomerge` | `docs/plan.md:483-486` |
| Three newtypes differing only in a prefix | One tagged union | `ozai` | `docs/ARCHITECTURE.md:69` |
| `FromStr` that guesses by length | Named parsers, one per encoding | `ozai` | `docs/ARCHITECTURE.md:193-194` |
| A module layout | A mirrored file layout, so the two trees are diffable | `zautomerge` | `AGENTS.md:7-10`, `docs/plan.md:490-491` |
| A Rust test that asserts a type's layout | Dropped. A test that asserts behaviour is kept, and an unportable test gets its gap written in the same commit | `zautomerge` | `AGENTS.md:58-60`, `docs/plan.md:1113-1115` |

## 3. What the house decided about async

Four projects made this decision. Three answered it differently. The reason for
each difference is recorded, so the difference itself is the lesson.

### 3.1 The answers

| Project | Runtime | Where `io` appears | Evidence |
|---|---|---|---|
| `ozai` | **None.** `std.Io` is the substrate, chosen per process, and it appears at the edges only | Threaded as a parameter and **never stored**. A struct holding an `Io` cannot be driven twice with different clocks | `docs/DECISIONS/0002-async-substrate.md:129-152`, `:179-186` |
| `zomp` | **zio is a direct dependency** | A parameter in `core/`, `fs/` and `session/`. One concrete runtime, `main.zig`'s `zio.Runtime.init`. One stored field, `ToolContext.io` | `docs/zomp-design.md:32`; `AGENTS.md:66-69`; `docs/zomp-design.md:378-382` |
| `zautomerge` | **None.** `std.Io` is a parameter on the constructor, and the document keeps it for later actor draws | Stored on the document, deliberately, with a named caller cost | `docs/plan.md:421`; `PROJECT.md:139-146` |
| `zig-agent-proto` | **None.** zio was evaluated and refused as a library dependency | Caller-supplied capability, passed directly or retained by the object built from it | `ARCHITECTURE.md:37-58`; `AGENTS.md:156-170` |

### 3.2 The decision that was reversed, and why that matters most

`ozai` chose zio on 2026-09-29 and reversed it on 2026-09-30. The record names the
reversal, and the reason is the part to carry.

> **No runtime dependency. `std.Io` is the substrate, chosen per process, and it
> appears at the edges only.** *Reversed from "zio is the runtime" on 2026-09-30.*
>
> (`ozai/docs/DECISIONS/0002-async-substrate.md:129-133`)

The load-bearing part was never the runtime's name. It is *where* a runtime is
allowed to appear (`0002:135-136`). Four reasons reversal beat deferral:

1. **There was nothing to schedule.** No file under `src/` or `test/` called
   `Io.async`, `Io.Group.async`, or a zio spawn. The endpoint's tasks were values.
   "A scheduler taken on for work that does not exist is a dependency every later
   reader pays to understand" (`0002:230-235`).
2. **All three original gaps closed without it.** Control messages, socket
   options, GSO and GRO moved into the transport; `Io.Evented` landed at
   `lib/std/Io.zig:31-37` (`0002:236-243`).
3. **The reason zio was chosen became a reason to drop it.** The argument was
   portability. "Threading `io` as a parameter and never storing it is what makes
   any runtime substitutable, zio included, and that property was bought by the
   vendoring phase rather than by this dependency" (`0002:244-251`).
4. **Deferring cost more than adopting.** Adopting zio later costs a rewrite of
   the socket seam, at the moment a runtime is finally wanted and the seam is
   finished (`0002:252-257`).

The record reopened the question a second time on 2026-10-01 and let it stand,
because the premise expired and the replacement was a fact about the tree rather
than a preference (`0002:324-333`). It also fixes the trigger for reopening it:
"when a connection becomes a task rather than a value" (`0002:299-306`).

### 3.3 Where the two projects differ, and the reason each gave

`zomp` and `ozai` both looked at zio. They chose differently because they are
different kinds of thing.

- `zomp`: "zomp is an application, not an interface library"
  (`docs/zomp-design.md:32`). It rejected zio everywhere because it "loses test
  portability", and rejected `std.Io` everywhere because it "over-abstracts the
  parts that genuinely want work-stealing".
- `ozai`: an application too, and it took the other answer, because its tasks
  were still values. `zomp` reached its answer because its agent loop is a
  long-lived actor that wants work-stealing from the first day.

So the deciding question is not "which runtime is better". The record states it:

> The question is not "is this the best available implementation" but "what in
> this repository needs it yet"
> (`ozai/docs/DECISIONS/0002-async-substrate.md:259-263`)

`zautomerge` took a third path that matters for this port. It stores the `io`
and names the cost:

> **A constructor takes a borrowed `std.Io` and the document keeps it.**
> **Caller cost: hold a live capability for the document's lifetime.**
> (`zautomerge/PROJECT.md:139-146`)

### 3.4 How a Rust `async fn` becomes a Zig function

The house record is blunt. There is no mechanical mapping.

> Rust `async fn` and `.await` define the *whole program's* scheduling (Executor,
> Future, Pin). Zig `std.Io` schedules only I/O sites; plain blocking code is
> still blocking. There is no 1:1 mapping.
> (`translate-rust/notes/research/idiom-mapping.md:567-569`)

The record separates two cases (`idiom-mapping.md:571-587`):

| Rust shape | Zig shape | Verdict in the record |
|---|---|---|
| An `async fn` that does one I/O call and then a compute step | A plain function taking `io`, calling `io.file...` or `io.async` | Captures I/O concurrency. The common case |
| `async` relying on `Future::poll`, `Pin`, `Stream`, `select!`, `join!` | Nothing | "a rewrite, not a transliteration" |

Two house projects ported a contract that hangs if you flatten it, and both
insisted on porting it literally.

- `zomp` decision D2: "The `EventStream` contract is ported **exactly**, including
  `end()`-without-result synthesizing an error", because "a naive queue port
  deadlocks the whole agent on any provider that drops a connection"
  (`docs/zomp-design.md:33`, quoting `packages/ai/src/utils/event-stream.ts:92-111`).
- `zomp` decision D6: the message union is closed, because "Zig cannot do
  declaration merging, and a closed union catches bad casts at comptime"
  (`docs/zomp-design.md:37`, quoting `types.ts:968`).

`zomp` also records that zio has no termios layer at all, which is why its TUI is
inline-first (`docs/zomp-design.md:38`).

`zig-agent-proto` adds the structured-concurrency rule the runtime-neutral answer
needs: every task that outlives a call belongs to a group, there is no detached
work, and a connection owns no group and starts no task
(`ARCHITECTURE.md:60-69`).

## 4. What went wrong

Every entry is a failure, wrong turn, or rework that a house project wrote
down. Each carries the file and line that records it. Nothing here is inferred.

### 4.1 A test that was green and proved nothing

This is the failure class with the most entries, and it is the one this port
is most likely to repeat.

| # | What happened | Evidence |
|---|---|---|
| 1 | An audit produced an **inverted gate ranking**, naming P9 the weakest when P9 was the most completely ported, from an instrument never checked against the tree. "**The fix was a retraction, not a patch.** A number derived from a bad instrument cannot be corrected by re-running it, because re-running it reproduces the same wrong number" | `zautomerge/docs/plan.md:141-151` |
| 2 | The instrument's cause: the port renames every ported test case into English, so counting upstream function names under-counted by a factor of three. `diff_marks` read 13 of 36 by name and is 36 of 36 by convention | `zautomerge/docs/STATUS.md:267-274` |
| 3 | "**A test that cannot be shown failing has not been tested.**" The recorded form: a suite that was green before the code was broken and green after it has verified nothing, and nothing in its output can tell you so | `zautomerge/docs/plan.md:153-158` |
| 4 | `ReadDoc::hydrate` dispatches on map, list and text, but its first three tests all hydrated `.root`, and a root is a map. "**Rewriting the `.text` arm to build an empty text left all three tests green**", `FAIL=0`, exit 0 | `zautomerge/docs/plan.md:244-257` |
| 5 | The repair turned one mutation into a sweep of 25, one per candidate arm. **23 of the 25 arms were invisible to the entire tree** while 2 were detected | `zautomerge/docs/STATUS.md:431` |
| 6 | An assertion over only what must be absent passes on an empty result | `zautomerge/docs/plan.md:169-173` |
| 7 | `Text.eql` is `asStr()` alone, so every test using it reads as a test of text equality and is a test of text content. The marks are invisible to it | `zautomerge/docs/plan.md:174-177` |
| 8 | `Document.loadIntoWith` computed `chunks[0].typ == .document` and dropped the answer **one line above the `if` that needed it**, so the first conjunct of upstream's rule was evaluated by nobody | `zautomerge/docs/plan.md:232-243` |
| 9 | A route comparison is not a content assertion. `expectSameThroughApplyChanges` pins two routes' agreement and cannot see a defect both routes share. Measured: the replay fired **zero** times across all 43 cases | `zautomerge/docs/plan.md:263-279` |
| 10 | `OpSet.seekOpsByIndex` has a fast path and a slow path that must agree, and the slow one was comptime-dead until a `-Dslow-path` option existed. Turning the option on makes the comparison live and it **disagrees** | `zautomerge/docs/plan.md:178-189` |
| 11 | A segfault inside the Anthropic serialiser **with every test in the tree green**. The provider's `system_prompt` pointed at a frame that had already returned | `zomp/docs/BLOCKERS.md:375-382` |
| 12 | The same defect on a second path: "a dangling system-prompt pointer is invisible to every test in the tree and fatal on the one path that assembles a real prompt first" | `zomp/docs/BLOCKERS.md:359-362` |
| 13 | "**A unit test is not reachability**: it calls the module directly, so a module whose only caller is its own test exercises the same path a test-only caller would" | `zomp/docs/BLOCKERS.md:119-124` |
| 14 | "**It is not what makes tests run**: `build.zig`'s `test` step iterates the shards array ... A module missing from a shard is a module whose tests never run, whatever the barrel lists" | `zomp/docs/zomp-design.md:922-928` |
| 15 | Four defects the 446 fixture tests did not find, all one class: **a borrow where a copy was required**. A `Response.reader()` pointer into a stack-local request, a dispatch list never cleared, event payloads sliced out of a buffer that later reallocated, a message held on the stack while queued events named it | `zomp/docs/zomp-design.md:694-699` |
| 16 | A first real provider call ended on a `400` for a reason "no test in this tree could see" | `zomp/docs/BLOCKERS.md:341-343`, `:386-390` |
| 17 | A real journal read exposed names pointing into a parsed line the store had released, producing poisoned UTF-8 in an installed response | `zomp/docs/BLOCKERS.md:732-738` |
| 18 | The guard that followed the reachability gap: `run_cmd`'s registry is walked against every module in `src/tools/`, and a tool that is neither registered nor excused by name fails the build | `zomp/docs/BLOCKERS.md:126-128` |

### 4.2 A claim that was measured with a bad instrument, or against the wrong subject

| # | What happened | Evidence |
|---|---|---|
| 19 | "**A measurement taken against the thing it measures is valid only until that thing changes, and the thing that changes it is usually the fix.**" A `43 opportunities, zero detections` figure was taken against a fast/slow pair that disagreed. A clamp that repairs the disagreement changes exactly the agreement the probe measured | `zautomerge/docs/plan.md:281-296` |
| 20 | "**a line number is not a stable reference.**" Of 144 sampled survey citations, **65 point at the wrong code**, file-local and one-directional in each file. They were deliberately left wrong rather than guessed | `zautomerge/docs/plan.md:309-314`; `docs/survey/README.md:60-65` |
| 21 | Three `build.zig` citations were **wrong within the hour**, because a neighbouring comment block grew by 28 lines. An agent broadcast an insertion anchor three times in about twenty minutes and **two of the three were stale** | `zautomerge/docs/plan.md:321-327` |
| 22 | "**The rule that survives all three cases: cite the anchor's identity, never its number.**" `path:line` is right for a file nobody is editing and wrong for any region under concurrent edit | `zautomerge/docs/plan.md:332-338` |
| 23 | 184 in-repo `path:line` citations were re-measured and **149 were wrong**. The Location column became symbol-based | `zautomerge/docs/STATUS.md:443-446`, `:491-495` |
| 24 | 25 count and path claims were wrong, including `AutomergeError` at 31 variants not 30, and `ReadDoc` at 34 methods not 30 | `zautomerge/docs/survey/README.md:54-59` |
| 25 | "`34 in-file test modules` is **not reproducible from any measure I could find**. `automerge/src` holds 67 `#[cfg(test)]` attributes across 42 files, `hexane/src` holds 33 across 17, and there are 47 `mod test` declarations. Whichever was meant, the number should be dropped rather than restated" | `zautomerge/docs/plan.md:1109-1113` |
| 26 | "**The `8/21` and `10/15` this row carried until 2026-10-01 were wrong in both halves**", the cases were already in the tree | `zautomerge/PROJECT.md:196` |
| 27 | One entry said `batch_insert.rs` had zero cases while the same file's coverage table said 46 of 46. "**Both halves are false**, and the table was right" | `zautomerge/docs/STATUS.md:1007-1012` |
| 28 | A dead-code claim was wrong and was checked. `bijou64` and `deep_fuzz` are read by `cfg`. "Neither is dead code" | `zautomerge/docs/plan.md:377-385`; `docs/survey/README.md:40-43` |
| 29 | A gate clause named "the five round-trip tests" where upstream has **three** | `zautomerge/docs/STATUS.md:430` |
| 30 | An earlier `ozai` record described a dependency the repository does not have. "`build.zig.zon:6` is `.dependencies = .{}` ... The 2026-09-29 record described a dependency this repository does not have" | `ozai/docs/DECISIONS/0002-async-substrate.md:9-15` |
| 31 | A rejected-candidate claim could not be reproduced and was marked unverified: `flushSendBatch` does not exist in `zigstack/zquic` at `master` | `ozai/docs/DECISIONS/0001-transport-substrate.md:100-106`, `:697-699` |
| 32 | Requirement 3 was downgraded from a flat pass. "**10 of 88 cells red, 1 open**", and the matrix was run at `4988228` rather than the pinned commit | `ozai/docs/DECISIONS/0001-transport-substrate.md:560-597`, `:688-690` |

### 4.3 An estimate that was wrong in the expensive direction

| # | What happened | Evidence |
|---|---|---|
| 33 | The `ozai` transport record "billed the certificate work and not the threading. The 2026-09-30 correction conceded that; execution says the correction still understated the rest" | `ozai/docs/DECISIONS/0001-transport-substrate.md:875-892` |
| 34 | The first version of the same record **omitted the largest item entirely**. There were 60 hidden-input call sites, 34 clock and 26 CSPRNG, plus a mutable `test_clock` global, and "the first version of this record omitted it entirely" | `ozai/docs/DECISIONS/0001-transport-substrate.md:202-225` |
| 35 | The seam file was predicted to "split rather than delete". It split, emptied to 115 lines, then was deleted | `ozai/docs/DECISIONS/0001-transport-substrate.md:835-845`, `:882` |
| 36 | The deletion set was much larger than recorded. `src/event_loop.zig` at 5 211 lines, not `ecn_socket.zig` at 584, is the socket owner | `ozai/docs/DECISIONS/0001-transport-substrate.md:682-687` |
| 37 | "The flag was not a flag to bend but the wrong shape, and the fix was to delete the walk" | `ozai/docs/DECISIONS/0001-transport-substrate.md:633-642` |
| 38 | "**Diff size is not a measure of this patch.**" The line counts barely moved because the deleted walk and the added lift, doc comments and tests are about the same size | `ozai/docs/DECISIONS/0001-transport-substrate.md:808-811` |
| 39 | A portability matrix recorded as 0 pass and 20 fail was "**the shape of an aborted run, not of twenty broken targets**". The harness was stopped with exit 143 after 12 of 20 | `zautomerge/docs/STATUS.md:870-877` |

### 4.4 A wrong turn that was caught and superseded

The house keeps these rather than deleting them, because a superseding record
without the thing it supersedes is a claim with no repair path.

| # | What happened | Evidence |
|---|---|---|
| 40 | A stack-pool defect was blamed for a teardown segfault. "**The saved context contradicts both halves.** ... This core establishes no stack-pool defect, and nothing here should be read as evidence for or against one" | `zomp/docs/BLOCKERS.md:481-490` |
| 41 | "all four are detached" was false for one of the four | `zomp/docs/BLOCKERS.md:46-48` |
| 42 | A checkout was declared absent because it was mislocated. "**What was missing was the URL, not the repository**" | `zomp/docs/BLOCKERS.md:84-86`, `:102-104` |
| 43 | "An earlier version of this section claimed 'what can this build actually call' has one answer for every entry point, and that was wrong" | `zomp/docs/BLOCKERS.md:228-231` |
| 44 | A recorded phase state went stale: an earlier paragraph said four modules had no caller, "which was the state when the phase closed and is not the state now" | `zomp/docs/zomp-design.md:891-893` |
| 45 | The house indentation rule demanded tabs. "An earlier version of this file demanded tabs; that is unfollowable, because `zig fmt --check` is the first step of the gate and it rewrites tabs" | `zomp/AGENTS.md:145-148` |
| 46 | Three house assumptions were corrected against the tree during the build: Zig 0.16 ships no regex at all, `zig fmt` emits four spaces, and the glob fast path is a real six-variant enum rather than something to invent | `zomp/docs/zomp-design.md:671-673` |
| 47 | `ozai`'s first transport record predicted splitting the `skip_cert_verify` bit. What shipped deletes the flag, the walk, and everything only the walk reached. "That is a rewrite wearing a patch's clothing" | `ozai/docs/DECISIONS/0001-transport-substrate.md:767-776`, `:633-642` |
| 48 | `ozai` reverted its runtime decision one day after taking it. See section 3.2 | `ozai/docs/DECISIONS/0002-async-substrate.md:3-8` |
| 49 | `ozai` had a stale line in a file it did not own: `ARCHITECTURE.md:40-43` still named zio as the runtime after the reversal | `ozai/docs/DECISIONS/0002-async-substrate.md:292-297` |
| 50 | `notui`'s Phase A existed because "the notui checkout was absent and its remote was never written into the provenance table, so Phase 6 was built from a behavioural specification instead of a port" | `notui/ROADMAP.md:88-98`; `zomp/docs/BLOCKERS.md:9-31` |
| 51 | A Zig contract defect became indistinguishable from a decision. "`AGENTS.md` restated that as settled, which is how a defect becomes indistinguishable from a decision" | `zig-agent-proto/SPEC-DECISIONS.md:117-121` |
| 52 | "closed" was replaced by "declared" for member sets, because "the absence of an index signature was read as a normative JSON rule it does not express" | `zig-agent-proto/SPEC-DECISIONS.md:214-226` |

### 4.5 A Zig 0.16 behaviour that cost real time

| # | What happened | Evidence |
|---|---|---|
| 53 | "`clearRetainingCapacity` **poisons what it retains with `0xAA` in Zig 0.16.** Taking a slice before the clear and reading it after yields garbage rather than the old bytes ... This is not a hypothetical: it silently corrupted the SSE reader's frame lines until the parse/clear order was fixed" | `zomp/AGENTS.md:153-156` |
| 54 | A module created with `root_source_file = b.path("src/root.zig")` has `src/` as its package root, so `@embedFile("../../test/...")` fails with "embed of file outside package path", and `.paths` in `build.zig.zon` does not widen it | `zomp/AGENTS.md:157-162` |
| 55 | "`zig-gate` prints the first 30 lines of the zbc report and counts only `error(` lines, so a warnings-only run reads as '0 potential issue(s)'" | `notui/AGENTS.md:35`; `notui/NEXT.md:30-34` |
| 56 | `zbc --jobs=1` crashed in its binding cache with exit 134, so there is no completed current `zbc` verdict | `notui/HANDOFF.md:22-24`; `notui/NEXT.md:60-62` |
| 57 | `expandTabs` sized its buffer with `line.len + 8`, which wraps when a line is within eight bytes of `maxInt(usize)` and would under-allocate. It is now `line.len +\| 8` | `notui/NEXT.md:52-55` |
| 58 | `zio.Group.spawn` "returns no handle and only **logs** task errors (`group.zig:129`); it also has no barrier ordering". A failed task leaks into silence | `zomp/docs/zomp-design.md:35`; `zomp/AGENTS.md:123-124` |
| 59 | "**`zig build test` prints a `failed command:` block above a green summary**, and that is not a failure ... **The step table and the exit code are the truth**" | `ozai/AGENTS.md:19-27` |
| 60 | `build.zig` opened `vendor/quic/src` from the consumer's working directory, so `b.dependency("ozai", ...)` aborted before any module was built | `ozai/docs/DECISIONS/0003-api-contract-cutover.md:41-47` |
| 61 | A gate entry point did not run: "its `anyzig` shim re-downloads the pinned toolchain and fails to extract it" | `ozai/README.md:27-30` |
| 62 | Fetching the working directory itself returned `error.IllegalFileTypeInPackage` | `ozai/README.md:146-148` |
| 63 | ReleaseSafe is not a fallback: a standard-library-only Ed25519 probe under Hexagon and QEMU derives `e13b9579...` instead of the captured `197f6b23...` public key | `ozai/README.md:489-491` |
| 64 | `std.http.Client.connectUnix` does not compile on Zig 0.16, and `std.Io.Uring` fails at lines 2732 and 3157 with error sets their return types exclude. "The kernel accepts `io_uring_setup` on this host, but that does not establish a working Zig backend" | `zig-agent-proto/AGENTS.md:332-342` |
| 65 | "**Zig 0.16 ships no regex.** `std.regex` was removed and nothing replaced it". Combined with the no-new-dependencies rule, a bounded in-tree engine was written | `zomp/AGENTS.md:149-152` |
| 66 | In Zig 0.16 a `///` doc comment on a `test` declaration is a compile error for the whole module, and the module failing to build takes down every test in the tree | `zautomerge/AGENTS.md:66-70` |

### 4.6 The environment

| # | What happened | Evidence |
|---|---|---|
| 67 | A build on a network filesystem dies with `EINVAL` and a `programmer bug caused syscall error` panic, because Zig's atomic file write uses `renameat2(RENAME_EXCHANGE)` and NFSv3 does not implement it. `tools/zig-pinned.sh` exists to work around it | `translate-rust/AGENTS.md:24-32` |
| 68 | "`.zig-cache` and `zig-pkg` **must be symlinks to local disk**." The package unpacker reports the files it writes as `illegal file type 'unknown'`, and the cache-rename path panics on an `EINVAL` from `access` | `zomp/AGENTS.md:20-24` |
| 69 | "**The `zig` on `PATH` is the anyzig shim**, which re-resolves and re-downloads the toolchain on every invocation", and it fails quietly rather than loudly | `translate-rust/AGENTS.md:27-28`; `zomp/AGENTS.md:8-11` |
| 70 | "`.minimum_zig_version` is a **lower bound**. A manifest floor says what a package declares that it needs. It is not the supported compiler, and it is no proof the package builds" | `zomp/docs/zomp-design.md:67-70` |
| 71 | `zio`'s `.version = "0.17.0"` is zio's own package version, not a Zig version. Reading "zio 0.17" as "Zig 0.17" is wrong | `zomp/docs/zomp-design.md:71-72` |
| 72 | Zig 0.16 `std.testing.tmpDir` creates `.zig-cache/tmp` relative to the working directory. Compiler cache flags and `TMPDIR` do not change that location, so an NFS checkout needs a UID-owned local source copy | `translate-rust/README.md:467-473` |
| 73 | Nix was absent, so the gate environment was set by hand. "**This is an environment limitation, not a project defect, and nothing here repairs shared tooling**" | `zomp/docs/BLOCKERS.md:543-551` |
| 74 | The shared gate labels `zbc` advisory, but "**The shared gate fails errors with `ZBC_STRICT=0`**; strict mode also fails warnings. The false advisory project task was removed" | `zomp/docs/BLOCKERS.md:904`; `zomp/AGENTS.md:201-205` |
| 75 | A lint invocation handed the tool one JSON array instead of one path per line, so "a single line of 2267 bytes overran the tool's fixed 1024-byte line reader". "Those runs are trace history for a caller that sent the wrong shape, and they are lint evidence in neither direction" | `ozai/README.md:57-62` |
| 76 | Four `zwanzig` store-violation ERRORs remained untriaged and were outside the repaired path | `zomp/docs/BLOCKERS.md:574` |
| 77 | Finding counts are not defect counts: all 478 current findings were dispositioned as 398 false positives and 80 conflicts with valid policies | `zomp/docs/BLOCKERS.md:833-835` |
| 78 | A closed error set could not express a real failure. `rpc.SessionError` had three names, so a journal that exists and cannot be read had no honest code. "Reporting `OutOfMemory` would have been the worse lie" | `zomp/docs/BLOCKERS.md:245-250` |
| 79 | Three hangs left open after a teardown repair: an uncancelable park on an empty ring, a join that blocks on the driver thread, and a gate nothing in production opens | `zomp/docs/BLOCKERS.md:599-604`, `:640-642` |
| 80 | A fix would have caused a regression, caught in review: removing the queued-steer exit also removed the only in-band exit for live steering | `zomp/docs/BLOCKERS.md:620-623` |

### 4.7 C bindings and vendored code

| # | What happened | Evidence |
|---|---|---|
| 81 | A tree-sitter C function type was written as a legacy empty parameter list. "**Writing it as a legacy empty list `()` still compiles, but it is a different C function type**, and optimized builds trap inside it on clang's `-fsanitize=function` mismatch trap" | `translate-rust/README.md:479-482` |
| 82 | "That directory supplies `tree-sitter.json`; **another working directory can silently select an older ABI**" | `translate-rust/README.md:487-488` |
| 83 | A fixture that duplicated only an outer array left freed literals behind, "which read back as `0xAA` in Debug and produce failures that look like codegen bugs but are use-after-free" | `translate-rust/README.md:490-492` |
| 84 | The same class of mistake: a type table that inference resolves in place must be a `var`, not a `const`, because resolution writes through it | `translate-rust/README.md:495-497` |
| 85 | A vendored upstream tree does not build on the pinned compiler. `build.zig.zon` claims `minimum_zig_version = "0.16.0"` and upstream `src/sys.zig:513` mistypes `posix.errno`. "**The revisit trigger 'drop the fork and consume the dependency directly' has nothing to consume**" | `ozai/docs/DECISIONS/0001-transport-substrate.md:731-743` |
| 86 | A vendored tree must pay back its gate exclusion. `test/vendored_invariants.zig` "fails if a socket, a clock, a global entropy source or a libc call returns to the vendored tree" | `ozai/TODO.md:124-130` |
| 87 | A `zig build ctest` exit 127 was "a build failure that is not one": a relative prefix produced a relative RUNPATH entry, and the step's working directory is `test/c/suite` | `zautomerge/PROJECT.md:242-252` |
| 88 | A green C suite is not the gate. "**A green suite alone is not this gate**: linking does not prove layout or signature parity" | `zautomerge/PROJECT.md:199` |
| 89 | Upstream `flushSendBatch` and a vendored grammar both showed that a package's own `paths` and its own ABI flags can point at different trees than the build does | `ozai/docs/DECISIONS/0001-transport-substrate.md:697-699`; `translate-rust/README.md:487-488` |

### 4.8 Two boundary defects in the iteration layer

Both are recorded because the symptom was not the defect. A port that trusts
the symptom will reproduce them.

| # | What happened | Evidence |
|---|---|---|
| 90 | `PrefixColumn::iter_range` **accumulates** the skipped widths into `total`, so a window opened at `s` reports absolute totals. The port had a window-relative variant and the op set compensated for it. "The compensation's symptom was not a wrong number but a **refusal**": `cast(usize, 0 - base)` is `error.Overflow` for every text object that does not begin at column row 0. Re-introducing the relative window took the tree from 46 to **69** `...FAIL` lines | `zautomerge/docs/plan.md:197-208` |
| 91 | `Iter::shift` is `set_max(range.end)` then `advance_to(range.start)`, and the port's was the first half alone while its own doc comment claimed both. "**A shape error, not a boundary one**": `shift(5..9)` on a fresh cursor left `pos()` at 0, on five consecutive runs, so the brief's "seed-dependent" reading of it was wrong | `zautomerge/docs/plan.md:209-214` |

The method the two defects teach is recorded next to them. Neither defect is
reachable only with the slow-path option on, so "the option-on build is green"
is not what closed them. What closed them is that each was falsified and then
measured over 400 seeds and 40 998 prefix windows, 60 seeds and 2 400 random row
windows, and 200 seeds over about 80 000 checked btree mutations
(`zautomerge/docs/plan.md:216-226`). "**So the promotion condition stands and is
still unmet**, on the parts that are not `src/hexane/**`" (`:228-229`).

## 5. What the house decided about C and third-party code

Four shapes appear across the six projects. Each is given with its reason and
the code shape it produced, because the shape is the part a port inherits.

### 5.1 The four shapes

| Shape | Project | Decision and reason | Resulting code shape |
|---|---|---|---|
| **Hand-written extern declarations plus a small C shim** | `translate-rust` | The tree-sitter C runtime is pinned in `build.zig.zon` with the comment "**Pinned C runtime. Local bindings keep node aggregates inside C.**" (`build.zig.zon:7`). The decision is to keep the C aggregate out of Zig, not to generate bindings | `opaque {}` for `Language`, `Parser`, `Tree` (`src/tree_sitter.zig:6`, `:8`, `:28`); one hand-written `extern fn` list at `:112-130`; a C file compiled with `addCSourceFile` at `build.zig:57`; the vendored grammar at `build.zig:76-78`. `Node` is an `extern struct` because the C layout crosses by pointer (`src/tree_sitter.zig:42`) |
| **Zig writes the C ABI itself** | `zautomerge` | The header is a product, not a binding. "**The C ABI is a shipped artifact.**" It is proved by generating the reference's own header with cbindgen at the pinned version and diffing (`PROJECT.md:63-69`) | `include/automerge.h`, production root `src/c/root.zig`, and a **separate** ABI check library `test/c/cabi.zig` that translates the real header (`build.zig:487`). The C test suite is upstream's own, linked with `linkSystemLibrary("cmocka", .{})` (`build.zig:628`) |
| **Own the syscalls at one seam, no C library** | `ozai` | Binding `cloudflare/quiche` over C was surveyed and priced at "roughly one person-week to bind, plus a permanent C/FFI and a Rust toolchain on the build path" (`0001:135-136`). `ChainSafe/quiche-zig` was rejected as "0 stars, one fork, treat it as scaffolding and write the extern block by hand" (`0001:136-137`) | "The Linux socket and node drivers require libc. Pure codecs and state machines do not." (`README.md:386-387`). The socket layer uses `std.os.linux.UDP.SEGMENT` and `.GRO` directly rather than a binding (`0002:187-192`), and it "may not assume which `Io` it was given" (`0002:284-290`) |
| **Vendored Zig source, stripped and gated** | `ozai` | The QUIC substrate is `endel/quic-zig` at a pinned commit SHA, with the socket-owning files **never copied** (`0001:716`) | `vendor/quic/` is a separate module with its own test step (`0001:727-729`), excluded from every text-reading gate section by one `GATE_EXCLUDE` pattern (`TODO.md:124-128`), and `vendor/quic/VENDORED.md` records what was taken, what was left, and every patch (`README.md:300-301`) |

### 5.2 The three projects that bound nothing, and why

- **`zig-agent-proto`**: a grep of `src/` for `@cImport`, `@cInclude`,
  `@cDefine`, `export fn`, `extern "c"` and `callconv` returns no matches.
  "The library has no dependencies beyond the Zig toolchain and no system
  library dependencies" (`AGENTS.md:126-127`). It ships a Zig static library, not
  a C-ABI one (`build.zig:23-28`). Its one C rule is that `extern` is used "only
  when the wire layout genuinely requires a C ABI" (`AGENTS.md:134-135`).
- **`notui`**: no C at all. One library dependency, `zg`, behind a single `width`
  seam, so Unicode knowledge enters in one place (`AGENTS.md:8`,
  `PORTING.md:90`).
- **`zomp`**: no C. `bash` and `git` shell out. The embedded shell, coreutils,
  git, diff, glob and TUI are each "a reimplementation someone else already
  wrote" and are deliberately not dependencies (`AGENTS.md:33-36`).

### 5.3 The rules that come out of this for a host C library

These are the house positions, each with its evidence. `docs/30-port-design.md`
should restate whichever apply to the AT-SPI D-Bus client.

1. **A C library is bound only when a Zig implementation does not exist or cannot
   exist.** `zig-agent-proto` refused zio, `dusty` and `pg.zig` because they are
   "the frontier of what is being built *against* `std.Io`, and they prove the
   interface is wide enough, but adopting them would invert the dependency"
   (`ARCHITECTURE.md:43-53`). The dependency record makes the same call for
   libdbus: "C where a Zig implementation exists; the house rule prefers the
   higher rung" (`local://zaccesskit-deps.md:62`).
2. **No new dependency without a written justification.** "Every dep added is a
   port the next person has to maintain" (`zomp/docs/zomp-design.md:44`). "Zero
   deps unless justified" (`ozai/AGENTS.md:53`).
3. **A hand-written extern block beats a fork of a binding, when the binding
   does not exist.** `ozai` would not use a 0-star fork and said so
   (`0001:136-137`).
4. **A C library is not a licence to keep the toolchain that built it.** The
   `quiche` option was rejected partly because it costs "a permanent C/FFI and a
   Rust toolchain on the build path" (`0001:135-136`).
5. **A vendored tree must be able to prove it is still pure.** The exclusion from
   the gates is paid back by a test that fails if a socket, a clock, a global
   entropy source or a libc call returns (`ozai/TODO.md:128-130`).
6. **A C ABI you ship yourself needs a separate shape check.** Linking a suite
   does not prove layout or signature parity (`zautomerge/PROJECT.md:199`), so
   the check compiles the real header and asserts names, by-value layout, enum
   discriminants and signatures (`PROJECT.md:66-70`).

## 6. Rules this project inherits

Two tables. The first is enforced by a named tool, so a violation fails a
command. The second is written down, so a violation fails a reviewer. An
`AGENTS.md` for this project can quote either.

### 6.1 Enforced by a tool

| Rule | Tool that enforces it | Evidence |
|---|---|---|
| Zero formatting diff | `zig fmt --check .` | `ozai/AGENTS.md:119`; `zomp/AGENTS.md:188`; `zautomerge/AGENTS.md:108`; `notui/AGENTS.md:29` |
| Four-space indentation, whatever `zig fmt` produces | `zig fmt --check` | `zomp/AGENTS.md:145-148` |
| Builds clean in Debug and ReleaseSafe | `zig build -Doptimize=Debug` and `ReleaseSafe` | `ozai/AGENTS.md:120` |
| Tests green in Debug and ReleaseSafe, zero leaks | `zig build test` with `std.testing.allocator` | `ozai/AGENTS.md:121`; `zomp/AGENTS.md:190-191` |
| Every changed file parses | `zig ast-check` | `ozai/AGENTS.md:122`; `zig-agent-proto/AGENTS.md:472-473` |
| Unused declarations still type-check | a `refAllDecls` test in each root | `ozai/AGENTS.md:123` |
| Zero lint errors | `zlint`, with its config in `zlint.json` | `ozai/AGENTS.md:124`, `:160-161`; `notui/AGENTS.md:30` |
| Changed paths measured, every uncovered path tested, refactored, or accepted with a written reason | `kcov` on 0.16, `zcov` on 0.17 | `ozai/AGENTS.md:125`, density rule at `:130-131` |
| Zero new static-analysis findings | `zwanzig` and `zippy` as opt-in jobs | `ozai/AGENTS.md:126`, `:161-162` |
| Every decoder fuzzed with bounded seeds, inputs replayed | `zig build test --fuzz=<bounded>` | `ozai/AGENTS.md:128` |
| Ten named steps in one command | `zig-gate`: `zig fmt --check`, `zig build`, `zig build test`, `zig ast-check`, `ziglint`, `zlint`, `zbc`, `zwanzig`, `cross-test`, opt-in `zig-cov` | `zomp/AGENTS.md:188-194` |
| A `///` doc comment on a `test` declaration is a compile error for the whole module | the Zig compiler | `zautomerge/AGENTS.md:66-70` |
| `@embedFile` outside the module's package root fails the build | the Zig compiler | `zomp/AGENTS.md:157-162` |
| Caches on local disk, not the mount | `renameat2(RENAME_EXCHANGE)` failure at build time | `zomp/AGENTS.md:20-24`; `translate-rust/AGENTS.md:29-32` |
| CI runs the toolchain half of the gate; `zlint` and `zbc` are deliberately out | `.github/workflows/ci.yml` | `zig-agent-proto/AGENTS.md:467-485` |

### 6.2 Written down only

| Rule | Evidence |
|---|---|
| Allocators are parameters, never a global and never the page allocator | `ozai/AGENTS.md:33-34`; `zomp/AGENTS.md:84`; `zautomerge/AGENTS.md:43-44`; `notui/AGENTS.md:15` |
| `io: std.Io` is threaded explicitly and never global | `ozai/AGENTS.md:59`; `zomp/AGENTS.md:66-69`; `zig-agent-proto/ARCHITECTURE.md:7-12` |
| State is a parameter, not a capture. Pure functions return new state | `ozai/AGENTS.md:69-70` |
| Network logic is pure over decoded bytes. No socket handle, no clock read, no allocator | `ozai/AGENTS.md:64-68` |
| Loops have fixed upper bounds and fail fast | `ozai/AGENTS.md:41-42` |
| Explicit error sets. No `anyerror` in an API. Never discard with `_ =` | `ozai/AGENTS.md:36-37`; `zomp/AGENTS.md:83`; `notui/AGENTS.md:17` |
| Fail-N allocator injection, so every OOM path is exercised | `ozai/AGENTS.md:73-75` |
| `unreachable` is a claim. Every uncovered path is answered test, refactor, or accept | `ozai/AGENTS.md:80-81` |
| Every parser is total over untrusted input. A `ParseError`, never a panic, never an unchecked allocation size | `zautomerge/AGENTS.md:45-47` |
| Wire compatibility is a golden-vector test, never a comment | `ozai/AGENTS.md:89-91`; `ozai/README.md:288-289` |
| A test that cannot be shown failing has not been tested | `zautomerge/docs/plan.md:153-158` |
| A phase is done when its gate command passes, not when the code compiles | `zautomerge/AGENTS.md:56-57`; `zomp/AGENTS.md:225-226` |
| Every non-obvious claim about upstream behaviour needs a `path:line` | `zautomerge/AGENTS.md:61-62`; `AGENTS.md:13-15` |
| Cite the anchor's identity, never its number, in a region under concurrent edit | `zautomerge/docs/plan.md:332-338` |
| A reviewer subagent after every non-trivial implementation | `ozai/AGENTS.md:133-149` |
| No backwards compatibility. Delete, do not deprecate. No aliases, shims or unused params | `ozai/AGENTS.md:51-52`; `notui/AGENTS.md:19` |
| Zero dependencies beyond the Zig toolchain unless justified in writing | `ozai/AGENTS.md:53`; `zomp/AGENTS.md:28-31` |
| A port names the one thing it does not port and why | `zautomerge/AGENTS.md:50-52`; `zautomerge/PROJECT.md:93-99` |
| Modules over 250 pure lines split by responsibility, never into `utils.zig` | `ozai/AGENTS.md:200-201` |
| Annotate a waiver with the invariant it encodes, never with a rule name alone | `zig-agent-proto/README.md:635-639` |

## 7. Named traps for this port

Each trap names the hazard, the precedent it comes from, and the AccessKit
evidence that shows it is present. Line numbers in the AccessKit column refer
to the read-only checkout at commit `466e24e252103f4d82bd6fbab98141b551e46e0c`.

### Trap 1. The async surface is a whole crate, not a function

**Hazard.** Rust `async fn` in upstream does not lower. The house record says
there is no 1:1 mapping and that anything using `select!`, `join!`, `Stream` or
`Pin` is a rewrite, not a transliteration.

**Precedent.** `translate-rust/notes/research/idiom-mapping.md:567-587`.
`ozai/docs/DECISIONS/0002-async-substrate.md:259-263`, which reframes the
question as "what in this repository needs it yet".

**Present.** All 84 `async fn`, `.await` and `async move` sites in the AccessKit
workspace are in one adapter: `adapters/unix/src/atspi/bus.rs` (63),
`adapters/unix/src/context.rs` (19) and `adapters/unix/src/executor.rs` (3).
The default feature pulls four async crates (`adapters/unix/Cargo.toml:14-17`)
and `zbus` 5.19 with `async-io` (`:25`). `accesskit` and `accesskit_consumer`
contain none.

**What to decide.** Whether the AT-SPI adapter's concurrency is a zio runtime, a
`std.Io` group, or neither. The house has answered this three different ways.

### Trap 2. `dyn Trait` lives only in the adapters, and one of them is a closure table

**Hazard.** `dyn Trait` has no Zig vtable. Both house ports built one, and
`zautomerge` restricted it to a single use and wrote the restriction into the
plan.

**Precedent.** `zautomerge/docs/plan.md:415` and `:465-486`;
`translate-rust/notes/design/architecture/runtime-traits.md:430-468`.

**Present.** 38 `dyn Trait` sites, none in `accesskit` or `accesskit_consumer`.
Five are in `atspi-common`: `adapter.rs:362` is
`Box<dyn AdapterCallback + Send + Sync>`, and `adapter.rs:426`,
`context.rs:38` and `context.rs:57` are `Arc<dyn ActionHandlerNoMut + Send + Sync>`.
The Android adapter adds `Box<dyn FnOnce(&mut JNIEnv, ...) + Send>`
(`adapters/android/src/inject.rs:104`).

### Trap 3. `macro_rules!` generates the public API of `accesskit`

**Hazard.** `zautomerge` maps a public `macro_rules!` to **nothing**.
`translate-rust` records derive and proc macros as a hard block that needs the
Rust toolchain to expand before anything can be translated. This port has no
Rust toolchain, so every generated declaration must be written out by hand.

**Precedent.** `zautomerge/docs/plan.md:416` and `:417`;
`translate-rust/notes/research/idiom-mapping.md:589-632`, blocker 5 at `:740-742`.

**Present.** `accesskit/src/lib.rs` is 3 698 lines and defines **24**
`macro_rules!`, from `flag_methods!` at `:1170` to
`unique_enum_property_methods!` at `:1778`. The last one generates a
getter, setter and clearer per property plus a test module per property
(`:1778-1823`). A further 103 `#[derive]` uses exist across the workspace.

### Trap 4. Return-position `impl Trait` with a lifetime capture has no house precedent

**Hazard.** `zautomerge` records one rule for `impl Trait` returns, and it is
"the concrete type" (`docs/plan.md:414`). AccessKit always names the capture
explicitly, so the easy rule does not cover the shape that is actually there.

**Precedent.** None. Recorded as a gap so it is a decision rather than an
accident.

**Present.** Eight sites use the Rust 2024 `use<...>` capture:
`accesskit_consumer/src/text.rs:1381`, `:1389`, `:1397` and
`accesskit_consumer/src/node.rs:170`, `:183`, `:192`, `:198`, `:204`. Example:
`-> impl DoubleEndedIterator<Item = NodeRef<'a>> + use<'a>`.

### Trap 5. Iterators are hand-written state machines, four traits deep

**Hazard.** `zautomerge` maps an iterator to a struct with `next() ?Item`, and
insists it is a value and not a heap object. `translate-rust` rates general
`Iterator` impls and `FnMut` closures as hard, and a v1 blocker.

**Precedent.** `zautomerge/docs/plan.md:413`;
`translate-rust/notes/research/idiom-mapping.md:402-441`.

**Present.** 29 `impl ... Iterator` sites. `accesskit_consumer/src/iterators.rs`
implements `Iterator`, `DoubleEndedIterator`, `ExactSizeIterator` and
`FusedIterator` for `ChildIds<'_>` (`:30`, `:51`, `:65`, `:74`) and three of
the four for `FollowingSiblings<'_>` (`:117`, `:145`, `:163`). Six free
functions carry the lifetimes (`:255`, `:296`).

### Trap 6. The public seam is three empty traits

**Hazard.** `zautomerge` notes that a method which needs `&mut self` only to
cache takes `*Document` in Zig and makes the cache explicit. The three
AccessKit handler traits have no other content, so the port decides what
"explicit cache" means for them.

**Precedent.** `zautomerge/docs/plan.md:483-486`.

**Present.** `accesskit/src/lib.rs:3336` `ActivationHandler`, `:3362`
`ActionHandler`, `:3376` `DeactivationHandler`. One method each.
`ActionRequest` is at `:3328`.

### Trap 7. `Arc`, `Rc`, `Box` and `Send + Sync` have no Zig counterpart

**Hazard.** The mapping table exists (`zautomerge/docs/plan.md:409-412`), but
each row moves a compile-time guarantee into a comment or a field. `zautomerge`
records the cost: "A route that grows a mirror alone drifts silently"
(`AGENTS.md:79-83`), and `RefCell` invariants become "an explicit field plus a
comment that nobody verifies" (`docs/plan.md:1161-1165`).

**Precedent.** `zautomerge/docs/plan.md:409-412`, `:1161-1170`;
`ozai/AGENTS.md:33-34`.

**Present.** 72 `Arc<`, 36 `Rc<`, 29 `Box<` and 11 `Arc<Mutex` sites across the
AccessKit workspace. All are in the adapters.

### Trap 8. `Result` and `Option` volume forces the error-set design up front

**Hazard.** 13 upstream error types collapsed to 3 sets plus 12 named derived
unions in `zautomerge`, and the plan devotes a full section to it. A port that
invents its error sets per module will not converge.

**Precedent.** `zautomerge/docs/plan.md:403`, `:423-459`.

**Present.** 446 `Result<` and 407 `Option<` sites across the workspace. One
note on volume: `translate-rust` refuses a `Display` body that needs an
allocator with `UnsupportedAllocatingFormatter` rather than emit it without
one (`README.md:96-101`). AccessKit core uses `format!` four times
(`accesskit/src/lib.rs`).

### Trap 9. Two upstream trees version independently

**Hazard.** An evidence set that does not pin to the tree you vendored is not
evidence. `ozai` downgraded an interop claim from "pass" to "10 of 88 cells
red" because the matrix ran at `4988228` rather than the pinned commit
(`0001:560-597`).

**Precedent.** `ozai/docs/DECISIONS/0001-transport-substrate.md:560-597`;
`zautomerge/docs/plan.md:281-303`.

**Present.** Core is `accesskit` 0.25.1 (`accesskit/Cargo.toml:3`). The C
bindings are `accesskit-c` 0.23.1. `adapters/unix` is 0.24.0
(`adapters/unix/Cargo.toml:3`) and depends on `accesskit_atspi_common` 0.21.0
(`:21`).

### Trap 10. A Rust oracle is a development-time tool, never a build dependency

**Hazard.** This port must not keep `cargo`. Both house ports that used a Rust
reference reached it only at development time and committed the answers.

**Precedent.** `zautomerge/AGENTS.md:23-25`: "It is a development tool, not part
of the port". `zautomerge/build.zig:671-676`: "The oracle is a development
tool: it is not reachable from the default step, so `zig build` and
`zig build test` need neither cargo nor the reference checkout".
`translate-rust` refuses rather than guesses (`README.md:304-308`).

**Present.** The two upstream trees are read-only checkouts here. Any fixture
must be a recorded file.

### Trap 11. This checkout is on a network filesystem

**Hazard.** "`.zig-cache` and `zig-pkg` **must be symlinks to local disk.** ...
Zig 0.16.0 cannot build there" (`zomp/AGENTS.md:20-24`). `translate-rust` hit
the same wall as a `programmer bug caused syscall error` panic from
`renameat2(RENAME_EXCHANGE)` (`AGENTS.md:29-32`).

**Precedent.** `zomp/AGENTS.md:20-24`; `translate-rust/AGENTS.md:29-32`;
`zig-agent-proto/AGENTS.md:440-445`.

**Present.** The project root is `~/zaccesskit`.
`docs/00-house-and-environment.md` owns the answer. This document only records
that three house projects had to solve it before anything else worked.

### Trap 12. The `zig` on `PATH` is the anyzig shim

**Hazard.** The shim re-resolves and re-downloads the toolchain on every
invocation, and it fails quietly rather than loudly. It reads
`.minimum_zig_version`, which is a lower bound and not a pin.

**Precedent.** `translate-rust/AGENTS.md:26-28`; `zomp/AGENTS.md:8-11`;
`zomp/docs/zomp-design.md:67-72`; `ozai/README.md:27-30`.

**Present.** Same host and same shim.

### Trap 13. Every tree walk needs a fixed upper bound

**Hazard.** "**Loops have fixed upper bounds**; fail fast"
(`ozai/AGENTS.md:41-42`). `zautomerge` hit the same wall on `materialize` and
`hydrate` and required an explicit depth limit with a real error
(`docs/plan.md:1180-1184`). `zomp` wrote a bounded in-tree regex engine and
recorded "Never let a bounded matcher report a bounded answer as a complete
one" (`AGENTS.md:149-152`).

**Present.** `accesskit_consumer` walks the tree in `iterators.rs` and
`text.rs`, with unbounded recursion in `text.rs` and in `zomp`'s upstream shape
this mirrors. Every walk needs a stated bound and an exhaustion error.

### Trap 14. Name collisions with Zig keywords and with the C ABI

**Hazard.** `translate-rust` emits `@"name"` for a Zig-keyword collision as a
required idiom (`notes/research/idiom-mapping.md:56-57`), and resolves a trait
method against an inherent method of the same name by namespacing the impl
(`runtime-traits.md:562-570`). The C bindings add a second namespace on top.

**Precedent.** `translate-rust/notes/research/idiom-mapping.md:56-57`;
`notes/design/architecture/runtime-traits.md:562-570`.

**Present.** `accesskit` exports `Node`, `NodeId`, `NodeRef`, `TreeId`, `Role`,
`Action` and `ActionRequest`. The C ABI has `ActionHandler`. Decide one naming
rule and write it into `AGENTS.md`, or two code bases will drift.

### Trap 15. Closures have almost no house precedent

**Hazard.** `translate-rust` records closures as a callable struct with a
`call(self: @This(), ...)` method, and states that `FnMut` and `move` need
interior mutation Zig's single `*T` does not express cleanly
(`notes/research/idiom-mapping.md:408-438`). `zomp` ported a whole event-stream
closure contract literally because flattening it deadlocks the agent
(`docs/zomp-design.md:33`).

**Present.** 14 closure sites in `accesskit` and `accesskit_consumer`, including
`self.walk(|node| ...)` at `accesskit_consumer/src/text.rs:684`, `:742` and
`:828`, and a captured closure at `accesskit_consumer/src/node.rs:90`.

### Trap 16. A green assertion that cannot fail

**Hazard.** The largest single entry in section 4. `zautomerge` measured 25
mutations across one dispatch and found 23 arms invisible to the whole tree
(`docs/STATUS.md:431`).

**Precedent.** `zautomerge/docs/plan.md:133-158`.

**Present.** Every AccessKit dispatch has arms: `Node` methods switch on a
`PropertyId`, `Role` has many variants, and `TreeUpdate` has several kinds. Each
needs a per-arm test, and the test must be shown failing once.

## 8. What this document does not settle

Four questions belong to `docs/30-port-design.md`, not here. Each is named so
the design document does not have to rediscover that it is open.

1. **The runtime.** Section 3 gives four house answers and the reason each was
   given. The choice for AccessKit follows from trap 1 and needs writing down.
2. **The dependency ladder for the AT-SPI client.** Section 5 gives the four
   shapes the house has used. `local://zaccesskit-deps.md` records the pins
   already made.
3. **The C ABI surface.** The upstream header is generated by cbindgen from the
   Rust types (`accesskit-c/include/accesskit.h`, 3 154 lines). Section 5 row 2
   is the house shape for writing one in Zig. The surface itself is
   `docs/31-c-abi-design.md`.
4. **The fixture corpus.** Section 4 entries 10, 20 and 22 are the reason the
   corpus must be a recorded file with a stated provenance, and the reason a
   count derived from the wrong instrument is worse than no count.
