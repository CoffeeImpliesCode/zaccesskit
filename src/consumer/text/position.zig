//! `Position`: a position inside a document, and the index-unit conversions
//! that put it on the same scale as the rest of the world.
//!
//! Upstream `accesskit_consumer/src/text.rs:161-332`, less the three character
//! movements at `text.rs:308-341`, which `text/position_motion.zig` owns with
//! the other twenty-seven so that every movement sits in one file.
//!
//! **`Position` is `InnerPosition` plus the document it belongs to.** The inner
//! position names a run and a character index; the root node is the document the
//! run is read against, and every walk below needs it: a run of two documents
//! has no meaning on its own, because the same run id in the other document is a
//! different run. `text/position_inner.zig` states the index units for the inner
//! half; this module doc states them again for the two conversions, because those
//! are the two functions in the whole layer that *change* unit and a caller
//! reading only their signature cannot tell.
//!
//! **The index units, at every boundary.** Three units are in play and all three
//! disagree for anything outside ASCII.
//!
//! - A **byte offset** is an index into a run's `value` slice, which is UTF-8.
//!   `character_lengths[i]` is the byte length of character `i`, so summing the
//!   first `n` entries gives the byte offset of character `n`.
//! - A **character index** counts Unicode scalar values. Every `character_index`
//!   field in this layer is in this unit, and every function that takes one
//!   takes it in this unit.
//! - A **UTF-16 code unit index** counts UTF-16 code units over the same text.
//!   One scalar value above the basic multilingual plane is two units and every
//!   other is one.
//!
//! **The three conversions and what each one takes and returns.**
//!
//! - `toGlobalUsvIndex(position) usize` takes a **character index** in and returns
//!   a **character index** out, counted over every run of the document in
//!   document order. The two are different scales even though the unit matches:
//!   the return counts from the start of the document, the argument counts from
//!   the start of its own run.
//! - `toGlobalUtf16Index(position) usize` takes a **character index** in and
//!   returns a **UTF-16 code unit index** out. This is the only function in the
//!   layer where the input and output units differ, and it is the one a caller
//!   misreads: a document of three ASCII characters answers the same for both,
//!   and one astral character separates them.
//! - `toLineIndex(position) usize` takes a **character index** in and returns a
//!   **line number**, counted from zero with the first line as zero.
//!
//! `toDegenerateRange` takes a **character index** and returns a `Range` whose two
//! ends are that position, so a range of one character.
//!
//! **Where the byte offset lives.** It never appears in a signature. It exists
//! only inside the two conversions, as the sum of `character_lengths` used to
//! slice `value`, because a character index cannot slice a byte string directly.
//! The sum is what `node_text[..slice_end]` needs, and `slice_end` is a byte
//! offset into that one run's `value`, not an offset into the document.
//!
//! **The bias, restated where it is applied.** `biasedToStart` moves forward to
//! the start of the next run and `biasedToEnd` moves backward to the end of the
//! previous one. This module adds `isFormatStart`, which depends on the backward
//! case: a position at the start of a run begins a new format exactly when the
//! run before it formatted its text differently, which is only meaningful when
//! the position has a run before it. The full statement of the two directions is
//! in `text/position_inner.zig`'s module doc; the reason it is repeated here is
//! that `isFormatStart` is where a caller who has only this file will meet it.
//!
//! **What this module deliberately does not own.** The thirty movement methods
//! are `text/position_motion.zig`'s. The two bounded line walks are
//! `text/line_walk.zig`'s. The ordering key and the bias helpers are
//! `text/position_inner.zig`'s, and this module calls them rather than
//! reimplementing any of them. `Range` is `text/range.zig`'s.
//!
//! **The allocator rule.** An allocating free function takes `gpa` first per
//! `AGENTS.md:99`. `toGlobalUsvIndex` and `toGlobalUtf16Index` allocate nothing
//! on the run walk they perform, and they take no allocator. Nothing in this file
//! allocates except through a call to `text/position_inner.zig`, which does.
//!
//! **The walk in `toLineIndex` is bounded.** It walks backward one line at a time
//! to the document start, and `docs/33` section 7's "walks that take the same
//! bound" list names `text.rs:287` for this file, so the bound is
//! `treeWalkStepBound` and the tag is `error.TreeCycle`.
//!
//! No function here reads a clock, opens a file or reaches for a runtime, so none
//! takes `io`.

const std = @import("std");
const schema = @import("../../schema/root.zig");

const line_walk = @import("line_walk.zig");
const node_ids = @import("../node_id.zig");
const position_inner = @import("position_inner.zig");
const tree_state = @import("../tree_state.zig");

const InnerPosition = position_inner.InnerPosition;
const NodeRef = node_ids.NodeRef;
const QueryError = tree_state.QueryError;
const TextPosition = schema.TextPosition;
const treeWalkStepBound = tree_state.treeWalkStepBound;

const assert = std.debug.assert;
const testing = std.testing;

// --- The type and its two trivial lifts, text.rs:161-173 -----------------------

/// A position inside one document: the node the document hangs off, and the run
/// and character index inside it. Upstream `Position<'a>`, `text.rs:161-164`.
///
/// **`character_index` is a character index**, not a byte offset and not a UTF-16
/// code unit index; the module doc states all three units. An index equal to the
/// run's `character_lengths` length is valid and means one past its last
/// character.
///
/// **Both fields borrow.** `root_node` and `inner.node` are two `NodeRef`
/// handles, each holding pointers into one `TreeState`, and the borrow ends at
/// the next call that can grow `TreeState.nodes`, because growing the map moves
/// its entries. Rebuild every `Position` after an update. The value owns nothing,
/// so it has no `deinit`, a copy is a second handle rather than a second owner,
/// and releasing a copy would be a double free.
///
/// **The two halves are not interchangeable.** `inner.node` names the run the
/// position sits in and `root_node` names the document; they are different nodes
/// and the type does not say the run is inside the document, so a caller must not
/// read one as the other.
pub const Position = struct {
    /// The node the document's text hangs off. Every walk below is measured
    /// against this node.
    root_node: NodeRef,

    /// Where in the document the position sits: the run, and a character index
    /// into that run.
    inner: InnerPosition,
};

/// The stored form of `position`: a local node id and a character index.
///
/// The value is meaningful only in the document `position` was taken from, so a
/// caller that keeps it past an update is holding a stale offset. It borrows
/// nothing. Upstream `Position::to_raw` at `text.rs:167-169`.
pub fn toRaw(position: Position) TextPosition {
    return position_inner.downgrade(position.inner);
}

/// The run `position` sits in.
///
/// A copy of the handle `position.inner` holds, not a borrow of `position`, so
/// the result stays valid after `position` goes away and needs no release. Upstream
/// `Position::inner_node` at `text.rs:171-173`.
pub fn innerNode(position: Position) NodeRef {
    return position.inner.node;
}

/// Whether `position` names the same offset of the same run of the same
/// document. Upstream `impl PartialEq for Position` at `text.rs:575-581`.
///
/// `false` when the two documents differ, because a position in one document has
/// no ordering against a position in another.
pub fn eql(a: Position, b: Position) bool {
    return std.meta.eql(a.root_node.id(), b.root_node.id()) and
        position_inner.eql(a.inner, b.inner);
}

// --- The predicates, text.rs:175-235 -------------------------------------------

/// Whether `position` begins a run of text whose formatting differs from the run
/// before it, and so is the first character of a new format run.
///
/// True at the document start, because nothing precedes it. Otherwise the
/// position must be at character zero of its run and the run before it must
/// format its text differently. Upstream `Position::is_format_start` at
/// `text.rs:175-186`.
///
/// **`error.TreeCycle` and `error.NoSuchNode`** come from the preceding-sibling
/// scan and from the document-start test. Allocates nothing.
pub fn isFormatStart(position: Position) QueryError!bool {
    if (try position_inner.isDocumentStart(position.inner, position.root_node)) return true;
    if (position.inner.character_index != 0) return false;
    var runs = try position_inner.precedingTextRuns(position.inner.node, position.root_node);
    // Upstream unwraps this at `text.rs:184` because the first test has already
    // established that a preceding run exists. A port cannot rely on that: a
    // platform can send a run whose `previous_on_line` chain is inconsistent,
    // and rule C8 bans the abort, so an absent run answers `true`, which is what
    // the document-start test above would have answered.
    const previous = (try runs.next()) orelse return true;
    return position_inner.textAttributesDiffer(position.inner.node, previous);
}

/// Whether `position` is at the start of a word.
///
/// True at the start of a paragraph, because a paragraph begins a word. Otherwise
/// the position must be a character index this run lists in `word_starts`.
/// Upstream `Position::is_word_start` at `text.rs:188-197`, whose `binary_search`
/// narrows the index to a `u8` first; see `position_inner.wordStartSlot`, which
/// narrows it the same way.
///
/// Allocates nothing and cannot fail.
pub fn isWordStart(position: Position) bool {
    const slot = position_inner.wordStartSlot(
        schema.vectors.wordStarts(&position.inner.node.data().properties),
        position.inner.character_index,
    );
    return slot.exact;
}

/// Whether `position` opens a visual line. Upstream `Position::is_line_start` at
/// `text.rs:199-201`. Allocates nothing and cannot fail.
pub fn isLineStart(position: Position) bool {
    return position_inner.isLineStart(position.inner);
}

/// Whether `position` closes a visual line. Upstream `Position::is_line_end` at
/// `text.rs:203-205`. Allocates nothing and cannot fail.
pub fn isLineEnd(position: Position) bool {
    return position_inner.isLineEnd(position.inner);
}

/// Whether `position` opens a paragraph.
///
/// True at the document start. Otherwise the position must open a line **and**
/// the line must end with a paragraph break, which is read from the *previous*
/// run on that line: the run before `position` holds the end of the line and so
/// holds the newline. That is the backward bias, and it is why this test and not
/// a forward one. Upstream `Position::is_paragraph_start` at `text.rs:207-211`.
///
/// **`error.TreeCycle` and `error.NoSuchNode`** come from the document-start test
/// and the backward bias. Allocates nothing.
pub fn isParagraphStart(position: Position) QueryError!bool {
    if (try position_inner.isDocumentStart(position.inner, position.root_node)) return true;
    if (!position_inner.isLineStart(position.inner)) return false;
    const previous = try position_inner.biasedToEnd(position.inner, position.root_node);
    return position_inner.isParagraphEnd(previous);
}

/// Whether `position` closes a paragraph.
///
/// True at the document end, because the end of the document is the end of the
/// last paragraph. Otherwise the position must be the end of a line whose text
/// ends with a newline. Upstream `Position::is_paragraph_end` at `text.rs:213-215`.
///
/// **`error.TreeCycle` and `error.NoSuchNode`** come from the document-end test.
pub fn isParagraphEnd(position: Position) QueryError!bool {
    if (try position_inner.isDocumentEnd(position.inner, position.root_node)) return true;
    return position_inner.isParagraphEnd(position.inner);
}

/// Whether `position` sits on the newline that separates two paragraphs.
///
/// False at the document end, because there is no next paragraph to separate.
/// Otherwise the position one character forward must close a paragraph, which is
/// the forward bias. Upstream `Position::is_paragraph_separator` at
/// `text.rs:217-223`.
///
/// **`error.TreeCycle` and `error.NoSuchNode`** come from the document-end test.
pub fn isParagraphSeparator(position: Position) QueryError!bool {
    if (try position_inner.isDocumentEnd(position.inner, position.root_node)) return false;
    const next = try forwardToCharacterEnd(position);
    if (try position_inner.isDocumentEnd(next.inner, position.root_node)) return false;
    return position_inner.isParagraphEnd(next.inner);
}

/// Whether `position` is the first position of the document. Upstream
/// `Position::is_page_start` at `text.rs:225-227`, which answers exactly what
/// `isDocumentStart` answers: a text document has one page, and the port says so
/// rather than inventing a second notion of position on it.
///
/// **`error.TreeCycle` and `error.NoSuchNode`** come from the walk.
pub fn isPageStart(position: Position) QueryError!bool {
    return position_inner.isDocumentStart(position.inner, position.root_node);
}

/// Whether `position` is the first position of the document. Upstream
/// `Position::is_document_start` at `text.rs:229-231`.
///
/// **`error.TreeCycle` and `error.NoSuchNode`** come from the preceding-sibling
/// scan.
pub fn isDocumentStart(position: Position) QueryError!bool {
    return position_inner.isDocumentStart(position.inner, position.root_node);
}

/// Whether `position` is one past the last position of the document. Upstream
/// `Position::is_document_end` at `text.rs:233-235`.
///
/// **`error.TreeCycle` and `error.NoSuchNode`** come from the following-sibling
/// scan.
pub fn isDocumentEnd(position: Position) QueryError!bool {
    return position_inner.isDocumentEnd(position.inner, position.root_node);
}

// --- The three character movements at text.rs:308-341 -------------------------

/// `position` moved forward one character, or to the start of the next run if
/// that was nearer.
///
/// The forward bias, then `+ 1`, then the forward bias again: the second bias is
/// what turns one-past-the-end-of-a-run into the start of the run after it. Upstream
/// `Position::forward_to_character_start` at `text.rs:308-318`.
///
/// **`error.TreeCycle` and `error.NoSuchNode`** come from the bias. Allocates
/// nothing.
pub fn forwardToCharacterStart(position: Position) QueryError!Position {
    const biased = try position_inner.biasedToStart(position.inner, position.root_node);
    return .{
        .root_node = position.root_node,
        .inner = try position_inner.biasedToStart(.{
            .node = biased.node,
            .character_index = biased.character_index + 1,
        }, position.root_node),
    };
}

/// `position` moved forward one character without leaving its run.
///
/// This is the **unbiased** step. It is what `isParagraphSeparator` uses to look
/// at the character after a position, and it is the one movement that does not
/// normalize across a run boundary, so at the end of a run it reports one past
/// that run's last character rather than the start of the next run. Upstream
/// `Position::forward_to_character_end` at `text.rs:320-329`.
///
/// **`error.TreeCycle` and `error.NoSuchNode`** come from the bias. Allocates
/// nothing.
pub fn forwardToCharacterEnd(position: Position) QueryError!Position {
    const biased = try position_inner.biasedToStart(position.inner, position.root_node);
    return .{
        .root_node = position.root_node,
        .inner = .{
            .node = biased.node,
            .character_index = biased.character_index + 1,
        },
    };
}

/// `position` moved backward one character, or to the end of the previous run if
/// that was nearer.
///
/// The backward bias, then `- 1`, then the forward bias: the last step is what
/// turns one-before-the-start-of-a-run into the end of the run before it. Upstream
/// `Position::backward_to_character_start` at `text.rs:331-341`.
///
/// **`error.LineChainCycle`** when the `previous_on_line` chain of the run behind
/// the position repeats, and **`error.NoSuchNode`** when a link names a node the
/// state does not hold. Both come from the bias. Allocates nothing.
pub fn backwardToCharacterStart(position: Position) QueryError!Position {
    const biased = try position_inner.biasedToEnd(position.inner, position.root_node);
    if (biased.character_index == 0) return error.InvalidPosition;
    return .{
        .root_node = position.root_node,
        .inner = try position_inner.biasedToStart(.{
            .node = biased.node,
            .character_index = biased.character_index - 1,
        }, position.root_node),
    };
}

// --- The index-unit conversions, text.rs:237-292 -------------------------------

/// The one-character range at `position`.
///
/// Both ends are `position`, so the range names no characters, and the ends are
/// already in order so nothing needs comparing. Upstream
/// `Position::to_degenerate_range` at `text.rs:237-239` builds the same value
/// through `Range::new(self.root_node, self.inner, self.inner)`.
///
/// **The range is measured against `position.root_node`, not against the run the
/// position sits in.** `Range.node` names the node the range is measured
/// against, and upstream passes the root for exactly that. Passing the run
/// instead is wrong in three places a caller can see: `setStart` and `setEnd`
/// then reject every legitimate position, because `setStart`'s check is that the
/// position's root is the range's node; `eql` never matches a range built any
/// other way; and `downgrade` records the run's id, so the weak range fails to
/// upgrade and `query.supportsTextRanges` answers false for a text run. This
/// function used to fill the field with `position.inner.node`.
///
/// **`text/range.zig`'s own `toDegenerateRange` is the spelling that was right**,
/// and it passes `position.root_node`. One upstream line had two implementations
/// here that disagreed.
///
/// Allocates nothing and cannot fail.
pub fn degenerateRangeParts(position: Position) struct {
    node: NodeRef,
    start: InnerPosition,
    end: InnerPosition,
} {
    return .{ .node = position.root_node, .start = position.inner, .end = position.inner };
}

/// The offset of `position` counted in **Unicode scalar values** from the start
/// of the document.
///
/// **Takes a character index, returns a character index.** The two are different
/// scales over the same unit: the argument counts from the start of its own run
/// and the result counts from the start of the document, so the result is never
/// smaller than the argument.
///
/// **`error.InvalidPosition`** replaces upstream's `panic!("invalid position")`
/// at `text.rs:256`, which fires when the position names a run the document does
/// not hold. **`error.TreeCycle`** and **`error.NoSuchNode`** come from the run
/// walk and from the character-count read.
///
/// Allocates nothing.
pub fn toGlobalUsvIndex(position: Position) QueryError!usize {
    var total: usize = 0;
    var runs = try position_inner.textRuns(position.root_node);
    while (try runs.next()) |run| {
        const text = schema.strings.value(&run.data().properties) orelse continue;
        if (std.meta.eql(run.id(), position.inner.node.id())) {
            const offset = byteOffsetOf(&run.data().properties, position.inner.character_index);
            const here = std.unicode.utf8CountCodepoints(text[0..offset]) catch offset;
            return total + here;
        }
        total += std.unicode.utf8CountCodepoints(text) catch text.len;
    }
    return error.InvalidPosition;
}

/// The offset of `position` counted in **UTF-16 code units** from the start of the
/// document.
///
/// **Takes a character index, returns a UTF-16 code unit index.** This is the one
/// function in the layer whose input and output units differ, and the two agree
/// only while every character is in the basic multilingual plane. A run holding
/// one astral character and two ASCII characters returns 4 here and 3 from
/// `toGlobalUsvIndex`; a test asserts that difference rather than leaving it to a
/// reader.
///
/// **`error.InvalidPosition`**, **`error.TreeCycle`** and **`error.NoSuchNode`**
/// mean what they mean in `toGlobalUsvIndex`; the panic this replaces is at
/// `text.rs:278`. Allocates nothing.
pub fn toGlobalUtf16Index(position: Position) QueryError!usize {
    var total: usize = 0;
    var runs = try position_inner.textRuns(position.root_node);
    while (try runs.next()) |run| {
        const text = schema.strings.value(&run.data().properties) orelse continue;
        if (std.meta.eql(run.id(), position.inner.node.id())) {
            const offset = byteOffsetOf(&run.data().properties, position.inner.character_index);
            return total + utf16Length(text[0..offset]);
        }
        total += utf16Length(text);
    }
    return error.InvalidPosition;
}

/// The line number `position` sits on, counting the first line as zero.
///
/// **Takes a character index, returns a line number.** Walks backward one line at
/// a time to the document start and counts the steps, so the answer is how many
/// line starts precede the line, and the line `position` is on is one after the
/// last one it passed. Upstream `Position::to_line_index` at `text.rs:281-292`.
///
/// **The bound.** `treeWalkStepBound(node_count)`, and `docs/33` section 7's
/// "walks that take the same bound" list names `text.rs:287` for this file.
/// **`error.TreeCycle`** when the backward walk overruns it, and
/// **`error.NoSuchNode`** when a `previous_on_line` link names a node the state
/// does not hold. Allocates nothing.
pub fn toLineIndex(position: Position) QueryError!usize {
    var current = if (position_inner.isLineStart(position.inner))
        position
    else
        try backwardToLineStart(position);

    var lines_before: usize = 0;
    const step_bound = treeWalkStepBound(position.root_node.tree_state.nodes.count());
    var step: usize = 0;
    while (!(try position_inner.isDocumentStart(current.inner, position.root_node))) {
        if (step == step_bound) return error.TreeCycle;
        step += 1;
        current = try backwardToLineStart(current);
        lines_before += 1;
    }
    return lines_before;
}

/// The start of the line `position` sits on.
///
/// Upstream has this on `Position` at `text.rs:508-514`, in the movement half of
/// the file. It is declared here because `toLineIndex` above calls it, and a
/// module that needs a movement must not import the module above it.
pub fn backwardToLineStart(position: Position) QueryError!Position {
    const biased = try position_inner.biasedToEnd(position.inner, position.root_node);
    return .{
        .root_node = position.root_node,
        .inner = try position_inner.biasedToStart(
            try line_walk.lineStart(biased),
            position.root_node,
        ),
    };
}

comptime {
    // A root handle, a run handle and a character index: two `NodeRef` values
    // plus the index. Measured, so a field added here is a build failure rather
    // than a silent change to what every text module passes by value.
    assert(@sizeOf(Position) == 2 * @sizeOf(NodeRef) + @sizeOf(usize));
    assert(@offsetOf(Position, "inner") == @sizeOf(NodeRef));
}

// --- The private helpers -------------------------------------------------------

/// The **byte offset** of character `character_index` in a run whose
/// `character_lengths` are `lengths`.
///
/// This is the only place the three index units meet. `lengths` is a byte count
/// per character, so the running sum is a byte offset; and `character_index` is a
/// character index, so it indexes `lengths` and not `value` directly. The sum is
/// clamped to `value.len`, because a platform can send a `character_lengths` whose
/// total disagrees with its `value` and a slice past the end is a panic rather
/// than a wrong number.
fn byteOffsetOf(properties: *const schema.Properties, character_index: usize) usize {
    const lengths = schema.vectors.characterLengths(properties);
    const counted = @min(character_index, lengths.len);
    var offset: usize = 0;
    for (lengths[0..counted]) |length| offset += length;
    const value = schema.strings.value(properties) orelse return 0;
    return @min(offset, value.len);
}

/// The length of `text` in UTF-16 code units.
///
/// One unit per scalar value below the basic multilingual plane and two above it.
/// Counts an ill-formed byte sequence as one unit, because `value` is a byte
/// slice from a platform and a position must still have an answer.
fn utf16Length(text: []const u8) usize {
    var total: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const width = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const next = @min(index + width, text.len);
        total += utf16UnitsIn(text[index..next]);
        index = next;
    }
    return total;
}

/// The UTF-16 code units the one code point in `bytes` holds: two when the code
/// point is outside the basic multilingual plane and one otherwise. Ill-formed
/// `bytes` is one unit, which is what the walk in `utf16Length` above counts for
/// a byte it cannot decode.
fn utf16UnitsIn(bytes: []const u8) usize {
    var view = std.unicode.Utf8View.init(bytes) catch return 1;
    var iterator = view.iterator();
    const codepoint = iterator.nextCodepointSlice() orelse return 1;
    return if (codepoint.len == 4) 2 else 1;
}

// --- Tests ---------------------------------------------------------------------

// --- Tests ---------------------------------------------------------------------

const test_allocator = testing.allocator;
const Node = schema.Node;
const NodeId = schema.NodeId;
const tree_index = @import("../tree_index.zig");
const FullNodeId = tree_index.FullNodeId;
const ParentAndIndex = tree_index.ParentAndIndex;
const TreeState = tree_state.TreeState;

/// The optional properties a fixture run may carry beyond its text.
///
/// A plain struct rather than a closure: the house rules forbid a captured
/// variable, and a build step is a place a capture would go.
const RunExtras = struct {
    font_size: ?f32 = null,
    language: ?[]const u8 = null,
    text_align: ?schema.TextAlign = null,
    previous_on_line: ?NodeId = null,
    next_on_line: ?NodeId = null,
    word_starts: ?[]const u8 = null,
    /// Set after `buildRun` returns, through `setRunLinks`, so a fixture that
    /// needs a link in both directions does not need two builders.
    none: void = {},
};

fn localId(raw: u64) NodeId {
    return .{ .value = raw };
}

fn fullId(id: NodeId) FullNodeId {
    return FullNodeId.init(id, .init(0));
}

/// A state whose root is node 1. Every fixture puts the nodes it names, so the
/// map holds nothing else and a node count in a test is the count the fixture
/// built.
fn testState() TreeState {
    return .{ .root_id = fullId(localId(1)), .focus_id = fullId(localId(1)) };
}

fn refOf(state: *TreeState, id: NodeId) !NodeRef {
    return NodeRef.init(state, fullId(id)) orelse error.NodeMissingFromFixture;
}

fn parentOf(parent: NodeId, index: usize) ParentAndIndex {
    return .{ .parent_id = fullId(parent), .index = index };
}

/// Builds one node, releasing it if any property write fails.
///
/// The caller owns the result and hands it to `put`, which releases it again if
/// the map cannot take it. No caller writes its own guard, because one that did
/// would release the same node twice on the first failure.
fn buildNode(role: schema.Role, extras: RunExtras) std.mem.Allocator.Error!Node {
    var node = Node.init(test_allocator, role);
    errdefer node.deinit();
    if (extras.font_size) |size| try schema.numbers.setFontSize(&node.properties, size);
    if (extras.language) |tag| try schema.strings.setLanguage(&node.properties, tag);
    if (extras.text_align) |value| try schema.enums.setTextAlign(&node.properties, value);
    if (extras.word_starts) |starts| try schema.vectors.setWordStarts(&node.properties, starts);
    return node;
}

/// Builds a text run holding `text`.
///
/// `byte_lengths` gives the byte length of each character, which is what
/// `character_lengths` stores and what makes the byte offset of every character
/// its running sum.
fn buildRun(
    text: []const u8,
    byte_lengths: []const u8,
    extras: RunExtras,
) std.mem.Allocator.Error!Node {
    var run = try buildNode(.text_run, extras);
    errdefer run.deinit();
    try schema.strings.setValue(&run.properties, text);
    try schema.vectors.setCharacterLengths(&run.properties, byte_lengths);
    return run;
}

/// Adds one node under `id`, taking ownership of `node`.
///
/// On failure `node` is released here, so no caller needs its own guard and
/// cannot release it twice.
fn put(state: *TreeState, id: NodeId, parent: ?ParentAndIndex, node: *Node) !void {
    errdefer node.deinit();
    try state.nodes.put(test_allocator, fullId(id), .{
        .parent_and_index = parent,
        .data = node.*,
    });
    // SAFETY: the map copied `node` by value on the lines above, so the
    // caller-owned slot no longer owns the properties, and no statement after
    // it reads `node`. A read anyway traps in Debug rather than aliasing the
    // stored copy with two owners.
    node.* = undefined;
}

/// Stores a run under `id` at `index` among the document root's children.
///
/// The run is handed over to the state, so a caller that keeps the returned
/// handle must not release the node.
fn addRun(
    state: *TreeState,
    id: NodeId,
    index: usize,
    text: []const u8,
    byte_lengths: []const u8,
    extras: RunExtras,
) !NodeRef {
    var run = try buildRun(text, byte_lengths, extras);
    try put(state, id, parentOf(localId(1), index), &run);
    return refOf(state, id);
}

/// Writes a `previous_on_line` or `next_on_line` onto a run already in the state.
///
/// A separate step because the two directions of a link often refer to runs the
/// fixture has not stored yet.
fn setRunLink(state: *TreeState, id: NodeId, previous: ?NodeId, next: ?NodeId) !void {
    const entry = state.nodes.getPtr(fullId(id)) orelse return error.NodeMissingFromFixture;
    if (previous) |target| try schema.ids_props.setPreviousOnLine(&entry.data.properties, target);
    if (next) |target| try schema.ids_props.setNextOnLine(&entry.data.properties, target);
}

/// Stores the document root, whose `children` list names the runs in order.
fn addDocumentRoot(state: *TreeState, children: []const NodeId) !NodeRef {
    var root = try buildNode(.document, .{});
    errdefer root.deinit();
    try schema.ids_props.setChildren(&root.properties, children);
    try put(state, localId(1), null, &root);
    return refOf(state, localId(1));
}

/// A document root holding one run with the given text and byte lengths.
fn oneRunDocument(text: []const u8, byte_lengths: []const u8) !TreeState {
    var state = testState();
    errdefer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{localId(2)});
    _ = try addRun(&state, localId(2), 0, text, byte_lengths, .{});
    return state;
}

test "toRaw carries a character index and innerNode names the run" {
    var state = try oneRunDocument("abc", &.{ 1, 1, 1 });
    defer state.deinit(test_allocator);
    const root = try refOf(&state, localId(1));
    const position: Position = .{
        .root_node = root,
        .inner = .{ .node = try refOf(&state, localId(2)), .character_index = 2 },
    };

    // The stored form keeps the character index and not a byte offset, so
    // character two of a three-character run is stored as two.
    const stored = toRaw(position);
    try testing.expectEqual(localId(2), stored.node_id);
    try testing.expectEqual(@as(usize, 2), stored.character_index);

    // The two handles in one position name two different nodes, so a caller that
    // read the inner one as the document sees the run here.
    try testing.expect(innerNode(position).id().local.eql(localId(2)));
    try testing.expect(!innerNode(position).id().local.eql(root.id().local));
}

test "eql needs the same document and the same offset of the same run" {
    var state = try oneRunDocument("ab", &.{ 1, 1 });
    defer state.deinit(test_allocator);
    const root = try refOf(&state, localId(1));
    const run = try refOf(&state, localId(2));
    const early: Position = .{ .root_node = root, .inner = .{ .node = run, .character_index = 0 } };
    const late: Position = .{ .root_node = root, .inner = .{ .node = run, .character_index = 1 } };

    try testing.expect(eql(early, early));
    try testing.expect(!eql(early, late));

    // A second document whose root and run carry different ids, so the two
    // positions differ in the fields a comparison reads. A comparison that
    // ignored the document would answer true here.
    var other = testState();
    defer other.deinit(test_allocator);
    _ = try addDocumentRoot(&other, &.{localId(7)});
    _ = try addRun(&other, localId(7), 0, "ab", &.{ 1, 1 }, .{});
    const elsewhere: Position = .{
        .root_node = try refOf(&other, localId(1)),
        .inner = .{ .node = try refOf(&other, localId(7)), .character_index = 0 },
    };

    try testing.expect(!eql(early, elsewhere));
}

test "degenerateRangeParts reports the position at both ends" {
    var state = try oneRunDocument("ab", &.{ 1, 1 });
    defer state.deinit(test_allocator);
    const root = try refOf(&state, localId(1));
    const position: Position = .{
        .root_node = root,
        .inner = .{ .node = try refOf(&state, localId(2)), .character_index = 1 },
    };

    // A degenerate range names no characters, so both ends are the one position.
    const parts = degenerateRangeParts(position);
    try testing.expect(position_inner.eql(parts.start, position.inner));
    try testing.expect(position_inner.eql(parts.end, position.inner));
    try testing.expect(position_inner.eql(parts.start, parts.end));
}

test "toGlobalUsvIndex counts a character index over every run of the document" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "ab", &.{ 1, 1 }, .{});
    _ = try addRun(&state, localId(3), 1, "cde", &.{ 1, 1, 1 }, .{});
    const root = try refOf(&state, localId(1));
    const second = try refOf(&state, localId(3));

    // Character zero of the second run is character two of the document, because
    // the first run holds two characters.
    try testing.expectEqual(@as(usize, 2), try toGlobalUsvIndex(.{
        .root_node = root,
        .inner = .{ .node = second, .character_index = 0 },
    }));
    // The end of the second run is the end of the document, so it is five.
    try testing.expectEqual(@as(usize, 5), try toGlobalUsvIndex(.{
        .root_node = root,
        .inner = .{ .node = second, .character_index = 3 },
    }));
}

test "the three index units disagree on a multi-byte character" {
    // "a", then U+1F642, a four-byte scalar value two UTF-16 units wide, then "b".
    // The run has three characters, seven bytes and five UTF-16 code units, and
    // every unit below is a different number for the same position.
    const text = "a\u{1F642}b";
    var state = try oneRunDocument(text, &.{ 1, 4, 1 });
    defer state.deinit(test_allocator);
    const root = try refOf(&state, localId(1));
    const run = try refOf(&state, localId(2));

    // Six bytes: the byte offset is a fourth number and the one no signature
    // names. One byte for "a", four for the astral character, one for "b".
    try testing.expectEqual(@as(usize, 6), text.len);

    // The **byte offset** of character two is one plus four, which is neither
    // the character index nor the UTF-16 index.
    try testing.expectEqual(@as(usize, 5), byteOffsetOf(&run.data().properties, 2));

    // The **character index** is two: two scalar values precede the position.
    try testing.expectEqual(@as(usize, 2), try toGlobalUsvIndex(.{
        .root_node = root,
        .inner = .{ .node = run, .character_index = 2 },
    }));

    // The **UTF-16 code unit index** is three: the astral character is two units,
    // so one plus two precede the position. A conversion that counted bytes
    // would answer five and one that counted characters would answer two.
    try testing.expectEqual(@as(usize, 3), try toGlobalUtf16Index(.{
        .root_node = root,
        .inner = .{ .node = run, .character_index = 2 },
    }));

    // The whole document is three characters and four UTF-16 units, which is the
    // difference the two functions exist to express.
    try testing.expectEqual(@as(usize, 3), try toGlobalUsvIndex(.{
        .root_node = root,
        .inner = .{ .node = run, .character_index = 3 },
    }));
    try testing.expectEqual(@as(usize, 4), try toGlobalUtf16Index(.{
        .root_node = root,
        .inner = .{ .node = run, .character_index = 3 },
    }));
}

test "the two global conversions agree at every offset of an ASCII run" {
    var ascii = try oneRunDocument("abcd", &.{ 1, 1, 1, 1 });
    defer ascii.deinit(test_allocator);
    const ascii_root = try refOf(&ascii, localId(1));
    const ascii_run = try refOf(&ascii, localId(2));

    // Every character is one byte, one scalar value and one UTF-16 unit, so the
    // two functions answer the same at every offset. This is the case that hides
    // the difference, and it is why the multi-byte test above exists.
    for (0..4) |index| {
        const at: Position = .{
            .root_node = ascii_root,
            .inner = .{ .node = ascii_run, .character_index = index },
        };
        try testing.expectEqual(try toGlobalUsvIndex(at), try toGlobalUtf16Index(at));
    }
}

test "toGlobalUsvIndex reports InvalidPosition for a run the document does not hold" {
    var state = try oneRunDocument("ab", &.{ 1, 1 });
    defer state.deinit(test_allocator);

    // A second document **inside the same state**, under tree index one. A
    // second `TreeState` would not do: both would number their root tree zero,
    // so that root's run would carry the same `FullNodeId` as this document's
    // run, the walk would find that run rather than miss one, and the test would
    // measure the wrong document instead of reaching the tag. The tree index is
    // what tells two documents apart inside one state, and the `std.meta.eql`
    // that `toGlobalUsvIndex` reads is what reads it.
    const other_run: FullNodeId = FullNodeId.init(localId(2), .init(1));
    const foreign = try buildRun("xy", &.{ 1, 1 }, .{});
    try state.nodes.put(test_allocator, other_run, .{
        .parent_and_index = null,
        .data = foreign,
    });

    // The position names a run of the other document, so the walk over this one
    // never finds it. Upstream panics at `text.rs:256` and `text.rs:278`, and a
    // caller cannot act on an abort.
    const off_document: Position = .{
        .root_node = try refOf(&state, localId(1)),
        .inner = .{
            .node = NodeRef.init(&state, other_run) orelse return error.NodeMissingFromFixture,
            .character_index = 1,
        },
    };

    try testing.expectError(error.InvalidPosition, toGlobalUsvIndex(off_document));
    try testing.expectError(error.InvalidPosition, toGlobalUtf16Index(off_document));
}

test "byteOffsetOf clamps a character_lengths total that overruns the value" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{localId(2)});
    // Three byte lengths over a one-byte value: the two properties disagree, and
    // a slice at the sum of the lengths is a panic rather than a wrong number.
    _ = try addRun(&state, localId(2), 0, "a", &.{ 4, 4, 4 }, .{});
    const run = try refOf(&state, localId(2));

    try testing.expectEqual(@as(usize, 1), byteOffsetOf(&run.data().properties, 3));
    // An index past the list clamps to the list, so the offset is the whole sum
    // and not a read past the end of it.
    try testing.expectEqual(@as(usize, 1), byteOffsetOf(&run.data().properties, 99));
}

test "isWordStart answers for a listed word start and not for a listed gap" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{localId(2)});
    // Word starts at characters zero and three.
    _ = try addRun(
        &state,
        localId(2),
        0,
        "ab cd",
        &.{ 1, 1, 1, 1, 1 },
        .{ .word_starts = &.{ 0, 3 } },
    );
    const root = try refOf(&state, localId(1));
    const run = try refOf(&state, localId(2));

    try testing.expect(isWordStart(.{
        .root_node = root,
        .inner = .{ .node = run, .character_index = 0 },
    }));
    // Character three is in the list, so this is the arm that does the work.
    try testing.expect(isWordStart(.{
        .root_node = root,
        .inner = .{ .node = run, .character_index = 3 },
    }));
    // Character one is in neither the list nor the document start.
    try testing.expect(!isWordStart(.{
        .root_node = root,
        .inner = .{ .node = run, .character_index = 1 },
    }));
}

test "isFormatStart is true at the document start and at a change of font size" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "ab", &.{ 1, 1 }, .{});
    _ = try addRun(&state, localId(3), 1, "cd", &.{ 1, 1 }, .{ .font_size = 14 });
    const root = try refOf(&state, localId(1));
    const first = try refOf(&state, localId(2));
    const later = try refOf(&state, localId(3));

    // The first run of a document is a format start because nothing precedes it.
    try testing.expect(try isFormatStart(.{
        .root_node = root,
        .inner = .{ .node = first, .character_index = 0 },
    }));
    // The second run changes its font size, so its character zero is a format
    // start even though it is not the document start. This is the case that
    // needs the backward look at the run before it.
    try testing.expect(try isFormatStart(.{
        .root_node = root,
        .inner = .{ .node = later, .character_index = 0 },
    }));
    // The middle of the second run is not a format start whatever its formatting.
    try testing.expect(!try isFormatStart(.{
        .root_node = root,
        .inner = .{ .node = later, .character_index = 1 },
    }));
}

test "isFormatStart is false where the run before it formats its text the same way" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "ab", &.{ 1, 1 }, .{ .font_size = 14 });
    _ = try addRun(&state, localId(3), 1, "cd", &.{ 1, 1 }, .{ .font_size = 14 });
    const root = try refOf(&state, localId(1));
    const later = try refOf(&state, localId(3));

    // Both runs are 14 points, so the second run's start is not a format start.
    // A comparison that dropped one property, or read the wrong run, says
    // otherwise, and the preceding test alone cannot tell those apart.
    try testing.expect(!try isFormatStart(.{
        .root_node = root,
        .inner = .{ .node = later, .character_index = 0 },
    }));
}

test "isFormatStart reads the last of the eleven properties, the alignment" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "ab", &.{ 1, 1 }, .{});
    _ = try addRun(&state, localId(3), 1, "cd", &.{ 1, 1 }, .{ .text_align = .center });
    const root = try refOf(&state, localId(1));
    const later = try refOf(&state, localId(3));

    // Alignment is the eleventh comparison upstream makes. A port that stopped
    // at ten would answer false here.
    try testing.expect(try isFormatStart(.{
        .root_node = root,
        .inner = .{ .node = later, .character_index = 0 },
    }));
}

test "isParagraphStart is true where the previous run ended the paragraph" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    // The first run ends a paragraph with a newline, so the second opens one.
    _ = try addRun(&state, localId(2), 0, "ab\n", &.{ 1, 1, 1 }, .{});
    _ = try addRun(&state, localId(3), 1, "cd", &.{ 1, 1 }, .{});
    const root = try refOf(&state, localId(1));
    const first = try refOf(&state, localId(2));
    const second = try refOf(&state, localId(3));

    // The second run starts a line and the run before it ended a paragraph, so
    // the backward bias is what makes this true.
    try testing.expect(try isParagraphStart(.{
        .root_node = root,
        .inner = .{ .node = second, .character_index = 0 },
    }));
    try testing.expect(try isParagraphEnd(.{
        .root_node = root,
        .inner = .{ .node = first, .character_index = 3 },
    }));
    // The first run's own start is the document start, so it is a paragraph start
    // by the first arm of the test.
    try testing.expect(try isParagraphStart(.{
        .root_node = root,
        .inner = .{ .node = first, .character_index = 0 },
    }));
}

test "isParagraphSeparator is true on the newline and false at either paragraph end" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "ab\n", &.{ 1, 1, 1 }, .{});
    _ = try addRun(&state, localId(3), 1, "cd", &.{ 1, 1 }, .{});
    const root = try refOf(&state, localId(1));
    const first = try refOf(&state, localId(2));
    const second = try refOf(&state, localId(3));

    // The newline is the separator: one character forward closes the paragraph.
    try testing.expect(try isParagraphSeparator(.{
        .root_node = root,
        .inner = .{ .node = first, .character_index = 2 },
    }));
    // The start of the second paragraph is not a separator, and neither is the
    // document end.
    try testing.expect(!try isParagraphSeparator(.{
        .root_node = root,
        .inner = .{ .node = second, .character_index = 0 },
    }));
    try testing.expect(!try isParagraphSeparator(.{
        .root_node = root,
        .inner = .{ .node = second, .character_index = 2 },
    }));
}

test "isDocumentStart, isDocumentEnd and isPageStart name the two outer ends" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "a", &.{1}, .{});
    _ = try addRun(&state, localId(3), 1, "b", &.{1}, .{});
    const root = try refOf(&state, localId(1));
    const first = try refOf(&state, localId(2));
    const second = try refOf(&state, localId(3));

    try testing.expect(try isDocumentStart(.{
        .root_node = root,
        .inner = .{ .node = first, .character_index = 0 },
    }));
    try testing.expect(try isPageStart(.{
        .root_node = root,
        .inner = .{ .node = first, .character_index = 0 },
    }));
    try testing.expect(try isDocumentEnd(.{
        .root_node = root,
        .inner = .{ .node = second, .character_index = 1 },
    }));
    // The first run has a run after it, so its end is not the document end.
    try testing.expect(!try isDocumentEnd(.{
        .root_node = root,
        .inner = .{ .node = first, .character_index = 1 },
    }));
}

test "isLineStart and isLineEnd answer from the run's own links" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{localId(2)});
    _ = try addRun(&state, localId(2), 0, "ab", &.{ 1, 1 }, .{});
    const root = try refOf(&state, localId(1));
    const run = try refOf(&state, localId(2));

    // A lone run declares no line link in either direction, so it is both.
    try testing.expect(isLineStart(.{
        .root_node = root,
        .inner = .{ .node = run, .character_index = 0 },
    }));
    try testing.expect(isLineEnd(.{
        .root_node = root,
        .inner = .{ .node = run, .character_index = 2 },
    }));
    try testing.expect(!isLineEnd(.{
        .root_node = root,
        .inner = .{ .node = run, .character_index = 1 },
    }));
}

test "isLineStart and isLineEnd need the neighbour a linked run names" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "ab", &.{ 1, 1 }, .{});
    _ = try addRun(&state, localId(3), 1, "cd", &.{ 1, 1 }, .{});
    try setRunLink(&state, localId(2), null, localId(3));
    try setRunLink(&state, localId(3), localId(2), null);
    const root = try refOf(&state, localId(1));
    const first = try refOf(&state, localId(2));
    const second = try refOf(&state, localId(3));

    // The two runs share a line, so the first run's end is not a line end and
    // the second run's start is not a line start.
    try testing.expect(isLineStart(.{
        .root_node = root,
        .inner = .{ .node = first, .character_index = 0 },
    }));
    try testing.expect(!isLineEnd(.{
        .root_node = root,
        .inner = .{ .node = first, .character_index = 2 },
    }));
    try testing.expect(!isLineStart(.{
        .root_node = root,
        .inner = .{ .node = second, .character_index = 0 },
    }));
    try testing.expect(isLineEnd(.{
        .root_node = root,
        .inner = .{ .node = second, .character_index = 2 },
    }));
}

test "forwardToCharacterEnd steps one character without leaving its run" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "ab", &.{ 1, 1 }, .{});
    _ = try addRun(&state, localId(3), 1, "cd", &.{ 1, 1 }, .{});
    const root = try refOf(&state, localId(1));
    const first = try refOf(&state, localId(2));

    // This movement is deliberately unbiased, so at the end of the first run it
    // reports one past that run rather than the start of the second. A port that
    // added the second bias here would answer the second run, and the paragraph
    // separator test above would silently stop crossing a run boundary.
    const stepped = try forwardToCharacterEnd(.{
        .root_node = root,
        .inner = .{ .node = first, .character_index = 1 },
    });
    try testing.expectEqual(localId(2), stepped.inner.node.id().local);
    try testing.expectEqual(@as(usize, 2), stepped.inner.character_index);
}

test "forwardToCharacterStart crosses to the next run at a run boundary" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "ab", &.{ 1, 1 }, .{});
    _ = try addRun(&state, localId(3), 1, "cd", &.{ 1, 1 }, .{});
    const root = try refOf(&state, localId(1));
    const first = try refOf(&state, localId(2));
    const second = try refOf(&state, localId(3));

    // The first bias moves the end of the first run to the start of the second
    // and the step then lands on that run's first character, so this movement
    // crosses the boundary the previous one does not.
    const crossed = try forwardToCharacterStart(.{
        .root_node = root,
        .inner = .{ .node = first, .character_index = 2 },
    });
    try testing.expectEqual(localId(3), crossed.inner.node.id().local);
    try testing.expectEqual(@as(usize, 1), crossed.inner.character_index);

    // From inside the run it is a plain step of one.
    const inside = try forwardToCharacterStart(.{
        .root_node = root,
        .inner = .{ .node = second, .character_index = 0 },
    });
    try testing.expectEqual(localId(3), inside.inner.node.id().local);
    try testing.expectEqual(@as(usize, 1), inside.inner.character_index);
}

test "backwardToCharacterStart crosses to the previous run and reports the document start" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "ab", &.{ 1, 1 }, .{});
    _ = try addRun(&state, localId(3), 1, "cd", &.{ 1, 1 }, .{});
    const root = try refOf(&state, localId(1));
    const first = try refOf(&state, localId(2));
    const second = try refOf(&state, localId(3));

    // The backward bias moves the start of the second run to the end of the
    // first and the step then lands on the first run's last character.
    const crossed = try backwardToCharacterStart(.{
        .root_node = root,
        .inner = .{ .node = second, .character_index = 0 },
    });
    try testing.expectEqual(localId(2), crossed.inner.node.id().local);
    try testing.expectEqual(@as(usize, 1), crossed.inner.character_index);

    // At the document start there is no character before it, and upstream's `- 1`
    // at `text.rs:337` underflows there. The port reports the tag rather than
    // wrapping to the largest character index.
    try testing.expectError(error.InvalidPosition, backwardToCharacterStart(.{
        .root_node = root,
        .inner = .{ .node = first, .character_index = 0 },
    }));
}

test "toLineIndex counts the lines before the one the position sits on" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3), localId(4) });
    _ = try addRun(&state, localId(2), 0, "a", &.{1}, .{});
    _ = try addRun(&state, localId(3), 1, "b", &.{1}, .{});
    _ = try addRun(&state, localId(4), 2, "c", &.{1}, .{});
    // The third run continues the second's line and the fourth starts a new one.
    // The links are a chain separate from the children list, which is what the
    // line walk follows.
    try setRunLink(&state, localId(3), localId(2), localId(4));
    const root = try refOf(&state, localId(1));
    const second = try refOf(&state, localId(2));
    const fourth = try refOf(&state, localId(4));

    // The first line is line zero, whatever run on it the position sits.
    try testing.expectEqual(@as(usize, 0), try toLineIndex(.{
        .root_node = root,
        .inner = .{ .node = second, .character_index = 0 },
    }));
    // The fourth run opens the second line, so one line precedes it.
    try testing.expectEqual(@as(usize, 1), try toLineIndex(.{
        .root_node = root,
        .inner = .{ .node = fourth, .character_index = 0 },
    }));
}
