//! The C ABI: the seam a platform adapter links against.
//!
//! **What this namespace is.** `include/zaccesskit.h` is 6581 lines and declares
//! 498 functions; this namespace implements them in Zig so a platform adapter can
//! be written in any language that speaks C. The header is the contract, and it
//! is the only thing a C consumer compiles against — so every export here has to
//! match a declaration in it exactly, in name, in argument order, in return shape,
//! and in the ownership of everything it hands back.
//!
//! **The layers, and why the order is a constraint.**
//!
//! - `handles.zig` and `allocation.zig` sit at the bottom and have no dependencies
//!   on each other or on anything above. `handles.zig` declares the eleven opaque
//!   handle types the header forward-declares and nothing else; `allocation.zig`
//!   owns the allocator, the per-thread error slot, and the catalogue of the 17
//!   `*_free` functions.
//! - `marshal.zig` sits next and holds **every** conversion between the port's Zig
//!   types and the header's `extern struct` forms. No other module in this
//!   namespace defines a conversion. Two copies of one conversion is how they
//!   diverge.
//! - The domain files sit above it, one per group of declarations: `node.zig` for
//!   the node accessors, `geometry.zig` for the affine and rect surface,
//!   `tree_info.zig`, `action_request.zig`, `platform.zig`. Each converts through
//!   `marshal.zig` and reaches the consumer layer beneath.
//!
//! **The rule that catches everyone.** A C string stops at the first NUL. The
//! header states it for the two `_with_length` setters, and it holds for the whole
//! family because `string_free` releases with `std.mem.span`, which finds the end
//! at the first NUL — so an allocation holding a byte past one is freed at the
//! wrong length. `marshal.dupCString` truncates for that reason, and every
//! function that takes or returns text says so in its own doc comment.
//!
//! **The three newest modules, and what each one is.** Two of them own no
//! export at all, and that is deliberate rather than unfinished.
//! `optionals.zig` is the twenty-five `accesskit_opt_*` forms and the absence
//! convention each one uses; the header declares no `accesskit_opt_*` function,
//! so there is nothing there to export. `property_value.zig` is the nineteen C
//! enumerations and the 273 tags they carry, proved to be one-to-one in both
//! directions. `tree_update.zig` is the one of the three with declarations, and
//! it owns all ten `accesskit_tree_update_*` exports.
//!
//! The runtime channel contains `accesskit_set_allocator`,
//! `accesskit_last_error`, `accesskit_last_error_name`, and
//! `accesskit_string_free`. `allocation.zig` owns the declared allocator and
//! the thread-local failure slot. This file exports the C functions.

const std = @import("std");
const builtin = @import("builtin");

/// The opaque handle types the header forward-declares. One declaration each, and
/// this is where a new one goes.
pub const handles = @import("handles.zig");

/// The allocator, the per-thread error slot, and the seventeen `*_free` functions.
pub const allocation = @import("allocation.zig");

/// Every conversion between the port's types and the header's `extern` forms.
pub const marshal = @import("marshal.zig");

/// The node accessors, and the property accessors that hang off them.
pub const node = @import("node.zig");

/// The 291 property accessors that go through a node's property store, and the
/// three node-lifetime declarations that bracket them.
pub const node_properties = @import("node_properties.zig");

/// The affine transform, rect, point, vec2 and size surface.
pub const geometry = @import("geometry.zig");

/// The tree metadata and its release.
pub const tree_info = @import("tree_info.zig");

/// The action request, the custom actions, and the platform callback surface.
pub const action_request = @import("action_request.zig");

/// The platform entry points and the ten per-platform releases.
pub const platform = @import("platform.zig");

/// The tree update: one atomic change to one tree, and its ten exports.
pub const tree_update = @import("tree_update.zig");

/// The nineteen C enumerations and the 273 tags they carry.
pub const property_value = @import("property_value.zig");

/// The twenty-five `accesskit_opt_*` forms and the absence convention each one
/// uses.
pub const optionals = @import("optionals.zig");

test "every module in this namespace is reachable and analysed" {
    // A `pub const` nothing references is a re-export the compiler may skip, so a
    // green run would report zero tests and prove nothing about the exports
    // underneath it. That has already happened twice in this package, once for
    // the schema layer and once for the consumer layer.
    std.testing.refAllDecls(handles);
    std.testing.refAllDecls(allocation);
    std.testing.refAllDecls(marshal);
    std.testing.refAllDecls(node);
    std.testing.refAllDecls(node_properties);
    std.testing.refAllDecls(geometry);
    std.testing.refAllDecls(tree_info);
    std.testing.refAllDecls(action_request);
    // Zig 0.16 resolves `.winapi` vtables only on x86_64.
    if (comptime builtin.cpu.arch == .x86_64) {
        std.testing.refAllDecls(platform);
    }
    std.testing.refAllDecls(tree_update);
    std.testing.refAllDecls(property_value);
    std.testing.refAllDecls(optionals);
}

// These functions do not require a platform handle.

/// Installs the allocator every exported function in this library allocates
/// through, or restores the C allocator when either half is `null`.
///
/// `include/zaccesskit.h:6472`. `alloc` and `free` must stay valid until the
/// process exits, and the library calls both from whichever thread made the
/// allocation, so both must be thread-safe. `context` reaches each function
/// unchanged and a `null` reaches them as `null`.
///
/// Call it once, before any other function in this header. Installing a second
/// pair leaves every block already made on its own pair, so nothing is released
/// through a pair that did not allocate it. Allocates nothing, releases nothing
/// and cannot fail, so the tag it leaves behind is `allocation.Tag.none`.
export fn accesskit_set_allocator(
    alloc: ?allocation.AllocFn,
    free: ?allocation.FreeFn,
    context: ?*anyopaque,
) callconv(.c) void {
    allocation.clearError();
    allocation.installAllocator(alloc, free, context);
}

/// The failure tag of the most recent call on the calling thread.
///
/// `include/zaccesskit.h:6484`. `allocation.Tag.none` means the call that just
/// returned did not fail, so a `null` or `false` return carrying it is an
/// ordinary answer: the property was unset, or the predicate said no. The value
/// belongs to the call that just returned and to nothing older, so a C consumer
/// reads it immediately after the call that failed and before it makes another
/// call on this thread.
///
/// This getter and `accesskit_last_error_name` preserve the failure slot.
/// All other exported calls clear the slot on entry.
export fn accesskit_last_error() callconv(.c) allocation.Tag {
    return allocation.lastError();
}

/// Returns the static error name from the most recent call on this thread.
/// Returns `null` if that call did not fail. Does not clear the failure slot.
/// The caller must not release the returned string.
export fn accesskit_last_error_name() callconv(.c) ?[*:0]const u8 {
    return allocation.lastErrorName();
}

/// Releases a string a getter in this header returned, exactly once.
///
/// `include/zaccesskit.h:2824`. The string is one block of the declared
/// allocator, so it goes back through that allocator and never through `free`.
/// The declared allocator itself is not released, and the pointer is unusable
/// afterwards.
///
/// **The block is the one the getter made from the declared allocator**, which
/// is `marshal.dup_c_string` and `std.Io.Writer.Allocating.toOwnedSliceSentinel`
/// in this port. A block carrying `allocation.zig`'s own head in front of it is
/// not one, and this function does not read that head, so a producer that makes
/// one cannot be released here.
///
/// The parameter is a non-optional pointer, so a C caller that passes `null`
/// dereferences it and the process ends, which is what the header promises at
/// `include/zaccesskit.h:2838` and the same argument
/// `accesskit_custom_action_free` makes for the handle it takes. A second call
/// on the same pointer is a double free, and so is a call on a string this
/// library did not return. Returns nothing and cannot fail.
export fn accesskit_string_free(value: [*:0]u8) callconv(.c) void {
    allocation.clearError();
    marshal.string_free(allocation.allocator(), value);
}

/// The all-zero tree identifier every adapter uses for the root tree.
///
/// `include/zaccesskit.h:1791` declares this as
/// `extern const struct accesskit_tree_id ACCESSKIT_TREE_ID_ROOT;`, so a C
/// caller reads a linked data symbol, not a function call. Upstream emits it
/// as a `pub static` at `accesskit-c/src/common.rs:226-227`.
///
/// A Zig `pub const` emits nothing, so `schema.tree_id_root` on its own left
/// the declaration in the header with no definition behind it: the symbol was
/// missing from every object file, and `test/c_consumer/consumer.c:2052` and
/// `:2308` both read it. `export const` does emit the read-only bytes, and
/// `zig build capi-parity` now walks `doc.objects` as well as `doc.functions`
/// so a second missing object cannot pass the gate the same way.
///
/// The value is sixteen zero bytes. It cannot fail and releases nothing.
const schema_root = @import("../schema/root.zig");
export const ACCESSKIT_TREE_ID_ROOT: schema_root.TreeId = schema_root.tree_id_root;

// --- tests ---------------------------------------------------------------------

/// How many blocks `Pair` can hold outstanding at once.
///
/// The bound is the largest live set the test that uses it builds, which is
/// three: `accesskit_tree_info_new` holds the handle,
/// `accesskit_tree_info_set_toolkit_name` adds the copy stored on it, and
/// `accesskit_tree_info_get_toolkit_name` adds the one the caller must release.
/// A fourth block without a release is refused rather than recorded over, so a
/// test that leaks a block fails instead of reading a stale address.
const live_capacity: usize = 3;

/// The pair `accesskit_set_allocator` installs in the tests below, and what it
/// was asked to do.
///
/// `backing` is a `std.heap.FixedBufferAllocator` rather than
/// `std.testing.allocator` because the free half records an address after the
/// block went back, and `std.testing.allocator` unmaps a page on a large free,
/// so that read faults instead of answering. A buffer allocator keeps the bytes
/// mapped, which is what makes the record observable. A release is recorded and
/// not reclaimed, so the buffer is sized for the whole test rather than for the
/// live set.
const Pair = struct {
    /// Where every block comes from.
    backing: *std.heap.FixedBufferAllocator,
    /// The address of every block handed out and not yet given back, in
    /// allocation order. Bounded by `live_capacity`.
    // SAFETY: `alloc` writes `live[live_count]` and only then bumps
    // `live_count`, and both walks over the domain are `live_count` rows wide,
    // so a `live_count`-bounded read never reaches an unwritten row.
    live: [live_capacity]usize = undefined,
    /// How many entries of `live` are in use.
    live_count: usize = 0,
    /// How many times the alloc half returned a block.
    allocs: usize = 0,
    /// How many times the free half ran.
    frees: usize = 0,
    /// How many releases named an address this pair was not holding. The header
    /// calls that a double free and a stray pointer, and neither is something a
    /// test can let a heap checker discover on its own.
    unrecorded_frees: usize = 0,
    /// The address the free half was last handed.
    last_freed: usize = 0,
    /// The `context` the last call carried, so a test can assert it arrives
    /// unchanged.
    seen_context: ?*anyopaque = null,

    /// The alloc half. It answers `null` at the bound rather than growing, so a
    /// leaked block is an answer the caller has to notice.
    fn alloc(size: usize, context: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *Pair = @ptrCast(@alignCast(context orelse return null));
        self.seen_context = context;
        if (self.live_count == live_capacity) return null;
        const block = self.backing.allocator().alloc(u8, size) catch return null;
        self.allocs += 1;
        self.live[self.live_count] = @intFromPtr(block.ptr);
        self.live_count += 1;
        return @ptrCast(block.ptr);
    }

    /// The free half. It records the address and drops the entry, and it does
    /// not reclaim, so a test may read an address after this returns.
    fn free(ptr: ?*anyopaque, context: ?*anyopaque) callconv(.c) void {
        const self: *Pair = @ptrCast(@alignCast(context orelse return));
        self.seen_context = context;
        const address = @intFromPtr(ptr orelse return);
        self.last_freed = address;
        self.frees += 1;
        // The bound is `live_capacity`: the walk is over the recorded set and
        // over nothing else, and `live_count` never passes it. The entries past
        // `live_count` are not read, so a stale address left by an earlier test
        // cannot match.
        var slot: ?usize = null;
        inline for (0..live_capacity) |index| {
            if (index < self.live_count and self.live[index] == address) slot = index;
        }
        if (slot) |index| {
            self.live[index] = self.live[self.live_count - 1];
            self.live_count -= 1;
            return;
        }
        self.unrecorded_frees += 1;
    }
};

/// A tree info for the tests below, built the way
/// `accesskit_tree_info_new` builds one.
///
/// **The Zig layer, not the C declaration.** An `export fn` is not `pub`, so
/// this file cannot name it, and a fixture spelled a second time here would be
/// testing that second spelling. `treeInfoNew` and `treeInfoSetToolkitName` are
/// the bodies of those two declarations, so the blocks below are the blocks the
/// C getters make, and the release is checked against the real thing.
fn newTreeInfo() !*tree_info.accesskit_tree_info {
    return tree_info.treeInfoNew(allocation.allocator(), 1);
}

test "the pair set_allocator installs receives every allocation and the context" {
    var storage: [4096]u8 align(16) = undefined;
    var backing: std.heap.FixedBufferAllocator = .init(&storage);
    var pair: Pair = .{ .backing = &backing };
    const context: *anyopaque = @ptrCast(&pair);

    const before = allocation.allocator().vtable;
    accesskit_set_allocator(Pair.alloc, Pair.free, context);
    defer accesskit_set_allocator(null, null, null);
    try std.testing.expect(allocation.allocator().vtable != before);

    // One allocation, and it reached the pair with the context unchanged. The
    // header's promise is that every allocation the library hands to C comes
    // from this pair, so a block made anywhere else would leave `allocs` at
    // zero here.
    const tree = try newTreeInfo();
    try std.testing.expectEqual(@as(usize, 1), pair.allocs);
    try std.testing.expectEqual(context, pair.seen_context);
    tree_info.treeInfoFree(tree);
}

test "set_allocator restores the C allocator when either half is null" {
    // `allocation.zig` proves this against its own helper. The copy here is
    // against the C declaration, because a `null` reaching the export and a
    // `null` reaching `installAllocator` are two different facts and only the
    // first is the header's.
    var storage: [4096]u8 align(16) = undefined;
    var backing: std.heap.FixedBufferAllocator = .init(&storage);
    var pair: Pair = .{ .backing = &backing };
    const context: *anyopaque = @ptrCast(&pair);

    const installed = blk: {
        accesskit_set_allocator(Pair.alloc, Pair.free, context);
        defer accesskit_set_allocator(null, null, null);
        break :blk allocation.allocator().vtable;
    };
    try std.testing.expect(installed != std.heap.c_allocator.vtable);

    // The header says "Passing `null` for either", so one half is enough.
    accesskit_set_allocator(Pair.alloc, null, context);
    try std.testing.expect(allocation.allocator().vtable == std.heap.c_allocator.vtable);
    accesskit_set_allocator(null, Pair.free, context);
    try std.testing.expect(allocation.allocator().vtable == std.heap.c_allocator.vtable);
    accesskit_set_allocator(null, null, null);
    try std.testing.expect(allocation.allocator().vtable == std.heap.c_allocator.vtable);
}

test "the failure tag reaches the C declaration, and only on the thread that failed" {
    // The tag is written on the failing path of an allocating export, and those
    // exports are in the domain modules: `allocation.failWith` is the one writer
    // in this library and `accesskit_last_error` is the one reader, so writing it
    // here and reading it through the declaration is what proves the two halves
    // meet on the same slot.
    allocation.clearError();
    try std.testing.expectEqual(allocation.Tag.none, accesskit_last_error());

    allocation.failWith(.out_of_memory);
    try std.testing.expectEqual(allocation.Tag.out_of_memory, accesskit_last_error());

    // Reading the tag does not clear it. That is what makes the next assertion a
    // statement about the slot rather than about the reader, and it is the one
    // place a C consumer is told to come back to.
    try std.testing.expectEqual(allocation.Tag.out_of_memory, accesskit_last_error());

    // The slot is per thread, so a worker that has made no call reads `none`
    // while this thread still reads its own failure. One plain global could not
    // produce both answers.
    const Seen = struct {
        const Self = @This();

        tag: allocation.Tag = .none,

        fn body(self: *Self) void {
            self.tag = accesskit_last_error();
        }
    };
    var seen: Seen = .{};
    const thread = try std.Thread.spawn(.{}, Seen.body, .{&seen});
    thread.join();
    try std.testing.expectEqual(allocation.Tag.none, seen.tag);
    try std.testing.expectEqual(allocation.Tag.out_of_memory, accesskit_last_error());

    // The next call on this thread clears it, which is the rule the reader
    // depends on. `accesskit_set_allocator` is one of the functions the rule
    // covers and it is one that cannot fail, so the tag is not a latch.
    accesskit_set_allocator(null, null, null);
    try std.testing.expectEqual(allocation.Tag.none, accesskit_last_error());
}

test "string_free returns the getter's own block to the declared allocator" {
    var storage: [4096]u8 align(16) = undefined;
    var backing: std.heap.FixedBufferAllocator = .init(&storage);
    var pair: Pair = .{ .backing = &backing };
    const context: *anyopaque = @ptrCast(&pair);

    accesskit_set_allocator(Pair.alloc, Pair.free, context);
    defer accesskit_set_allocator(null, null, null);

    const tree = try newTreeInfo();
    try std.testing.expectEqual(@as(usize, 1), pair.allocs);

    try tree_info.treeInfoSetToolkitName(tree, "wasm");
    try std.testing.expectEqual(@as(usize, 2), pair.allocs);

    // The getter's one block, and the only one the caller owes a release for.
    const text = (try tree_info.treeInfoGetToolkitName(
        allocation.allocator(),
        tree,
    )) orelse return error.NoToolkitName;
    try std.testing.expectEqual(@as(usize, 3), pair.allocs);
    try std.testing.expectEqual(@as(usize, live_capacity), pair.live_count);

    // The block the caller holds is the one the getter just made. Naming it
    // here is what lets the release below be checked against an address instead
    // of against a count.
    const held: usize = @intFromPtr(text);
    try std.testing.expect(pair.live[2] == held);

    // The whole of the ownership rule: the release goes back through the pair,
    // it goes back for that address, and it goes back once.
    accesskit_string_free(text);
    try std.testing.expectEqual(@as(usize, 1), pair.frees);
    try std.testing.expectEqual(held, pair.last_freed);
    try std.testing.expectEqual(@as(usize, 2), pair.live_count);
    try std.testing.expectEqual(@as(usize, 0), pair.unrecorded_frees);

    // The handle still owns its two blocks and returns both, so the accounting
    // closes: every block the pair made came back to it exactly once.
    tree_info.treeInfoFree(tree);
    try std.testing.expectEqual(@as(usize, 3), pair.frees);
    try std.testing.expectEqual(@as(usize, 0), pair.live_count);
    try std.testing.expectEqual(@as(usize, 0), pair.unrecorded_frees);
}

test "a string this library did not return is not released as one" {
    // A block the library never handed out has no head and no length, so the
    // only thing a test can assert is that `Pair` sees a release it cannot
    // match. That is the double free and the stray pointer the header forbids,
    // and it is why a consumer that keeps a pointer it was given by other means
    // cannot reach this function.
    var storage: [4096]u8 align(16) = undefined;
    var backing: std.heap.FixedBufferAllocator = .init(&storage);
    var pair: Pair = .{ .backing = &backing };
    const context: *anyopaque = @ptrCast(&pair);

    accesskit_set_allocator(Pair.alloc, Pair.free, context);
    defer accesskit_set_allocator(null, null, null);

    const borrowed = try backing.allocator().allocSentinel(u8, 0, 0);
    accesskit_string_free(@ptrCast(@constCast(borrowed.ptr)));
    try std.testing.expectEqual(@as(usize, 1), pair.frees);
    try std.testing.expectEqual(@as(usize, 1), pair.unrecorded_frees);
    try std.testing.expectEqual(@as(usize, 0), pair.live_count);
}
