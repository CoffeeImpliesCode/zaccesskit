# 36 — The consumer layer call graph

`docs/33-consumer-interface-contract.md` fixes which module **owns** each shared type and
operation. This document records the other half: which module **calls** which, symbol by symbol.
Every later change to `src/consumer/` has to be checked against this list, because a change to a
signature is invisible to the owner and visible only to the caller.

**How to check it.** Run `zig build docs-tables`. The two-column tables in section 2 are generated,
and the run compares them against the source and exits 1 on a difference, so a stale row is a red
build rather than something a reader has to notice. The prose in this document is written by a
person and is not checked by any tool. The last statement in section 4 records what the tables do
not cover.

**A file lists only what it consumes, not what it declares.** The owning side of every symbol is
in `docs/33` section 8 and in section 1 of this document.

## 1. Edges this wave produced by ruling, which `docs/33` does not state

`docs/33` section 8 gives the operations each module owns. Four edges came from a ruling made
while the wave ran, and a reader who works from `docs/33` alone cannot derive them.

| Caller | Symbol | Declared in | Why it is here |
|---|---|---|---|
| `tree_state.zig`, `node_ref/properties.zig`, `filter.zig`, `iterators/*.zig` | `treeWalkStepBound` | `tree_state.zig` | Bounds 5 to 9 of `docs/33` section 7 name `node_ref/hierarchy.zig` and `node_ref/geometry.zig`, and section 7.1 is ambiguous about the owner. The walk sites span seven modules, so the function sits in the L2 module every one of them imports. |
| `tree_state.zig`, `node_ref/*.zig` | `QueryError` | `tree_state.zig` | Same reasoning. `docs/33` section 5 shows the set next to `UpdateError`, which is in `tree.zig`; `QueryError` cannot be there, because `node_ref/hierarchy.zig` is at L5 and returns it. |
| `node_ref/properties.zig`, `filter.zig` | `activeDescendant` | `node_id.zig` | `docs/33` section 1.1 gives `node.rs:825-996` to `node_ref/set_state.zig`, which is L7, while the two callers sit at L2 and L6. `node_id.zig` owns the `NodeRef` body and both callers already import it. |
| `tree.zig` | `validateGlobal`, `computeEffectiveFocus` | `tree_validate.zig` | The two calls at `accesskit_consumer/src/tree.rs:483` and `:485` sit inside `tree_grafts.zig`'s range, and `docs/33` section 3 forbids `tree_grafts.zig` from importing `tree_validate.zig`. The calls moved to `tree.zig`, which orchestrates and already may import the validator. The validation runs **after** every mutation, so a future edit that hoists a call earlier weakens the guarantee. |

**Three placement rulings that supersede `docs/33` section 1.1 and section 2.**

| Type | Declared in | Ruling |
|---|---|---|
| `TreeIndex`, `TreeIndexMap`, `FullNodeId`, `ParentAndIndex` | `tree_index.zig` | The data structure that holds the type owns it. `NodeState` holds `ParentAndIndex` and `TreeState.nodes` holds `NodeState`, so the chain bottoms out at the index map. |
| `NodeState`, `SubtreeState`, `InternalChanges`, `TreeState` | `tree_state.zig` | `TreeState.nodes` holds `NodeState`. Putting either in `node_id.zig` makes the two files import each other for a type each owns the use of. |
| `FilterResult`, `FilterFn`, `commonFilter`, `commonFilterWithRootException` | `filter.zig` | `commonFilter` calls eleven operations that take a `FilterFn`, so `FilterFn` sits below those calls. A `FilterFn` is a **struct of a function pointer plus a `?*anyopaque` context**, never a bare function pointer: Zig has no closure, and a caller needing per-call state has nowhere else to put it. |

## 2. The per-module rows

**Which tables here are generated.** Every two-column table below sits inside a pair of HTML comment
markers that name the module, and `zig build docs-tables` wrote what is between them. The tool reads
every module under `src/`, resolves each qualified name to the file that finally declares it, and
prints one row per declaring module. A plain run compares and exits 1 on a difference; `--write`
rewrites. Delete a marker pair and write the table yourself and the tool leaves it alone. The two
tables at the end of this section list imports rather than symbols, so they carry no marker and no
tool wrote them.

**What a row is, and what is not one.** A row is a symbol the file names, and the file that
declares it. `@import("std")` is the standard library and not this repository, so it is never a
row. `include/zaccesskit.h` is the ABI contract rather than an import, so it is not scanned here
either: `tools/capi_parity` owns the comparison between that header and what `src/capi` exports.
A name that resolves to no module is a finding and the run fails, because a dropped symbol makes
every table smaller and the difference empty.

`AGENTS.md:99` is the authority for the two parameter orders below, and the difference between them
is a language fact rather than a preference: **an allocating free function takes `gpa` first; an
allocating method takes the receiver first, because Zig builds the call syntax only in that
order.**

### `tree_index.zig`

<!-- docs-tables:begin tree_index.zig -->
| Symbol | Declared in |
|---|---|
<!-- docs-tables:end tree_index.zig -->

Imports nothing in the consumer layer. Declares `TreeIndex`, `TreeIndexMap`, `FullNodeId`,
`ParentAndIndex`, and the two index maps.

### `tree_state.zig`

<!-- docs-tables:begin tree_state.zig -->
| Symbol | Declared in |
|---|---|
| `NodeRef`, `activeDescendant` | `node_id.zig` |
| `FullNodeId`, `ParentAndIndex`, `TreeIndexMap` | `tree_index.zig` |
<!-- docs-tables:end tree_state.zig -->

Declares `TreeState`, `NodeState`, `SubtreeState`, `InternalChanges`, `QueryError`,
`UpdateError` and `treeWalkStepBound`.

### `node_id.zig`

<!-- docs-tables:begin node_id.zig -->
| Symbol | Declared in |
|---|---|
| `FullNodeId` | `tree_index.zig` |
| `NodeState`, `TreeState` | `tree_state.zig` |
<!-- docs-tables:end node_id.zig -->

Declares `NodeRef` with `id`, `data` and `init`, plus `activeDescendant`.

### `filter.zig`

<!-- docs-tables:begin filter.zig -->
| Symbol | Declared in |
|---|---|
| `FilteredSiblingsIterator` | `iterators/following.zig` |
| `NodeRef` | `node_id.zig` |
| `boundingBox` | `node_ref/geometry.zig` |
| `filteredParent`, `followingFilteredSiblings`, `isRoot`, `parent`, `precedingFilteredSiblings` | `node_ref/hierarchy.zig` |
| `isFocused` | `node_ref/predicates.zig` |
| `clipsChildren`, `isGraft`, `isHidden`, `role` | `node_ref/properties.zig` |
| `FullNodeId`, `ParentAndIndex` | `tree_index.zig` |
| `NodeState`, `QueryError`, `TreeState`, `treeWalkStepBound` | `tree_state.zig` |
<!-- docs-tables:end filter.zig -->

Declares `FilterResult`, `FilterFn`, `commonFilter` and `commonFilterWithRootException`.

### `node_ref/properties.zig`

<!-- docs-tables:begin node_ref/properties.zig -->
| Symbol | Declared in |
|---|---|
| `NodeRef` | `node_id.zig` |
| `FullNodeId`, `ParentAndIndex` | `tree_index.zig` |
| `QueryError`, `TreeState`, `treeWalkStepBound` | `tree_state.zig` |
<!-- docs-tables:end node_ref/properties.zig -->

Declares the raw and inherited property reads and the graft test.

### `node_ref/hierarchy.zig`

<!-- docs-tables:begin node_ref/hierarchy.zig -->
| Symbol | Declared in |
|---|---|
| `FilterFn`, `FilterResult` | `filter.zig` |
| `ChildIdsIterator`, `ChildrenIterator`, `FilteredChildrenIterator`, `child_ids`, `children`, `filtered_children`, `firstFilteredChild`, `lastFilteredChild` | `iterators/children.zig` |
| `FilteredSiblingsIterator`, `FollowingSiblingIdsIterator`, `FollowingSiblingsIterator`, `followingSiblings`, `following_filtered_siblings`, `following_sibling_ids` | `iterators/following.zig` |
| `PrecedingSiblingIdsIterator`, `PrecedingSiblingsIterator`, `precedingSiblings`, `preceding_filtered_siblings`, `preceding_sibling_ids` | `iterators/preceding.zig` |
| `NodeRef` | `node_id.zig` |
| `isGraft` | `node_ref/properties.zig` |
| `FullNodeId` | `tree_index.zig` |
| `QueryError`, `TreeState`, `treeWalkStepBound` | `tree_state.zig` |
<!-- docs-tables:end node_ref/hierarchy.zig -->

**Two things this wave changed.** `followingFilteredSiblings` and `precedingFilteredSiblings`
return `QueryError!FilteredSiblingsIterator`. Upstream
`FollowingFilteredSiblings::new` at `iterators.rs:349-353` calls `next_filtered_sibling` and
`node.filtered_parent`, both bounded walks named in `docs/33` section 7, so the error is reachable
rather than defensive and rule C8 forbids dropping it. The port reads the ancestor with `parentOf`
instead of calling `filteredParent`, so only the scan remains to report. `filter.zig` needs `try`
on the inner expression at each of its two call sites for the same reason.

**The back end no longer asks the filter about an ancestor.** Upstream's `text_node_filter` includes
the root only so that `filtered_parent` succeeds, and that clause has no home in a context-free
`FilterFn`. The port therefore derives the back end without the filter: it is the last included
child of `node`'s nearest ancestor, whatever role that ancestor has, read by `parentOf` at
`following.zig:334-338` and `preceding.zig:242-246`. A filter that includes only leaves therefore
has a back end, which is what every text run, format, word and line walk needs and what the old
derivation left null. `following.zig` owns the rationale because it owns `FilteredSiblingsIterator`;
`preceding.zig` points at it rather than restating it. Two consequences follow and both are
intended: the constructor now descends children, so a `children` list that forms a cycle reports
`error.TreeCycle` where it used to answer `null`; and a filter naming `.document` would leave
`Role.label` and `Role.terminal` broken, which is why no filter in this layer does.

**One duplicate that this wave removed.** `firstFilteredChild`, `lastFilteredChild` and
`filteredParent` live in `iterators/children.zig` because `following.zig` and `preceding.zig` are
below `node_ref/containers.zig` and cannot import it. `node_ref/containers.zig` and
`node_ref/hierarchy.zig` should call those three rather than keep their own copies.

### `node_ref/predicates.zig`

<!-- docs-tables:begin node_ref/predicates.zig -->
| Symbol | Declared in |
|---|---|
| `FilterFn`, `FilterResult` | `filter.zig` |
| `NodeRef`, `activeDescendant` | `node_id.zig` |
| `filteredParent` | `node_ref/hierarchy.zig` |
| `hasPopup`, `isDisabled`, `isSelected`, `rawIsReadOnly`, `role`, `toggled` | `node_ref/properties.zig` |
| `FullNodeId`, `ParentAndIndex` | `tree_index.zig` |
| `QueryError`, `TreeState`, `treeWalkStepBound` | `tree_state.zig` |
<!-- docs-tables:end node_ref/predicates.zig -->

### `node_ref/geometry.zig`

<!-- docs-tables:begin node_ref/geometry.zig -->
| Symbol | Declared in |
|---|---|
| `FilterFn`, `FilterResult` | `filter.zig` |
| `NodeRef` | `node_id.zig` |
| `children`, `parent` | `node_ref/hierarchy.zig` |
| `FullNodeId` | `tree_index.zig` |
| `QueryError`, `TreeState`, `treeWalkStepBound` | `tree_state.zig` |
| `inverse`, `mul`, `mulPoint`, `transformRectBbox` | `../../schema/geometry/affine.zig` |
<!-- docs-tables:end node_ref/geometry.zig -->

### `node_ref/containers.zig`

Owns `isItemLike` and `isContainerWithSelectableChildren`. They sit with their only caller because
moving them next to the other role matches would close the cycle `containers` to `set_state` to
`text/query` to `containers` that `docs/33` section 3 forbids.

<!-- docs-tables:begin node_ref/containers.zig -->
| Symbol | Declared in |
|---|---|
| `FilterFn`, `FilterResult` | `filter.zig` |
| `firstFilteredChild`, `lastFilteredChild` | `iterators/children.zig` |
| `NodeRef` | `node_id.zig` |
| `children`, `parent`, `parentAndIndex` | `node_ref/hierarchy.zig` |
| `role` | `node_ref/properties.zig` |
| `FullNodeId`, `ParentAndIndex` | `tree_index.zig` |
| `QueryError`, `TreeState`, `treeWalkStepBound` | `tree_state.zig` |
<!-- docs-tables:end node_ref/containers.zig -->

### `node_ref/strings.zig`

Declares `LabelledBy` (upstream `iterators.rs:537-585`), which sits with `labelled_by` because
`docs/30-port-design.md` section 3.2 gives `node.rs:719-824` to this file.

<!-- docs-tables:begin node_ref/strings.zig -->
| Symbol | Declared in |
|---|---|
| `FilterResult` | `filter.zig` |
| `FilteredChildrenIterator` | `iterators/children.zig` |
| `NodeRef` | `node_id.zig` |
| `filteredChildren` | `node_ref/hierarchy.zig` |
| `descendantLabelFilter`, `isTextInput` | `node_ref/predicates.zig` |
| `role` | `node_ref/properties.zig` |
| `hasValue`, `writeValue` | `node_ref/set_state.zig` |
| `textRuns` | `text/position_inner.zig` |
| `FullNodeId`, `ParentAndIndex` | `tree_index.zig` |
| `QueryError`, `TreeState` | `tree_state.zig` |
<!-- docs-tables:end node_ref/strings.zig -->

### `node_ref/set_state.zig`

<!-- docs-tables:begin node_ref/set_state.zig -->
| Symbol | Declared in |
|---|---|
| `NodeRef` | `node_id.zig` |
| `parent` | `node_ref/hierarchy.zig` |
| `isMultiline` | `node_ref/predicates.zig` |
| `documentRange`, `supportsTextRanges` | `text/query.zig` |
| `writeText` | `text/range.zig` |
| `FullNodeId`, `ParentAndIndex` | `tree_index.zig` |
| `QueryError`, `TreeState`, `treeWalkStepBound` | `tree_state.zig` |
<!-- docs-tables:end node_ref/set_state.zig -->

### `iterators/children.zig`

<!-- docs-tables:begin iterators/children.zig -->
| Symbol | Declared in |
|---|---|
| `FilterFn`, `FilterResult` | `filter.zig` |
| `nextFilteredSibling`, `previousFilteredSibling` | `iterators/sibling_scan.zig` |
| `NodeRef` | `node_id.zig` |
| `FullNodeId` | `tree_index.zig` |
| `QueryError`, `TreeState`, `treeWalkStepBound` | `tree_state.zig` |
<!-- docs-tables:end iterators/children.zig -->

Declares `ChildIdsIterator`, `ChildrenIterator`, `FilteredChildrenIterator`, the three
constructors, and the three shared filtered steps.

### `iterators/following.zig`

<!-- docs-tables:begin iterators/following.zig -->
| Symbol | Declared in |
|---|---|
| `FilterFn`, `FilterResult` | `filter.zig` |
| `lastFilteredChild` | `iterators/children.zig` |
| `nextFilteredSibling`, `previousFilteredSibling` | `iterators/sibling_scan.zig` |
| `NodeRef` | `node_id.zig` |
| `FullNodeId` | `tree_index.zig` |
| `QueryError`, `TreeState`, `treeWalkStepBound` | `tree_state.zig` |
<!-- docs-tables:end iterators/following.zig -->

### `iterators/preceding.zig`

<!-- docs-tables:begin iterators/preceding.zig -->
| Symbol | Declared in |
|---|---|
| `FilterFn`, `FilterResult` | `filter.zig` |
| `firstFilteredChild` | `iterators/children.zig` |
| `FilteredSiblingsIterator` | `iterators/following.zig` |
| `previousFilteredSibling` | `iterators/sibling_scan.zig` |
| `NodeRef` | `node_id.zig` |
| `FullNodeId` | `tree_index.zig` |
| `QueryError`, `TreeState`, `treeWalkStepBound` | `tree_state.zig` |
<!-- docs-tables:end iterators/preceding.zig -->

### `iterators/sibling_scan.zig`

<!-- docs-tables:begin iterators/sibling_scan.zig -->
| Symbol | Declared in |
|---|---|
| `FilterFn`, `FilterResult` | `filter.zig` |
| `child_ids`, `children` | `iterators/children.zig` |
| `following_sibling_ids` | `iterators/following.zig` |
| `preceding_sibling_ids` | `iterators/preceding.zig` |
| `NodeRef` | `node_id.zig` |
| `FullNodeId` | `tree_index.zig` |
| `QueryError`, `TreeState`, `treeWalkStepBound` | `tree_state.zig` |
<!-- docs-tables:end iterators/sibling_scan.zig -->

### `tree_apply.zig`

<!-- docs-tables:begin tree_apply.zig -->
| Symbol | Declared in |
|---|---|
| `GraftScratch` | `tree_grafts.zig` |
| `FullNodeId`, `ParentAndIndex`, `TreeIndex` | `tree_index.zig` |
| `InternalChanges`, `TreeState`, `UpdateError` | `tree_state.zig` |
<!-- docs-tables:end tree_apply.zig -->

### `tree_grafts.zig`

<!-- docs-tables:begin tree_grafts.zig -->
| Symbol | Declared in |
|---|---|
| `FullNodeId`, `ParentAndIndex`, `TreeIndex` | `tree_index.zig` |
| `InternalChanges`, `NodeIdSet`, `TreeIdNodeMap`, `TreeIdSet`, `TreeState`, `UpdateError` | `tree_state.zig` |
<!-- docs-tables:end tree_grafts.zig -->

### `tree_validate.zig`

<!-- docs-tables:begin tree_validate.zig -->
| Symbol | Declared in |
|---|---|
| `FullNodeId`, `TreeIndex` | `tree_index.zig` |
| `TreeState`, `UpdateError`, `graftChainStepBound` | `tree_state.zig` |
<!-- docs-tables:end tree_validate.zig -->

### `tree.zig`

<!-- docs-tables:begin tree.zig -->
| Symbol | Declared in |
|---|---|
| `NodeRef` | `node_id.zig` |
| `applyUpdate` | `tree_apply.zig` |
| `FullNodeId` | `tree_index.zig` |
| `InternalChanges`, `NodeState`, `QueryError`, `TreeState`, `UpdateError` | `tree_state.zig` |
| `computeEffectiveFocus`, `validateGlobal` | `tree_validate.zig` |
<!-- docs-tables:end tree.zig -->

### `text/hit_test.zig`

<!-- docs-tables:begin text/hit_test.zig -->
| Symbol | Declared in |
|---|---|
| `FilterFn`, `FilterResult` | `filter.zig` |
| `fetchInheritedProperty` | `node_ref/properties.zig` |
| `FullNodeId`, `ParentAndIndex` | `tree_index.zig` |
| `QueryError`, `TreeState` | `tree_state.zig` |
<!-- docs-tables:end text/hit_test.zig -->

### `text/inherited.zig`

<!-- docs-tables:begin text/inherited.zig -->
| Symbol | Declared in |
|---|---|
| `fetchInheritedFlag`, `fetchInheritedProperty` | `node_ref/properties.zig` |
| `Position` | `text/position.zig` |
| `Range`, `RangePropertyValue`, `fetchProperty`, `init` | `text/range.zig` |
| `FullNodeId`, `ParentAndIndex` | `tree_index.zig` |
| `QueryError`, `TreeState` | `tree_state.zig` |
<!-- docs-tables:end text/inherited.zig -->

### `text/line_walk.zig`

<!-- docs-tables:begin text/line_walk.zig -->
| Symbol | Declared in |
|---|---|
| `NodeRef` | `node_id.zig` |
| `InnerPosition` | `text/position_inner.zig` |
| `QueryError`, `TreeState`, `treeWalkStepBound` | `tree_state.zig` |
<!-- docs-tables:end text/line_walk.zig -->

### `text/position.zig`

<!-- docs-tables:begin text/position.zig -->
| Symbol | Declared in |
|---|---|
| `NodeRef` | `node_id.zig` |
| `lineStart` | `text/line_walk.zig` |
| `InnerPosition`, `biasedToEnd`, `biasedToStart`, `downgrade`, `eql`, `isDocumentEnd`, `isDocumentStart`, `isLineEnd`, `isLineStart`, `isParagraphEnd`, `precedingTextRuns`, `textAttributesDiffer`, `textRuns`, `wordStartSlot` | `text/position_inner.zig` |
| `FullNodeId`, `ParentAndIndex` | `tree_index.zig` |
| `QueryError`, `TreeState`, `treeWalkStepBound` | `tree_state.zig` |
<!-- docs-tables:end text/position.zig -->

### `text/position_inner.zig`

<!-- docs-tables:begin text/position_inner.zig -->
| Symbol | Declared in |
|---|---|
| `NodeRef` | `node_id.zig` |
| `relativeIndexPath` | `node_ref/containers.zig` |
| `filteredChildren`, `followingFilteredSiblings`, `precedingFilteredSiblings` | `node_ref/hierarchy.zig` |
| `role` | `node_ref/properties.zig` |
| `text_run_filter` | `text/hit_test.zig` |
| `FullNodeId`, `ParentAndIndex` | `tree_index.zig` |
| `QueryError`, `TreeState`, `treeWalkStepBound` | `tree_state.zig` |
<!-- docs-tables:end text/position_inner.zig -->

### `text/position_motion.zig`

<!-- docs-tables:begin text/position_motion.zig -->
| Symbol | Declared in |
|---|---|
| `NodeRef` | `node_id.zig` |
| `lineEnd`, `lineStart` | `text/line_walk.zig` |
| `Position`, `isDocumentEnd`, `isDocumentStart`, `isFormatStart`, `isParagraphStart` | `text/position.zig` |
| `InnerPosition`, `biasedToEnd`, `biasedToStart`, `documentEndInner`, `documentStartInner`, `followingTextRuns`, `isParagraphEnd`, `precedingTextRuns`, `textAttributesDiffer`, `wordStartSlot` | `text/position_inner.zig` |
| `FullNodeId`, `ParentAndIndex` | `tree_index.zig` |
| `QueryError`, `TreeState`, `treeWalkStepBound` | `tree_state.zig` |
<!-- docs-tables:end text/position_motion.zig -->

### `text/query.zig`

<!-- docs-tables:begin text/query.zig -->
| Symbol | Declared in |
|---|---|
| `boundingBoxInCoordinateSpace`, `hitTest` | `node_ref/geometry.zig` |
| `isTextInput` | `node_ref/predicates.zig` |
| `role` | `node_ref/properties.zig` |
| `characterIndexAtPoint`, `inheritedTextDirection`, `text_run_filter` | `text/hit_test.zig` |
| `Position`, `isDocumentEnd` | `text/position.zig` |
| `InnerPosition`, `clampedUpgrade`, `textRuns`, `upgrade` | `text/position_inner.zig` |
| `forwardToLineEnd`, `forwardToLineStart` | `text/position_motion.zig` |
| `Range`, `WeakRange`, `downgrade`, `init` | `text/range.zig` |
| `FullNodeId`, `ParentAndIndex` | `tree_index.zig` |
| `NodeState`, `QueryError`, `TreeState` | `tree_state.zig` |
<!-- docs-tables:end text/query.zig -->

### `text/range.zig`

<!-- docs-tables:begin text/range.zig -->
| Symbol | Declared in |
|---|---|
| `NodeRef` | `node_id.zig` |
| `transform` | `node_ref/geometry.zig` |
| `followingFilteredSiblings` | `node_ref/hierarchy.zig` |
| `fetchInheritedProperty` | `node_ref/properties.zig` |
| `text_run_filter` | `text/hit_test.zig` |
| `Position` | `text/position.zig` |
| `ComparablePath`, `InnerPosition`, `biasedToEnd`, `biasedToStart`, `comparable`, `downgrade` | `text/position_inner.zig` |
| `FullNodeId`, `ParentAndIndex` | `tree_index.zig` |
| `QueryError`, `TreeState` | `tree_state.zig` |
| `transformRectBbox` | `../../schema/geometry/affine.zig` |
<!-- docs-tables:end text/range.zig -->

### `root.zig`

Imports nothing in the consumer layer but the modules below, which it re-exports as the
namespace `@import("consumer/root.zig")` names.

<!-- docs-tables:begin root.zig -->
| Symbol | Declared in |
|---|---|
<!-- docs-tables:end root.zig -->

### The four update-protocol files, as an import table

| File | Imports | Notes |
|---|---|---|
| `tree_apply.zig` | `tree_state.zig`, `tree_index.zig`, `tree_grafts.zig` | Stops at the end of the graft and removal work. |
| `tree_grafts.zig` | `tree_state.zig`, `tree_index.zig` | May not import `tree_validate.zig`; the closing validation is `tree.zig`'s. |
| `tree_validate.zig` | `tree_state.zig`, `tree_index.zig` | Importable by `tree.zig` only. |
| `tree.zig` | `tree_state.zig`, `tree_index.zig`, `node_id.zig`, `tree_apply.zig`, `tree_validate.zig` | Orchestrates: calls the passes, then calls the validators last. |

### The text layer, as an import table

| File | Imports |
|---|---|
| `text/hit_test.zig` | `tree_state.zig`, `tree_index.zig`, `node_id.zig`, `filter.zig`, `node_ref/properties.zig` |
| `text/position_inner.zig` | `tree_state.zig`, `tree_index.zig`, `node_id.zig`, `node_ref/hierarchy.zig`, `node_ref/properties.zig`, `node_ref/containers.zig`, `text/hit_test.zig` |
| `text/position.zig` | `node_id.zig`, `node_ref/hierarchy.zig`, `node_ref/properties.zig`, `text/position_inner.zig` |
| `text/position_motion.zig` | `node_id.zig`, `text/position_inner.zig`, `text/position.zig` |
| `text/line_walk.zig` | `text/position_inner.zig` |
| `text/range.zig` | `../../schema/geometry/affine.zig`, `node_id.zig`, `tree_state.zig`, `tree_index.zig`, `node_ref/hierarchy.zig`, `node_ref/properties.zig`, `node_ref/geometry.zig`, `text/position_inner.zig`, `text/position.zig`, `text/hit_test.zig` |
| `text/inherited.zig` | `node_id.zig`, `tree_state.zig`, `tree_index.zig`, `node_ref/hierarchy.zig`, `node_ref/properties.zig`, `text/position_inner.zig`, `text/position.zig`, `text/range.zig` |
| `text/query.zig` | `tree_state.zig`, `tree_index.zig`, `node_id.zig`, `node_ref/geometry.zig`, `node_ref/hierarchy.zig`, `node_ref/predicates.zig`, `node_ref/properties.zig`, `text/position_inner.zig`, `text/position.zig`, `text/position_motion.zig`, `text/range.zig`, `text/hit_test.zig` |

## 3. The one mutual-import cluster, and why it is legal

Four consumer files import each other:

```
iterators/children.zig     -> sibling_scan.zig
iterators/following.zig    -> children.zig, sibling_scan.zig
iterators/preceding.zig    -> children.zig, following.zig, sibling_scan.zig
iterators/sibling_scan.zig -> children.zig, following.zig, preceding.zig
```

`docs/33` section 1.1 grants `iterators/sibling_scan.zig` the other three, and `docs/33`
section 1.3 says an iterator reads `NodeState.parent_and_index` and the `children` property
directly rather than calling `node_ref/`. Upstream holds all six iterators in one file, where
`FilteredChildren::next` at `iterators.rs:511` calls `next_filtered_sibling`, and that function at
`iterators.rs:261` calls `current.children()`. Splitting the file without a cycle would put one
walk in two files.

**Zig resolves a circular file import.** Four `schema/` modules rely on it and their tests run, so
the cluster is not a build risk. The cost is that `docs/33` section 1.1's import column for
`iterators/children.zig`, `following.zig` and `preceding.zig` does not name `sibling_scan.zig`,
which the three need for the scan step. A reviewer running that check will find the edge; the
resolution is this section, not a rewrite.

## 4. What this document does not record

The generated tables record the consumer layer and one directory outside it,
`src/schema/geometry/`, which a consumer reaches past `src/schema/root.zig` for `mul`, `inverse`
and `transformRectBbox`. They do not record the rest of `src/schema/`: the property accessors in
`src/schema/props/` are one group each, which `docs/33` section 8 records, and `src/schema/root.zig`
re-exports them all through one namespace. They do not record `std`, which is not a repository
module, or `include/zaccesskit.h`, which is the ABI contract rather than an import and which
`tools/capi_parity` compares against `src/capi`. They do not record the `docs/33` section 8 rows for
operations no file in this wave calls, nor the 78 property forwards and the 39 inherited
accessors. For those, `docs/33` section 8 is the record.