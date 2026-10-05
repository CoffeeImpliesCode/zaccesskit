//! The allocation contract and the error slot for the C ABI.
//!
//! **What this module is for.** It owns the only two pieces of mutable state
//! the C surface needs: the allocator every exported function allocates
//! through, and the failure tag a call that cannot report a failure through its
//! return value writes for `accesskit_last_error`. Nothing else in the C ABI
//! holds state.
//!
//! **The allocator contract, in two sentences.** Every allocation the library
//! hands to C comes from the one declared allocator, which is the C allocator
//! until `accesskit_set_allocator` installs a pair, and every such allocation
//! goes back through `release` and never through `free`. A `release` of
//! `null`, of a pointer this library never returned, or of a pointer this
//! library already released is refused, and a refused `release` terminates the
//! process rather than corrupting the heap.
//!
//! **The error-slot lifetime, in two sentences.** The tag belongs to one
//! thread, because `include/zaccesskit.h:121` fixes it that way: it is the tag
//! of the most recent call on the calling thread. It is valid only until the
//! next call on that thread, so a C consumer reads it immediately after the
//! call that failed and before it makes another call.
//!
//! **Which exports this module contributes.** It has no `export fn`. The three
//! C symbols that reach it, `accesskit_set_allocator` at
//! `include/zaccesskit.h:6472`, `accesskit_last_error` at `:6484`, and each of
//! the 17 `*_free` functions, are thin forwarders declared in `capi/root.zig`,
//! which owns every other `export fn` in this library.
//!
//! **What this module deliberately does not do.** It does not declare the C
//! types a `*_free` owns, and it does not decide which nested blocks one of
//! them releases. `capi/marshal.zig` owns the `extern struct` forms and the
//! per-type teardown that walks them; this module owns the single-block
//! primitive they all end in.
//!
//! **The ABI claim.** C11 against a library built by Zig 0.16.0. The tag
//! values match `accesskit_error` at `include/zaccesskit.h:1761-1764` member for
//! member, and the installed pair has the shape of the two function pointers
//! the header declares at `:6472-6474`.
//!
//! **The shortest sequence that uses this module.** Install a pair with
//! `installAllocator` if the library must not use the C allocator, make
//! allocations with `create` or `createBytes`, and release each one with
//! `release` when the C caller is finished with it.
//!
//! **What the consumer must release, and when.** Every `char *` a getter
//! returned, every node, tree info, tree update, custom action, action request
//! and adapter handle it still owns, once, with the matching `*_free` from the
//! catalogue below. A `push` or a `set` that takes ownership cancels the duty.
//!
//! **The loop bound.** The only domain this module loops over is
//! `free_kinds`, whose length is fixed at `free_kind_count`. It is 17 because
//! the shipped header declares 17 `*_free` functions, counted at
//! `include/zaccesskit.h:2824`, `:5006`, `:5068`, `:5128`, `:5157`, `:5294`,
//! `:5372` and the 10 platform frees between `:5720` and `:6436`.

const std = @import("std");

/// The failure modes of the allocating entry points in this module.
///
/// Every one of them leaves nothing behind: `create`, `createBytes` and
/// `createCString` allocate one block, and a failed allocation returns no
/// pointer at all.
pub const Error = error{
    /// The declared allocator returned `null`. The error slot holds
    /// `Tag.out_of_memory` when a C entry point reports it.
    OutOfMemory,
};

/// Mirrors the C enum `accesskit_error` at `include/zaccesskit.h:1761`.
///
/// The discriminant values are the header's, so a cast to `c_int` produces the
/// constant a C consumer names.
pub const Tag = enum(c_int) {
    /// The call that just returned did not fail. A `null` or `false` return
    /// carrying this tag is an ordinary answer: the property was unset, or the
    /// predicate said no.
    none = 0,

    /// The call that just returned failed to allocate. Nothing it would have
    /// produced survives.
    out_of_memory = 1,
};

/// Why `release` refused a pointer.
///
/// A caller cannot tell `.not_ours` from "already released" apart, because the
/// block has gone back to the declared allocator by then and this module keeps
/// no registry of live pointers. Both are the same defect and both terminate the
/// process, so the distinction carries no action.
pub const Refusal = enum {
    /// The pointer is a live block this library handed out.
    none,

    /// The pointer was `null`. `include/zaccesskit.h` promises that a `null`
    /// free terminates the process, and this is that promise.
    null_pointer,

    /// The 16 bytes before the pointer do not carry this library's live word,
    /// so the pointer was never returned here or has already been released.
    not_ours,
};

/// The allocation half of the pair `accesskit_set_allocator` installs.
///
/// It has the type of the first parameter of that declaration at
/// `include/zaccesskit.h:6472`. `size` is a byte count, not a type size, and
/// the function must return memory aligned to at least 8 bytes, which is what
/// `malloc` gives.
pub const AllocFn = *const fn (size: usize, context: ?*anyopaque) callconv(.c) ?*anyopaque;

/// The release half of the pair `accesskit_set_allocator` installs.
///
/// It has the type of the second parameter of that declaration at
/// `include/zaccesskit.h:6473`. `ptr` is always the pointer the matching `alloc`
/// returned, never one this module moved.
pub const FreeFn = *const fn (ptr: ?*anyopaque, context: ?*anyopaque) callconv(.c) void;

/// One `*_free` function in the shipped header and the upstream teardown it
/// ports.
///
/// `upstream` names the Rust function at commit
/// `8b6ed37c20ed4c59390e253407983333053662ba` that owns the same work, so a
/// reader can check the port against the crate rather than against this file.
pub const FreeKind = struct {
    /// The name the header declares, without the `accesskit_` prefix carried by
    /// the C symbol itself.
    name: []const u8,

    /// The line the declaration stands on in `include/zaccesskit.h`.
    header_line: u32,

    /// The upstream Rust function that performs the same teardown, as
    /// `path:line` under `accesskit-c/`.
    upstream: []const u8,
};

/// Every `*_free` in the shipped header, in header order.
///
/// Seventeen entries, and no more: `docs/31-c-abi-design.md` section 9.1
/// corrected its own earlier count of 19 after an implementer wrote a second
/// `accesskit_node_free` and a second `accesskit_tree_info_free` and the link
/// failed on both. One entry here per declared function, and no duplicates.
pub const free_kinds = [_]FreeKind{
    .{ .name = "string", .header_line = 2824, .upstream = "src/common.rs:511" },
    .{ .name = "custom_action", .header_line = 5006, .upstream = "src/common.rs:710" },
    .{ .name = "custom_actions", .header_line = 5068, .upstream = "src/common.rs:773" },
    .{ .name = "node", .header_line = 5128, .upstream = "src/common.rs:852" },
    .{ .name = "tree_info", .header_line = 5157, .upstream = "src/common.rs:881" },
    .{ .name = "tree_update", .header_line = 5294, .upstream = "src/common.rs:1009" },
    .{ .name = "action_request", .header_line = 5372, .upstream = "src/common.rs:1129" },
    .{
        .name = "android_platform_action",
        .header_line = 5720,
        .upstream = "src/android.rs:39",
    },
    .{ .name = "android_adapter", .header_line = 5753, .upstream = "src/android.rs:87" },
    .{
        .name = "android_injecting_adapter",
        .header_line = 5855,
        .upstream = "src/android.rs:213",
    },
    .{ .name = "ios_adapter", .header_line = 5910, .upstream = "src/ios.rs:79" },
    .{
        .name = "ios_subclassing_adapter",
        .header_line = 6018,
        .upstream = "src/ios.rs:232",
    },
    .{ .name = "macos_adapter", .header_line = 6068, .upstream = "src/macos.rs:63" },
    .{
        .name = "macos_subclassing_adapter",
        .header_line = 6186,
        .upstream = "src/macos.rs:197",
    },
    .{ .name = "unix_adapter", .header_line = 6273, .upstream = "src/unix.rs:48" },
    .{ .name = "windows_adapter", .header_line = 6356, .upstream = "src/windows.rs:60" },
    .{
        .name = "windows_subclassing_adapter",
        .header_line = 6436,
        .upstream = "src/windows.rs:154",
    },
};

/// The number of `*_free` functions the shipped header declares: 17.
///
/// This is the compile-time bound on every loop over `free_kinds`.
pub const free_kind_count: u32 = @intCast(free_kinds.len);

comptime {
    // `docs/31-c-abi-design.md` section 9.1 names the header lines. If the
    // catalogue and the header ever disagree the count above is the thing that
    // goes stale, so the assertion sits next to it.
    if (free_kinds.len != 17) @compileError("the header declares 17 free functions");
}

/// The word a live block carries in its head.
///
/// Written before the pointer escapes to C and overwritten before the block
/// goes back to the declared allocator.
const live_word: u64 = 0x7A43_4B49_5400_0001;

/// The word a released block carries in its head.
const dead_word: u64 = 0x7A43_4B49_5400_0000;

/// The head every block this library hands to C carries.
///
/// It sits immediately before the payload and records where the declared
/// allocator must be told to return the memory. Its size is a multiple of 8 on
/// every target, so the payload keeps the alignment the allocator gave.
const Head = struct {
    word: u64,
    raw: ?[*]u8,
    bytes: usize,
};

/// The tag of the most recent call on the calling thread.
///
/// One thread-local variable, not a plain global: `include/zaccesskit.h:121`
/// scopes the tag to the calling thread, and a plain global is wrong the moment
/// the library is called from two threads.
threadlocal var slot: Tag = .none;

/// The installed pair, or `null` while the C allocator is declared.
///
/// Set once, before any other function in the header, and read without
/// synchronization afterwards. That is the order `include/zaccesskit.h:6459`
/// states, so the read needs no lock.
var installed: ?Pair = null;

/// The pair `accesskit_set_allocator` installed.
const Pair = struct {
    alloc: AllocFn,
    free: FreeFn,
    context: ?*anyopaque,
};

/// The tag of the most recent call on this thread.
///
/// The value belongs to the call that just returned and nothing older, because
/// every entry point clears the slot on entry.
pub fn lastError() Tag {
    return slot;
}

/// Clears the tag for this thread. Every exported function calls it on entry.
pub fn clearError() void {
    slot = .none;
}

/// Records `value` as the failure of the call in progress.
///
/// Only a failing path calls it. A `null` from a string getter because the
/// property was unset is an ordinary answer and leaves the tag at `Tag.none`.
pub fn failWith(value: Tag) void {
    slot = value;
}

/// Installs the pair every allocation and every release goes through.
///
/// A `null` for `alloc` or for `free` restores the default C allocator, which
/// is what `include/zaccesskit.h:6459` promises. `context` is passed back to
/// both functions unchanged, and a `null` reaches them as `null`.
///
/// **Call it once, before any other function in the header.** That is the
/// contract `include/zaccesskit.h:6459` and `:6469-6470` set, and this
/// implementation cannot enforce it or detect a breach.
///
/// It cannot enforce it because a `std.mem.Allocator` is a pointer to its holder,
/// and `allocator()` hands back a pointer to **this module's** `installed` field
/// rather than to a snapshot. A store built before a second install therefore
/// reads the new pair when it releases, and the pair that made the block never
/// hears about it. Pinning it would mean a fresh holder per call, which means an
/// allocation to avoid an allocation.
///
/// So the guarantee is a precondition and not a property: a host that installs
/// a second pair after the first allocation releases the first block through a
/// pair that did not make it. `accesskit_node_free` releases through the node's
/// own store rather than through `allocator()`, which is what keeps a node sound
/// under the breach; a block from `allocator()` directly is not so protected.
pub fn installAllocator(alloc: ?AllocFn, free: ?FreeFn, context: ?*anyopaque) void {
    const a = alloc orelse return restoreDefault();
    const f = free orelse return restoreDefault();
    installed = .{ .alloc = a, .free = f, .context = context };
}

/// The declared allocator, for a Zig lifetime no C caller ever sees.
///
/// A block from this allocator is released with `std.mem.Allocator.free` and
/// not with `release`, because `release` reads the head `create` writes and this
/// path does not write one. Every pointer that crosses the C boundary comes
/// from `create`, `createBytes` or `createCString` instead.
///
/// The result is `std.heap.c_allocator` while no pair is installed, so this
/// module requires a libc link on every target.
pub fn allocator() std.mem.Allocator {
    if (installed == null) return std.heap.c_allocator;
    return .{ .ptr = &installed.?, .vtable = &pair_vtable };
}

/// Allocates one `T` and returns it zeroed.
///
/// The caller owns the result and releases it with `release`. `error.OutOfMemory`
/// leaves nothing allocated. This is the only route to a pointer that crosses
/// the C boundary, so every `*_free` in the catalogue ends in `release`.
pub fn create(comptime T: type) Error!*T {
    const head = try carve(@sizeOf(T), @alignOf(T));
    const payload: *T = @ptrCast(@alignCast(payloadOf(head, @alignOf(T))));
    return payload;
}

/// Allocates `len` bytes and returns them zeroed.
///
/// The caller owns the slice and releases the pointer it starts at with
/// `release`. `error.OutOfMemory` leaves nothing allocated.
pub fn createBytes(len: usize) Error![]u8 {
    const head = try carve(len, 1);
    return payloadOf(head, 1)[0..len];
}

/// Allocates a copy of `bytes` with one `0` byte after it, cut at the first
/// `0` byte in `bytes`.
///
/// The result is the `char *` a C getter returns, so it is owned by the caller
/// and released with `accesskit_string_free`. `error.OutOfMemory` leaves nothing
/// allocated.
///
/// The cut is not a choice. `include/zaccesskit.h:5050-5053` and `:2890-2892`
/// state it for the whole family: "A byte string is stored up to the first NUL
/// byte, because a value holding one cannot come back out of a `char *` getter
/// without losing its tail." A C consumer that writes an interior NUL reads the
/// bytes up to it and loses the rest. Every producer gets that behaviour by
/// coming through here, so no getter has to repeat the rule and no caller has to
/// decide what to do about an interior NUL.
pub fn createCString(bytes: []const u8) Error![*:0]u8 {
    const cut = bytes[0 .. std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len];
    const head = try carve(cut.len + 1, 1);
    const payload = payloadOf(head, 1);
    @memcpy(payload[0..cut.len], cut);
    payload[cut.len] = 0;
    return @ptrCast(@alignCast(payload));
}

/// Reports whether `ptr` is a live block this library handed out, without
/// releasing it.
///
/// `release` refuses a pointer for which this is not `Refusal.none` and
/// terminates the process, so this is the form a test uses to observe that a
/// second release of the same pointer is caught.
pub fn check(ptr: ?*anyopaque) Refusal {
    const head = headOf(ptr) orelse return .null_pointer;
    return if (loadWord(head) == live_word) .none else .not_ours;
}

/// Releases one block from `create`, `createBytes` or `createCString`.
///
/// The declared allocator is not released, only the block. The block is unusable
/// afterwards and a second call on the same pointer is refused.
///
/// The call terminates the process for `null` and for a pointer this library
/// did not return, which are the two cases the header documents as defects and
/// which the alternative, a `free` of a bad pointer, cannot report.
pub fn release(ptr: ?*anyopaque) void {
    const head = headOf(ptr) orelse std.process.abort();
    if (loadWord(head) != live_word) std.process.abort();

    @atomicStore(u64, &head.word, dead_word, .release);
    allocator().free(rawOf(head));
}

fn restoreDefault() void {
    installed = null;
}

const pair_vtable: std.mem.Allocator.VTable = .{
    .alloc = pairAlloc,
    .resize = pairResize,
    .remap = pairRemap,
    .free = pairFree,
};

fn pairAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    _ = alignment;
    const pair: *Pair = @ptrCast(@alignCast(ctx));
    const block = pair.alloc(len, pair.context) orelse return null;
    return @ptrCast(block);
}

fn pairResize(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return false;
}

fn pairRemap(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = ret_addr;
    return null;
}

fn pairFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = alignment;
    _ = ret_addr;
    const pair: *Pair = @ptrCast(@alignCast(ctx));
    pair.free(@constCast(memory.ptr), pair.context);
}

fn carve(payload_bytes: usize, payload_align: usize) Error!*Head {
    // `payload_align` bytes of slack cover the round-up `payloadOf` does, and
    // rounding the request up to the head's own alignment keeps it aligned.
    const total = @sizeOf(Head) + payload_bytes + payload_align;
    const bytes = std.mem.alignForward(usize, total, @alignOf(Head));
    // Round the head count **up**. Flooring here is a heap overflow: `total` is
    // rounded up to the head's alignment, so `bytes` is usually not a multiple
    // of the head size, and `bytes / @sizeOf(Head)` silently drops the remainder.
    // The payload starts one head in, so a block shorter than
    // `@sizeOf(Head) + payload_bytes` writes past the end of its own allocation.
    // Every `create`, `createBytes` and `createCString` goes through here, so
    // the overflow is on every path. A sweep of `total` over 200 payload sizes
    // and four alignments found 424 short cases.
    const heads = std.math.divCeil(usize, bytes, @sizeOf(Head)) catch
        return error.OutOfMemory;
    const memory = allocator().alloc(Head, heads) catch
        return error.OutOfMemory;
    const head = &memory[0];
    head.* = .{
        .word = live_word,
        .raw = @ptrCast(memory.ptr),
        .bytes = memory.len * @sizeOf(Head),
    };
    return head;
}

fn payloadOf(head: *Head, alignment: usize) [*]u8 {
    const base = @intFromPtr(head) + @sizeOf(Head);
    return @ptrFromInt(std.mem.alignForward(usize, base, alignment));
}

fn rawOf(head: *Head) []u8 {
    return @as([*]u8, @ptrCast(head))[0..head.bytes];
}

fn headOf(ptr: ?*anyopaque) ?*Head {
    const any = ptr orelse return null;
    return @ptrFromInt(@intFromPtr(any) - @sizeOf(Head));
}

fn loadWord(head: *Head) u64 {
    return @atomicLoad(u64, &head.word, .acquire);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Counts what the installed pair is asked to do, so a test can assert that one
/// release reached the declared allocator exactly once.
///
/// The pair runs on a `FixedBufferAllocator` rather than on
/// `std.testing.allocator`. `check` reads the head of a block after the block
/// was released, and `std.testing.allocator` unmaps a page on a large free,
/// so that read faults instead of returning the dead word. A buffer allocator
/// keeps the bytes mapped, which is what makes the refusal observable.
const Counters = struct {
    allocs: usize = 0,
    frees: usize = 0,
    heads: usize = 0,
    context: ?*anyopaque = null,

    fn allocThunk(size: usize, context: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *Counters = @ptrCast(@alignCast(context orelse return null));
        const bytes = std.mem.alignForward(usize, size, @alignOf(Head));
        const heads = bytes / @sizeOf(Head);
        const memory = arena.allocator().alloc(Head, heads) catch return null;
        self.allocs += 1;
        self.heads = heads;
        self.context = context;
        return @ptrCast(memory.ptr);
    }

    fn freeThunk(ptr: ?*anyopaque, context: ?*anyopaque) callconv(.c) void {
        const self: *Counters = @ptrCast(@alignCast(context orelse return));
        const memory: [*]Head = @ptrCast(@alignCast(ptr orelse return));
        arena.allocator().free(memory[0..self.heads]);
        self.frees += 1;
    }
};

/// The backing store the counting pair allocates from. `useCounters` resets it
/// so each case starts from an empty buffer.
var arena_bytes: [16 * 1024]u8 align(@alignOf(Head)) = undefined;
var arena: std.heap.FixedBufferAllocator = undefined;

/// Installs the counting pair. The caller restores the C allocator with a
/// `defer`, because a test body is a function and runs its defers.
fn useCounters(counters: *Counters) void {
    arena = .init(&arena_bytes);
    installAllocator(Counters.allocThunk, Counters.freeThunk, counters);
}

/// One block shape, used to exercise the create and release pair without naming
/// a C type this module does not own.
const Fixture = struct {
    owner: usize,
    bytes: [8]u8,
};

test "the catalogue holds one entry per free function the header declares" {
    try testing.expectEqual(@as(usize, 17), free_kinds.len);
    try testing.expectEqual(@as(u32, 17), free_kind_count);

    // Header order is declaration order, so the lines strictly ascend and a
    // repeated line would be a repeated function.
    var previous: u32 = 0;
    inline for (free_kinds, 0..) |kind, index| {
        if (index != 0) try testing.expect(kind.header_line > previous);
        previous = kind.header_line;
        try testing.expect(kind.name.len != 0);
        try testing.expect(kind.upstream.len != 0);

        inline for (free_kinds[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, kind.name))
                return error.DuplicateFreeFunction;
        }
    }
}

test "a null free is refused rather than forwarded to the allocator" {
    var counters: Counters = .{};
    useCounters(&counters);
    defer installAllocator(null, null, null);
    try testing.expectEqual(Refusal.null_pointer, check(null));
    try testing.expectEqual(@as(usize, 0), counters.frees);
}

test "every free releases once and refuses the second release" {
    // One case per catalogue entry. The bound is `free_kinds.len`, which the
    // module doc fixes at the 17 the header declares.
    inline for (free_kinds, 0..) |kind, index| {
        var counters: Counters = .{};
        useCounters(&counters);
        defer installAllocator(null, null, null);

        const block = try create(Fixture);
        block.* = .{ .owner = index, .bytes = [_]u8{1} ** 8 };
        try testing.expectEqual(@as(usize, 1), counters.allocs);

        release(block);
        try testing.expectEqual(@as(usize, 1), counters.frees);

        // This is the double free. The head carries the dead word now, so the
        // check refuses it and no second free reaches the pair.
        try testing.expectEqual(Refusal.not_ours, check(block));
        try testing.expectEqual(@as(usize, 1), counters.frees);
        try testing.expect(kind.name.len != 0);
    }
}

test "a released string and a released block are refused alike" {
    var counters: Counters = .{};
    useCounters(&counters);
    defer installAllocator(null, null, null);

    const text = try createCString("accessibility");
    const borrowed: [*:0]const u8 = @ptrCast(text);
    try testing.expectEqualStrings("accessibility", std.mem.span(borrowed));

    release(@ptrCast(@constCast(text)));
    try testing.expectEqual(Refusal.not_ours, check(@ptrCast(@constCast(text))));

    const block = try create(Fixture);
    release(block);
    try testing.expectEqual(Refusal.not_ours, check(block));
    try testing.expectEqual(@as(usize, 2), counters.frees);
}

test "the context reaches the installed pair unchanged" {
    var counters: Counters = .{};
    installAllocator(Counters.allocThunk, Counters.freeThunk, &counters);
    defer installAllocator(null, null, null);

    const block = try create(Fixture);
    try testing.expectEqual(@as(usize, 1), counters.allocs);
    try testing.expect(counters.context.? == @as(*anyopaque, @ptrCast(&counters)));
    release(block);
}

test "passing null for either half restores the C allocator" {
    const installed_vtable = blk: {
        var counters: Counters = .{};
        installAllocator(Counters.allocThunk, Counters.freeThunk, &counters);
        defer installAllocator(null, null, null);
        break :blk allocator().vtable;
    };
    try testing.expect(installed_vtable != std.heap.c_allocator.vtable);
    try testing.expect(allocator().vtable == std.heap.c_allocator.vtable);

    // One null is enough. The header says "Passing `null` for either".
    var counters: Counters = .{};
    installAllocator(Counters.allocThunk, null, &counters);
    try testing.expect(allocator().vtable == std.heap.c_allocator.vtable);

    installAllocator(null, Counters.freeThunk, &counters);
    try testing.expect(allocator().vtable == std.heap.c_allocator.vtable);
    installAllocator(null, null, null);
}

test "an error written on this thread reads back through the slot" {
    clearError();
    try testing.expectEqual(Tag.none, lastError());

    failWith(.out_of_memory);
    try testing.expectEqual(Tag.out_of_memory, lastError());

    // The next call clears it, so a tag never outlives the call that set it.
    clearError();
    try testing.expectEqual(Tag.none, lastError());
}

test "the error slot is per thread, not one global" {
    const Seen = struct {
        value: Tag = .none,

        fn body(self: *@This()) void {
            clearError();
            failWith(.out_of_memory);
            self.value = lastError();
        }
    };

    clearError();
    var seen: Seen = .{};
    const thread = try std.Thread.spawn(.{}, Seen.body, .{&seen});
    thread.join();

    // The worker read back its own failure and this thread still reads none,
    // which one plain global could not produce.
    try testing.expectEqual(Tag.out_of_memory, seen.value);
    try testing.expectEqual(Tag.none, lastError());
    clearError();
}

test "the tag values are the ones the C enum names" {
    try testing.expectEqual(@as(c_int, 0), @intFromEnum(Tag.none));
    try testing.expectEqual(@as(c_int, 1), @intFromEnum(Tag.out_of_memory));
}

test "the enumerable domains are swept at compile time" {
    // `AGENTS.md` requires every enumerable domain to be named by a test rather
    // than sampled.
    inline for (@typeInfo(Tag).@"enum".fields) |field| {
        _ = std.meta.stringToEnum(Tag, field.name) orelse return error.UnknownTag;
    }
    inline for (@typeInfo(Refusal).@"enum".fields) |field| {
        _ = std.meta.stringToEnum(Refusal, field.name) orelse return error.UnknownRefusal;
    }
}

test "every carved block is large enough for its payload" {
    // The regression this records: the head count was computed by **flooring**
    // `bytes / @sizeOf(Head)`, and `bytes` is rounded up to the head's alignment
    // first, so the remainder was dropped and the block came out short. Because
    // `payloadOf` places the payload one head in, every `create`, `createBytes`
    // and `createCString` wrote past the end of its own allocation.
    //
    // **The existing tests could not see it** because their allocator pair
    // over-allocates, so the overflow landed inside slack. This test asserts the
    // block is big enough rather than relying on a heap checker to notice.
    //
    // The bound is 64 payload lengths across four alignments. The head is 24
    // bytes and the block rounds to 8, so the shortfall cycles every third
    // length and 64 steps covers every remainder class.
    const alignments = [_]usize{ 1, 2, 4, 8 };
    for (1..65) |payload_len| {
        for (alignments) |alignment| {
            const head = try carve(payload_len, alignment);

            // One head for the bookkeeping, then the payload, then the slack
            // `payloadOf` consumes aligning the payload pointer.
            const needed = @sizeOf(Head) + payload_len + alignment;
            if (head.bytes < needed) return error.BlockTooSmall;

            // The end of the payload, as a pointer, must sit inside the block.
            const payload_start = @intFromPtr(payloadOf(head, alignment));
            const payload_end = payload_start + payload_len;
            const block_end = @intFromPtr(head.raw) + head.bytes;
            if (payload_end > block_end) return error.PayloadPastEndOfBlock;

            allocator().free(head.raw.?[0..head.bytes]);
        }
    }
}
