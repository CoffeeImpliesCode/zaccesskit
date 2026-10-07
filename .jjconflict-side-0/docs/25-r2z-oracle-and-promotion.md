# 25 — The oracle, the promotion gate and the mechanisms worth copying

Consumed by `docs/30-port-design.md`, which turns sections 1, 2, 3 and 8 into
per-module acceptance rules, and by `docs/40-plan.md`, which turns section 7
into milestone gates.

Every claim below carries a source. `path:line` is a citation. Anything not read
directly is marked `[INFERENCE]`.

The source of prior art is `translate-rust`, read only at
`~/translate-rust`. Paths in this document without a
leading directory are relative to that repository.

## 1. The promotion gate

### 1.1 What the gate is

A generated package is not published because the translator produced text. It is
published because the package that text builds passed its own `zig build test`.
The rule is stated once, at `README.md:4-7`: the translator "generates a
package, and promotes that package only after it builds and runs its own tests".

`tools/test-generated-corpus.sh:8-12` restates it as the reason a corpus row
exists at all:

> Every package is promoted by the driver, so a row is present only because its
> manifest, sources and own `zig build test` passed.

The implementation is one function, `promoteWithHooks` at
`src/backend/zig/package.zig:908-998`. Everything below is a stage of it.

### 1.2 The stages, with `path:line`

| # | Stage | Where | What it does | What failure means |
|---|-------|-------|--------------|-------------------|
| 1 | Validate the in-memory package shape | `package.zig:915`, body at `:166-170` | Fills a null fingerprint with 0 and calls `ast.validateForTranslation`. Catches a missing root file, a duplicate or invalid file path, a missing std import, an empty translated function, and 18 other conditions listed at `backend/zig/ast.zig:603-624`. | Nothing is written. The caller sees the named error. |
| 2 | Create a staging directory | `package.zig:916`, body `makeStagingDirectory` at `:580-609` | Builds a sibling path `.{basename}.staging.{nonce_hex}` at `:552-574`, with a 16-byte nonce from `io.randomSecure` (`:498`, `:576-578`) and at most 16 attempts (`:499`). `createDir` is the claim; `PathAlreadyExists` retries. | `error.StagingPathExhausted` at `:608`. `error.InvalidOutputDirectory` for an empty or `.`-only path at `:557-560`. |
| 3 | Write everything | `package.zig:919`, body `writeToDisk` at `:425-457` | Writes `build.zig` (`:438`), `build.zig.zon` (`:442`), every `pkg.files` entry (`:446-449`), and the vendored runtime when the package needs one (`:454-456`, body at `:459-470`). | `cleanupPromotion` at `:885-893` deletes the staging tree and returns the original error. The output directory is never touched. |
| 4 | Read the staged tree back | `package.zig:920-927`, body `validateStagedPackage` at `:652-702` | Stats every declared file (`:624-635`), requires `build.zig`, `build.zig.zon` and `src/root.zig` (`:668-670`), re-checks the manifest carries `.name = .` (`:691`), carries exactly one `.fingerprint = 0x…` (`:637-650`, `:692-700`), and lists `"src"` in `.paths` (`:701`). It also validates the package again with the resolved fingerprint at `:660-664`. | `error.InvalidGeneratedSource`, `error.InvalidGeneratedManifest`, `error.MissingFingerprint`. Staging is deleted. |
| 5 | Build and test the staged package | `package.zig:929`, body `runGeneratedBuildTest` at `:759-770` | Runs `zig_executable build test` with `cwd` set to the staging directory (`:748-751`), once per flag in `promotion_optimize_flags` (`:704-710`): `-Doptimize=Debug` then `-Doptimize=ReleaseSafe`. The first non-zero exit is returned unchanged (`:721-735`). | `error.GeneratedPackageBuildFailed` at `:944`. The captured stdout and stderr are printed first (`:865-879`), so a one-pass compile error is visible. |
| 6 | Resolve and patch the manifest fingerprint, once | `package.zig:933-985` | On a failure, `resolveFingerprint` reads a `0x…` value the compiler printed (`:795-816`, markers at `:772-793`), `patchManifestFingerprint` rewrites `build.zig.zon` (`:818-853`), and the build runs a second time (`:983`). | A second failure is final (`:948-956`). Ambiguous output is `error.ProbeOutputAmbiguous` (`:276`). |
| 7 | Re-validate with the final fingerprint | `package.zig:987-994` | The same read-back as stage 4, now with `require_fingerprint = true`, so the manifest on disk must carry the value the probe resolved. | `error.InvalidGeneratedManifest` at `:696`. |
| 8 | Publish | `package.zig:996`, body `publishStagedPackage` at `:895-904` | One `rename`. Absolute paths use `renameAbsolute`, relative paths use `Dir.rename`. A directory that becomes visible to a consumer appears complete or not at all. | `error.InvalidOutputDirectory` at `:898` when one path is absolute and the other is not. |

Two properties of this shape matter more than the individual stages.

**The compiler is the build's own compiler.** `zig_executable` is
`@import("toolchain").zig_executable` (`package.zig:17`,
`src/driver/pipeline.zig:16`), and that module is created from
`b.graph.zig_exe` at `build.zig:20-22`. The comment at `build.zig:17-19` says
why: a PATH lookup for `zig` can land on the anyzig shim, which has no version
to resolve outside a checkout and then fails silently.

**Two optimize modes are one gate, not two.** Debug catches compile-time
breakage. ReleaseSafe is what a consumer runs, where the optimizer is on and
`std.debug.assert` guards are load-bearing. The comment is at `package.zig:704-706`.

### 1.3 The refusal path

A gate that only accepts success teaches nothing about its own boundary. So
negative fixtures are pinned too.

| Kind | Where | Rule |
|------|-------|------|
| Wire fixture that must be refused | `build.zig:479-494`, loop at `:495-515` | The CLI must exit non-zero **and** `$out` must not exist (`:507`). A translator that writes a package before refusing fails this. |
| Source fixture that must be refused with a **named** error | `build.zig:527-530`, loop at `:531-557` | The declared error is compared by name. The comment at `build.zig:517-526` says why: exiting non-zero "stays green when a fixture starts failing with a *different* error". |
| The published table | `README.md:292-308` | Five source fixtures with their exact typed error. A fixture leaves the table by working, never by deletion (comment at `build.zig:524-526`). |
| Refusal before any decode | `src/driver/pipeline.zig:73-83` | The wire version is read, range-checked, and compared before `ir.serialize.decode` runs. |
| Refusal leaves no package output | `src/driver/pipeline.zig:643-697` | Tests for v1, v2 and v4 assert that `out_dir/build.zig` does not exist after the failure. |

The named-error idea is the transferable one. `README.md:304-306` is explicit
that pinning a refusal "is not an exemption: wrong output for valid Rust is a
defect wherever it appears". The pin records where coverage stops, so a silent
change of boundary is visible.

### 1.4 The same rule as a per-module checklist

A hand port has no package generator, so there is no `build.zig` to write and
no fingerprint to patch. The transferable part is the order: prove the thing
stands on its own before anything depends on it. Per module, a port author
satisfies the gate with these items.

| # | Item | What "pass" means for a hand port | Replaces |
|---|------|-------------------------------------|----------|
| 1 | The module builds alone | `zig build test` compiles the module with no other module's help, or with exactly the imports the header of its upstream counterpart declares. | Stage 1 |
| 2 | The module's public surface is complete | A test names every upstream public function, type and constant the port claims to carry. A missing name is a test failure, not a note. | Stage 1 |
| 3 | It builds at two optimize modes | Debug and ReleaseSafe, both green, both with zero leaks under `std.testing.allocator`. `docs/18-testing-strategy.md` §2 already sets this layout. | Stage 5 |
| 4 | The declared refusals are refused by name | For each upstream construct the port does not model, a test asserts the exact error the port returns. | Stages 3, 4 |
| 5 | A refusal leaves no partial state | After a refusal, the port holds no handle, no arena block and no registered interface. Assert the counter is unchanged. | Stage 4 |
| 6 | A consumer can use it without reading the source | A test in a separate module reaches the port through `b.dependency(...).module(...)` only. `README.md:69-78` is the model for the generated case; the same rule applies. | Stage 8 |
| 7 | It is byte-reproducible | Two runs of the same fixture produce identical bytes. | Stages 3, 8 |
| 8 | The pinned byte layouts are checked on a big-endian target | `cross-test.profile.sh:29-33` names `powerpc64-linux` as the row that catches an endianness bug in tree serialisation, action-channel marshalling and the C ABI structs. | Stage 5 |

Items 1 to 8 are exactly what `zig-gate` already runs for this project. The port
does not need a second gate; it needs its own build graph to satisfy the same
one.

### 1.5 Which parts of the gate only exist because a translator exists

This is the honest boundary. Four of the eight stages have no hand-port
equivalent at all.

| Stage | Why it is translator-only | The hand-port substitute |
|-------|---------------------------|--------------------------|
| 2, staging directory and nonce | A generator writes many files and must not leave a half-written tree where a consumer can find it. A human writes one file with one editor. | None needed. A port author does not publish; a commit does. |
| 6, fingerprint probe and one-shot patch | Only a generated manifest can carry a fingerprint the compiler computed from bytes nobody has read. `build.zig.zon` in this project has a committed fingerprint at `build.zig.zon:7`. | None needed, for the same reason. |
| 5, "its own `zig build test`" as a *separate* package | The generated package is consumed by an unknown consumer, so it must be proved consumable. The port's own build graph already proves that for every module in it. | The house gate, `zig-gate`, plus the cross-test matrix. |
| 8, atomic publish by rename | Same reason as stage 2. | None needed. |

What survives for a hand port is the **discipline**, not the machinery:

- validate before writing anything (stage 1 before stage 3);
- read back what you wrote rather than trusting what you meant to write (stage 4);
- run the two optimize modes, not one (stage 5);
- pin refusals by name so the boundary cannot move silently (section 1.3);
- delete the scratch on every failure path, including allocation failure
  (`package.zig:885-893` attaches cleanup at `:919`, `:927`, `:930`, `:941`,
  `:951`, `:967`, `:972`, `:980`, `:984`, `:994`, `:997`).

## 2. Golden files

### 2.1 Where they live and what they contain

Three trees, all under `test/golden/`. A `find` over the directory returns 26
files.

```
test/golden/
  rust_ir/     3 files  <fixture>.rustir.json   canonical v6 frontend IR
  zig_ast/     3 files  <fixture>.zigast.json   Zig AST, format version 1
  zig_src/    20 files  <fixture>/<package path> emitted Zig source, one file
                                  per emitted file, at its package path
```

The seven `zig_src/` fixture trees are `adler`, `compat`, `fnv`, `hex`, `mini`,
`multimod` and `wyhash`. The three with both JSON snapshots are `fnv`, `hex`
and `mini`. `zig_src/fnv/src/root.zig` is the one the golden-file discipline in
`AGENTS.md:7` names as the example.

The first bytes of each format, read from the files:

```
test/golden/rust_ir/mini.rustir.json
{"format_version":6,"crate_name":"mini","edition":"2021","sidecar":null,
 "toolchain":null,"crates":[{"name":"mini", ...

test/golden/zig_ast/mini.zigast.json
{
  "format_version": 1,
  "name": "mini",
  "version": "0.0.0",
  "fingerprint": null,
```

The IR JSON is compact, one line. The Zig AST JSON is indented. The difference
is not a rule; it is what each encoder emits.

### 2.2 How one is generated and what fails when it drifts

The rule is one sentence at `README.md:504-506`:

> Golden files under `test/golden/` are the emitted Zig, and they are
> regenerated from validated canonical IR rather than edited by hand. Change
> the translator, regenerate, and read the diff.

Generation is one build step per fixture. Seven steps exist:
`generate-mini-wire` (`build.zig:211-216`), `generate-fnv-golden`
(`:229-234`), `generate-hex-golden` (`:247-252`), `generate-mini-golden`
(`:265-270`), `generate-compat-golden` (`:283-288`),
`generate-wyhash-golden` (`:301-306`), `generate-adler-golden` (`:319-324`),
`generate-multimod-golden` (`:337-342`). Each is a compiled program whose
source is registered as a build root (`build.zig:1017-1024`). The wire
generator's comment is explicit about the path it takes: "the trusted source →
validation → canonical encoder path" (`build.zig:197-199`).

Comparison happens in one function, `checkGolden` at
`test/golden_test.zig:58-86`.

| Case | Behaviour | Line |
|------|-----------|------|
| Content differs | Prints both payloads with their byte counts and returns `error.GoldenMismatch`. | `:76-82` |
| File absent | `error.GoldenMissing`. | `:83-85` |
| Trailing newline | Exactly one final newline is stripped from the golden file, because "text editors and generated snapshots use different file endings". Every other byte is strict. | `:72-75` |

Three more gates protect the comparison itself.

| Gate | What it stops | Line |
|------|----------------|------|
| Fixed analysis width | `golden_target_pointer_width: u16 = 64` (`test/golden_test.zig:39`). A null width makes the frontend follow the host ABI, so on a 32-bit or wasm32 host every snapshot changes bytes and the mismatch reads as a translator regression. | `:33-39`, test at `:695` |
| File-set shape | `expectPackageShape` (`:88-145`) fails on a wrong file count, a duplicate path, an unexpected path, a missing path, a duplicate or missing root, or a fixture that claims tests and produced none. | `:93-143` |
| No orphan | `test/golden_test.zig:811-857` walks `test/golden/` and `test/*.json` and fails any file no test or build step names. The comment at `:806-810` records the reason: `test/golden/zig_src/hex/**` "sat unread while the emitted text changed underneath it". | `:811-857`, key at `:792-804` |

The orphan gate is the one worth copying. A golden nobody reads is not
evidence. It is decoration.

### 2.3 The canonical wire format and its version

The canonical wire is **v6**. The constant is at `src/ir/serialize.zig:20`:

```zig
pub const wire_format_version: u32 = 6;
```

The version enters the pipeline at `RustIr`, and every other version is
rejected before a package is created (`README.md:40-41`).

Two separate version numbers exist, and confusing them is a defect:

| Format | Current version | Constant | Decoder gate |
|--------|-----------------|----------|--------------|
| Canonical IR wire | 6 | `src/ir/serialize.zig:20` | `src/ir/serialize.zig:6918-6920` rejects any other value with `error.InvalidFormatVersion`. |
| Zig AST wire (`--dump zigast`) | 1 | `src/backend/zig/serialize.zig:14` | `src/backend/zig/serialize.zig:3646-3647`. |
| Legacy sidecar (`--dump model`) | 3 | `src/model/json.zig:33` | `src/model/json.zig:2309` accepts 1 to 3 for `parse`; `:2323` demands exactly 3 for `parseFull`. |

The driver refuses a bad version in two steps, and the order matters.
`decodeWireJson` at `src/driver/pipeline.zig:59-85`:

1. Parse the root as an object, or `error.BadWireFormat` (`:69-72`).
2. Read `format_version`, or `error.MissingField` (`:73`).
3. Reject a negative value or one above `maxInt(u32)` (`:74-80`).
4. Compare against `wire_format_version`, or `error.UnsupportedWireVersion`
   (`:81-83`).
5. Only then call `ir.serialize.decode` (`:84`).

Four tests pin the refusal: v1 at `src/driver/pipeline.zig:603-611`, v2 at
`:613-621`, v4 at `:623-631`, v5 at `:633-641`. Three more assert that no
package directory survives the refusal (`:678-697`).

The legacy wire corpus is the evidence that the gate has teeth. Sixteen JSON
files sit in `test/`. Reading the first 400 bytes of each:

| `format_version` | Files |
|------------------|-------|
| 2 | `adler`, `atoi`, `crc16`, `fletcher`, `itoa`, `leb128`, `percent-encoding`, `seahash`, `siphasher`, `syn`, `wyhash`, `xxhash-rust` |
| 3 | `fnv`, `hex` |
| 6 | `mini` only |
| no field | `mini-rustdoc.json` |

`README.md:287-290` lists the refused set by name. Only `test/mini.json` is a
translation input. The other fifteen are inventory.

`README.md:44-48` records one more rule that matters for a port with byte
layouts: literal array lengths and repeat counts are `u64` output metadata,
independent of the translator's pointer width, and they stay unquoted decimal
JSON numbers across the full `u64` range. Decoding rejects a negative or
overflowing count with `BadWireFormat`, without clamping and without passing it
through a float.

### 2.4 Fixed-endian node hashing

`README.md:49-50` states one sentence: "Inferred-record ordering uses
fixed-endian node hashing, so canonical snapshots do not depend on host byte
order."

The mechanism is at `src/frontend/infer.zig:30-47`:

```zig
const InstantiationContext = struct {
    pub fn hash(_: InstantiationContext, node: exprs.NodeId) u64 {
        const little = std.mem.nativeToLittle(exprs.NodeId, node);
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&little));
    }
    ...
};

/// Fixed-endian node hashing keeps inferred-record ordering portable.
pub const InstantiationMap = std.HashMapUnmanaged(...);
```

The key is converted to little-endian **before** hashing. `nativeToLittle` is
a no-op on a little-endian host and a `@byteSwap` on a big-endian one, so the
hashed bytes are the same on both. Without the conversion the hash of a given
node id differs per host, and any output ordered by that hash differs per host.

The same rule appears twice more, for a different reason.

| Where | What it protects |
|-------|-----------------|
| `src/frontend/ts_ext.zig:5764-5768` | Rust `to_le_bytes` must lower to a little-endian encoding on every target, so it cannot share the native-endian `to_ne_bytes` path. |
| `src/frontend/ts_ext.zig:9068-9072` | Same rule stated at the lowering site. |
| `src/frontend/resolve_methods_test.zig:5985-5986` | `stream.rs:190-191` encodes explicitly little-endian; the native-endian default changes hashes on a big-endian consumer target. |

### 2.5 Why a port with a C interface needs this rule

An AccessKit port has byte layouts in its C interface, and the upstream header
proves it.

| Upstream construct | Bytes | Where |
|--------------------|-------|-------|
| `accesskit_tree_id` | `uint8_t bytes[16]`, no field for byte order | `accesskit-c/include/accesskit.h:707-709` |
| `accesskit_color` | three `uint8_t` | `accesskit.h:754-758` |
| `accesskit_affine` | `double _0[6]`, 48 bytes | `accesskit.h:934-936` |
| `accesskit_action_data` | an `accesskit_action_data_Tag` plus eight anonymous-struct arms: `int32_t custom_action`, `char *value`, `double numeric_value`, `accesskit_scroll_unit scroll_unit`, `accesskit_scroll_hint scroll_hint`, `accesskit_point scroll_to_point`, `accesskit_point set_scroll_offset`, `accesskit_text_selection set_text_selection`. No arm is a `bool` | `accesskit.h:1025-1053` |
| `accesskit_node_ids` | `size_t length` plus a pointer | `accesskit.h:688-691` |

Two consequences for the port.

**A canonical snapshot of an ABI record is a byte vector, never a decoded
struct.** `test/golden/zig_src/mini/src/root.zig` is compared as source text.
The port's ABI snapshots must be compared as bytes, and the byte order must be
fixed by the serialiser, not by the host.

**A big-endian execution row is the only real proof.** `docs/00-house-and-environment.md`
records `powerpc64-linux` as the row that catches an endianness bug in the tree
serialisation, the action-channel marshalling and the C ABI structs. The reason
is at `cross-test.profile.sh:29-33`: "Those are byte layouts, so a big-endian
row is the only execution proof that they are written correctly."

The rule for a hand port, stated once: **any value that feeds an ordering, a
hash, or a snapshot goes through an explicit `to_le` or an explicit byte vector
before it is used.** `nativeToLittle` is the Zig spelling. It costs one
comptime branch.

## 3. The oracle, and what happens without Rust

### 3.1 What `tools/rust-corpus-oracle.sh` needs from a Rust toolchain

The script is 767 lines. Read as a whole, it is one question asked twice: does
the translated Zig compute what the upstream Rust crate computes?

| Requirement | Where | What it does if missing |
|-------------|-------|------------------------|
| `cargo` on PATH | `:327-329` | `exit 2`, "install a modern stable Rust toolchain". |
| `rustc` on PATH | `:328-329` | Same. |
| `python3` on PATH | `:330` | `exit 2`. Needed to read `cargo metadata` JSON at `:611-627` and `:677-695`. |
| A reachable crates.io registry | `:436-440` | `exit 2`, `registry-unreachable`. The comment at `:44-48` names the crates: `rand_core` and `num-traits` for the oracle build; `criterion`, `quickcheck`, `getrandom` and `xxhash-c-sys` for the upstream test targets. |
| `rustup`, optional | `:340-345` | Without it the script cannot compute the active toolchain, so `RUSTUP_TOOLCHAIN` is not exported. |
| Local, non-network scratch | `:160-313` | `exit 2`. The check reads `/proc/mounts` directly (`:198-214`) and refuses `nfs`, `cifs`, `9p`, `ceph`, `lustre`, `fuse` and 11 others (`:220-222`). It also refuses `/tmp`, `/var/tmp` and `/dev/shm` (`:234-251`), and anything inside the repository (`:246-248`). |
| The seven fixture crate roots | `:77`, checked at `:292-300` | `exit 2`. Each must exist, be owned by the caller, carry no `target/` directory, and contain no symlink. |

Two more toolchain facts are worth naming because they are subtle.

**A fixture's own `rust-toolchain.toml` is overridden.** `test/crates/atoi`
ships one pinning 1.57.0. The script exports `RUSTUP_TOOLCHAIN` from a
directory that has no `rust-toolchain` file (`:332-345`) and then **verifies**
the override is in force while the working directory is the staged `atoi` root
(`:420-424`). A fixture's pin must not decide the toolchain that judges it.

**All cargo writes leave the repository.** `CARGO_HOME`, `CARGO_TARGET_DIR`,
`TMPDIR`, `TMP` and `TEMP` are set under one run directory at `:393-400`, and
each is re-checked to be inside it and on local storage at `:405-411`.

The script also proves it changed nothing. It hashes every staged file before
and after (`stage_tree` at `:353-365`) and re-hashes the source trees at the end
(`:712-731`). A difference is reported as `FIXTURE-MUTATED` and fails the run
(`:753-755`).

### 3.2 What the oracle actually does

Two stages, four receipts' worth of output.

**Stage one: build and run the oracle twice.** The oracle is
`test/rust-corpus-oracle/`, a Cargo package whose dependencies are seven path
dependencies on the fixture crates (`test/rust-corpus-oracle/Cargo.toml:12-26`).
It runs once with the empty default feature closure and once with `--features
xxh32` (`rust-corpus-oracle.sh:471-472`), writing
`rust-corpus-oracle.default.json` and `rust-corpus-oracle.xxh32.json`. Each run
must produce a `--output` receipt byte-identical to the receipt it printed on
stdout (`:449-461`). A difference is `ORACLE-MISMATCH`.

Every case compares a value against something that is **not** produced by the
same call. Three kinds, declared at `test/rust-corpus-oracle/src/main.rs:7-14`:

| Kind | The comparison |
|------|----------------|
| `Vector` | The result against a value published by the upstream crate or its canonical C implementation. |
| `Consistency` | Two different upstream code paths must agree. |
| `Distinct` | Two code paths must **not** agree. |

**Stage two: run the original crates' own tests.** `run_upstream` at `:540-596`
runs `cargo test --lib --tests` and `cargo test --doc` from each crate's own
staged manifest. `xxhash-rust` gets three named configurations instead of one
(`:648-658`), because its default closure legitimately compiles to zero tests.

The runner separates three failure classes, and the separation is the point
(`:500-521`, `:523-538`):

| Class | Meaning |
|-------|---------|
| `UPSTREAM-FAIL` | The crate's own tests ran and failed, or its sources do not compile. Never downgraded. |
| `PREREQ-UNAVAIL` | The log names an unreachable registry, an unresolvable package or an incompatible toolchain. Only a failure under `--strict-prerequisites`. |
| `VERSION-DRIFT` | `cargo metadata` resolves a different version than the receipt declares (`:702-706`). |

### 3.3 The one thing worth copying verbatim

Not the script. The **provenance discipline in the oracle program**.
`test/rust-corpus-oracle/src/main.rs:15-34` is a table giving, per crate, the
exact upstream file the expected value came from: a test constant, a test
table, a doctest, a C test-vector header. And `:27-34` records a case where two
upstream documents disagree about one value, and the receipt keeps the
disagreement **checked** rather than silently resolved.

That is the pattern a recorded-fixture harness needs, and it is not about Rust.

### 3.4 What a port with no Rust toolchain must do instead

The port philosophy is binding: no `rustc`, no `cargo`, no `Cargo.toml`, no
`Cargo.lock`, no `build.rs`, no `cbindgen`, no `rust-toolchain`, and no step
that shells out to `cargo`. Not at build time, and not as a reference build, a
golden-vector generator or a test oracle. `docs/00-house-and-environment.md`
§3.3 records the same conclusion from the other direction: `cargo` and `rustc`
exist on this host under `$XDG_DATA_HOME` on NFS, and "Any cross-check against
upstream AccessKit behaviour must use a recorded fixture, not a Rust oracle."

The route is recorded fixtures with a version and a checksum.
`docs/18-testing-strategy.md` §5 already specifies the format and this document
does not restate it. What `translate-rust` contributes is the *shape* of the
discipline:

| Property | translate-rust | What the port needs |
|----------|----------------|---------------------|
| The expected value comes from outside the code under test | `src/main.rs:7-14`, three kinds of comparison | Every fixture names `recorded_from` and an upstream commit. |
| A disagreement is recorded, not resolved | `src/main.rs:27-34` | A fixture whose upstream value conflicts with another source keeps both and marks which is authoritative. |
| The expected value is anchored to a version | receipt `crate_versions` (`main.rs:45-48`, `:93-101`) plus `cargo metadata` re-resolution (`rust-corpus-oracle.sh:660-710`) | `manifest.json` carries `sources.core.commit` and `sources.c.version`. A port cannot re-resolve anything, so the **recorded** version is the only version. |
| The byte sequence is checked before it is interpreted | `stage_tree` sha256 at `:359-363` | `cases[].body_sha256` and `body_len`. |
| Nothing is deleted | `:60-61`, `:143-145`, `:763-765` | `docs/18` §5.4 rule 1: fixtures are committed files; nothing in the build or the harness consults a remote. |

**The regeneration problem.** Upstream may be unavailable: a tag may be
force-pushed, or the network may be gone. `docs/18` §5.4 resolves it in four
rules, and the one that matters here is rule 2: regeneration is a re-recording
from another recorded fixture. The recorder extends an existing `.bin` through
the port's own serialiser and stores the result as a **new** case with
`derived_from` naming its parent, so nobody reads it as upstream authority.
Rule 4 makes the same point for version bumps: a new `sources` entry and a
higher `schema`, never a rewrite of an existing case.

The port cannot do what `rust-corpus-oracle.sh:660-710` does. That code
re-resolves every fixture with `cargo metadata` at run time and fails on drift.
A port has no resolver, so **drift is impossible and verification is
impossible**. The substitute is to make the fixture set itself the authority:
the checksum proves the bytes are the committed bytes, and the recorded commit
proves which upstream tree they came from. A reviewer cannot re-derive the
value. That is a real loss, and the plan must state it rather than paper over
it.

### 3.5 Is the oracle route open to this port?

**No. It is closed, and it must stay closed.**

Four reasons, in order of weight.

1. **The build constraint forbids it.** The rule names `cargo` as a reference
   build, a golden-vector generator and a test oracle. `rust-corpus-oracle.sh`
   is all three at once: it runs `cargo fetch` (`:437`), `cargo run` (`:449`)
   and `cargo test` (`:555`, `:563`), and it writes two receipt files that the
   translated packages are compared against.
2. **The upstream tree leaves the project.** `local://zaccesskit-deps.md:81-84`
   records that the C ABI moved out of the main AccessKit repository on
   2024-07-21, so a port targets two repositories that version independently
   (core 0.25.1, C bindings 0.23.1). A differential oracle over a moving pair of
   upstream trees is a maintenance burden the port cannot carry.
3. **The runner's own infrastructure is unusable.** It requires a local
   non-network scratch outside the repository (`:160-313`), a reachable
   registry (`:436-440`), and seven staged copies of upstream crates. A port has
   none of these and must not acquire them.
4. **The value is in the expected values, not in the mechanism.** The expected
   values are upstream's published test vectors. Those can be transcribed once,
   by hand, into a committed `.bin` with a commit hash and a checksum. What
   cannot be transcribed is a *live* re-verification, and the port must not
   pretend to have one.

What remains open, and is the honest replacement: a **recorded conformance
suite** whose every case names the upstream commit, the upstream file inside
that commit, and the byte offset or test name the value came from. That is the
same table `test/rust-corpus-oracle/src/main.rs:17-26` already carries, for
seven crates, in a Rust file this port will never compile.

## 4. The diagnostic taxonomy

### 4.1 How the count was taken

The analyzer is the whole of `src/`. There is no single diagnostic registry
file. Diagnostics reach the user in one of two shapes: an identifier declared in
an explicit `error{…}` set, or an identifier returned from a function whose
error set is inferred. The second shape is the majority, and no single file
enumerates it.

The count therefore needs a stated method. Three numbers, each reproducible.

| Number | Method | Command |
|--------|--------|---------|
| **563** | Distinct `error.X` identifiers in non-test source, minus the five that are standard-library names (`FileNotFound`, `InvalidLiteral`, `OutOfMemory`, `PathAlreadyExists`, `Unsupported`). | `cd src && find . -name '*.zig' ! -name '*_test.zig' -print0 \| xargs -0 grep -hoE '\berror\.[A-Z][A-Za-z0-9_]+' \| sed 's/^error\.//' \| sort -u \| grep -vxF -f <std-error-names> \| grep -vxE 'FileNotFound\|InvalidLiteral\|OutOfMemory\|PathAlreadyExists\|Unsupported' \| wc -l` |
| **568** | The same scan before the standard-library subtraction. | Same command without the last `grep -vxE`. |
| **1142** | Distinct `error.X` identifiers across all of `src/`, test files included. | `cd src && grep -rhoE '\berror\.[A-Z][A-Za-z0-9_]+' --include='*.zig' . \| sed 's/^error\.//' \| sort -u \| wc -l` |

**The headline number for this document is 563.** It is the count of distinct
diagnostics a run of the tool can raise from production code.

Within those 563, **98 names are declared in an explicit error set**, across 13
sets holding 124 member slots in total. The remaining 465 are inferred. An
inferred error name is invisible to a reader of the error set, so the set is not
the taxonomy.

### 4.2 The 13 declared sets, enumerated

Each row was read from the file. Members are listed in source order.

| Set | File and line | Members | What it refuses |
|-----|---------------|---------|-----------------|
| `ValidationError` | `src/ir/validate.zig:16-57` | 40 | The IR cannot safely enter lowering. Structural integrity first (`InvalidEntityId`, `InvalidModuleId`, `InvalidNodeId`, `InvalidBodyTable`, `MissingBodyMetadata`, `BodyKindMismatch`), then reference integrity (`UnownedEntity`, `MissingUseMetadata`, `InvalidUseMetadata`), then **the four `Unsupported*` names that are the translator's real coverage boundary**: `UnsupportedExternalNominalType`, `UnsupportedExpression`, `UnsupportedPattern`, `UnsupportedType`. Plus `UnresolvedTypePath` and `InvalidTypePath` for a type path the validator cannot resolve. The set's own doc comment at `:78-81` states the intent: "A missing record, unresolved reference, or explicit unsupported marker is an error instead of an empty declaration or a skipped item." |
| `ValidationError` | `src/backend/zig/ast.zig:603-624` | 20 | A package or file is not complete enough for output. `MissingRootFile`, `DuplicateFilePath`, `InvalidFilePath`, `InvalidPackageName`, `DuplicateDependencyName`, `InvalidDependencyName`, `MissingFingerprint`, `DependencySourceUnavailable`, `MissingStdImport`, `EmptyTranslatedFunction`, `EmptyTranslatedBody`, `EmptyTranslatedContainer`, `UnnamedMatchSelector`, `MissingTypedLiteralIdentity`, `UnsupportedTranslationNode`, `DuplicateTraitDescriptorCase`, `AmbiguousMatchCapture`, `InvalidPointerAlignment`, `InvalidIdentifier`, `ElseCaptureWithoutElseBody`. The comment at `:600-602` bounds it: canonical serialization stays lossless, these errors apply only at output boundaries. |
| `IngestError` | `src/frontend/ingest.zig:46-66` | 19 | The manifest. Nine `CargoManifest*` names, `RootSourceNotFound`, `OutOfMemory`, and eight names that mirror `std.Io` (`DiskQuota`, `FileTooBig`, `DeviceBusy`, `Locked`, `AccessDenied`, `SystemResources`, `OperationAborted`, `Unexpected`). The `CargoManifest*` family exists because a translator reads a manifest it did not write, so every field it does not model is a refusal rather than a silent omission (`ingest.zig:127-136`, `:258-263`). |
| `TopologyError` | `src/ir/graph.zig:123-138` | 15 | The module tree. `NoCrate`, `MissingRootModule`, `InvalidEntityId`, `InvalidModuleId`, `InvalidModuleEntity`, `InvalidParent`, `InvalidResolvedEntity`, `UnknownModuleItem`, `MissingModuleItem`, `DuplicateModuleItem`, `InvalidModuleItemParent`, `MissingUseMetadata`, `InvalidUseMetadata`, `InvalidDependency`, `UnownedEntity`. The first 14 of these 15 also appear in `ir/validate.zig`, so the two sets overlap by design: the graph validates as it is built, the IR validates before lowering. |
| `NodeWalkError` | `src/ir/exprs.zig:805-811` | 5 | A body table reference. `InvalidExprRef`, `InvalidStatementRef`, `InvalidPatternRef`, `InvalidTypeRef`, `InvalidTypeTraversal`. |
| `FingerprintError` | `src/driver/pipeline.zig:37-43` | 5 | The fingerprint probe produced no usable value. `ProbeNonZero`, `ProbeTerminated`, `ProbeOutputUnrecognized`, `ProbeOutputAmbiguous`, `ManifestFingerprintMissing`. |
| `PromotionError` | `src/backend/zig/package.zig:501-507` | 5 | Promotion. `GeneratedPackageBuildFailed`, `InvalidOutputDirectory`, `InvalidGeneratedManifest`, `InvalidGeneratedSource`, `StagingPathExhausted`. |
| `ConstLowerError` | `src/frontend/cst.zig:3811-3818` | 3, plus `OutOfMemory` | A `const` initialiser. `InvalidConstArray`, `InvalidLiteral`, `UnsupportedConstInitializer`, `InvalidTypeTraversal`. Declared as `std.mem.Allocator.Error \|\| error{…}`, so `OutOfMemory` is part of the set by construction. |
| `DeclarationTypeError` | `src/frontend/cst.zig:1234-1238` | 3 | A nominal type in a declaration. `UnresolvedNominalType`, `InvalidNominalType`, `OutOfMemory`. |
| `MacroMatchError` | `src/frontend/expand.zig:1445-1449` | 3 | A macro matcher. `OutOfMemory`, `FragmentMismatch`, `MacroRepetitionDepthExceeded`. |
| `CrossModuleScanError` | `src/backend/zig/lower.zig:3287-3291` | 3 | The cross-module visibility scan. `OutOfMemory`, `ModuleHierarchyCycle`, `MissingEntityId`. |
| `SelfRewriteError` | `src/ir/types.zig:179` | 2 | A `Self` substitution. `OutOfMemory`, `InvalidTypeTraversal`. |
| `WireCompatibilityError` | `src/driver/pipeline.zig:19-21` | 1 | The wire version. `UnsupportedWireVersion`. |

Sum of member slots: **124**. Distinct names after de-duplication across the
13 sets: **98**. The 26-name difference is `OutOfMemory` (7 sets), `InvalidTypeTraversal`
(3), `InvalidEntityId` (2), `MissingRootModule` (2), `NoCrate` (2), `MissingEntityId`
(2), `MissingEntityReference`-adjacent names, and the other repeats.

**A 13th name exists that is not in any set.** `UnsupportedAllocatingFormatter`
appears in `README.md:302` and in the pinned refusal table at `build.zig:530`,
but is not declared anywhere in `src/`. It is raised through an inferred set.
That is the clearest single illustration of why the declared sets are not the
taxonomy: a reader who read all 124 declared members would still miss a
diagnostic the README treats as part of the public contract.

### 4.3 Severity

Zig error sets carry no severity. The pipeline has one failure channel:
`src/main.zig:9-17` catches any error, logs `translate-rust failed: <name>`,
adds a second line for `UnsupportedExpression` alone (`:11-15`, reading the
thread-local reason buffer at `ir/validate.zig:66-75`), and returns the error.
The process exit status is non-zero.

So **all 563 are fatal, with one partial exception.** An `UnsupportedExpression`
carries a reason string through `ir/validate.zig:71-75`, and that reason is the
only diagnostic in the tree with a human-readable payload. The reason is
**copied, not borrowed**, into a 256-byte thread-local buffer (`:66-67`), because
the IR it names lives in an arena the failing translation releases before the
caller reads the diagnosis back. That is a design decision worth copying: a
diagnostic whose payload points into freed memory is a use-after-free that only
shows up under a failing allocator test.

Two severity vocabularies exist and neither is the pipeline's.

| Vocabulary | Where | Values |
|-----------|-------|--------|
| Ownership markers | `src/ir/ownership.zig:133-140` | `comment`, `assert_unreachable`, `redesign_required`. Only two instances exist, both in tests (`:286-289`, `:296-299`). This is a design record, not live behaviour: the note at `notes/design/architecture/runtime-traits.md` is marked historical, and no emission path from `src/` reaches this enum. `[INFERENCE]` |
| Upstream macro reasons | `src/frontend/cst.zig:106-110` | `dependency_source_unavailable`, `build_script_not_executed`, `source_unavailable`. Attached to an `UnsupportedMacro` record (`:112-116`) that the pipeline turns into a named error. `build_script_not_executed` is how the translator says "I refuse to run `cargo`", and it is a refusal, not a severity. |

### 4.4 Where the 563 live

| Area | Distinct diagnostics raised anywhere in that area |
|------|------------------------------------------------------|
| `src/frontend/` | 374 |
| `src/backend/zig/` | 143 |
| `src/ir/` | 47 |
| `src/model/` (legacy sidecar inventory only) | 22 |
| `src/main.zig` (CLI argument errors) | 11 |
| `src/driver/` | 10 |
| `src/tree_sitter.zig` | 1 |

The column sums to 608, not 563. Names are raised in more than one area:
`UnresolvedNominalType` is declared in `ir/validate.zig` and raised from
`frontend/ts_ext.zig`; `InvalidTypeTraversal` appears in three declared sets.
The 563 is the count of distinct names, not of raise sites.

Three files carry most of the weight:

| File | Distinct | Why |
|------|----------|-----|
| `src/frontend/ts_ext.zig` | 242 | The tree-sitter CST extractor. It names the shape it did not expect: `ExpectedFunctionBlock` (24 sites), `MalformedCst` (101), `InvalidType` (14), `UnresolvedNominalType` (13), and a long tail of one-site names. |
| `src/backend/zig/lower.zig` | 97 | The lowering pass. `UnsupportedAssociatedTypeProjection`, `UnsupportedGenericTraitImpl`, `UnsupportedGenericTraitAlias`, `UnsupportedExternalUse`, `UnsupportedEntityKind`, `UnsupportedTypeAliasTarget`, `UnsupportedIteratorAdapter`, `UnsupportedDynamicTrait`. |
| `src/frontend/pipeline.zig` | 92 | The orchestration pass, including the incomplete-graph errors the `--dump` modes raise (`main.zig:423`, `:901`). |

`src/model/` holds 23 more. It is the legacy sidecar decoder, reachable only
through `--dump model`, which `README.md:42-43` says is "diagnostic inventory
only" and "never accepted as translation input". A port that has no legacy
format has no reason to keep those 23.

### 4.5 Which of the 563 a hand port must check for by hand

All of them, and no analyzer will run over hand-written Zig. That is the honest
answer, so the useful question is which **families** transfer, and what a port
author substitutes for the machine check.

#### 4.5.1 Families that do not transfer

| Family | Count | Why it is translator-only |
|--------|-------|---------------------------|
| `Expected*` | 211 | Names the CST node shape the extractor wanted and did not find. A tree-sitter parser produces a CST; a hand-written port has no CST. |
| `Malformed*` | 14 | Same. `MalformedCst` at 101 sites is a parse failure. |
| `CargoManifest*` | 9 | Names a field of `Cargo.toml`. A port reads no manifest; `local://zaccesskit-deps.md` records the pins in a `.zon` and in `devenv.nix`. |
| `Probe*`, `FingerprintProbe*`, `ManifestFingerprintMissing`, `StagingPathExhausted`, `GeneratedPackageBuildFailed` | 10 | Section 1.5. Promotion machinery. A hand port publishes nothing. |
| `model/*` names | 23 | Legacy sidecar inventory. `README.md:42-43`. |

That is 267 of 563. The remaining 296 are in principle relevant and none of
them is checked by a machine for a hand port.

#### 4.5.2 Families that transfer, with the substitute

The `Unsupported*`, `Unresolved*`, `Unknown*`, `Ambiguous*`, `Unnamed*` and
`Duplicate*` families are the translator's coverage boundary, and a port has
the same boundary: an upstream construct with no honest Zig equivalent. 79 of
the 563 sit in these families.

| Substitute | What it does | Which house rule |
|-----------|--------------|------------------|
| A **coverage table** naming every upstream item and its Zig counterpart or its named refusal | Replaces the analyzer's discovery. `README.md:292-308` is the model: five fixtures with their exact typed error, and the note that a fixture leaves the table by working, never by deletion. | No backwards compatibility, no shims: a refusal must be named, not silent. |
| A **comptime exhaustiveness sweep** over every enumerable domain the port models | `inline for` over `@typeInfo(ErrorSet)`, over every enum field, over every wire variant. Exercises every error path at compile time. | `ozai/AGENTS.md:79-81`. |
| A **refusal is a value, not a string** | A port that refuses returns a named error from a declared set, so `inline for` over the set can assert each arm is reachable and each is documented. | `ozai/AGENTS.md:76-78`. |
| **Fail-N allocator injection at every boundary** | The translator's `cleanupPromotion` is tested by forcing a failure at each attachment point. A port's equivalent is `std.testing.checkAllAllocationFailures` at every function that owns memory. | `ozai/AGENTS.md:73-75`. |
| A **golden or fixture diff** for every change | Section 2. A refusal that changes which error it returns is a build failure, because the pinned name moved. | `ozai/AGENTS.md:89-91`. |

#### 4.5.3 The specific diagnostics a port's first modules will hit

Ranked by how likely an AccessKit module is to produce them, with the
translator's own name where one exists. Every mapping below is `[INFERENCE]`
unless a citation is given.

| Port situation | Nearest translator diagnostic | Source |
|----------------|-----------------------------|--------|
| An AT-SPI interface method has no Zig equivalent | `UnsupportedStandardMethod` | `backend/zig/lower.zig:10034` in `lower_test.zig` |
| An upstream trait is not `comptime`-duck-typed | `UnsupportedDynamicTrait` | `backend/zig/strategies/default.zig:77` |
| An upstream type is outside the Zig type model | `UnsupportedExternalNominalType` | `strategies/default.zig:137` |
| An opaque upstream handle needs a layout rule | `DependencySourceUnavailable` | `backend/zig/ast.zig:611` |
| An upstream macro produces a construct the port does not model | `ExternalMacroSourceUnavailable`, `BuildScriptArtifactUnavailable` | `README.md:283-286` |
| A byte layout cannot be reproduced | `InvalidPointerAlignment`, `InvalidIdentifier` | `backend/zig/ast.zig:621-622` |
| A tagged union needs a discriminant the port does not emit | `UnnamedMatchSelector`, `DuplicateTraitDescriptorCase`, `AmbiguousMatchCapture` | `backend/zig/ast.zig:616`, `:619-620` |
| A callback crosses an opaque handle | No translator equivalent. `docs/22-zig-build-surface.md:663-666` records this as a fifth case the port will hit anyway, and it is an ABI-document rule, not a code rule. | — |

The last row is the one that matters most for `docs/31-c-abi-design.md`: the
translator never had to state a layout rule across an opaque handle, because
every aggregate it moved was fully typed on both sides. An AccessKit port does.

## 5. The pinned toolchain runner

### 5.1 What `tools/zig-pinned.sh` solves

The script's header states the problem at `tools/zig-pinned.sh:4-17` and names
three host facts. All three fail quietly rather than loudly, which is what makes
a runner worth having.

| # | Host fact | Consequence of ignoring it | Where the script answers it |
|---|-----------|----------------------------|----------------------------|
| 1 | `zig` on PATH is the **anyzig shim**. It re-resolves and re-downloads the toolchain on every invocation. | Every build pays a full fetch. | `:47-72` walks `~/.cache/zig/p` newest-first by mtime, keeps the first candidate that actually runs, and bypasses the shim. `R2Z_ZIG` overrides (`:51-52`). |
| 2 | The repository is on an **NFSv3 mount**. Zig's atomic file write uses `renameat2(RENAME_EXCHANGE)`, which NFSv3 does not implement. | Any directory Zig writes into atomically on the mount dies with `EINVAL` and a "programmer bug caused syscall error" panic. That covers both cache directories **and** the install prefix. | `:76-125` moves `--cache-dir` and `--global-cache-dir` to local disk (`:151-152`) and finds the scratch root by comparing `stat -f -c %T` against the repository's own filesystem (`:103-119`), refusing `/tmp` and `/var/tmp` on HU hosts (`:89-94`). |
| 3 | **Concurrent `zig build` runs sharing one cache directory corrupt it and abort.** Agents and humans build in parallel here. | Two builds, one cache, an abort with no useful message. | `:142-180` takes an exclusive `flock` on a file descriptor (`exec 9>`, `flock -x 9`) around the whole invocation. `R2Z_NO_LOCK=1` bypasses it (`:167-170`). |

Two further details are not in the header and matter more than the header.

| Detail | Where | Why |
|--------|-------|-----|
| The real toolchain goes **first on PATH** for child builds. | `:156-161` | The build spawns child `zig` processes. Package promotion runs `zig build test` on generated packages, and the e2e program spawns `zig test` and `zig build`. A bare `zig` in a child has no `build.zig.zon` to resolve a version from, so the shim exits 1 silently. |
| `./zig-out` must be a **real directory**, not a symlink. | `:128-140` | An earlier version symlinked `zig-out` into scratch. That breaks the test suite: `std.Io.Dir.createDirPath` refuses a path component that is a symlink, so `createDirPath(io, "zig-out")` fails with `NotDir`. The script removes such a symlink and creates a real directory. The install step only copies files, so it does not write atomically and is safe on the mount. |

The script forwards every argument to `zig build` unchanged (`:148-154`), so its
call sites read like `zig build` call sites (`README.md:344-396`).

`AGENTS.md:24-32` records the first two facts in prose and says both "fail
quietly rather than loudly". `AGENTS.md:45-52` records the override variables
and the 8 GiB floor on the default cache root.

### 5.2 Does `zaccesskit` need an equivalent?

Measured against `zaccesskit/devenv.nix`, `zaccesskit/.envrc` and `zig-gate`.

#### What already exists here

| Need | Where it is met | Evidence |
|------|-----------------|----------|
| Caches off NFS | `devenv.nix:14-24` resolves `cacheRoot` from `ZACCESKIT_CACHE_ROOT`, then `XDG_CACHE_HOME`, then `$HOME/.cache`. `devenv.nix:39` sets `ZIG_GLOBAL_CACHE_DIR`. `devenv.nix:56-66` symlinks `.zig-cache` and `zig-pkg` to local disk and prints a message instead of silently moving a populated directory. | `devenv.nix:36-39`, `:49-67`. `host-scratch.sh:62-63` exports `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR` before `devenv.nix` narrows them. |
| Gate caches per project | `devenv.nix:43-44` sets `GATE_CACHE_DIR` and `GATE_CROSS_OUTPUT`. The reason is a lock, not a style rule: `devenv.nix:36-38` records that Zig flocks every global-cache manifest, so a build that dies holding one wedges every later build wanting the same cache. | Enforced by the gate too: `zig-gate:338-344` refuses a `GATE_CACHE_DIR` or `GATE_GLOBAL_CACHE_DIR` that is not on an approved physical volume, before creating anything. |
| Refuse a bad scratch path | `.envrc:7-9` sources `~/.dev-env.sh`, which sources `~/.local/lib/host-scratch.sh` (`.dev-env.sh:25-26`). | `host-scratch.sh:55-63` exports `HOST_SCRATCH_ROOT`, `TMPDIR`, `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR`. |
| Source checks scoped | `devenv.nix:47` sets `GATE_EXCLUDE` for the five cache and VCS directories. | `zig-gate:59-60` makes `GATE_EXCLUDE` replace the default rather than extend it, so the project must list all five itself. |
| `zig-out` stays a real directory | Met, and explicitly. | `zig-gate:415` excludes `./zig-out` and `zig-gate:413` excludes `./zig-pkg` from the same source list, both treating them as real directories in the project root. `zig-gate:795` excludes `zig-pkg` from coverage. `docs/00-house-and-environment.md` §4.3 names only `.zig-cache` and `zig-pkg` as the symlink targets. |

#### What is not met here

| Need | Status in `zaccesskit` | Evidence |
|------|------------------------|----------|
| Resolve a real toolchain, bypass the shim | **Not met.** `zig` on PATH here is the anyzig shim. Running `zig version` in `~/zaccesskit` prints three `anyzig:` lines and reports `0.16.0` from `/tmp/cache/zaccesskit/global/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ`. With a warm cache the resolution took 0.171 s, so the cost is small on this host. | `zig-gate:149` is `ZIG="${ZIG:-zig}"`. The gate therefore runs the shim for every stage, and `devenv.nix` sets no `ZIG`. `zig-gate:44` documents the override: "Pin it (ZIG=/path/to/zig)". |
| Serialize concurrent builds | **Not met.** `zig-gate` holds no lock: a grep for `flock` and for `lock` across all 823 lines returns nothing. `devenv.nix` sets no lock either. | `cross-test.profile.sh:51-52` sets `CROSS_JOBS=2` and `CROSS_BUILD_JOBS=2`, so two Zig builds do run at once. `tools/zig-pinned.sh:14-16` and `tools/test-generated-corpus.sh:139-142` both record that concurrent builds over one cache abort. |

#### Verdict: complementary, not overlapping, not conflicting

The two setups are **complementary**. `devenv.nix` already handles the largest
of the three host facts, the NFS cache, and it does it with a better mechanism:
a Nix expression sets the cache variables for every process in the shell, while
a wrapper script only affects processes that remember to call it.
`zig-pinned.sh` handles the two `devenv.nix` does not: toolchain resolution and
serialization.

There is one **conflict**, and it is about ordering. `zig-pinned.sh:156-161`
puts the resolved toolchain first on `PATH`. `devenv.nix` deliberately does not
touch `PATH`. A shell with both gets the runner's `PATH` prefix; a shell with
only the devenv environment gets the shim. The plan must pick one. The runner
is the better place, because the shim's dangerous failure mode is a silent exit
1 in a **child** build with no `build.zig.zon` to resolve a version from
(`build.zig:17-19`), and a shell-level `PATH` edit is the only thing that
reaches a child.

There is one **overlap**: the cache relocation. Both move caches off NFS.
Keeping `devenv.nix` as the single owner is correct, and the runner is not
copied.

#### The recommendation, stated once

`zaccesskit` does **not** need `tools/zig-pinned.sh` copied. It needs two
things the runner happens to also carry.

1. **`zig-gate` run with `ZIG` set to a real cached toolchain.** The gate
   already honours the variable (`zig-gate:149`, documented at `:44`), and
   `devenv.nix` already has a task mechanism that sets environment variables
   (`devenv.nix:71-72` runs `zig-gate` as `gate:zaccesskit`). Setting `ZIG` in
   `devenv.nix` reaches every stage and every child without a wrapper.
2. **A lock around gate runs that can overlap.** `devenv shell -- gate` and
   `devenv shell -- run test` both invoke `zig-gate` (`devenv.nix:71-77`), and an
   agent plus a human can run them at once. An exclusive `flock` on a file under
   `${cacheRoot}` costs one line and removes a class of abort.

The rest of `zig-pinned.sh` is a workaround for a checkout this project does
not have: `tools/zig-pinned.sh:9-13` moves the install prefix off NFS, and this
project's `zig-out` is small enough to stay on the mount. Copying that would be
solving the same problem twice.

## 6. The hand-written C workaround

### 6.1 What `abi-fix-draft/tree_sitter.c` is for

The file is 63 lines and holds 12 wrapper functions. Its own header states the
problem, at `abi-fix-draft/tree_sitter.c:3-7`:

> TSNode is a 32-byte aggregate that the tree-sitter API passes and returns by
> value. Zig and Clang disagree about its passing convention on some targets
> (ARM, ARM_BE, Hexagon, LoongArch, MIPS64), so every by-value TSNode call is
> confined to this C file, compiled by the same compiler as the runtime; only
> pointers and scalars cross the Zig/C boundary.

The rule the file enforces: **only pointers and scalars cross.**

| Wrapper | Signature shape |
|---------|-----------------|
| `r2z_ts_tree_root_node` | `(const TSTree *, TSNode *out)` → `void` |
| `r2z_ts_node_type` | `(const TSNode *)` → `const char *` |
| `r2z_ts_node_start_byte` / `end_byte` / `named_child_count` | `(const TSNode *)` → `uint32_t` |
| `r2z_ts_node_is_named` / `has_error` | `(const TSNode *)` → `bool` |
| `r2z_ts_node_child` / `named_child` / `child_by_field_name` / `prev_named_sibling` / `next_named_sibling` | `(const TSNode *, uint32_t, TSNode *out)` → `bool`, where `false` means the node was null (`:39`, `:44`, `:49`, `:54`, `:59`) |

`TSNode` appears exactly twice per wrapper: once behind a pointer, once as an
out-parameter. It is never a parameter by value and never a return value.

The build wiring is two lines, at `build.zig:56-58`:

```zig
ts_mod.addIncludePath(tree_sitter.path("lib/include"));
ts_mod.addCSourceFile(.{ .file = b.path("src/tree_sitter.c"), .flags = &.{"-std=c11"} });
ts_mod.linkLibrary(tree_sitter.artifact("tree-sitter"));
```

and the Zig side declares thirteen `extern fn … callconv(.c)` at
`src/tree_sitter.zig:118-130`, all pointer-in, pointer-out.

The live file is `src/tree_sitter.c`, not the draft. A `diff` of the two shows
three differences, and the draft is the one with the fuller comment: the live
file carries the same 12 wrappers plus `r2z_ts_node_field_name_for_named_child`
(`src/tree_sitter.c:45-47`), a shorter comment at `:3-4`, and no trailing
newline in the draft. The draft is a record of the reasoning; the live file is
the shipped code.

### 6.2 What it teaches about writing C a Zig build can consume

Four lessons, each with the evidence that makes it a rule rather than a hint.

| Lesson | Evidence |
|--------|----------|
| **An aggregate must not cross the boundary by value.** The disagreement is between two compilers' opinions of the same ABI, so no Zig-side declaration can fix it. Only removing the by-value case can. | `abi-fix-draft/tree_sitter.c:3-7`. Five named targets. |
| **The shim must be compiled by the same compiler as the library it wraps.** Two compilers disagreeing is the whole problem, so one shim compiled by a second compiler would reintroduce it. | `build.zig:57-58`: the C source file and the linked tree-sitter artifact are attached to the same module. |
| **An out-parameter plus a `bool` beats a by-value return.** The caller learns both "did this succeed" and "here is the value", with no aggregate in any parameter list. | `abi-fix-draft/tree_sitter.c:37-45` for the two child accessors. |
| **A null result is a value, not an error.** `ts_node_child` returns a null `TSNode` on an out-of-range index. The shim converts that to `false` at the boundary, so the Zig side writes `if (!r2z_ts_node_child(self, i, &found)) return null;` (`src/tree_sitter.zig:78`). | Same lines. |

A fifth lesson is recorded elsewhere in the same tree and is worth more to a
port than any of the four.

**A generated C file is edited only through its generator.**
`README.md:475-482` records that `vendor/tree-sitter-rust/scanner.c` is
hand-written while `parser.c` and `tree_sitter/parser.h` are generated, and that
the generated files declare
`tree_sitter_rust_external_scanner_create` with a `(void)` parameter list.
Writing it as a legacy empty list `()` still compiles, but it is a different C
function type, and optimized builds trap inside it on clang's
`-fsanitize=function` mismatch trap. `.local/finish/archived-docs/ARCHIVE-NOTES.txt`
records that an earlier investigation blamed a "Zig 0.16.0 miscompilation" for
this and then withdrew the classification: the failures were fixture defects and
the crash was the C function-type mismatch.

The rule for a port: **a hand-written C shim is fine; a hand-edited generated C
file is not.** If the shim must be generated, its generator is part of the port
and its output is a golden file.

### 6.3 Does an AccessKit port need an equivalent, and for which dependency?

**Yes, for one dependency: the C ABI surface itself.**

The upstream header passes and returns aggregates by value in at least 40
places. Read from `accesskit-c/include/accesskit.h`:

| Function | Line | Aggregate passed or returned by value | Size |
|----------|------|---------------------------------------|------|
| `accesskit_affine_translate(struct accesskit_vec2 p)` | `:2425` | `vec2` in, `affine` out | 16 in, 48 out |
| `accesskit_affine_map_unit_square(struct accesskit_rect rect)` | `:2427-2428` | `rect` in | 32 |
| `accesskit_affine_mul(struct accesskit_affine a, struct accesskit_affine b)` | `:2442-2443` | two `affine` in | 96 |
| `accesskit_affine_determinant(struct accesskit_affine affine)` | `:1330` | `affine` in | 48 |
| `accesskit_affine_transform_point(struct accesskit_affine affine, struct accesskit_point point)` | `:1333`, `:1336` | both | 64 |
| `accesskit_point_add_vec2(struct accesskit_point point, struct accesskit_vec2 vec)` | `:2450-2451` | both | 32 |
| `accesskit_point_sub_point(struct accesskit_point a, struct accesskit_point b)` | `:1356-1357` | both | 32 |
| `accesskit_rect_with_origin(struct accesskit_rect rect, struct accesskit_point origin)` | `:2468-2469` | both | 48 |
| `accesskit_tree_id` setters and getters | `:2404`, `:1304` | `tree_id` | 16 |
| `accesskit_opt_lresult` | `:1131-1134` | `bool` plus `LRESULT` | pointer-width plus 1 |

The aggregate definitions, for the size column:

| Type | Line | Layout |
|------|------|--------|
| `accesskit_tree_id` | `:707-709` | `uint8_t bytes[16]` |
| `accesskit_affine` | `:934-936` | `double _0[6]` |
| `accesskit_rect` | `:941-958` | four `double`, at `:945`, `:949`, `:953` and `:957`, 32 bytes |
| `accesskit_point` | `:998-1007` | two `double`, at `:1002` and `:1006`, 16 bytes |
| `accesskit_vec2` | `:1079-1088` | two `double`, at `:1083` and `:1087`, 16 bytes |
| `accesskit_size` | `:1093-1102` | two `double`, at `:1097` and `:1101`, 16 bytes |
| `accesskit_action_data` | `:1025-1053` | a tag plus a union whose arms are `int32_t`, `char *`, `double`, two `uint8_t`, two `accesskit_point` and one `accesskit_text_selection` |
| `accesskit_opt_lresult` | `:1131-1134` | `bool` plus `LRESULT`, which is platform-defined |

So the port's C ABI needs the same treatment, and the concrete dependency is
**the AccessKit C header**, not an external library.

| Why this is the port's own header and not a dependency | Evidence |
|-------------------------------------------------------|----------|
| The port does not link `libaccesskit`. It implements the ABI. | The port philosophy forbids linking an existing `libaccesskit`. |
| The header is the port's product for C consumers. | `docs/22-zig-build-surface.md:472` records that `addIncludePath` exists so a consumer that links the C artifact finds `accesskit.h` without reaching into the tree. `docs/22-zig-build-surface.md:690-691` records that the port ships a checked-in header and installs it, because `-femit-h` is broken on 0.16.0. |
| The four documented shim triggers do not cover this case. | `docs/22-zig-build-surface.md:621-666` lists a variadic export, a bitfield, a compile-time macro and an unrenderable macro. **Aggregate passing convention is a fifth, and it is not on that list.** `[INFERENCE]`, from the header reading above. |

The shape of the fix is the one `abi-fix-draft/tree_sitter.c` demonstrates,
stated for the port's own surface.

1. The checked-in `accesskit.h` keeps its upstream by-value signatures. A C
   consumer compiles against upstream's header, so changing the header changes
   the ABI.
2. The port's Zig side declares **no** `extern fn` for any of those 40
   functions. It calls only the pointer-shaped ones directly.
3. `src/c_abi/` holds one C file per aggregate family, with a wrapper per
   upstream function: out-parameter for the aggregate, scalars for everything
   else. Compiled by `b.addCSourceFiles` with an explicit `-std=c11`
   (`docs/22-zig-build-surface.md:1530-1531` is the pattern), linked into the
   same module as the Zig side.
4. `docs/31-c-abi-design.md` states the layout rule as a test, not a comment.
   `cross-test.profile.sh:29-33` names `powerpc64-linux` as the row that proves
   the C ABI structs are byte-correct.

Item 4 is the one `translate-rust` cannot teach, and the reason is in section
4.5.3: the translator had no opaque handle crossing a callback. The port does
(`docs/22-zig-build-surface.md:663-666`), and an opaque handle has no layout the
compiler can check. That rule has to be written down and tested by hand.

## 7. The corpus loop

### 7.1 How the translator learns that a rule is wrong

Six steps. Each with its `path:line`.

**Step 1 — the corpus exists.** `test/crates/` holds 19 crate roots. A `find` of
the directory returns 19 entries: `adler`, `allocating-fmt`, `atoi`, `compat`,
`crc16`, `differential`, `fletcher`, `fnv`, `hex`, `itoa`, `leb128`, `mini`,
`multimod`, `percent-encoding`, `seahash`, `siphasher`, `syn`, `wyhash`,
`xxhash-rust`.

Ten of them translate end to end, and `README.md:149-151` names them: `mini`,
`fnv`, `compat`, `wyhash`, `adler`, `multimod`, `xxhash-rust`, `hex`,
`leb128` and `percent-encoding`. Three of those ten are byte-identical to their
published crates.io archives (`README.md:328-331`).

**Step 2 — the discovered packages are declared, not scanned.** The rows table
is `test/generated_corpus.zig:149-375`, 22 rows. Each row names a `kind`
(`:70-79`: `source`, `wire_fixture`, `wire_canonical`, `serialized_ast`), an
`id`, a `crate_dir` or a `fixture`, a `Width` (`:84`: `any`, `w32`, `w64`), an
explicit feature list, and a `has_api` flag with a one-line `note`. The notes
say why a row is shaped as it is. Two examples:

```zig
// test/generated_corpus.zig:220-221
.has_api = false,
.note = "manifest declares no default feature, so the closure is empty and no algorithm module survives",
```

```zig
// test/generated_corpus.zig:240-241
.has_api = true,
.note = "default = [\"std\"] pulls in alloc; FromHex for fixed arrays is gated on target_pointer_width, so this is the 32-bit half of the pair",
```

**Step 3 — every row goes through the real driver.** `generateRow` at
`test/generated_corpus.zig:548-579` dispatches on `kind`:

| Kind | Call | Line |
|------|------|------|
| `source` | `driver.translate` or `driver.translateWithOptions` | `:585`, `:587` |
| `wire_fixture` | `driver.translateWireJson` | `:558` |
| `wire_canonical` | write a fresh v6 wire, then `driver.translateWireJson` | `:604-633` |
| `serialized_ast` | encode to Zig AST JSON, decode back, then `driver.promotePackage` | `:638-660` |

Every one of those ends in promotion. The file's own header states it
(`test/generated_corpus.zig:2-7`): "each row goes through the real driver, and a
row is only present because `driver.promotePackage` published it after its
manifest, its sources and its own `zig build test` passed."

**Step 4 — the gate fails, and the failure is reported per row.** A row that
fails is recorded and the run continues, so one invocation reports every red
scenario (`test/generated_corpus.zig:490-509`, and the same rule stated at
`:17`). If any row failed, no aggregate is written and the run returns
`error.CorpusRowsFailed` (`:515-525`).

Inside promotion, the failure surfaces as `error.GeneratedPackageBuildFailed`
after the captured compiler output is printed (`package.zig:939-946`,
`printBuildFailure` at `:865-879`), and the staging tree is deleted
(`cleanupPromotion`, `:885-893`). So a wrong rule leaves **no output at all**,
which is what makes "a row is present only because it passed" true rather than
aspirational.

**Step 5 — the rule changes.** This is the only step with no fixed `path:line`,
because it is wherever the rule lives. Examples read in this wave:

| Rule | Where | Symptom that pointed at it |
|------|-------|----------------------------|
| `HashMap`/`HashSet` must keep the source hasher, not become `std.AutoHashMap` | `backend/zig/strategies/default.zig:152-156`, and again at `:354-356` | Swapping the hasher for Wyhash "for the `fnv` crate, the single reason it exists" — a crate that compiles and computes the wrong value. |
| An external nominal type at a generic boundary carries no resolved metadata | `backend/zig/strategies/default.zig:137` | `UnsupportedExternalNominalType`, now the pinned refusal for `atoi` (`README.md:301`). |
| A `Display` body that needs an allocator cannot use the native `format` hook | `README.md:97-101` | `UnsupportedAllocatingFormatter`, the pinned refusal for `allocating-fmt` (`build.zig:530`). |
| A tuple literal's element row is private to that literal | `README.md:254-263` | Wrong output for valid Rust, in `compat`, with no compile error. |

**Step 6 — the goldens change, and the diff is the evidence.**
`zig build generate-<fixture>-golden` rewrites `test/golden/zig_src/<fixture>/**`
from validated canonical IR (`build.zig:218-342`, one step per fixture;
`README.md:504-506`). The next `zig build test` compares the new bytes against
the new files and passes. The review is the diff, not the green run.

The loop closes because of the orphan guard. A fixture nobody reads cannot
carry the evidence: `test/golden_test.zig:806-810` records that
`test/golden/zig_src/hex/**` "sat unread while the emitted text changed
underneath it", and `:811-857` now fails the build when that happens again.

### 7.2 The matrix stage

Promotion is not the last stage. `tools/test-generated-corpus.sh:8-17` names
two stages that cannot be one build step:

| Stage | What runs | What it proves |
|-------|-----------|----------------|
| Host | `tools/zig-pinned.sh generated-corpus -- --output <dir>`, which runs `test/generated_corpus.zig` (`:179-180`) | Every row promoted. Every promoted package's contents read back, never assumed (`inspectPackage` at `test/generated_corpus.zig:664-698`, and the comment at `:121`: "Facts read back out of a promoted package, never assumed"). |
| Matrix | `cross-test` over the generated aggregate, `CROSS_BUILD_STEP=test`, all 53 Tier 1/2 Zig 0.16.0 targets (`:195-206`, `:201`) | The aggregate's pure `test` graph compiles and runs on 53 targets. The aggregate's build script "compiles and runs test artifacts and does nothing else, so a foreign target row never runs a host compiler" (`:15-17`). |

Two properties of that second stage are worth naming. The producer **refuses a
pre-existing output directory** (`test-generated-corpus.zig:783-837`, and
`tools/test-generated-corpus.sh:170-174`), and the aggregate's cross-test
profile **replaces `cleanup`** so the per-run cache and state survive for
inspection (`test/generated_corpus.zig:1520-1524`). Neither deletes anything.

### 7.3 The hand-port equivalent

A port has no corpus of crates to translate and no matrix of generated packages.
It has modules, and each module's coverage is argued rather than swept. The
question to answer is the same: **how does the author learn a rule is wrong?**

| Translator step | Hand-port equivalent | The recorded artefact |
|-----------------|---------------------|----------------------|
| 1. The corpus | A coverage table. One row per upstream item: the upstream name, the upstream `path:line`, the Zig counterpart or the named refusal, and the test that proves it. `README.md:292-308` is the model, including the note that a row leaves the table by working, never by deletion. | The table itself, in `docs/30-port-design.md` or `docs/31-c-abi-design.md`. |
| 2. Discovered packages | The module list. Every `src/` file the port claims, named once. | The `check-sources` walk already required by `build.zig:777-800` finds a `src/` file no test root reaches; the port needs that guard because it is the only thing standing in for the rows table. |
| 3. Every item goes through the real code | Every coverage-table row has a test. A row with no test is a row that will not fail. | The test file named in the row. |
| 4. The gate fails, per row | One failing test names the defect. `docs/18-testing-strategy.md` §8 requires it: "Every item here passes on a stub: every one executes a body and compares a result." | The failure message. |
| 5. The rule changes | Edit the module, then re-run. | `jj st`, per `ozai/AGENTS.md:98-99`. |
| 6. The goldens change | The fixture set changes. A byte that the port now emits differently becomes a **new** case, never a rewritten one (`docs/18-testing-strategy.md` §5.4 rule 4). | `test/fixtures/manifest.json` plus the `.bin` and `.meta.json` pair. |

The step with no substitute is step 2. The translator's rows table is
machine-readable and 22 rows long, and it is checked: a row that stops
translating fails the build, and a fixture no step names fails the orphan guard.
A port's coverage table is prose. Nothing checks it. Two mitigations, both
already required elsewhere in this project:

1. **The dead-source guard.** `build.zig:777-800` walks `src/**/*.zig` and fails
   on any file no test root reaches. Its comment at `:778-782` gives the reason:
   a file outside every import graph "is never compiled at all: its tests do not
   run, and its type errors stay invisible".
2. **The coverage table names its own test.** A row whose test file is deleted
   then fails to compile, which is the same orphan signal as
   `test/golden_test.zig:811-857`.

### 7.4 The one asymmetry worth stating

The translator's corpus is **adversarial by construction**: 19 crates, most of
them real published libraries with their own tests, chosen because they break
the translator in different ways. `README.md:320-326` says plainly that the
list is a list of fixtures, not a coverage rate, and that wider sweeps stopped
at a typed error.

A port has no equivalent adversarial corpus. Its nearest is the platform: a real
AT-SPI bus, a real windowing system, a real desktop. That is why section 6.3
ends on a layout rule nobody's compiler can check, and why
`docs/18-testing-strategy.md` §6 spends 100 lines on scripted platforms and
fake D-Bus peers. **The corpus is the part a hand port cannot copy, and the
substitute is the platform simulation, not a test suite.**

## 8. What to copy

Eight mechanisms to adopt verbatim, and eight to leave behind. Each carries its
defence.

### 8.1 Adopt

**1. Validate before writing anything.**
`src/driver/pipeline.zig:176` runs `ir.validateForTranslation` before
`lowerRustIr` at `:177`, and `:197` before `:198` on the wire path. The comment
at `:175` is the rule: "Invalid IR must not reach a package writer."
*Defence:* a port author has the same ordering available and the same reason. A
struct layout validated after the memory is written is a heap corruption, not a
test failure.

**2. Read back what you wrote.**
`package.zig:920-927` calls `validateStagedPackage`, which stats every declared
file (`:624-635`), re-parses the manifest, and checks the fingerprint appears
exactly once (`:637-650`). The comment at `:420-424` states the intent:
"Everything lands before the caller verifies anything, so a staged package is
complete or the promotion fails."
*Defence:* the port writes no package, but it does write files: generated D-Bus
marshalling tables, a generated header, an options blob. `stat` after `write`
costs nothing and catches a partial write.

**3. Run two optimize modes, not one.**
`package.zig:704-710` builds the staged package at `-Doptimize=Debug` and then
`-Doptimize=ReleaseSafe`. The comment at `:704-706` gives the reason:
"ReleaseSafe is what a consumer runs, where the optimizer is on and
`std.debug.assert` guards are load-bearing."
*Defence:* this project already runs both (`docs/18-testing-strategy.md` §8,
item G3 requires Debug and ReleaseSafe). Copying the *reason* matters: a
Debug-only pass says nothing about whether an integer overflow in an AT-SPI
length field traps in a release build.

**4. Fixed-endian hashing wherever an ordering depends on it.**
`src/frontend/infer.zig:30-34` converts the key with `nativeToLittle` before
hashing, and the comment at `:41` says why in one line.
*Defence:* `cross-test.profile.sh:29-33` names `powerpc64-linux` as the only row
that catches an endianness bug in the tree serialisation, the action-channel
marshalling and the C ABI structs. The port has all three.

**5. Fix the analysis width in the harness, not per host.**
`test/golden_test.zig:39` sets `golden_target_pointer_width: u16 = 64`, and the
comment at `:33-38` explains that a null width makes the frontend follow the
host ABI, so "on a 32-bit or wasm32 host every snapshot changes bytes and the
failure reads as a translator regression."
*Defence:* the same argument applies to a pointer width in a serialised record.
`accesskit.h:688-691` puts a `size_t length` in `accesskit_node_ids`. A
snapshot that follows the host pointer width is not a snapshot.

**6. Pin a refusal by name, not by exit status.**
`build.zig:517-526` explains the distinction: a non-zero exit "stays green when
a fixture starts failing with a *different* error, so this entry asserts the
typed error by name". `README.md:304-306` adds the constraint: "That is not an
exemption."
*Defence:* this is the mechanism that makes a coverage boundary auditable. A
port that refuses an upstream construct must name the refusal in a test, or the
boundary moves silently the first time someone widens a `switch`.

**7. Fail on an orphaned artefact.**
`test/golden_test.zig:811-857` walks `test/golden/` and `test/*.json` and fails
any file no test or build step names. The comment at `:806-810` records the
defect it prevents: `test/golden/zig_src/hex/**` "sat unread while the emitted
text changed underneath it."
*Defence:* the same class of defect is a committed `.bin` fixture no harness
loads. `docs/18-testing-strategy.md` §5.5 requires a `.bin` to have a sibling
`.meta.json`, which catches a half-committed pair; the orphan guard catches a
fully committed pair nobody reads.

**8. Clean up on every failure path, and never delete what you did not create.**
`cleanupPromotion` at `package.zig:885-893` is attached at eleven points
(`:919`, `:927`, `:930`, `:941`, `:951`, `:967`, `:972`, `:980`, `:984`,
`:994`, `:997`), so no promotion failure leaves a staging tree. The oracle
runner goes further: it refuses to delete anything at all
(`tools/rust-corpus-oracle.sh:60-61`, `:143-145` removes `--clean` outright,
`:763-765`) and prints the run directory for the caller to remove
(`:746`).
*Defence:* both halves are right for their own scope. A port's scratch is
temporary and must be released on every path, including a `fail-N` allocation
at step 12 of a decode. A port's **fixtures** are evidence and must never be
deleted by a test run.

### 8.2 Leave behind

**1. `test/golden/rust_ir/` and `test/golden/zig_ast/` snapshots.**
These exist to catch a change in an intermediate representation between two
stages of the same program. A hand port has one stage: Rust-shaped source in,
Zig out, tested at the boundary. There is no IR to snapshot.
*Note what is kept:* the emitted-source goldens under `zig_src/` have an
analogue — the recorded byte fixtures — and item 7 of section 8.1 already covers
their discipline.

**2. The three wire versions.**
`src/ir/serialize.zig:20` (v6), `src/backend/zig/serialize.zig:14` (v1) and
`src/model/json.zig:33` (v3) exist because a format evolved across a program's
life and the old files were still on disk. A port starts at one format and, by
the house rule of no backwards compatibility (`ozai/AGENTS.md:51`), never grows
a second. The **discipline** transfers: `docs/18-testing-strategy.md` §5.5
requires the harness to refuse a `schema` it does not know, which is
`decodeWireJson` at `src/driver/pipeline.zig:81-83` in another shape.

**3. `--dump model` and the 23 diagnostics in `src/model/`.**
`README.md:42-43` calls it "diagnostic inventory only" and says it "is never
accepted as translation input". It exists to read files a *previous version*
wrote. A port has no previous version.

**4. `zig-pinned.sh` as a wrapper.**
Section 5.2 already reduces this to two lines. `devenv.nix` owns the caches
(`:14-24`, `:39`, `:56-66`); the gate honours a `ZIG` override
(`zig-gate:149`). Copying a 180-line wrapper to solve a problem a Nix expression
already solves is the wrong direction.

**5. `cross-test.sh` as a second matrix.**
`translate-rust` runs two matrices: its own test graph over every Tier 1/2
target of the Zig 0.16.0 support table (`cross-test.profile.sh:4-7`, `:29`) and
the generated-package aggregate over the same set (`tools/test-generated-corpus.sh:201`).
The second exists only because
the first cannot see generated packages. `zaccesskit` has one matrix, and
`docs/00-house-and-environment.md` §8 already records two open items about it
(a `CROSS_BUILD_STEP` mismatch and a deliberate `CROSS_REQUIRE_RUNNERS=1`).
Fixing those is worth more than adding a second matrix.

**6. The staged-fixture corpus roots.**
`test/crates/` carries 19 crates including full published archives
(`README.md:328-331` for the three archive-verified ones). That is a corpus for
a program that consumes arbitrary input. A port consumes a fixed, pinned API:
core 0.25.1 and C bindings 0.23.1 (`local://zaccesskit-deps.md:74-79`). Vendoring
19 crates would be vendoring inputs the port does not accept.

**7. The `r2z-core` vendored runtime.**
`package.zig:451-456` writes an embedded runtime into every generated package
that needs one, because a translated crate has no runtime of its own to call
into. A hand-written port's runtime is `zio`, already a pinned dependency
(`build.zig.zon:29-33`), and it is not re-vendored per artefact.

**8. `agent-notes/` and the archived records.**
`agent-notes` is a **dangling symlink** in this checkout:

```
lrwxrwxrwx agent-notes -> ~/.agents/agent-notes
```

and the target does not exist. `AGENTS.md:3` warns of this in advance: "The
notes describe private agent-notes and archived records; do not assume their
original paths are present in this checkout."

Four indexed records are absent or superseded, and a reader should know which.

| Record | Where indexed | Status |
|--------|---------------|--------|
| Every `agent-notes/**` record | `AGENTS.md:3`, `notes/README.md:3-13` | **Absent.** The symlink target does not exist. |
| `notes/design/architecture.md` and its four siblings | `notes/README.md:100-108` | **Present but superseded.** Each carries the banner "Historical design record — not current coverage. Written during the exploration phase of this translator… Nothing here is a claim that `translate-rust` supports a Rust shape" (`architecture.md:1-5`, and the same four lines in `pkg-dep-macros.md:1-5`). The `pkg-dep-macros.md` layout (`r2z-<crate>/`, `.@"r2z-hex"`, `:25-33`) does not match the shipped writer, which names the package after the crate (`.name = .compat` in the promoted manifest). |
| `tools/zig-0.16.0-vec-literal-miscompile.md` | Archived at `.local/finish/archived-docs/` | **Superseded and withdrawn.** `ARCHIVE-NOTES.txt` records that the document's own banner withdraws the "Zig 0.16.0 miscompilation" classification: the eight frontend failures were fixture defects, and the ReleaseSafe crash was a C function-type mismatch in the vendored scanner, fixed by writing `tree_sitter_rust_external_scanner_create` with a `(void)` parameter list. `README.md:475-482` carries the surviving rule. |
| The old `README.md` | Archived at `.local/finish/archived-docs/README.md` | **Superseded.** `ARCHIVE-NOTES.txt` records it as 236 lines and 14.4 KB, replaced by a portable document with stock `zig build` commands, no house gate, no host names and no private-notes links. Substantive content was preserved. |

**Defence for leaving all four behind:** none of them is a mechanism. They are
records of how this project reached its current state, and reading them as
current would give a port author rules that have already been overtaken. The
archive is worth reading once, for the reasoning. It is not worth copying.
