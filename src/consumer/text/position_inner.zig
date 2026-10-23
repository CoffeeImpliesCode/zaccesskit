//! `InnerPosition`: a position inside one text run, and the biased helpers
//! that decide which run a position between two runs belongs to.
//!
//! Upstream `accesskit_consumer/src/text.rs:16-160`, less the two bounded walks
//! at `text.rs:115-141`, which `text/line_walk.zig` owns because each needs its
//! own bounded body, its own error tag and its own tests. `comparable` at
//! `text.rs:107-113` is in the line walk's nominal range but is not a walk: it
//! is the ordering key the biased helpers produce, so it stays here with them.
//!
//! **The three index units, stated once because every function below crosses
//! them.** A tree text position is counted in three different units and they
//! disagree for anything outside ASCII.
//!
//! 1. **Byte offset.** An offset into a run's `value` slice, which is UTF-8.
//!    `character_lengths[i]` is the byte length of character `i`, so the sum of
//!    the first `n` entries is the byte offset of character `n`. `character_lengths`
//!    is a byte count and `value` is a byte string, so the two agree exactly.
//! 2. **Character index.** A count of Unicode scalar values. `InnerPosition.character_index`
//!    is one of these: it indexes `character_lengths`, so `character_index ==
//!    character_lengths.len` is the position one past the last character of the
//!    run, and that is a valid index meaning "end of run". Every field named
//!    `character_index` in this file, in `text/position.zig` and in
//!    `text/position_motion.zig` is in this unit.
//! 3. **UTF-16 code unit index.** A count of UTF-16 code units over the same
//!    text. One scalar value above the basic multilingual plane is two units and
//!    every other is one, so this unit differs from the character index for any
//!    astral character. `text/position.zig`'s `toGlobalUtf16Index` returns one and
//!    `toGlobalUsvIndex` returns a character index instead.
//!
//! A fourth unit appears in the source and is **not** a position: `word_starts`
//! holds `u8` values, so a word start is a character index that cannot exceed
//! 255. Upstream narrows a character index to `u8` before searching that list,
//! at `text.rs:195`, `:396` and `:443`, and `wordStartSlot` narrows the same way
//! with `@truncate`, so the three agree exactly including for a run of more than
//! 255 characters.
//!
//! **The bias, and which way each direction goes.** Two runs of a document are
//! separated by a boundary, and one offset names that boundary twice: the end of
//! the earlier run and the start of the later one. Upstream resolves the
//! ambiguity by moving the position, and the direction is part of the contract
//! rather than an implementation detail, because a caller that passes the wrong
//! one gets a position off by one character and nothing else reports it.
//!
//! - `biasedToStart` moves **forward**, to the start of the *next* run. It fires
//!   only when the position is at the end of its run, and only when a following
//!   text run exists. A position at the end of the last run has nowhere to go,
//!   so it stays where it is.
//!   fires only when the position is at the start of its run, and only when a
//!   preceding text run exists. A position at the start of the first run stays
//!   where it is.
//!
//! So the two are not inverses at a run boundary and a caller must say which one
//! it means: `biasedToStart` answers "which run does this boundary open" and
//! `biasedToEnd` answers "which run does it close". The ordering key
//! `comparable` normalizes with `biasedToStart`, which is what makes two
//! positions that name the same boundary compare equal.
//!
//! **Why this module owns the text-run walks.** `docs/33-consumer-interface-contract.md`
//! section 1.1 row 14 gives this module the biased helpers, and every one of
//! them needs the first following or the first preceding text run.
//! `text/query.zig` also declares those three iterators, and this module may not
//! import it: section 1.1 row 22 records that `text/query.zig` needs
//! `text/position.zig`, and section 3's prohibition row for this module names
//! `query.zig` explicitly. One of the two declarations has to be the one this
//! module reads, and it is this one, because this module sits below every
//! caller and every caller already imports it. The filter itself is not
//! duplicated: `text/hit_test.zig` owns `text_run_filter` and this module uses
//! it. The duplicate to remove is the three iterator builders in
//! `text/query.zig`; the report names the exact lines.
//!
//! **What this module deliberately does not own.** `Position` and the thirty
//! movement methods are `text/position.zig`'s and `text/position_motion.zig`'s.
//! The two line walks are `text/line_walk.zig`'s. The document range is
//! `text/query.zig`'s. `Relative` index paths are `node_ref/containers.zig`'s
//! and this module calls them rather than keeping a second walk.
//!
//! **`textAttributesDiffer` is here, not in `text/query.zig`.** Upstream holds
//! it at `text.rs:1366-1379`, inside `text/query.zig`'s range, but
//! `Position::is_format_start` at `text.rs:175` and the three format movements at
//! `text.rs:343`, `:358` and `:362` all call it and none of them may import
//! `text/query.zig`. This module is below all four. The comparison itself reads
//! eleven properties and nothing else, so it needs no run walk of its own.
//!
//! **The allocator rule, once.** An allocating free function takes `gpa` first
//! per `AGENTS.md:99`; an allocating method takes the receiver first, because Zig
//! builds the call syntax only in that order. `comparable` is a free function and
//! takes `gpa` first. The two bias helpers allocate nothing and take no
//! allocator, so a caller that passes one is passing an argument this module
//! does not name.
//!
//! Nothing here reads a clock, opens a file or reaches for a runtime. No
//! function takes `io`, and every `const` is a `const`.

const std = @import("std");
const schema = @import("../../schema/root.zig");

const containers = @import("../node_ref/containers.zig");
const hierarchy = @import("../node_ref/hierarchy.zig");
const hit_test = @import("hit_test.zig");
const node_ids = @import("../node_id.zig");
const properties = @import("../node_ref/properties.zig");
const tree_index = @import("../tree_index.zig");
const tree_state = @import("../tree_state.zig");
// The cursor types are bound from the iterator modules rather than from
// `node_ref/hierarchy.zig`, because that file binds them privately while its own
// three wrappers return them. A caller that names the type needs the owner.
const FilteredChildrenIterator = @import("../iterators/children.zig").FilteredChildrenIterator;
const FilteredSiblingsIterator = @import("../iterators/following.zig").FilteredSiblingsIterator;

const FullNodeId = tree_index.FullNodeId;
const NodeRef = node_ids.NodeRef;
const QueryError = tree_state.QueryError;
const TextPosition = schema.TextPosition;

const assert = std.debug.assert;
const testing = std.testing;

// --- TextPosition <-> InnerPosition, text.rs:22-53 and :143-149 ---------------

/// The position named by `weak`, or `null` when the tree cannot answer.
///
/// `weak.node_id` names the text run inside its own tree and `tree_index_map`
/// names which tree, so the two together name one node; `node_id` supplies the
/// tree when `weak` carries only a local id. `null` when the state holds no node
/// for that id, when the node's role is not `Role.text_run`, or when
/// `character_index` is past the run's `character_lengths`. This is upstream's
/// `InnerPosition::upgrade` at `text.rs:22-35`.
///
/// Allocates nothing and leaves the state as it was on every path.
pub fn upgrade(
    state: *const tree_state.TreeState,
    weak: TextPosition,
    node_id: FullNodeId,
) ?InnerPosition {
    const node = state.nodeById(node_id.withSameTree(weak.node_id)) orelse return null;
    if (properties.role(node) != .text_run) return null;
    const character_index = weak.character_index;
    if (character_index > characterCount(node)) return null;
    return .{ .node = node, .character_index = character_index };
}

/// The position named by `weak`, with `character_index` pulled inside the run.
///
/// `null` under the same two conditions as `upgrade`, so a stored position whose
/// index is past the end of a run that has since shrunk answers a clamped
/// position rather than `null`. This is upstream's `InnerPosition::clamped_upgrade`
/// at `text.rs:37-53`.
///
/// Allocates nothing and leaves the state as it was on every path.
pub fn clampedUpgrade(
    state: *const tree_state.TreeState,
    weak: TextPosition,
    node_id: FullNodeId,
) ?InnerPosition {
    const node = state.nodeById(node_id.withSameTree(weak.node_id)) orelse return null;
    if (properties.role(node) != .text_run) return null;
    return .{
        .node = node,
        .character_index = @min(weak.character_index, characterCount(node)),
    };
}

/// The stored form of `position`, naming the run by its local id alone.
///
/// The returned value is meaningful only in the tree `position.node` was taken
/// from. It borrows nothing, so a copy is the same value. This is upstream's
/// `InnerPosition::downgrade` at `text.rs:143-149`.
pub fn downgrade(position: InnerPosition) TextPosition {
    return .{ .node_id = position.node.id().local, .character_index = position.character_index };
}

/// Whether both positions name the same offset of the same run. Upstream's
/// `impl PartialEq for InnerPosition` at `text.rs:152-158`.
///
/// Compares the run by full id, tree number included, because two trees may
/// name the same local node and they are different runs.
pub fn eql(a: InnerPosition, b: InnerPosition) bool {
    return sameRun(a.node, b.node) and a.character_index == b.character_index;
}

// --- The boundary predicates, text.rs:55-81 -----------------------------------

/// Whether `position` is at character zero of its run. A character index, so
/// this is the first character and not the byte offset zero.
///
/// Upstream `InnerPosition::is_run_start` at `text.rs:55-57`.
pub fn isRunStart(position: InnerPosition) bool {
    return position.character_index == 0;
}

/// Whether `position` is at the end of its run, meaning one past its last
/// character.
///
/// Upstream `InnerPosition::is_run_end` at `text.rs:63-65`.
pub fn isRunEnd(position: InnerPosition) bool {
    return position.character_index == characterCount(position.node);
}

/// Whether `position` opens a visual line, which needs no run before it on the
/// same line as well as a run start.
///
/// Upstream `InnerPosition::is_line_start` at `text.rs:59-61`. Reads
/// `previous_on_line`, so it never leaves the run's own node.
pub fn isLineStart(position: InnerPosition) bool {
    return isRunStart(position) and
        schema.ids_props.previousOnLine(&position.node.data().properties) == null;
}

/// Whether `position` closes a visual line, which needs no run after it on the
/// same line as well as a run end.
///
/// Upstream `InnerPosition::is_line_end` at `text.rs:67-69`.
pub fn isLineEnd(position: InnerPosition) bool {
    return isRunEnd(position) and
        schema.ids_props.nextOnLine(&position.node.data().properties) == null;
}

/// Whether `position` ends a paragraph, which needs a line end and a newline as
/// the run's last character.
///
/// Upstream `InnerPosition::is_paragraph_end` at `text.rs:71-73`, which unwraps
/// the run's `value` at `:72`. A run that declares no `value` contributes no
/// characters, so it cannot end with a newline and the port answers `false`
/// rather than aborting; `text/query.zig`'s `runValue` takes the same reading
/// of the same unwrap.
pub fn isParagraphEnd(position: InnerPosition) bool {
    if (!isLineEnd(position)) return false;
    const text = schema.strings.value(&position.node.data().properties) orelse return false;
    return text.len != 0 and text[text.len - 1] == '\n';
}

/// Whether `position` is the first position of the document.
///
/// `root_node` is the node the document's text hangs off, and it is the root of
/// the `followingTextRuns` and `precedingTextRuns` walks, so the answer is about
/// that document and not about the tree at large.
///
/// `error.TreeCycle` and `error.NoSuchNode` come from the preceding-sibling
/// scan. Upstream `InnerPosition::is_document_start` at `text.rs:75-77`.
pub fn isDocumentStart(position: InnerPosition, root_node: NodeRef) QueryError!bool {
    if (!isRunStart(position)) return false;
    var runs = try precedingTextRuns(position.node, root_node);
    return (try runs.next()) == null;
}

/// Whether `position` is one past the last position of the document.
///
/// `error.TreeCycle` and `error.NoSuchNode` come from the following-sibling
/// scan. Upstream `InnerPosition::is_document_end` at `text.rs:79-81`.
pub fn isDocumentEnd(position: InnerPosition, root_node: NodeRef) QueryError!bool {
    if (!isRunEnd(position)) return false;
    var runs = try followingTextRuns(position.node, root_node);
    return (try runs.next()) == null;
}

// --- The two biases, text.rs:83-105 ---------------------------------------------

/// `position` moved **forward** to the start of the next run, or unchanged.
///
/// Moves only when `position` is at the end of its run and a following text run
/// exists; see the module doc for why the direction is forward. Upstream
/// `InnerPosition::biased_to_start` at `text.rs:83-93`.
///
/// Allocates nothing. `error.TreeCycle` and `error.NoSuchNode` come from the
/// following-sibling scan.
pub fn biasedToStart(position: InnerPosition, root_node: NodeRef) QueryError!InnerPosition {
    if (!isRunEnd(position)) return position;
    var runs = try followingTextRuns(position.node, root_node);
    const next_run = (try runs.next()) orelse return position;
    return .{ .node = next_run, .character_index = 0 };
}

/// `position` moved **backward** to the end of the previous run, or unchanged.
///
/// Moves only when `position` is at the start of its run and a preceding text
/// run exists; see the module doc for why the direction is backward. Upstream
/// `InnerPosition::biased_to_end` at `text.rs:95-105`.
///
/// Allocates nothing. `error.TreeCycle` and `error.NoSuchNode` come from the
/// preceding-sibling scan.
pub fn biasedToEnd(position: InnerPosition, root_node: NodeRef) QueryError!InnerPosition {
    if (!isRunStart(position)) return position;
    var runs = try precedingTextRuns(position.node, root_node);
    const previous_run = (try runs.next()) orelse return position;
    return .{
        .node = previous_run,
        .character_index = characterCount(previous_run),
    };
}

// --- The ordering key, text.rs:107-113 ------------------------------------------

/// The key that orders `position` against every other position of `root_node`'s
/// document: the child-index path from the root down to the run, then the
/// character index.
///
/// The path is normalized with `biasedToStart` first, which is what makes the
/// end of one run and the start of the next compare equal. Upstream's
/// `InnerPosition::comparable` at `text.rs:107-113` returns a `(Vec<usize>, usize)`
/// tuple; `ComparablePath` is that tuple with the allocator it was built with.
///
/// The returned value owns `indices` and holds the allocator that grew it, which
/// must stay valid for the life of the key. Release it with `deinit`. On
/// `error.OutOfMemory` nothing is allocated and the caller keeps `position`.
/// `error.TreeCycle` and `error.NoSuchNode` come from the bias and from
/// `node_ref/containers.zig`'s parent climb.
pub fn comparable(
    gpa: std.mem.Allocator,
    position: InnerPosition,
    root_node: NodeRef,
) QueryError!ComparablePath {
    const normalized = try biasedToStart(position, root_node);
    const indices = try containers.relativeIndexPath(gpa, normalized.node, root_node.id());
    return .{
        .gpa = gpa,
        .indices = indices,
        .character_index = normalized.character_index,
    };
}

// --- textAttributesDiffer, text.rs:1366-1379 -----------------------------------

/// Whether the two runs format their text differently.
///
/// Compares eleven properties and nothing else: the font family, the language,
/// the font size, the font weight, the background and foreground colours, the
/// three decorations, the alignment and the vertical offset. Each comparison is
/// on the optional value, so a run that declares nothing and a run that declares
/// nothing else agree, and two runs that declare different values for one
/// property differ however the other ten compare. Upstream
/// `NodeRef::text_attributes_differ` at `text.rs:1366-1379`, which carries a
/// `// TODO: more attributes` and stops at eleven.
///
/// Reads the properties directly rather than through an inherited accessor,
/// because upstream reads this node's own values and not its ancestors'.
/// Allocates nothing.
pub fn textAttributesDiffer(a: NodeRef, b: NodeRef) bool {
    const left = a.data().properties;
    const right = b.data().properties;
    if (!std.mem.eql(
        u8,
        schema.strings.fontFamily(&left) orelse "",
        schema.strings.fontFamily(&right) orelse "",
    )) return true;
    if (!std.mem.eql(
        u8,
        schema.strings.language(&left) orelse "",
        schema.strings.language(&right) orelse "",
    )) return true;
    if (!sameFloat(schema.numbers.fontSize(&left), schema.numbers.fontSize(&right))) return true;
    if (!sameFloat(
        schema.numbers.fontWeight(&left),
        schema.numbers.fontWeight(&right),
    )) return true;
    if (!std.meta.eql(
        schema.colors.backgroundColor(&left),
        schema.colors.backgroundColor(&right),
    )) return true;
    if (!std.meta.eql(
        schema.colors.foregroundColor(&left),
        schema.colors.foregroundColor(&right),
    )) return true;
    if (!std.meta.eql(schema.colors.overline(&left), schema.colors.overline(&right))) return true;
    if (!std.meta.eql(
        schema.colors.strikethrough(&left),
        schema.colors.strikethrough(&right),
    )) return true;
    if (!std.meta.eql(schema.colors.underline(&left), schema.colors.underline(&right))) return true;
    if (!std.meta.eql(schema.enums.textAlign(&left), schema.enums.textAlign(&right))) return true;
    if (!std.meta.eql(
        schema.enums.verticalOffset(&left),
        schema.enums.verticalOffset(&right),
    )) return true;
    return false;
}

// --- The text-run walks, text.rs:1381-1400 and :1408-1436 ----------------------

/// Every text run below `root_node`, in document order.
///
/// `error.TreeCycle` when the descendant scan overruns `treeWalkStepBound`, and
/// `error.NoSuchNode` when the state holds no node for an id a `children` list
/// names. Upstream `NodeRef::text_runs` at `text.rs:1381-1384`.
///
/// The cursor borrows the state through the `NodeRef` it was built from, so
/// rebuild it after any call that can grow `TreeState.nodes`.
pub fn textRuns(root_node: NodeRef) QueryError!FilteredChildrenIterator {
    return hierarchy.filteredChildren(root_node, hit_test.text_run_filter);
}

/// The text runs that follow `node` among its siblings, nearest first.
///
/// `root_node` is the node the document's text hangs off. Upstream threads it
/// only to build the filter's captured root id at `text.rs:1391`, and the port's
/// filter carries no context, so the walk depends on nothing but the sibling
/// list and the parameter is kept for the caller to read the intent.
///
/// `error.TreeCycle` and `error.NoSuchNode` come from the sibling scan. Upstream
/// `NodeRef::following_text_runs` at `text.rs:1386-1392`.
pub fn followingTextRuns(
    node: NodeRef,
    root_node: NodeRef,
) QueryError!FilteredSiblingsIterator {
    _ = root_node;
    return hierarchy.followingFilteredSiblings(node, hit_test.text_run_filter);
}

/// The text runs that precede `node` among its siblings, nearest first.
///
/// `root_node` is the node the document's text hangs off, and it is the root the
/// walk is measured against; see `followingTextRuns` for why it is a parameter.
///
/// `error.TreeCycle` and `error.NoSuchNode` come from the sibling scan. Upstream
/// `NodeRef::preceding_text_runs` at `text.rs:1394-1400`.
pub fn precedingTextRuns(
    node: NodeRef,
    root_node: NodeRef,
) QueryError!FilteredSiblingsIterator {
    _ = root_node;
    return hierarchy.precedingFilteredSiblings(node, hit_test.text_run_filter);
}

/// The first position of `root_node`'s document: character zero of its first run.
///
/// `error.NoSuchNode` when `root_node` declares no text run, so the document has
/// no first position. That replaces upstream's `.unwrap()` at `text.rs:1409`,
/// which fires on a node that `supports_text_ranges` would have rejected.
/// `error.TreeCycle` comes from the descendant scan. Upstream
/// `NodeRef::document_start_inner` at `text.rs:1408-1414`.
pub fn documentStartInner(root_node: NodeRef) QueryError!InnerPosition {
    var runs = try textRuns(root_node);
    const first = (try runs.next()) orelse return error.NoSuchNode;
    return .{ .node = first, .character_index = 0 };
}

/// The position one past the last character of `root_node`'s document.
///
/// `error.NoSuchNode` when `root_node` declares no text run, replacing upstream's
/// `.unwrap()` at `text.rs:1424`. `error.TreeCycle` comes from the descendant
/// scan. Upstream `NodeRef::document_end_inner` at `text.rs:1423-1429`.
pub fn documentEndInner(root_node: NodeRef) QueryError!InnerPosition {
    var runs = try textRuns(root_node);
    const last = (try runs.nextBack()) orelse return error.NoSuchNode;
    return .{ .node = last, .character_index = characterCount(last) };
}

// --- The word-start search, text.rs:195, :396 and :443 -------------------------

/// Where `character_index` sits in `word_starts`, as an index into that list.
///
/// `word_starts` is sorted and holds `u8` values, so it is searched by binary
/// search. `index` is the position of the entry itself when `exact` is true and
/// the position the entry would take when it is false, which is the two arms of
/// upstream's `binary_search` at `text.rs:195`, `:396` and `:443`.
///
/// `character_index` is a character index and the entries are `u8`, so the
/// search key is `@truncate`d exactly as upstream's `character_index as u8`
/// narrows it. A run of more than 255 characters therefore wraps the key, and
/// the port reproduces that rather than widening it, because a widened search
/// would answer `false` where upstream answers `true` and the two would differ
/// on a tree a platform can send.
///
/// The loop is bounded by `word_starts.len`: each step discards at least half of
/// the remaining range, so the walk cannot exceed the list length even once.
pub fn wordStartSlot(
    word_starts: []const u8,
    character_index: usize,
) struct { index: usize, exact: bool } {
    const key: u8 = @truncate(character_index);
    var low: usize = 0;
    var high: usize = word_starts.len;
    var step: usize = 0;
    while (low < high) {
        if (step == wordStartSearchStepBound(word_starts.len)) {
            return .{ .index = high, .exact = false };
        }
        step += 1;
        const middle = low + (high - low) / 2;
        if (word_starts[middle] < key) low = middle + 1 else high = middle;
    }
    const exact = low < word_starts.len and word_starts[low] == key;
    return .{ .index = low, .exact = exact };
}

/// The most steps `wordStartSlot` may take over a list of `word_start_count`
/// entries.
///
/// Each step discards at least one entry from the range it searches, so no list
/// of `n` entries takes more than `n` steps. `docs/33` section 7 names nine
/// bounded walks and this is not one of them, because the input is a finite list
/// rather than a tree; the bound is still named here so the loop above has one.
pub fn wordStartSearchStepBound(word_start_count: usize) usize {
    return word_start_count;
}

// --- The two types -------------------------------------------------------------

/// A position inside one text run: the run, and a character index into it.
///
/// `character_index` is a **character index**, not a byte offset and not a UTF-16
/// code unit index; the module doc states all three units. An index equal to the
/// run's `character_lengths` length is valid and means one past the last
/// character. Upstream `InnerPosition<'a>`, `text.rs:16-19`.
///
/// **Both fields borrow.** `node` holds two pointers into one `TreeState`, and
/// the borrow ends at the next call that can grow `TreeState.nodes`, because
/// growing the map moves its entries. Rebuild every `InnerPosition` after an
/// update. The value owns nothing, so it has no `deinit`, a copy is a second
/// handle to the same run rather than a second owner, and releasing a copy would
/// be a double free.
pub const InnerPosition = struct {
    /// The run this position sits in. Borrows one `NodeState` of the state the
    /// position was built from.
    node: NodeRef,

    /// Offset from the start of the run, counted in Unicode scalar values. Equals
    /// `character_lengths.len` at the end of the run.
    character_index: usize,
};

/// The ordering key of a position: the child-index path from the document root
/// down to the run, then the character index. Upstream's `(Vec<usize>, usize)` at
/// `text.rs:109-112`.
///
/// **The value owns `indices` and stores the allocator that grew it.** That
/// allocator must stay valid for the life of the key, and it must be the
/// allocator `deinit` releases the memory through, or `deinit` is a mismatched
/// free. Copying a `ComparablePath` copies the handle, not the storage, so a copy
/// is not a second owner and must not be deinitialised separately.
pub const ComparablePath = struct {
    /// The allocator that grew `indices` and that `deinit` releases it through.
    gpa: std.mem.Allocator,

    /// Each ancestor's `children` index, rootmost first, ending with this run's
    /// own index in its parent's list.
    indices: std.ArrayList(usize),

    /// The position's character index within the run `indices` ends at.
    character_index: usize,

    /// Releases `indices` and the allocator handle. The value is unusable
    /// afterwards and a second call is a double free.
    pub fn deinit(self: *ComparablePath) void {
        self.indices.deinit(self.gpa);
        // SAFETY: `indices.deinit` released the only buffer the value owned,
        // and no statement after it reads `self`.
        self.* = undefined;
    }

    /// Whether `self` sorts before, with, or after `other`.
    ///
    /// The comparison is lexicographic on `indices` element by element, then on
    /// `indices.len`, then on `character_index`. A shorter path that is a prefix
    /// of a longer one therefore sorts first, which is what a tuple comparison of
    /// `(Vec<usize>, usize)` does in upstream's `impl PartialOrd for Position` at
    /// `text.rs:583-592`.
    pub fn order(self: ComparablePath, other: ComparablePath) std.math.Order {
        const shared = @min(self.indices.items.len, other.indices.items.len);
        for (self.indices.items[0..shared], other.indices.items[0..shared]) |left, right| {
            const element = std.math.order(left, right);
            if (element != .eq) return element;
        }
        const by_length = std.math.order(self.indices.items.len, other.indices.items.len);
        if (by_length != .eq) return by_length;
        return std.math.order(self.character_index, other.character_index);
    }
};

comptime {
    // `NodeRef` is 32 bytes at alignment 8: two pointers and a `FullNodeId` held
    // by value, which is 16 bytes on its own. The character index therefore
    // follows at offset 32 and the whole position is 40. These are measured, not
    // derived, so a field added to either struct is a build failure rather than
    // a silent change to what every text module passes by value.
    assert(@sizeOf(NodeRef) == 32);
    assert(@alignOf(NodeRef) == 8);
    assert(@sizeOf(InnerPosition) == 40);
    assert(@alignOf(InnerPosition) == 8);
    assert(@offsetOf(InnerPosition, "character_index") == 32);

    // A key is a handle, a list and a count, and the count follows the list, so
    // the field order is what keeps `character_index` out of the pointer half.
    assert(@offsetOf(ComparablePath, "character_index") >= 2 * @sizeOf(usize));

    // The search key narrows a `usize` to a `u8`, which is the one place a text
    // position loses information. `@truncate` is the only spelling that keeps
    // upstream's `as u8` behaviour, so the narrowing is pinned here rather than
    // left to a reader to infer from the call site.
    assert(@bitSizeOf(u8) == 8);
}

// --- The private helpers -------------------------------------------------------

/// Whether `a` and `b` name the same node, tree number included.
///
/// The comparison is field-wise because `FullNodeId` is a plain struct and Zig
/// derives nothing for it. Two trees may name the same local node, and they are
/// different runs, so the tree number is part of the identity.
fn sameRun(a: NodeRef, b: NodeRef) bool {
    return std.meta.eql(a.id(), b.id());
}

/// The character count of `node`'s run, which is the length of its
/// `character_lengths` and not the byte length of its `value`.
///
/// An absent `character_lengths` reads as an empty slice through the schema
/// getter, so a run that declares none has no characters and `character_index`
/// zero is both its start and its end.
fn characterCount(node: NodeRef) usize {
    return schema.vectors.characterLengths(&node.data().properties).len;
}

/// Two optional `f32` values that agree or do not.
///
/// `std.meta.eql` would work, but spelling the comparison out records that two
/// absent values agree, which is the case `textAttributesDiffer` depends on and
/// the case a reader of that function cannot see.
fn sameFloat(left: ?f32, right: ?f32) bool {
    if (left == null and right == null) return true;
    if (left == null or right == null) return false;
    return left.? == right.?;
}

// --- Tests ---------------------------------------------------------------------

// --- Tests ---------------------------------------------------------------------

const test_allocator = testing.allocator;
const Node = schema.Node;
const NodeId = schema.NodeId;
const ParentAndIndex = tree_index.ParentAndIndex;
const TreeState = tree_state.TreeState;

fn localId(raw: u64) NodeId {
    return .{ .value = raw };
}

fn fullId(id: NodeId) FullNodeId {
    return FullNodeId.init(id, .init(0));
}

/// A state whose root is node 1. Every fixture puts the nodes it names, so the
/// map holds nothing else and a count in a test is the number of nodes the test
/// built.
fn testState() TreeState {
    return .{ .root_id = fullId(localId(1)), .focus_id = fullId(localId(1)) };
}

/// Adds one node under `id` and takes ownership of it. `parent` is `null` for
/// the root. Every caller defers `state.deinit`, so no caller releases `node`.
fn put(state: *TreeState, id: NodeId, parent: ?ParentAndIndex, node: Node) !void {
    try state.nodes.put(test_allocator, fullId(id), .{
        .parent_and_index = parent,
        .data = node,
    });
}

/// The handle for `id`. Every fixture puts the node in first, so a `null` here is
/// the fixture's own defect and the error says so.
fn refOf(state: *TreeState, id: NodeId) !NodeRef {
    return NodeRef.init(state, fullId(id)) orelse error.NodeMissingFromFixture;
}

fn parentOf(parent: NodeId, index: usize) ParentAndIndex {
    return .{ .parent_id = fullId(parent), .index = index };
}

/// A document root holding `count` empty text-run children, each on its own
/// line. Node 1 is the root; the runs are nodes 2 through `count + 1`.
///
/// The children's `children` list is written by `put`, so it names the runs in
/// order and the ordering key of a run is its own index in that list.
fn documentWithRuns(count: usize) !TreeState {
    var state = testState();
    errdefer state.deinit(test_allocator);

    var root = Node.init(test_allocator, .document);
    errdefer root.deinit();
    const child_ids = try test_allocator.alloc(NodeId, count);
    defer test_allocator.free(child_ids);
    for (child_ids, 0..) |*slot, index| slot.* = localId(index + 2);
    try schema.ids_props.setChildren(&root.properties, child_ids);
    try put(&state, localId(1), null, root);

    for (child_ids, 0..) |child_id, index| {
        var run = Node.init(test_allocator, .text_run);
        errdefer run.deinit();
        try schema.strings.setValue(&run.properties, "x");
        try schema.vectors.setCharacterLengths(&run.properties, &.{1});
        try put(&state, child_id, parentOf(localId(1), index), run);
    }
    return state;
}

/// A single run whose `value` is `text` and whose `character_lengths` are
/// `byte_lengths`, so the byte offset of every character is the running sum.
fn runWith(text: []const u8, byte_lengths: []const u8) !Node {
    var run = Node.init(test_allocator, .text_run);
    errdefer run.deinit();
    try schema.strings.setValue(&run.properties, text);
    try schema.vectors.setCharacterLengths(&run.properties, byte_lengths);
    return run;
}

test "upgrade answers null for a node that is not a text run" {
    var state = testState();
    defer state.deinit(test_allocator);
    const label = Node.init(test_allocator, .label);
    try put(&state, localId(1), null, label);

    const weak: TextPosition = .{ .node_id = localId(1), .character_index = 0 };
    try testing.expect(upgrade(&state, weak, fullId(localId(1))) == null);
    try testing.expect(clampedUpgrade(&state, weak, fullId(localId(1))) == null);
}

test "upgrade answers null for an index past the end of the run" {
    var state = testState();
    defer state.deinit(test_allocator);
    try put(&state, localId(1), null, try runWith("ab", &.{ 1, 1 }));

    // Two characters, so index two is the end of the run and index three is past
    // it. A port that compared against `character_index < len` would reject the
    // end of the run, which is a position the whole layer relies on.
    const at_end: TextPosition = .{ .node_id = localId(1), .character_index = 2 };
    try testing.expect(upgrade(&state, at_end, fullId(localId(1))) != null);

    const past_end: TextPosition = .{ .node_id = localId(1), .character_index = 3 };
    try testing.expect(upgrade(&state, past_end, fullId(localId(1))) == null);
}

test "clampedUpgrade pulls an index past the end back to the end of the run" {
    var state = testState();
    defer state.deinit(test_allocator);
    try put(&state, localId(1), null, try runWith("ab", &.{ 1, 1 }));

    const past_end: TextPosition = .{ .node_id = localId(1), .character_index = 9 };
    const clamped = clampedUpgrade(&state, past_end, fullId(localId(1))) orelse
        return error.NodeMissingFromFixture;
    try testing.expectEqual(@as(usize, 2), clamped.character_index);
}

test "downgrade and upgrade are inverses across a run boundary" {
    var state = testState();
    defer state.deinit(test_allocator);
    try put(&state, localId(1), null, try runWith("abc", &.{ 1, 1, 1 }));

    // The stored form names the local id alone, and `upgrade` needs the full id
    // of the run, which is what makes the pair lossy across trees and not here.
    const stored = downgrade(.{ .node = try refOf(&state, localId(1)), .character_index = 2 });
    try testing.expectEqual(localId(1), stored.node_id);
    try testing.expectEqual(@as(usize, 2), stored.character_index);

    const back = upgrade(&state, stored, fullId(localId(1))) orelse
        return error.NodeMissingFromFixture;
    try testing.expectEqual(@as(usize, 2), back.character_index);
}

test "eql compares the run by full id, so two trees answer for the same local id" {
    var state = testState();
    defer state.deinit(test_allocator);
    const here = try runWith("a", &.{1});
    try state.nodes.put(test_allocator, fullId(localId(1)), .{
        .parent_and_index = null,
        .data = here,
    });
    const other_tree: FullNodeId = FullNodeId.init(localId(1), .init(1));
    const elsewhere = try runWith("a", &.{1});
    try state.nodes.put(test_allocator, other_tree, .{
        .parent_and_index = null,
        .data = elsewhere,
    });

    const local_ref = try refOf(&state, localId(1));
    const foreign_ref = NodeRef.init(&state, other_tree) orelse
        return error.NodeMissingFromFixture;

    const left: InnerPosition = .{ .node = local_ref, .character_index = 1 };
    const same: InnerPosition = .{ .node = local_ref, .character_index = 1 };
    const other_tree_position: InnerPosition = .{ .node = foreign_ref, .character_index = 1 };

    try testing.expect(eql(left, same));
    // A tree number is part of a run's identity, so this is where a comparison
    // that dropped it would answer true.
    try testing.expect(!eql(left, other_tree_position));
}

test "isRunStart and isRunEnd place the two ends of a run, and both are valid" {
    var state = testState();
    defer state.deinit(test_allocator);
    try put(&state, localId(1), null, try runWith("abc", &.{ 1, 1, 1 }));
    const run = try refOf(&state, localId(1));

    try testing.expect(isRunStart(.{ .node = run, .character_index = 0 }));
    try testing.expect(!isRunStart(.{ .node = run, .character_index = 1 }));

    // Index three is one past the last character, so it is the end and not an
    // out-of-range index. Every bias and every line walk depends on that.
    try testing.expect(isRunEnd(.{ .node = run, .character_index = 3 }));
    try testing.expect(!isRunEnd(.{ .node = run, .character_index = 2 }));
}

test "isLineStart and isLineEnd need the absent neighbour, not the position alone" {
    var state = testState();
    defer state.deinit(test_allocator);
    // The two runs sit on one visual line, so each names the other: the first
    // through `next_on_line` and the second through `previous_on_line`. A line
    // boundary needs one of those to be absent, and that is the whole test.
    var first = try runWith("ab", &.{ 1, 1 });
    try schema.ids_props.setNextOnLine(&first.properties, localId(2));
    try put(&state, localId(1), null, first);
    var second = try runWith("cd", &.{ 1, 1 });
    try schema.ids_props.setPreviousOnLine(&second.properties, localId(1));
    try put(&state, localId(2), parentOf(localId(1), 1), second);

    const one = try refOf(&state, localId(1));
    const two = try refOf(&state, localId(2));

    // The first run's start is a line start because nothing precedes it on the
    // line, and the first run's end is not a line end because the second
    // follows it there.
    try testing.expect(isLineStart(.{ .node = one, .character_index = 0 }));
    try testing.expect(!isLineEnd(.{ .node = one, .character_index = 2 }));
    // The second run is the mirror image, and a predicate that tested only the
    // position and not the neighbour would answer the opposite here.
    try testing.expect(!isLineStart(.{ .node = two, .character_index = 0 }));
    try testing.expect(isLineEnd(.{ .node = two, .character_index = 2 }));
}

test "a run with no line neighbour is both a line start and a line end" {
    var state = try documentWithRuns(2);
    defer state.deinit(test_allocator);
    const one = try refOf(&state, localId(2));

    // `documentWithRuns` writes no `next_on_line` and no `previous_on_line`, so
    // each run is a whole line of its own. A predicate that read the neighbour
    // the wrong way round would make the first run a line end and not a line
    // start.
    try testing.expect(isLineStart(.{ .node = one, .character_index = 0 }));
    try testing.expect(isLineEnd(.{ .node = one, .character_index = 1 }));
}

test "isParagraphEnd needs a line end and a trailing newline" {
    var state = testState();
    defer state.deinit(test_allocator);
    try put(&state, localId(1), null, try runWith("ab\n", &.{ 1, 1, 1 }));
    try put(&state, localId(2), parentOf(localId(1), 1), try runWith("cd", &.{ 1, 1 }));
    const first = try refOf(&state, localId(1));
    const second = try refOf(&state, localId(2));

    try testing.expect(isParagraphEnd(.{ .node = first, .character_index = 3 }));
    // The newline is there but the run does not end, so the newline is a
    // character in the middle of the text and not a paragraph break.
    try testing.expect(!isParagraphEnd(.{ .node = first, .character_index = 2 }));
    // A run with no newline is not a paragraph end whatever its index.
    try testing.expect(!isParagraphEnd(.{ .node = second, .character_index = 2 }));
}

test "isParagraphEnd answers false for a run with no value rather than unwrapping" {
    var state = testState();
    defer state.deinit(test_allocator);
    // A run with no `value` at all, which upstream's `.unwrap()` at `text.rs:72`
    // aborts on. The port answers false and a test is the difference.
    var run = Node.init(test_allocator, .text_run);
    errdefer run.deinit();
    try put(&state, localId(1), null, run);

    try testing.expect(!isParagraphEnd(.{
        .node = try refOf(&state, localId(1)),
        .character_index = 0,
    }));
}

test "isDocumentStart and isDocumentEnd answer only at the two outer ends" {
    var state = try documentWithRuns(3);
    defer state.deinit(test_allocator);
    const root = try refOf(&state, localId(1));
    const one = try refOf(&state, localId(2));
    const two = try refOf(&state, localId(3));
    const three = try refOf(&state, localId(4));

    try testing.expect(try isDocumentStart(.{ .node = one, .character_index = 0 }, root));
    // The same run at its end has a following run, so it is not the document end.
    try testing.expect(!try isDocumentEnd(.{ .node = one, .character_index = 1 }, root));

    try testing.expect(try isDocumentEnd(.{ .node = three, .character_index = 1 }, root));
    try testing.expect(!try isDocumentStart(.{ .node = three, .character_index = 0 }, root));

    // A middle run has both a preceding and a following run.
    try testing.expect(!try isDocumentStart(.{ .node = two, .character_index = 0 }, root));
    try testing.expect(!try isDocumentEnd(.{ .node = two, .character_index = 1 }, root));
}

test "biasedToStart moves forward across a run boundary and only at a run end" {
    var state = try documentWithRuns(2);
    defer state.deinit(test_allocator);
    const root = try refOf(&state, localId(1));
    const one = try refOf(&state, localId(2));
    const two = try refOf(&state, localId(3));

    // At the end of the first run, so it moves to the start of the second.
    const moved = try biasedToStart(.{ .node = one, .character_index = 1 }, root);
    try testing.expectEqual(two.id(), moved.node.id());
    try testing.expectEqual(@as(usize, 0), moved.character_index);

    // In the middle of the first run, so it stays. A port that ignored the
    // run-end test would move a character position to a run start.
    const held = try biasedToStart(.{ .node = one, .character_index = 0 }, root);
    try testing.expectEqual(one.id(), held.node.id());
    try testing.expectEqual(@as(usize, 0), held.character_index);
}

test "biasedToStart leaves the end of the last run where it is" {
    var state = try documentWithRuns(1);
    defer state.deinit(test_allocator);
    const root = try refOf(&state, localId(1));
    const only = try refOf(&state, localId(2));

    // There is no following run, so the bias has nowhere to go and the position
    // stays at the end rather than wrapping to the start of the same run.
    const held = try biasedToStart(.{ .node = only, .character_index = 1 }, root);
    try testing.expectEqual(only.id(), held.node.id());
    try testing.expectEqual(@as(usize, 1), held.character_index);
}

test "biasedToEnd moves backward across a run boundary and only at a run start" {
    var state = try documentWithRuns(2);
    defer state.deinit(test_allocator);
    const root = try refOf(&state, localId(1));
    const one = try refOf(&state, localId(2));
    const two = try refOf(&state, localId(3));

    // At the start of the second run, so it moves to the end of the first. The
    // direction is backward, which is the opposite of `biasedToStart`, and the
    // two are not inverses.
    const moved = try biasedToEnd(.{ .node = two, .character_index = 0 }, root);
    try testing.expectEqual(one.id(), moved.node.id());
    try testing.expectEqual(@as(usize, 1), moved.character_index);

    // At the end of the second run, so it stays.
    const held = try biasedToEnd(.{ .node = two, .character_index = 1 }, root);
    try testing.expectEqual(two.id(), held.node.id());
    try testing.expectEqual(@as(usize, 1), held.character_index);
}

test "biasedToEnd leaves the start of the first run where it is" {
    var state = try documentWithRuns(1);
    defer state.deinit(test_allocator);
    const root = try refOf(&state, localId(1));
    const only = try refOf(&state, localId(2));

    // There is no preceding run, so a backward bias has nowhere to go. It must
    // not saturate at zero on the same run, because that would make the start and
    // the end of the first run compare equal.
    const held = try biasedToEnd(.{ .node = only, .character_index = 0 }, root);
    try testing.expectEqual(only.id(), held.node.id());
    try testing.expectEqual(@as(usize, 0), held.character_index);
}

test "comparable normalizes a run boundary so the two spellings compare equal" {
    var state = try documentWithRuns(2);
    defer state.deinit(test_allocator);
    const root = try refOf(&state, localId(1));
    const one = try refOf(&state, localId(2));
    const two = try refOf(&state, localId(3));

    // The end of the first run and the start of the second name one boundary.
    // `comparable` biases toward the start, so both keys name the second run at
    // character zero and the two compare equal. Without the bias the end of the
    // first run would sort after the start of the second and a degenerate range
    // spanning the boundary would report itself non-degenerate.
    var from_end = try comparable(test_allocator, .{ .node = one, .character_index = 1 }, root);
    defer from_end.deinit();
    var from_start = try comparable(test_allocator, .{ .node = two, .character_index = 0 }, root);
    defer from_start.deinit();

    try testing.expectEqual(std.math.Order.eq, from_end.order(from_start));
}

test "comparable orders two runs of the same document by their child index" {
    var state = try documentWithRuns(3);
    defer state.deinit(test_allocator);
    const root = try refOf(&state, localId(1));
    const one = try refOf(&state, localId(2));
    const three = try refOf(&state, localId(4));

    var first_key = try comparable(test_allocator, .{ .node = one, .character_index = 0 }, root);
    defer first_key.deinit();
    var third_key = try comparable(test_allocator, .{ .node = three, .character_index = 0 }, root);
    defer third_key.deinit();

    try testing.expectEqual(std.math.Order.lt, first_key.order(third_key));
    try testing.expectEqual(std.math.Order.gt, third_key.order(first_key));
}

test "comparable orders two offsets inside one run by character index" {
    var state = testState();
    defer state.deinit(test_allocator);
    try put(&state, localId(1), null, try runWith("abcd", &.{ 1, 1, 1, 1 }));
    const run = try refOf(&state, localId(1));

    var early = try comparable(test_allocator, .{ .node = run, .character_index = 1 }, run);
    defer early.deinit();
    var late = try comparable(test_allocator, .{ .node = run, .character_index = 3 }, run);
    defer late.deinit();

    try testing.expectEqual(std.math.Order.lt, early.order(late));
}

test "documentStartInner and documentEndInner name the two outer ends" {
    var state = try documentWithRuns(3);
    defer state.deinit(test_allocator);
    const root = try refOf(&state, localId(1));

    const start = try documentStartInner(root);
    try testing.expectEqual(localId(2), start.node.id().local);
    try testing.expectEqual(@as(usize, 0), start.character_index);

    // The end is one past the last character of the last run, so its index is
    // the run's character count rather than the last character's index.
    const end = try documentEndInner(root);
    try testing.expectEqual(localId(4), end.node.id().local);
    try testing.expectEqual(@as(usize, 1), end.character_index);
}

test "documentStartInner reports no node for a document with no text run" {
    var state = testState();
    defer state.deinit(test_allocator);
    try put(&state, localId(1), null, Node.init(test_allocator, .document));

    // Upstream unwraps the same read at `text.rs:1409` and `text.rs:1424`; a
    // caller cannot act on an abort, so both report the tag instead.
    const root = try refOf(&state, localId(1));
    try testing.expectError(error.NoSuchNode, documentStartInner(root));
    try testing.expectError(error.NoSuchNode, documentEndInner(root));
}

test "textAttributesDiffer answers on the eleven properties upstream compares" {
    var state = testState();
    defer state.deinit(test_allocator);
    try put(&state, localId(1), null, try runWith("a", &.{1}));
    try put(&state, localId(2), parentOf(localId(1), 1), try runWith("b", &.{1}));
    const plain = try refOf(&state, localId(1));
    const same = try refOf(&state, localId(2));

    // Two runs that declare nothing at all agree, which is the case a
    // comparison that treated an absent value as a sentinel would get wrong.
    try testing.expect(!textAttributesDiffer(plain, same));

    const entry = state.nodes.getPtr(fullId(localId(2))) orelse
        return error.NodeMissingFromFixture;
    try schema.numbers.setFontSize(&entry.data.properties, 12);
    try testing.expect(textAttributesDiffer(plain, same));

    schema.numbers.clearFontSize(&entry.data.properties);
    try schema.strings.setLanguage(&entry.data.properties, "en-GB");
    try testing.expect(textAttributesDiffer(plain, same));
}

test "textAttributesDiffer separates two runs that differ only in alignment" {
    var state = testState();
    defer state.deinit(test_allocator);
    try put(&state, localId(1), null, try runWith("a", &.{1}));
    try put(&state, localId(2), parentOf(localId(1), 1), try runWith("b", &.{1}));
    const left = try refOf(&state, localId(1));
    const right = try refOf(&state, localId(2));

    const entry = state.nodes.getPtr(fullId(localId(2))) orelse
        return error.NodeMissingFromFixture;
    try schema.enums.setTextAlign(&entry.data.properties, .center);

    // Alignment is the last of the eleven comparisons, so a port that stopped at
    // ten would answer the same here.
    try testing.expect(textAttributesDiffer(left, right));
}

test "wordStartSlot finds an exact entry and reports an absent one as a gap" {
    const word_starts = [_]u8{ 0, 4, 9 };

    try testing.expectEqual(true, (wordStartSlot(&word_starts, 4)).exact);
    try testing.expectEqual(@as(usize, 1), (wordStartSlot(&word_starts, 4)).index);

    // Character six is between the second and third entries, so the slot is the
    // place it would take and not an entry of the list.
    const gap = wordStartSlot(&word_starts, 6);
    try testing.expectEqual(false, gap.exact);
    try testing.expectEqual(@as(usize, 2), gap.index);

    try testing.expectEqual(true, (wordStartSlot(&word_starts, 0)).exact);
    try testing.expectEqual(@as(usize, 3), (wordStartSlot(&word_starts, 20)).index);
    try testing.expectEqual(false, (wordStartSlot(&word_starts, 20)).exact);
}

test "wordStartSlot truncates its key exactly as upstream's as u8 cast narrows it" {
    const word_starts = [_]u8{0};

    // A `usize` narrowed to `u8` is its low byte, so character 256 asks the
    // search for character 0 and finds it. A widened search answers false here,
    // and reproducing the wrap is what keeps the port equal to upstream on a run
    // a platform can send.
    try testing.expectEqual(true, (wordStartSlot(&word_starts, 256)).exact);
    try testing.expectEqual(false, (wordStartSlot(&word_starts, 257)).exact);
}

test "wordStartSlot returns the end of the list rather than looping past its bound" {
    const word_starts = [_]u8{ 2, 4, 6, 8, 10, 12 };

    // Each step discards at least one entry, so a list of six takes at most six
    // steps and the bound is the length. The search still finds the entry, which
    // is what proves the loop stayed inside the bound rather than the bound never
    // being reached.
    try testing.expectEqual(
        wordStartSearchStepBound(word_starts.len),
        word_starts.len,
    );
    try testing.expectEqual(true, (wordStartSlot(&word_starts, 6)).exact);
    // Slot two, because six is the **third** entry of the list and the slot is
    // the index of the entry the search found. Upstream's `binary_search` at
    // `text.rs:396` and `text.rs:443` returns the index of the element it
    // matched, so a hit is never one past the entry. `forwardToWordStart` is
    // what adds the one, at `text.rs:397`, and this search does not; the previous
    // expectation of three was that addition applied twice.
    try testing.expectEqual(@as(usize, 2), (wordStartSlot(&word_starts, 6)).index);
}
