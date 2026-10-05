# zaccesskit — agent rules

Read this file first. Then read `docs/00-house-and-environment.md`, then the
research under `docs/`, then `docs/30-port-design.md` and `docs/40-plan.md`
when they land. Read `skill://asd-ste100` before you write prose.

## 1. What this project is

`zaccesskit` is a pure Zig port of the Rust `accesskit` accessibility toolkit. It
re-implements the platform-neutral accessibility tree, the tree update
protocol, the action channel from the platform back to the application, and the
platform adapters. It runs on the `zio` async runtime, which replaces the
`tokio` runtime the Rust crates use, and it links the platform half as C.

Three constraints bind every decision in this repository.

1. **Not a wrapper.** Do not link `libaccesskit`. Do not declare an `extern`
   function whose body is Rust. Do not forward a call into Rust. Every upstream
   Rust module and every public function gets a Zig counterpart.
2. **Zero Rust toolchain.** No `rustc`, no `cargo`, no `Cargo.toml`, no
   `Cargo.lock`, no `build.rs`, no `rust-toolchain` file and no `cbindgen`, and
   no step that shells out to any of them. `rustc 1.98.1` and `cargo 1.98.1` are
   installed on this host. They are not build inputs and must never become a
   reference build, a fixture generator or a test oracle.
3. **Zig before C.** Take the first rung that works. The Zig standard library,
   then a Zig package pinned in `build.zig.zon`, then a `translate-c` binding to
   a system C library, then a hand-written C shim. The last rung needs a written
   reason: a macro, an opaque handle, a callback with a non-representable type,
   or varargs.

The Zig version is **0.16.0**. `build.zig.zon:11` holds
`.minimum_zig_version`, and that file is the single version authority for the
project and for every tool the gate runs. `zig` on `PATH` is an anyzig shim
that reads the same field to select the toolchain. Do not install a second
compiler beside the shim and do not write the version anywhere else.

`docs/30-port-design.md`, `docs/31-c-abi-design.md`, `docs/40-plan.md` and
`docs/50-verification.md` all exist. They own the module layout, the C seam, the
milestone order and the evidence record. When a rule below hands a decision to
one of them, take it there, and delete the interim rule in the same change.

## 2. Golden rules

Safety before performance before developer experience. When two of the three
conflict, take them in that order.

- **Explicit everything.** An allocator is a parameter, never a global. An API
  declares its own error set and never leaks `anyerror`. Control flow is
  explicit. No hidden allocation, no hidden state, no macro that hides a branch.
- **Handle every error.** Never discard one with `_ =`. Ask of every `if`
  whether its `else` branch needs handling. Assert the positive space and the
  negative space at every boundary.
- **Pair the assertions.** Write a value, then read it back. Split a compound
  assertion into `assert(a);` and `assert(b);` so the failure names one field.
  State a compile-time relationship with `comptime assert(...)`.
- **Bound every loop.** Give it a fixed upper bound, name the bound, and report
  exhaustion as its own error. An event loop asserts that it terminates.
- **Keep functions small.** Push `if`s up and `for`s down. The parent owns the
  mutable state. A helper computes and returns, it does not apply.
- **Name as the house names.** Functions `camelCase`, types `PascalCase`,
  variables and struct fields `snake_case`. Append the unit to the name, as in
  `timeout_ms`, `byte_count` and `frame_index`. Do not abbreviate. Two or more
  parameters of the same type become an options struct. A callback is the last
  parameter and is named `<caller>_callback`.
- **Make division explicit.** Use `@divExact`, `@divFloor` or `div_ceil`, and
  put the rounding rule in the name of the result.
- **Format with the tool.** Run `zig fmt`. Keep a line under 100 columns. Put
  braces on a multi-line `if`.
- **A comment says why.** Delete a comment that restates the code. An assertion
  that is obviously true beats a comment.
- **No backwards compatibility.** Delete, do not deprecate. No alias, no shim,
  no unused parameter, no deprecation note.
- **Zero dependencies unless a document justifies one.** Write a helper as a Zig
  program under `tools/`, not as a shell script.

## 3. Architecture: extreme testable by default

Mandatory for new code, the default for a refactor, and a review finding when
it is missing.

- **`io` threaded explicitly, never global.** Every function that can block or
  perform I/O takes `io` as a parameter. The consequence is the rule: there is
  no global runtime. No module holds an `Io` in a file-scope variable, and no
  module reaches for a global one. A test builds its own `Io` and hands it in,
  so a deterministic backend is a parameter swap.
- **Platform logic is a pure function of decoded input.** Each state machine
  takes a decoded message and a state value, and returns a new state plus an
  action list. It holds no handle, reads no clock and takes no allocator.
  `docs/23-core-boundary.md` records that the core and the consumer half of
  upstream need no `io` at all, so do not add one there.
- **State is a parameter, not a capture.** Pass it, as in
  `step(event, &state)`. A pure function returns the new state. A closure that
  captures a counter hides the sequence, and a result of `(5,4)` after `(5,0)`
  becomes invisible.
- **Split at the bridges.** Dispatch becomes a loop plus a processor. Each step
  is provably independent, and the number of branches on the prime path stays
  low.
- **Allocator injection and fail-N.** Every allocating function takes a
  `std.mem.Allocator` as its first parameter. A test fails the Nth allocation,
  from 0 up to the first success, so every `error.OutOfMemory` path and every
  `errdefer` runs at least once. The gate cannot inject a failing allocator, so
  this is a duty of the test tree.
- **Errors are values.** Declare the error set. Sweep it at compile time with
  `inline for` over `@typeInfo(ErrorSet)`, so every member is named by a test.
- **Comptime exhaustiveness is the strongest coverage substitute Zig has.** Run
  `try comptime testFn();` and an `inline for` over every enumerable domain. A
  wire enum and a tree property type are enumerable domains, so decode every
  variant in a comptime sweep rather than sampling one in a runtime test.
- **`unreachable` is a claim.** Use it only for a case that cannot occur, and
  say why in a comment. Answer every path a sweep leaves uncovered with a test,
  a refactor or a written acceptance. Never add a test because a coverage
  number asked for one.
- **Determinism is a feature.** Inject the seed. Read no clock in logic. Fuzz
  at every decoder boundary with a metamorphic oracle, such as encode, decode,
  encode as a fixed point. Mutate the suite so that coverage means detection.
- **Wire compatibility is a test, not a comment.** A claim of byte compatibility
  with upstream is a fixture test carrying recorded bytes, or it is an
  unverified claim.

A module that cannot be driven deterministically, or that cannot have a failure
injected into it, is a review finding and not a documented limitation.

### 3.1 No Rust, anywhere

- Keep the tree free of `Cargo.toml`, `Cargo.lock`, `build.rs`,
  `rust-toolchain*` and `cbindgen*`. Check with
  `find . -name 'Cargo.*' -o -name 'build.rs' -o -name 'rust-toolchain*' -o -name 'cbindgen*'`
  and expect no line.
- Do not let any build step, gate stage, test harness or fixture generator
  invoke `cargo` or `rustc`. A command printed in a document is not a build
  input. A script that runs it is.
- Do not keep a Cargo reference build, a golden-vector generator or a test
  oracle. A comparison against upstream takes a recorded fixture.
- A checked-in C header is hand written, or generated by Zig `comptime`. The
  generator lives in this repository under `tools/`, is written in Zig, and
  builds with the Zig toolchain alone.
- The gate checks none of this. It is a review rule, and section 10 is where the
  reviewer executes it.

### 3.2 The `io` question belongs to `docs/30-port-design.md`

- Until that document settles it, apply this rule: every function that can
  block or perform I/O takes `io` as a parameter, and no module holds one in a
  file-scope variable.
- Do not reopen the question in a code comment or a commit message. Record the
  choice and its reason in `docs/30-port-design.md`.
- When that document decides, delete the interim rule in the same change. Do
  not keep both, and do not leave a transitional helper behind.

### 3.3 Time is data

- Nothing here reads the clock. No `Timestamp.now`, no `os.time`, no
  `std.time.nanoTimestamp`, no `std.time.Instant.now` outside a test that
  supplies a fixed value. Grep for the four names across `src/`, `test/` and
  `tools/` and expect no hit outside a test.
- A timestamp is a parameter or a struct field. A test supplies it.
- zio 0.18.0 has no virtual clock. `Timestamp.now` reaches `os.time`, and
  zio's own runner builds a real `Io.Threaded` per test. The runtime does not
  lift this rule for the port, so the port lifts the time itself.
- A deadline and a timeout are values in a state struct, not a call into a
  timer. An adapter fires when a supplied time passes a stored deadline.

## 4. The build

- `zig` on `PATH` is an anyzig shim, not the compiler. It reads
  `.minimum_zig_version` from `build.zig.zon`. Do not bypass it.
- Enter the environment through direnv. `.envrc` sources `$HOME/.dev-env.sh`
  and then runs `use devenv`. If `ZIG_GLOBAL_CACHE_DIR` or `GATE_CACHE_DIR` is
  empty in your shell, run `devenv shell`.
- Run the gate with `zig-gate`. Inside devenv use `devenv shell -- gate:zaccesskit`.
  `devenv shell -- run test` runs `zig version` and then the gate.
- `zig-gate` runs ten stages in this order: `fmt`, `build`, `test`, `ast-check`,
  `ziglint`, `zlint`, `zbc`, `zwanzig`, `cross-test`, `zig-cov`. The first nine
  are on by default and the tenth is advisory and off. The script prints the
  exact command it runs at the head of its own output, so use that command and
  do not keep a second list of commands in a note.
- Three build steps exist:
  - `zig build` runs the default step and builds the published `zaccesskit`
    module.
  - `zig build test` runs the library tests in **Debug and ReleaseSafe**.
  - `zig build cross-test` runs the Debug shard through the build system's own
    runner selection, which is native for the host and `qemu_user` for a
    foreign target.
- **Why `test` runs two modes.** The gate runs a plain `zig build test` and
  passes no `-Doptimize`, so the modes come from `build.zig`. A step that
  declares only Debug never finds a ReleaseSafe-only failure. The Debug shard is
  the published module itself, so a change that breaks
  `dep.module("zaccesskit")` breaks the gate.
- **Why `cross-test` runs one mode.** The native step already covers both
  safety modes, and a foreign row is about execution rather than optimisation.
  The Debug run also reports counted results to `cross-test`, which the `bash -c`
  launcher does not.
- **Keep the two cache paths as symlinks to local disk.** `.zig-cache` and
  `zig-pkg` point into `/tmp/cache/zaccesskit/`. This checkout
  is on NFS, and Zig 0.16.0 cannot write its cache there. The two observed
  failures, verbatim:
  ```text
  error: package contains 'zio-2662fdc.../src/sync' which has illegal file type 'unknown'
  ```
  ```text
  thread N panic: programmer bug caused syscall error: INVAL
  ... in dirRenamePreserveLinux
  ```
- If either path is a real directory, run `devenv shell`. Do not remove the
  contents by hand and do not create the directory with `mkdir`.
- **Adding a dependency.** Add an entry to `build.zig.zon` whose `.url` is a
  codeload tarball of one exact commit, with the `.hash` that `zig build`
  computes from the resolved tree. Pin by commit. Never pin a moving branch,
  never pin a tag alone, and never use a `git+` URL. Check the package's own
  `minimum_zig_version` against 0.16.0 before you add it, and record in
  `docs/30-port-design.md` why the standard library is not enough.
- `zio` is pinned to commit `2662fdc45997611b962b560c513c16963475a01b`. Its
  `.version` of `0.18.0` is zio's own package version, not a Zig version.
- **Do not claim that an X11 adapter compiles here.** `X11/extensions/XTest.h`,
  `X11/extensions/Xfixes.h`, `X11/extensions/XInput2.h` and `xkbcommon.h` are
  absent while the runtime libraries are present. Re-check the four files with
  `test -f /usr/include/<path>` before you write a `translate-c` binding to one
  of them, and put a compile claim for that adapter on the host where the
  headers exist.

## 5. Zig specifics this project has already learned

Each item names the failure it prevents. Do not rediscover them.

- **Keep the default server-mode test runner.** zio's own `build.zig:114` sets
  `.mode = .simple`, which drops counted results, and the compiler's runner
  panics with `fuzz test requires server` at `lib/compiler/test_runner.zig:259`
  when a fuzz target runs in that mode. `b.addTest` with no `.mode` override is
  correct, and `ozai/build.zig:227` sets `.mode = .server` explicitly. A
  project that copies zio's wiring loses the count and loses fuzzing. Check:
  `zig build test` prints a count.
- **Add a `fuzz` build step.** The house gate has no fuzz stage, and `grep -c
  fuzz` over the 823 lines of `zig-gate` returns `0`. A fuzz step therefore never
  runs unless a gate line in `docs/40-plan.md` names it. Put the target file and
  the corpus directory in that line.
- **`src/root.zig` declares five names, and every one of them earns its
  place.** It re-exports the three namespaces `schema`, `consumer` and `capi`,
  and it mirrors `version` and `minimum_zig_version` out of `build.zig.zon`
  through the `build_options` module. It used to be a module doc comment and
  nothing else, and the `empty-file` warning `zlint` reported for it was the
  correct verdict on that file. The file is not that file any more, so the
  warning and the exemption that allowed it are both gone. Do not add a
  placeholder `pub const`, an `export fn` or an unused import to quiet a
  linter, and do not flatten the three namespaces into the root:
  `docs/30-port-design.md` record R2 fixes them one level down, because a
  consumer names those types in one signature.
- **A re-export nothing references analyses nothing.** Zig analyses lazily, so
  `pub const schema = @import("schema/root.zig")` compiles without looking at
  one module under `src/schema/`. `zig build test` reported green that way,
  having checked two constants and two tests. Each of the three namespaces
  therefore has a test in `src/root.zig` that calls
  `std.testing.refAllDecls` on it, and a fourth namespace needs one in the
  same change.
- **Z001 is off in `.ziglint.zon`, and it stays off.** Z001 asks for a
  camelCase function name. 498 of its findings are the C ABI surface, where
  the Zig identifier **is** the C symbol in `include/zaccesskit.h` byte for
  byte: 440 are `export fn accesskit_*` across seven files under `src/capi/`,
  and 58 are the `@export`-driven declarations in `src/capi/platform.zig`,
  whose emitted symbol name is the C name. Renaming one to
  `accesskitNodeChildren` satisfies Z001 and breaks every C caller. A rename
  driver in this repository did exactly that and corrupted 807 sites across
  nine files. **A lint rule that would break a foreign-function boundary is
  not a style rule for this package**, so the rule goes off and the count
  means what it says.
  - `zig build capi-parity` is what holds the 498 to the header instead. The
    property it asserts is two-directional: it compares the header
    declarations against the symbols the Zig side exports and fails on a
    symbol present on one side and not the other. That holds against a rename
    applied to the Zig side alone, which is the mistake this exemption exists
    because it happened. **Its limit: the Zig side is scanned lexically, so a
    rename applied to both the Zig declarations and the tool's own
    expectations would pass.** Reaching that needs an edit to
    `include/zaccesskit.h` too, so the header is the fixed side and the blind
    spot is a coordinated edit of the header and the tool.
  - The cost is stated, not hidden. Z001 reported 546 findings, so turning it
    off also stops reporting the 48 that are fixable. `ziglint` 0.5.3 loads
    one `.ziglint.zon` per run and has no per-directory rule scoping, so a
    config cannot exempt `src/capi/` alone. Naming and review own those 48.
  - Do not "fix" this by renaming a C symbol, by adding
    `// ziglint-ignore: Z001` to 498 lines, or by adding a second config.
    `docs/32-layout-and-naming-corrections.md:206-221` settles naming for the
    Zig half, and this settles it for the boundary.
- **`identifier-style` is off in `.zwanzig.json`, and it stays off.** The rule
  asks for `camelCase` on a function, `snake_case` on a constant and a payload,
  and `PascalCase` on a type. 605 of its 637 findings are the same
  vendor-mirror and C ABI class that Z001 already covers, and the same
  reasoning applies: renaming them changes behaviour or breaks a foreign
  boundary, not style. The config is `{"disabled_rules":["identifier-style"]}`.
  - **The mechanism exists and is the same shape as `.ziglint.zon`.** zwanzig
    reads `--config <path>`, default `.zwanzig.json`, resolved from the working
    directory, which `zig-gate:7` sets to the project root. The keys are
    `enabled_rules` and `disabled_rules` (`tools/zwanzig/src/config.zig:267-268`),
    they are mutually exclusive (`config.zig:274-276`), and `Config.rule_filter`
    (`config.zig:2`) is what the runner filters on. Verified by running the
    tool on a scratch file, not by reading this paragraph: with no config a
    deliberately bad name is reported, and with this config it is not, while
    `unused-decl` and `optional-unwrap` on the same file still are.
  - **It cannot be narrowed the way Z001 cannot be narrowed either.** The whole
    config key set is `enabled_rules`, `disabled_rules`, `max_worklist_steps`,
    `max_states_per_point`, `use_widening`, `escape_max_depth`,
    `optional_unwrap_test_severity`, `resource_models` and `escape_models`
    (`config.zig:267-340`, `Config` at `config.zig:2-14`). There is no
    per-directory and no per-path key, so one root config cannot exempt
    `src/capi/` alone. `{"exclude_paths":[...]}` parses as an unknown key and
    is ignored, which is worse than useless: it reads like a narrowing and
    narrows nothing.
  - **The cost is stated, not hidden.** Turning the rule off also stops
    reporting the **32 that are fixable**, listed per file below. Naming and
    review own those, the same trade `.ziglint.zon` makes for its 48.
  - **Do not "fix" this by renaming a C symbol, by adding a `zwanzig-disable`
    comment to hundreds of lines, or by adding a second config.** zwanzig does
    support `zwanzig-disable`, `zwanzig-disable-next-line` and
    `zwanzig-enable` (`tools/zwanzig/src/suppression.zig`), and 605 of them is
    the same mistake as the 498 `// ziglint-ignore` lines the rule above
    already rules out.
  - Its own blind spot, so nobody over-reads it: the rule exempts an alias whose
    initialiser is a screaming-snake identifier or field access
    (`identifier_style.zig:1054-1077`), which is why some vendor mirrors do not
    appear. A name reached any other way is still reported, which is why the
    count is 637 rather than 605.
  - **The 32 that are fixable, by file.** From
    `/tmp/scratch/shared/zw-identifier-style.txt`, which is a
    pre-fix snapshot; the four `atspi` `SIGNATURE` entries in it are already
    spelled `signature` in the tree, so the live number is lower. Each is a
    plain rename with no vendor or ABI tie:

    |File|Fixable names|
    |---|---|
    |`src/adapters/android/java_call.zig`|1|
    |`src/adapters/android/node.zig`|1|
    |`src/adapters/android/root.zig`|3|
    |`src/adapters/windows/com.zig`|1|
    |`src/adapters/windows/queued_events.zig`|1|
    |`src/capi/marshal.zig`|4|
    |`src/capi/node.zig`|4|
    |`src/capi/node_properties.zig`|3|
    |`src/capi/optionals.zig`|4|
    |`src/capi/platform.zig`|1|
    |`src/capi/property_value.zig`|2|
    |`src/consumer/iterators/children.zig`|2|
    |`src/consumer/iterators/following.zig`|2|
    |`src/consumer/iterators/preceding.zig`|2|
    |`src/consumer/text/position_inner.zig`|1|

    Two of them are not renames at all. `src/capi/optionals.zig:562` and `:592`
    flag `C`, a `comptime` loop binding holding a `type`, inside the
    `inline for (optional_rows)` sweep whose comment above it says a `type` has
    no run-time form. Read those two as the rule misreading a local and leave
    them.

    Three are `pub` and cross a module boundary, so a rename there is not a
    one-line edit: `child_ids`, `filtered_children`
    (`src/consumer/iterators/children.zig:179`, `:406`) and the sibling
    `*_sibling_ids` pair have callers across `src/consumer/`. `position_inner.zig:492`
    and `adapters/android/node.zig:757` are `pub fn ..._step_bound` next to the
    existing `treeWalkStepBound` (`src/consumer/tree_state.zig:603`), so the
    repo holds both spellings of that idea today; settle which one wins before
    renaming, or the rename makes the split permanent.
- **`optional-unwrap` on `TreeState.root` and `TreeState.focusInTree` is a
  recorded exemption, and it stays one.** Two findings, at
  `src/consumer/tree_state.zig:457` and `:485`. Both are upstream ports whose
  `.?` is upstream's `.unwrap()` on a precondition the port documents:
  `tree.rs:513-515` and `tree.rs:530-532`. Both doc comments name the
  invariant (I1 and I4) and the error `validateGlobal` raises when it does not
  hold, and the module doc at `tree_state.zig:131-134` records the decision.
  - **The rule is right about this code. The signature is what forecloses the
    fix.** Both return a bare `NodeRef`, not an error union, so an error tag has
    nowhere to go. Removing the `.?` needs `orelse unreachable`, which is the
    same panic spelled differently and is forbidden, or a signature change that
    a lint slice does not own.
  - **The existing assertion does not suppress it, and moving it does not
    help.** `resolveDebugAssertionName`
    (`tools/zwanzig/src/assertions.zig:220`) does resolve the `assert` alias to
    `std.debug.assert`, so the guard is visible to the tool. But the guard is
    `assert(self.nodes.contains(self.root_id))`, which proves the right
    invariant one level away from where `isGuardedByAssertion` looks: the rule
    wants an assertion on the unwrapped expression's own nullness. Moving the
    assertion there does not typecheck, because the bound `?NodeRef` still has
    to become a `NodeRef`. That buys a green gate with worse code.
  - **The cost of the fix that is deliberately not taken.** Widening `root` to
    `!NodeRef` touches **20 call sites**: ten in
    `src/adapters/android/adapter.zig`, one in `src/adapters/android/root.zig`,
    seven in `src/adapters/ios/root.zig`, two in `src/adapters/macos/root.zig`,
    and two in this file's own tests. Every adapter site sits in a function
    that already returns an error union, so the migration is mechanical — and it
    changes an interface `docs/30-port-design.md` section 4.5 and `docs/33`
    declare, done from a lint slice, across files other slices own.
    **`focusInTree` is the cheap half and still stays**: its only two callers
    are its own tests at `tree_state.zig:933` and `:938`, so widening it is a
    two-site edit. It stays because widening it alone splits the documented
    family of three — `root`, `focusInTree` and `focus` — which
    `docs/30-port-design.md` section 4.5 keeps on one signature. **Priced, not
    overlooked. Ruled 2026-10-06.**
  - **Do not "fix" this by** writing `orelse unreachable`, by adding
    `zwanzig-disable` to the two lines, or by widening either signature inside a
    lint change.
- **Bound the address space on native runs only.** `build.zig:22` sets four
  gibibytes and `addCeilingedRun` applies it through a `bash -c` launcher whose
  script is `ulimit -v 4194304; exec "$0"`. Keep it off `cross-test`. Under
  `qemu_user` the limit would bound the emulator rather than the guest, and a
  shell launcher reports no counted results to `cross-test`.
- **Read the step table and the exit code, not a `failed command:` block.** A
  `zig build test` step that wrote to stderr makes the runner print a
  `failed command:` block above a green summary, because
  `Step.result_failed_command` may be populated even when the step succeeded.
  The message is the evidence, not the failure.
- **Keep `cross-test.profile.sh` strict.** `CROSS_REQUIRE_RUNNERS=1` turns a
  missing runner into a failure instead of degrading execution coverage into
  compile coverage. Keep `powerpc64-linux` in the matrix, because it is the only
  row that catches an endianness bug in a byte layout.

## 6. Porting rules

- **One upstream Rust file becomes one Zig file under `src/`.** The layout is
  fixed by `docs/30-port-design.md`.
- **The upstream Rust is assumed to compile.** Borrow checking is upstream's
  problem and is out of scope. Do not report a missing lifetime annotation as a
  port defect.
- **A defect is wrong output for valid input.** It includes code that compiles
  and computes the wrong value, a panic on a valid input, an `unreachable`
  reached on a valid input, and a wire message that a peer rejects.
- **Record the mapping function by function.** One row per public or
  `pub(crate)` item, with the upstream `path:line`, the Zig name and the Zig
  `path:line`. `docs/30-port-design.md` holds that table, as
  `docs/12-accesskit-adapters.md:1126` records. A module with no row is a module
  whose port is not claimed. Do not invent a row for an item you did not port.
- **No shim survives the cutover.** Do not write a `compat.zig` or a
  `deprecated.zig`, and do not keep an alias that forwards to the new name, as
  in `pub const Tree = TreeInfo;`. Change the caller and delete the old path in
  the same commit.
- **Translate a panic into an error or into an assertion, and say which in the
  row.** The upstream panic sites in the tree half are already located in
  `docs/23-core-boundary.md`. Each becomes a member of one named error set.
- **Translate a lifetime into a parameter or a named pointer.** Do not copy a
  value that upstream borrows, because the copy hides the aliasing the Rust
  code made explicit.
- **Take the decision order for each new binding.** Standard library, then a
  pinned Zig package, then `translate-c`, then a hand-written C shim with the
  reason named in the row.
- **A rung 4 shim names its cause.** A macro, an opaque handle, a callback with
  a non-representable type, or varargs. A shim with no named cause is a
  wrapper, and section 1 forbids a wrapper.

## 7. Testing and verification

- **The gate is `zig-gate`.** Run it once, after the work lands, not while
  editing. Section 4 names the stages.
- **A green gate does not prove** a coverage figure, because `zig-cov` is off
  by default and `build.zig` has no coverage wiring. It does not prove
  fuzzing, a sanitizer, `ReleaseFast` or `ReleaseSmall`, foreign execution where
  a runner is missing, an analyser pass over a file outside the gate's `find`
  list, or the absence of a leak unless the tests use a leak-detecting
  allocator. Coverage is advisory and off by default, so never quote a
  percentage as if it were a gate.
- **Reproduce a bug before and after the fix.** Write the failing test, run it
  and paste the failure output. Then fix it and paste the passing run. A fix
  with no red run is unverified.
- **Keep a regression test only for a defect a consumer can plausibly see:**
  wrong output, a crash on a valid input, a wire message a peer rejects, a
  memory error or a leak. Delete a test that pins an internal shape that nothing
  outside the module can observe.
- **Never keep a test that passes on a stub.** A test whose subject is a mock,
  a fake or a placeholder proves the placeholder. Test the real implementation,
  and where a seam must be replaced, drive the real code through that seam in the
  same test that exercises the seam.
- **Never write a wiring test.** A test that asserts a declaration is exported,
  a field is assigned, a build step runs, or a call reaches its neighbour tests
  the build graph. It passes while the code is wrong. Assert an observable
  result instead.
- **Never assert only that a result is non-empty, and never assert only that a
  count grew.** Both pass for a wrong value. Assert the value, or a checksum of
  it.
- **Take the oracle from a recorded fixture.** No Rust toolchain may run, so a
  fixture is a committed file and never a generated one. The harness is its own
  module root so that `@embedFile` resolves, which turns a missing fixture into
  a build failure rather than a skip.
- **Check every fixture before it decodes.** Assert the byte length and the
  SHA-256, and record the upstream commit the bytes came from. A truncated merge
  then fails instead of passing on a shorter input.
- **Record a new case by hand from the upstream tree, or extend an existing
  case** through the port's own serializer and name the case it derives from.
  Nothing in the build consults a remote.

## 8. Writing rules

- **Read `skill://asd-ste100` before you write.** Apply it to documents, commit
  messages, comments and doc comments. It does not apply to code or to a
  command.
- **Write Simplified Technical English.** Active voice, short sentences, one
  instruction per sentence, no semicolons, no contractions, American spelling.
- **Use one name for one thing.** Do not rename the same item between two
  documents, and do not call one object "the toolkit", "the library" and "the
  crate".
- **Ban the marketing words.** Do not write "robust", "seamless", "powerful",
  "leverage", "comprehensive" or "world-class" unless a measurement is quoted
  beside it.
- **State the contract, then the reason.** A doc comment states the observable
  result, the precondition, the reachable errors, what survives each error and
  what the caller must release. The `why` clause is an addition and never a
  substitute for the contract.
- **Remove slop.** Slop is a comment that restates the code, a divider, a vague
  `TODO`, a passive sentence with a known actor, a stacked auxiliary, a
  nominalization such as "perform an analysis", or a hedge such as "it is
  important to note that". Remove each one and keep the why-comment.
- **Use a table when there are facts.** One fact per row. No date stamp and no
  frontmatter.

## 9. Version control

- **The repository is `jj`, colocated with git.** It was created with `jj git
  init --colocate`. Use `jj`. Never run a raw git command except `jj git push`.
- **Start new work on a clean change.** Run `jj st`. If the change is dirty,
  checkpoint it with `jj commit -m "wip: ..."`, then `jj new`.
- **Do parallel work in a worktree.** `jj worktree add <path>`. Two agents never
  edit one working copy.
- **Commit only when asked.** Never commit a red tree. A red gate blocks the
  push and not a workaround.
- **Never run `jj abandon` without permission.** Read `jj st` first and name
  what the change contains.
- **Treat the upstream trees as read-only.** `/tmp/scratch/accesskit`,
  `/tmp/scratch/accesskit-c` and
  `/tmp/scratch/goose` hold the pinned upstream sources. Read
  them, do not edit them, and do not add agent rules to them.
- **Never write to `/tmp` or `/var/tmp`.** Not a scratch directory, not a
  probe output, not a cache, not an archive, not a temporary file, and not as
  the `TMPDIR`, `TMP` or `TEMP` of a command that writes one. Every byte this
  work produces goes under `/tmp/scratch/<slice>/` or the
  cache at `/tmp/cache/zaccesskit/`. This is the user's standing
  instruction and it is not a default to be overridden when a tool suggests
  one: `zig build` has been seen to land a `cimport.h` under a path containing
  a `tmp` segment, so when a tool writes somewhere unexpected, move the result
  and point the tool at `/home/tmp2` rather than accepting the path.
  `/vol/tmp` is a read-only mount holding reference headers such as the JDK
  used by `docs/42`; it is read, never written, and it is not a scratch
  directory either.
- **Clean up your own scratch before you finish.** `/tmp/scratch/`
  accumulates a directory per slice. Remove yours when the slice lands, and
  remove it when the slice fails, because a failed slice's scratch is the one
  somebody will mistake for evidence later.
- **`HANDOFF.md` is never committed.** The `.gitignore` lists it for that
  reason.

## 10. Before you claim something is done

Execute every item in the same turn as the claim, and paste the raw output.
Every item can fail, and every failure points at a defect.

1. `zig-gate` exits 0, and the stage line shows `fmt`, `build`, `test`,
   `ast-check`, `ziglint`, `zlint`, `zbc`, `zwanzig` and `cross-test` as run.
   Read the stage line rather than the verdict line, because a skipped stage is
   invisible in the exit code.
2. `zig build test` printed a test count. A run with no count and no `skipped`
   line is a harness failure, not a clean run.
3. Each changed file has a test that fails when the implementation is wrong.
   Prove it: break the implementation on purpose, run the test, paste the
   failure, then restore the code. A test you have never seen fail is not
   evidence.
4. Each new error value is reachable from a test. Name the test and the error.
5. Each loop added carries a named upper bound and an exhaustion branch. Point
   at the bound in the diff.
6. The diff holds no `while (true)`, no `catch {}`, no `_ =` on a fallible
   call, and no `unreachable` without a comment that says why the case is
   impossible. Show the grep result for each.
7. The diff holds no file-scope `var` and no global runtime. Show the grep
   result.
8. `find . -name 'Cargo.*' -o -name 'build.rs' -o -name 'rust-toolchain*' -o
   -name 'cbindgen*'` prints nothing, and no build step or test invokes `cargo`
   or `rustc`.
9. Each function ported in this change has a row in the mapping table with both
   `path:line` values. Point at the row.
10. A grep for the old name of a renamed item finds no reference outside the
    mapping table. Paste it.
11. Every fixture named in the manifest loads, its length matches and its
    SHA-256 matches. Paste the harness output.
12. When the change adds a decoder boundary, `zig build fuzz` runs over its
    committed corpus and exits 0, and `docs/40-plan.md` names the gate line
    that runs it.
13. No claim about upstream behaviour rests on memory. Either a fixture proves
    it or the sentence is marked `[INFERENCE]`.
14. No scratch directory, probe binary or generated artifact remains outside
    the fixture tree.
15. `zig fmt --check` reports no file, and `jj st` lists only the files this
    change meant to touch.
