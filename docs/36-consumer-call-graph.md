# 36 — The consumer layer call graph

`docs/33-consumer-interface-contract.md` fixes which module **owns** each shared type and
operation. This document records the other half: which module **calls** which, symbol by symbol.
Every later change to `src/consumer/` has to be checked against this list, because a change to a
signature is invisible to the owner and visible only to the caller.

**How to check it.** One grep per row over `src/consumer/` for the symbol name. A symbol that a
caller names and no longer exists is a compile error; a symbol that changed shape is a compile
error at the call site. A row here that no longer matches its file is a stale row, and the file is
the truth.

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

Each row is a symbol the file names, and the file that declares it. `AGENTS.md:99` is the
authority for the two parameter orders below, and the difference between them is a language fact
rather than a preference: **an allocating free function takes `gpa` first; an allocating method
takes the receiver first, because Zig builds the call syntax only in that order.**

### `tree_index.zig`

Imports nothing in the consumer layer. Declares `TreeIndex`, `TreeIndexMap`, `FullNodeId`,
`ParentAndIndex`, and the two index maps.

### `tree_state.zig`

| Symbol | Declared in |
|---|---|
| `FullNodeId`, `ParentAndIndex`, `TreeIndexMap` | `tree_index.zig` |
| `NodeRef` | `node_id.zig` |

Declares `TreeState`, `NodeState`, `SubtreeState`, `InternalChanges`, `QueryError`,
`UpdateError` and `treeWalkStepBound`.

### `node_id.zig`

| Symbol | Declared in |
|---|---|
| `FullNodeId`, `TreeIndex` | `tree_index.zig` |
| `NodeState`, `TreeState`, `QueryError` | `tree_state.zig` |

Declares `NodeRef` with `id`, `data` and `init`, plus `activeDescendant`.

### `filter.zig`

| Symbol | Declared in |
|---|---|
| `FullNodeId` | `tree_index.zig` |
| `QueryError`, `treeWalkStepBound` | `tree_state.zig` |
| `NodeRef` | `node_id.zig` |
| `role`, `isGraft`, `isHidden`, `clipsChildren`, `directTransform`, `boundingBox`, `rawIsHidden` | `node_ref/properties.zig` |
| `isRoot`, `parent`, `filteredParent`, `parentAndIndex`, `childIds`, `children`, `filteredChildren`, `followingSiblings`, `precedingSiblings`, `followingFilteredSiblings`, `precedingFilteredSiblings`, `deepestFirstChild`, `deepestLastChild`, `deepestFirstFilteredChild`, `deepestLastFilteredChild`, `isDescendantOf` | `node_ref/hierarchy.zig` |
| `isFocused`, `descendantLabelFilter`, `isTextInput`, `isMultiline` | `node_ref/predicates.zig` |
| `directTransform`, `boundingBox`, `transform`, `relativeTransform` | `node_ref/geometry.zig` |

Declares `FilterResult`, `FilterFn`, `commonFilter` and `commonFilterWithRootException`.

### `node_ref/properties.zig`

| Symbol | Declared in |
|---|---|
| `FullNodeId`, `ParentAndIndex` | `tree_index.zig` |
| `TreeState`, `NodeState`, `QueryError`, `treeWalkStepBound` | `tree_state.zig` |
| `NodeRef` | `node_id.zig` |

Declares the raw and inherited property reads and the graft test.

### `node_ref/hierarchy.zig`

| Symbol | Declared in |
|---|---|
| `FullNodeId` | `tree_index.zig` |
| `QueryError`, `treeWalkStepBound` | `tree_state.zig` |
| `NodeRef` | `node_id.zig` |
| `FilterFn`, `FilterResult` | `filter.zig` |
| `isGraft` | `node_ref/properties.zig` |
| `ChildIdsIterator`, `ChildrenIterator`, `FilteredChildrenIterator`, `child_ids`, `children`, `filtered_children`, `firstFilteredChild`, `lastFilteredChild`, `filteredParent` | `iterators/children.zig` |
| `FollowingSiblingIdsIterator`, `FollowingSiblingsIterator`, `FilteredSiblingsIterator`, `following_sibling_ids`, `followingSiblings`, `following_filtered_siblings` | `iterators/following.zig` |
| `PrecedingSiblingIdsIterator`, `PrecedingSiblingsIterator`, `preceding_sibling_ids`, `precedingSiblings`, `preceding_filtered_siblings` | `iterators/preceding.zig` |

**Two things this wave changed.** `followingFilteredSiblings` and `precedingFilteredSiblings`
return `QueryError!FilteredSiblingsIterator`. Upstream
`FollowingFilteredSiblings::new` at `iterators.rs:349-353` calls `next_filtered_sibling` and
`node.filtered_parent`, both bounded walks named in `docs/33` section 7, so the error is reachable
rather than defensive and rule C8 forbids dropping it. `filter.zig` needs `try` on the inner
expression at each of its two call sites for the same reason.

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

| Symbol | Declared in |
|---|---|
| `FullNodeId` | `tree_index.zig` |
| `QueryError`, `treeWalkStepBound` | `tree_state.zig` |
| `NodeRef` | `node_id.zig` |
| `FilterFn` | `filter.zig` |
| `role`, `isGraft`, `isHidden` | `node_ref/properties.zig` |
| `parent`, `filteredParent`, `children`, `childIds` | `node_ref/hierarchy.zig` |

### `node_ref/geometry.zig`

| Symbol | Declared in |
|---|---|
| `Affine` | `../../schema/geometry/affine.zig` |
| `QueryError`, `treeWalkStepBound` | `tree_state.zig` |
| `NodeRef` | `node_id.zig` |
| `FilterFn` | `filter.zig` |
| `transform`, `relativeTransform` | `node_ref/hierarchy.zig` |

### `node_ref/containers.zig`

Owns `isItemLike` and `isContainerWithSelectableChildren`. They sit with their only caller because
moving them next to the other role matches would close the cycle `containers` to `set_state` to
`text/query` to `containers` that `docs/33` section 3 forbids.

| Symbol | Declared in |
|---|---|
| `FullNodeId` | `tree_index.zig` |
| `QueryError`, `treeWalkStepBound` | `tree_state.zig` |
| `NodeRef` | `node_id.zig` |
| `FilterFn` | `filter.zig` |
| `parent`, `parentAndIndex`, `childIds`, `children`, `isRoot` | `node_ref/hierarchy.zig` |
| `role`, `isHidden`, `supportsAction` | `node_ref/properties.zig` |
| `isContainerWithSelectableChildren`, `isItemLike` | this file |

### `node_ref/strings.zig`

Declares `LabelledBy` (upstream `iterators.rs:537-585`), which sits with `labelled_by` because
`docs/30-port-design.md` section 3.2 gives `node.rs:719-824` to this file.

| Symbol | Declared in |
|---|---|
| `FullNodeId` | `tree_index.zig` |
| `QueryError`, `treeWalkStepBound` | `tree_state.zig` |
| `NodeRef` | `node_id.zig` |
| `FilterFn` | `filter.zig` |
| `childIds`, `children`, `filteredChildren`, `firstFilteredChild`, `lastFilteredChild`, `parent`, `isRoot` | `node_ref/hierarchy.zig` and `iterators/children.zig` |
| `role`, `isHidden` | `node_ref/properties.zig` |
| `isTextInput`, `isMultiline` | `node_ref/predicates.zig` |
| `documentRange`, `supportsTextRanges`, `textRuns` | `text/query.zig` |

### `node_ref/set_state.zig`

| Symbol | Declared in |
|---|---|
| `FullNodeId` | `tree_index.zig` |
| `QueryError`, `treeWalkStepBound` | `tree_state.zig` |
| `NodeRef` | `node_id.zig` |
| `FilterFn` | `filter.zig` |
| `parent`, `childIds`, `isRoot` | `node_ref/hierarchy.zig` |
| `role`, `isHidden`, `supportsAction` | `node_ref/properties.zig` |
| `isItemLike`, `isContainerWithSelectableChildren` | `node_ref/containers.zig` |
| `documentRange`, `textRuns`, `supportsTextRanges` | `text/query.zig` |
| `writeValue`, `documentRange` | `text/range.zig` |

### `iterators/children.zig`

| Symbol | Declared in |
|---|---|
| `FullNodeId` | `tree_index.zig` |
| `TreeState`, `NodeState`, `QueryError`, `treeWalkStepBound` | `tree_state.zig` |
| `NodeRef` | `node_id.zig` |
| `FilterFn`, `FilterResult` | `filter.zig` |
| `nextFilteredSibling`, `previousFilteredSibling` | `iterators/sibling_scan.zig` |

Declares `ChildIdsIterator`, `ChildrenIterator`, `FilteredChildrenIterator`, the three
constructors, and the three shared filtered steps.

### `iterators/following.zig`

| Symbol | Declared in |
|---|---|
| `FullNodeId` | `tree_index.zig` |
| `QueryError` | `tree_state.zig` |
| `NodeRef` | `node_id.zig` |
| `FilterFn`, `FilterResult` | `filter.zig` |
| `child_ids`, `children`, `lastFilteredChild` | `iterators/children.zig` |
| `nextFilteredSibling`, `previousFilteredSibling` | `iterators/sibling_scan.zig` |

### `iterators/preceding.zig`

| Symbol | Declared in |
|---|---|
| `FullNodeId` | `tree_index.zig` |
| `QueryError` | `tree_state.zig` |
| `NodeRef` | `node_id.zig` |
| `FilterFn`, `FilterResult` | `filter.zig` |
| `child_ids`, `children`, `filteredParent`, `firstFilteredChild` | `iterators/children.zig` |
| `nextFilteredSibling`, `previousFilteredSibling` | `iterators/sibling_scan.zig` |
| `FilteredSiblingsIterator`, `ScanDirection` | `iterators/following.zig` |

### `iterators/sibling_scan.zig`

| Symbol | Declared in |
|---|---|
| `FullNodeId` | `tree_index.zig` |
| `QueryError`, `treeWalkStepBound` | `tree_state.zig` |
| `NodeRef` | `node_id.zig` |
| `FilterFn`, `FilterResult` | `filter.zig` |
| `child_ids`, `children` | `iterators/children.zig` |
| `following_sibling_ids` | `iterators/following.zig` |
| `preceding_sibling_ids` | `iterators/preceding.zig` |

### `tree_apply.zig`, `tree_grafts.zig`, `tree_validate.zig`, `tree.zig`

| File | Imports | Notes |
|---|---|---|
| `tree_apply.zig` | `tree_state.zig`, `tree_index.zig`, `tree_grafts.zig` | Stops at the end of the graft and removal work. |
| `tree_grafts.zig` | `tree_state.zig`, `tree_index.zig` | May not import `tree_validate.zig`; the closing validation is `tree.zig`'s. |
| `tree_validate.zig` | `tree_state.zig`, `tree_index.zig` | Importable by `tree.zig` only. |
| `tree.zig` | `tree_state.zig`, `tree_index.zig`, `node_id.zig`, `tree_apply.zig`, `tree_validate.zig` | Orchestrates: calls the passes, then calls the validators last. |

### `text/*.zig`

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

It does not record the schema accessors, which `src/schema/props/` owns and every module may
import. It does not record the `docs/33` section 8 rows for operations no file in this wave calls,
and it does not record the 78 property forwards and the 39 inherited accessors, which `docs/33`
section 8 says are one group each rather than shared operations. For those, `docs/33` section 8 is
the record.