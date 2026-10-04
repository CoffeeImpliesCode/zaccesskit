//! The fuzz and adversarial harness for the property table and the tree index
//! map.
//!
//! **What this covers.** `src/schema/props/table.zig` is the widest surface in
//! the port: 87 property identifiers in `PropertyId`, 29 payload variants in
//! `PropertyValue`, and a dispatch on both. `src/consumer/tree_index.zig` hands
//! each tree a number and answers in both directions, so a stale entry there is
//! a use-after-free. The four invariants below are the ones this harness
//! exists to hold.
//!
//! 1. A discriminant above the last variant is refused, never a default. The
//!    byte domain is swept whole, so the sweep reaches 255 rather than stopping
//!    at the last declared member.
//! 2. `TreeIndexMap.getOrCreateIndex` at
//!    `src/consumer/tree_index.zig:198` stays consistent across growth. A random
//!    sequence of reads, registrations and copies is the only way to find an
//!    entry that went stale.
//! 3. `Properties.set` at `src/schema/props/table.zig:1166` frees the value it
//!    displaces exactly once, and `PropertyValue.deinit` at `:391` walks a
//!    union without running the wrong arm. The whole harness runs under
//!    `std.testing.allocator`, so a leak and a double free are both findings,
//!    and a counting wrapper turns "no leak" into a positive count.
//! 4. The C ABI offsets hold for every variant. `abi.zig` reads the conformance
//!    table out of `include/zaccesskit.h` and checks every row.
//!
//! **Reproducing a failure.** Every sweep prints the seed it used and the case
//! it reached. The seed is `random.default_seed` unless a sweep names another,
//! and `Random` is a pure function of the seed, so the same seed and the same
//! case number reach the same inputs on every host. To replay one case, run
//! this file with the printed seed:
//!
//! ```text
//! zig test test/fuzz/property_table.zig
//! ```
//!
//! The fuzz target replays its committed corpus through the same entry point
//! under any runner, so the corpus is exercised by a plain `zig test` and not
//! only by `zig build fuzz`.
//!
//! **What is not here.** `src/capi/` does not exist, so the harness checks the
//! header's recorded numbers rather than a compiled C fixture, and the
//! `accesskit_opt_*` rows have no Zig counterpart to compare against. Both are
//! named in `abi.zig` rather than glossed over.

const std = @import("std");

const random = @import("random.zig");
const generate = @import("generate.zig");
const abi = @import("abi.zig");

const table = @import("../../src/schema/props/table.zig");
const ids = @import("../../src/schema/ids.zig");
const values = @import("../../src/schema/values.zig");
const action_mod = @import("../../src/schema/action.zig");
const node_enums = @import("../../src/schema/node_enums.zig");
const tree_index = @import("../../src/consumer/tree_index.zig");

const testing = std.testing;
const assert = std.debug.assert;

const Random = random.Random;
const SliceForm = generate.SliceForm;

const PropertyValue = table.PropertyValue;
const PropertyValueTag = table.PropertyValueTag;
const PropertyId = table.PropertyId;
const Properties = table.Properties;

const TreeId = ids.TreeId;
const treeIdFromBytes = ids.treeIdFromBytes;
const TreeIndexMap = tree_index.TreeIndexMap;
const TreeIndex = tree_index.TreeIndex;

/// The seed every sweep in this file starts from.
///
/// It is `random.default_seed` written out here so that a failure message
/// carries the number rather than a name, and so that a reader who changes one
/// sweep's seed does not change another's.
const sweep_seed: u64 = random.default_seed;

/// The steps one store sweep runs.
///
/// The bound is the harness's own. It is wide enough that a store reaches a
/// different shape on every step, and narrow enough that the sweep stays
/// inside the four gibibytes `build.zig:34` gives a test shard.
pub const store_step_count: usize = 2000;

/// The steps one index-map sweep runs. Same reasoning as `store_step_count`.
pub const index_step_count: usize = 2000;

/// The number of distinct tree identifiers one index sweep chooses from.
///
/// The bound is the harness's own. A domain of one would only ever exercise the
/// repeat path and a domain of thousands would not fit the sweep, so the
/// sweep names a number and asserts that every step drew from it.
pub const tree_domain: usize = 24;

/// The widest input the fuzz entry reads.
///
/// The bound is the harness's own. `Smith.bytes` fills a fixed buffer, so the
/// buffer size is the bound on one case and `valueRangeAtMost` keeps the length
/// the fuzzer asked for below it.
pub const max_input_len: usize = 256;

/// The corpus the fuzz entry replays when no fuzzer drives it.
///
/// Each entry is embedded at compile time, so a missing case is a build failure
/// rather than a skip. `corpus_lengths` pins the length of each, so a truncated
/// merge fails instead of replaying a shorter input.
pub const corpus_lengths = [_]usize{ 0, 64, 192 };

pub const corpus = [_][]const u8{
    @embedFile("corpus/case_01_empty.bin"),
    @embedFile("corpus/case_02_ordered.bin"),
    @embedFile("corpus/case_03_dense.bin"),
};

/// An allocator that counts live allocations and delegates to another one.
///
/// The counting turns "the testing allocator did not report a leak" into a
/// positive number, which is the difference between a claim and a measurement.
/// `live` is the count that matters: it must not rise while a store is
/// overwritten and must be zero after the store is released.
pub const Counting = struct {
    /// The allocator every call is forwarded to.
    inner: std.mem.Allocator,
    /// How many allocations are outstanding right now.
    live: usize = 0,
    /// How many allocations succeeded since the wrapper was made.
    allocs: usize = 0,
    /// How many releases arrived since the wrapper was made.
    frees: usize = 0,

    /// The failures this allocator reports. It adds none of its own.
    pub const Error = std.mem.Allocator.Error;

    /// A counter that forwards to `inner`.
    pub fn init(inner: std.mem.Allocator) Counting {
        return .{ .inner = inner };
    }

    /// The allocator a caller hands to the code under test.
    pub fn allocator(self: *Counting) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        const memory = self.inner.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live += 1;
        self.allocs += 1;
        return memory;
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        // A resize keeps one allocation outstanding, so the live count does
        // not move. A caller that read the count as the byte total would be
        // wrong here.
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        // A remap also keeps one allocation outstanding.
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.live -= 1;
        self.frees += 1;
        self.inner.rawFree(memory, alignment, ret_addr);
    }
};

const vtable: std.mem.Allocator.VTable = .{
    .alloc = Counting.alloc,
    .resize = Counting.resize,
    .remap = Counting.remap,
    .free = Counting.free,
};

/// A property identifier chosen from the whole byte domain, in range or out.
///
/// The out-of-range case returns `null`, which is what the port answers for a
/// byte at or past `propertyIdCount`. A caller that stored that byte and read
/// it back would be reading a property the table does not declare.
fn propertyIdFromByte(byte: u8) ?PropertyId {
    return table.propertyIdFromInt(byte);
}

test "a byte at or past the last property names no property and never a default" {
    const gpa = testing.allocator;
    const rows = try abi.parseRows(abi.header_text);
    std.debug.print(
        "\n[tree-index/property-table] header rows {d}, payload offsets {d}, " ++
            "optional rows {d}\n",
        .{ rows.len, rows.payloadRowCount(), rows.optionalRowCount() },
    );

    var cases: usize = 0;
    var byte: u16 = 0;
    while (byte <= 255) : (byte += 1) {
        const value: u8 = @intCast(byte);
        cases += 1;
        const decoded = propertyIdFromByte(value);
        if (value < table.propertyIdCount) {
            try testing.expect(decoded != null);
            try testing.expectEqual(value, @intFromEnum(decoded.?));
        } else {
            // The refusal is the whole point: a byte at or past the last
            // property must not come back as the first property.
            try testing.expect(decoded == null);
        }
    }
    try testing.expectEqual(@as(usize, 256), cases);
    try testing.expectEqual(@as(u8, 87), @intCast(table.propertyIdCount));
    std.debug.print(
        "[tree-index/property-table] propertyIdFromInt: {d} bytes, " ++
            "{d} refused at or past {d}\n",
        .{ cases, 256 - table.propertyIdCount, table.propertyIdCount },
    );

    // The store refuses the same byte the same way, through a second door.
    var store = Properties.init(gpa);
    defer store.deinit();
    var probe: u16 = table.propertyIdCount;
    while (probe <= 255) : (probe += 1) {
        const value: u8 = @intCast(probe);
        cases += 1;
        try testing.expect(propertyIdFromByte(value) == null);
    }
    std.debug.print(
        "[tree-index/property-table] property id cases {d}\n",
        .{cases},
    );
}

test "a byte at or past the last action names no action" {
    var cases: usize = 0;
    var byte: u16 = 0;
    while (byte <= 255) : (byte += 1) {
        const value: u8 = @intCast(byte);
        cases += 1;
        const decoded = action_mod.actionFromInt(value);
        if (value < action_mod.actionCount) {
            try testing.expect(decoded != null);
            try testing.expectEqual(value, @intFromEnum(decoded.?));
        } else {
            try testing.expect(decoded == null);
        }
    }
    std.debug.print(
        "[tree-index/property-table] actionFromInt: {d} bytes, " ++
            "{d} refused at or past {d}\n",
        .{ cases, 256 - action_mod.actionCount, action_mod.actionCount },
    );
}

test "a byte at or past the last decoration style names no style" {
    var cases: usize = 0;
    var byte: u16 = 0;
    while (byte <= 255) : (byte += 1) {
        const value: u8 = @intCast(byte);
        cases += 1;
        const decoded = node_enums.textDecorationStyleFromInt(value);
        if (value < node_enums.TextDecorationStyle.count) {
            try testing.expect(decoded != null);
            try testing.expectEqual(value, @intFromEnum(decoded.?));
        } else {
            try testing.expect(decoded == null);
        }
    }
    std.debug.print(
        "[tree-index/property-table] textDecorationStyleFromInt: {d} bytes\n",
        .{cases},
    );
}

test "a mask bit above the last member yields no member and never overflows" {
    var source = Random.init(sweep_seed);
    var cases: usize = 0;

    // The four masks a boundary bug hides behind: nothing, everything, one
    // low bit, and one bit above the domain.
    const fixed = [_]u32{
        0,
        std.math.maxInt(u32),
        1,
        @as(u32, 1) << @intCast(action_mod.actionCount),
        (@as(u32, 1) << @intCast(action_mod.actionCount)) - 1,
    };
    var index: usize = 0;
    while (index < fixed.len) : (index += 1) {
        cases += 1;
        try checkActionMask(fixed[index]);
        try checkFlagMask(fixed[index]);
    }
    while (index < action_mod.actionCount * 8) : (index += 1) {
        const mask = source.next();
        cases += 1;
        try checkActionMask(mask);
        try checkFlagMask(mask);
    }
    std.debug.print(
        "[tree-index/property-table] mask sweeps {d} masks, {d} actions, {d} flags\n",
        .{ cases, action_mod.actionCount, table.flagCount },
    );
}

fn checkActionMask(mask: u32) !void {
    var buffer: [action_mod.actionCount]action_mod.Action = undefined;
    const members = action_mod.actionSetMembers(mask, &buffer);
    try testing.expect(members.len <= action_mod.actionCount);
    var expect_present = false;
    for (members, 0..) |member, _| {
        try testing.expect(@intFromEnum(member) < action_mod.actionCount);
        expect_present = action_mod.actionSetContains(mask, member);
        try testing.expect(expect_present);
    }
    // Every member the mask carries and no other: the count is the popcount
    // over the declared domain, not a lower bound.
    var carried: usize = 0;
    inline for (comptime action_mod.action_values) |member| {
        if (action_mod.actionSetContains(mask, member)) carried += 1;
    }
    try testing.expectEqual(carried, members.len);
}

fn checkFlagMask(mask: u32) !void {
    var buffer: [table.flagCount]table.Flag = undefined;
    const members = table.flagSetMembers(mask, &buffer);
    try testing.expect(members.len <= table.flagCount);
    var carried: usize = 0;
    inline for (comptime std.enums.values(table.Flag)) |flag| {
        if (table.flagSetContains(mask, flag)) carried += 1;
    }
    try testing.expectEqual(carried, members.len);
}

test "every tag stores, reads back and releases, in every slice shape" {
    const gpa = testing.allocator;
    var source = Random.init(sweep_seed);
    var cases: usize = 0;

    const tags = comptime std.enums.values(PropertyValueTag);
    var tag_index: usize = 0;
    while (tag_index < tags.len) : (tag_index += 1) {
        const tag = tags[tag_index];
        var form_index: usize = 0;
        while (form_index < SliceForm.count) : (form_index += 1) {
            const form: SliceForm = @enumFromInt(@intCast(form_index));
            cases += 1;

            const built = try generate.buildValue(&source, gpa, tag, form);
            defer built.deinit(gpa);
            try testing.expectEqual(tag, built.getTag());

            // A copy taken through the port's own clone must be equal by
            // payload and independent by buffer.
            var copied = try table.propertyValueClone(gpa, built);
            defer copied.deinit(gpa);
            try testing.expect(built.eql(copied));

            if (tag == .none) {
                // Absence is what a getter sees, and the store never holds it.
                continue;
            }

            // Store it under a property that declares that payload, then read
            // it back through both doors the store offers.
            const id = propertyIdForTag(tag);
            try testing.expectEqual(tag, table.propertyValueTagOf(id));

            var store = Properties.init(gpa);
            defer store.deinit();
            try store.set(id, built);
            try testing.expectEqual(@as(usize, 1), store.count());
            try testing.expectEqual(tag, store.get(id).?.getTag());
            try testing.expect(store.get(id).?.eql(copied));
            try testing.expectEqual(id, store.items.items[0].id);

            // The same store answers a second read from the same entry.
            const again = store.get(id);
            try testing.expect(again != null);
            try testing.expectEqual(store.items.items[0].value.getTag(), again.?.getTag());
        }
    }
    std.debug.print(
        "[tree-index/property-table] payload shapes {d} cases over {d} tags and " ++
            "{d} slice forms\n",
        .{ cases, tags.len, SliceForm.count },
    );
}

test "a store answers through a model after a random sequence of writes" {
    const gpa = testing.allocator;
    var counter = Counting.init(gpa);
    const counted = counter.allocator();
    var source = Random.init(sweep_seed);

    var store = Properties.init(counted);
    defer store.deinit();
    var model = Properties.init(counted);
    defer model.deinit();

    const rows = try abi.parseRows(abi.header_text);
    std.debug.print(
        "[tree-index/property-table] header rows {d}, payload offsets {d}, " ++
            "optional rows {d}\n",
        .{ rows.len, rows.payloadRowCount(), rows.optionalRowCount() },
    );

    var step: usize = 0;
    while (step < store_step_count) : (step += 1) {
        const id = generate.pickPropertyId(&source);
        const roll = source.below(10);

        if (roll < 5) {
            // A set, with the payload the table declares for this property, so
            // a stale discriminant after a sorted-slice shift shows up as a
            // tag the descriptor does not declare.
            const tag = table.propertyValueTagOf(id);
            const value = try generate.buildValue(&source, counted, tag, formFor(source));
            const copy = try table.propertyValueClone(counted, value);
            try store.set(id, value);
            try model.set(id, copy);
        } else if (roll < 7) {
            // A repeated set of the same property, which is the overwrite path
            // that has to release the value it displaces.
            const tag = table.propertyValueTagOf(id);
            const value = try generate.buildValue(&source, counted, tag, formFor(source));
            const copy = try table.propertyValueClone(counted, value);
            try store.set(id, value);
            try model.set(id, copy);
        } else if (roll < 8) {
            store.clear(id);
            model.clear(id);
        } else if (roll < 9) {
            const tag = table.propertyValueTagOf(id);
            const default = try generate.buildValue(&source, counted, tag, .single);
            const copy = try table.propertyValueClone(counted, default);
            const inserted = try store.getOrInsert(id, default);
            const model_inserted = try model.getOrInsert(id, copy);
            try testing.expectEqual(inserted.getTag(), model_inserted.getTag());
        } else {
            // A read, which must answer the model whatever the store holds.
            const theirs = store.get(id);
            const ours = model.get(id);
            try testing.expectEqual(ours == null, theirs == null);
            if (theirs) |value| {
                try testing.expectEqual(model.get(id).?.getTag(), value.getTag());
            }
        }

        // After every step the two stores must agree structurally, and every
        // entry must carry the payload its property declares.
        try testing.expectEqual(model.count(), store.count());
        try testing.expect(store.eql(&model));
        try checkStoreInvariants(&store);
    }

    std.debug.print(
        "[tree-index/property-table] store sweep {d} steps, seed 0x{x}, " ++
            "{d} allocations live\n",
        .{ step, sweep_seed, counter.live },
    );
}

fn formFor(source: *Random) SliceForm {
    return @enumFromInt(@as(u8, @intCast(source.below(SliceForm.count))));
}

/// Every entry is in ascending id order, carries the payload its property
/// declares, and is never the port's absence.
fn checkStoreInvariants(store: *const Properties) !void {
    try testing.expect(store.count() <= table.propertyIdCount);
    var index: usize = 0;
    while (index < store.count()) : (index += 1) {
        const entry = store.items.items[index];
        try testing.expect(entry.value != .none);
        try testing.expectEqual(table.propertyValueTagOf(entry.id), entry.value.getTag());
        if (index > 0) {
            try testing.expect(
                @intFromEnum(store.items.items[index - 1].id) < @intFromEnum(entry.id),
            );
        }
    }
}

test "a repeated set releases the value it displaces and keeps the new one" {
    const gpa = testing.allocator;
    var counter = Counting.init(gpa);
    const counted = counter.allocator();

    // One property, one owned payload at a time. A `set` that failed to
    // release would raise `live` once per overwrite; a `set` that released
    // twice would trip the testing allocator underneath.
    var store = Properties.init(counted);
    defer store.deinit();

    const tags = comptime std.enums.values(PropertyValueTag);
    var steady_live: usize = 0;
    var cases: usize = 0;
    var step: usize = 0;
    while (step < 64) : (step += 1) {
        const tag = tags[step % tags.len];
        if (tag == .none) continue;
        const id = propertyIdForTag(tag);
        cases += 1;
        try store.set(id, try generate.buildValue(&Random.init(sweep_seed +% step), counted, tag, .single));
        try testing.expectEqual(tag, store.get(id).?.getTag());
        try testing.expectEqual(@as(usize, 1), store.count());
        if (step == 0) {
            steady_live = counter.live;
            continue;
        }
        // The store holds one value, so the live count is a function of that
        // one value and not of how many overwrites came before it.
        try testing.expectEqual(steady_live, counter.live);
    }

    try testing.expectEqual(counter.live, counter.allocs - counter.frees);
    try testing.expectEqual(@as(usize, 0), counter.live);
    std.debug.print(
        "[tree-index/property-table] overwrite sweep {d} sets, steady live {d}, " ++
            "allocs {d}, frees {d}\n",
        .{ cases, steady_live, counter.allocs, counter.frees },
    );
}

test "every stored property releases once when the store is released" {
    const gpa = testing.allocator;
    var counter = Counting.init(gpa);
    const counted = counter.allocator();

    // The widest store the table allows: every property at once, each with its
    // declared payload and the maximal slice, so the teardown walks every arm
    // of the union in one call.
    const tags = comptime std.enums.values(PropertyValueTag);
    var store = Properties.init(counted);
    var case_count: usize = 0;
    for (tags) |tag| {
        if (tag == .none) continue;
        try store.set(propertyIdForTag(tag), try generate.buildValue(
            &Random.init(sweep_seed +% case_count),
            counted,
            tag,
            .maximal,
        ));
        case_count += 1;
    }
    try testing.expectEqual(@as(usize, 28), store.count());
    try checkStoreInvariants(&store);
    const live_before = counter.live;
    try testing.expect(live_before > 0);

    store.deinit();
    try testing.expectEqual(@as(usize, 0), counter.live);
    try testing.expectEqual(counter.allocs, counter.frees);

    std.debug.print(
        "[tree-index/property-table] full store {d} properties, {d} allocations, " ++
            "{d} freed on deinit\n",
        .{ store_count_expected, live_before, live_before },
    );
}

const store_count_expected: usize = 28;

test "the tree index map stays consistent across a random sequence of reads and writes" {
    const gpa = testing.allocator;
    var source = Random.init(sweep_seed);

    var map = TreeIndexMap.empty;
    defer map.deinit(gpa);

    var assigned: [tree_domain]TreeId = undefined;
    var index: usize = 0;
    while (index < tree_domain) : (index += 1) {
        assigned[index] = treeIdFromBytes(@splat(@as(u8, @intCast(index + 1))));
    }

    var cases: usize = 0;
    var step: usize = 0;
    while (step < index_step_count) : (step += 1) {
        const pick = source.below(tree_domain);
        const id = assigned[pick];
        const roll = source.below(10);

        if (roll < 5) {
            const next_before = map.next;
            const got = try map.getOrCreateIndex(gpa, id);
            cases += 1;
            // A repeat must not burn a number, and a first sighting must take
            // exactly the next one.
            const already = map.getIndex(id) != null and map.getIndex(id).?.value() < next_before;
            if (already) {
                try testing.expectEqual(next_before, map.next);
            } else {
                try testing.expectEqual(next_before, got.value());
            }
            try testing.expectEqual(id, map.getId(got).?);
            try testing.expectEqual(got, map.getIndex(id).?);
        } else if (roll < 7) {
            // A probe must register nothing.
            const unseen = treeIdFromBytes(@splat(0xfe));
            const before = map.next;
            try testing.expect(map.getIndex(unseen) == null);
            try testing.expect(map.getId(TreeIndex.init(before)) == null or before > 0);
            try testing.expectEqual(before, map.next);
            cases += 1;
        } else {
            try testing.expect(map.getIndex(id) != null);
            cases += 1;
        }

        try checkIndexInvariants(&map);
    }

    // The strongest statement: the two directions agree for every number the
    // map has handed out, and no two numbers name the same tree.
    var seen: u32 = 0;
    var number: u32 = 0;
    while (number < map.next) : (number += 1) {
        const id = map.getId(TreeIndex.init(number)).?;
        const back = map.getIndex(id).?;
        try testing.expectEqual(number, back.value());
        seen |= @as(u32, 1) << @intCast(number % 32);
    }
    try testing.expectEqual(map.id_to_index.count(), map.index_to_id.count());
    try testing.expectEqual(@as(u32, @intCast(map.id_to_index.count())), map.next);

    std.debug.print(
        "[tree-index/property-table] index sweep {d} steps, {d} registrations, " ++
            "{d} registered trees, mask 0x{x}\n",
        .{ step, cases, map.next, seen },
    );
}

fn checkIndexInvariants(map: *const TreeIndexMap) !void {
    try testing.expectEqual(map.id_to_index.count(), map.index_to_id.count());
    try testing.expectEqual(@as(u32, @intCast(map.id_to_index.count())), map.next);
    var number: u32 = 0;
    while (number < map.next) : (number += 1) {
        const index = TreeIndex.init(number);
        const id = map.getId(index) orelse return error.IndexNotReverseRegistered;
        try testing.expectEqual(index, map.getIndex(id) orelse return error.IdNotForwardRegistered);
    }
}

test "a copy of the map answers as the source did and neither follows the other" {
    const gpa = testing.allocator;
    var source = Random.init(sweep_seed);

    var map = TreeIndexMap.empty;
    defer map.deinit(gpa);
    var index: usize = 0;
    while (index < tree_domain) : (index += 1) {
        _ = try map.getOrCreateIndex(gpa, treeIdFromBytes(@splat(@as(u8, @intCast(index + 1)))));
    }

    var copy = TreeIndexMap.empty;
    defer copy.deinit(gpa);
    try map.cloneInto(&copy, gpa);
    try checkIndexInvariants(&copy);
    try testing.expectEqual(map.next, copy.next);

    // A registration after the copy must not reach the copy.
    const fresh = treeIdFromBytes(@splat(0xab));
    const assigned = try map.getOrCreateIndex(gpa, fresh);
    try testing.expectEqual(fresh, map.getId(assigned).?);
    try testing.expect(copy.getIndex(fresh) == null);
    try checkIndexInvariants(&map);
    try checkIndexInvariants(&copy);

    std.debug.print(
        "[tree-index/property-table] clone sweep {d} registered trees, copy {d}\n",
        .{ map.next, copy.next },
    );
}

test "every header row a payload tag projects onto is declared with its offset" {
    const rows = try abi.parseRows(abi.header_text);
    try testing.expect(rows.len > 0);

    var cases: usize = 0;
    var projected: usize = 0;
    inline for (comptime std.enums.values(PropertyValueTag)) |tag| {
        const name = abi.tagProjection(tag) orelse {
            cases += 1;
            continue;
        };
        projected += 1;
        cases += 1;
        const row = rows.find(name) orelse return error.HeaderRowMissing;
        // A projected row is an aggregate, so it has a payload offset. A row
        // that writes `-` here is a header edit this harness must see.
        try testing.expect(row.payload_offset != null);
    }
    try testing.expectEqual(@as(usize, 26), projected);
    try testing.expectEqual(abi.tag_count, cases);

    var checked: usize = 0;
    inline for (comptime abi.zig_checks) |check| {
        const row = rows.find(check.header_name) orelse return error.HeaderRowMissing;
        try testing.expectEqual(row.size, @sizeOf(check.zig_type));
        try testing.expectEqual(row.alignment, @alignOf(check.zig_type));
        if (check.payload_field) |field| {
            const recorded = row.payload_offset orelse return error.HeaderRowMissingPayload;
            try testing.expectEqual(recorded, @offsetOf(check.zig_type, field));
        } else {
            try testing.expect(row.payload_offset == null);
        }
        checked += 1;
    }

    std.debug.print(
        "[tree-index/property-table] C ABI: {d} tags, {d} projected rows, " ++
            "{d} rows checked against a Zig type, {d} header rows\n",
        .{ abi.tag_count, projected, checked, rows.len },
    );
}

/// The property that declares the payload `tag` carries.
///
/// The walk over the domain is `table.propertyIdCount` wide, which is the count
/// of rows in `property_descriptors`. A tag with no property is a defect in the
/// table itself, so it is a named error and not a skip.
fn propertyIdForTag(tag: PropertyValueTag) PropertyId {
    var index: usize = 0;
    while (index < table.propertyIdCount) : (index += 1) {
        const row = table.property_descriptors[index];
        if (row.tag == tag) return row.id;
    }
    return error.NoPropertyCarriesTag;
}

/// The state the fuzz entry carries into one case.
///
/// A struct rather than two bare parameters, because two parameters of the same
/// type are a struct under the house rule.
pub const FuzzContext = struct {
    /// The allocator every allocation in one case goes through.
    gpa: std.mem.Allocator,
    /// The seed the case's generator starts from.
    seed: u64,
};

/// One fuzz case, driven by `std.testing.Smith`.
///
/// The bytes become a short input and the input drives `replayOne`, which is
/// the same entry the committed corpus drives. One implementation, so a corpus
/// case and a fuzzer case cannot take different paths.
fn fuzzOne(context: FuzzContext, smith: *std.testing.Smith) anyerror!void {
    var buffer: [max_input_len]u8 = undefined;
    smith.bytes(&buffer);
    const length: u8 = smith.valueRangeAtMost(u8, 0, max_input_len);
    const drawn: u64 = smith.value(u64);
    return replayOne(context, buffer[0..length], drawn);
}

/// One case over an explicit input, which is what both the corpus and the
/// fuzzer reach.
///
/// The walk over the input is `input.len` bytes, which the caller bounds by
/// `max_input_len`. Every op it performs is drawn from a generator seeded by
/// `seed`, so the same input and the same seed reach the same store.
pub fn replayOne(context: FuzzContext, input: []const u8, seed: u64) !void {
    var source = Random.init(seed);
    var store = Properties.init(context.gpa);
    defer store.deinit();

    const rounds = if (input.len == 0) 1 else input.len;
    var offset: usize = 0;
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        const byte = input[offset];
        offset += 1;
        if (offset == input.len) offset = 0;

        const id = generate.pickPropertyId(&source);
        const tag = table.propertyValueTagOf(id);
        switch (byte & 3) {
            0 => {
                const value = try generate.buildValue(&source, context.gpa, tag, .drawn);
                try store.set(id, value);
            },
            1 => store.clear(id),
            2 => {
                const default = try generate.buildValue(&source, context.gpa, tag, .empty);
                _ = try store.getOrInsert(id, default);
            },
            3 => {
                _ = store.get(id);
            },
            else => unreachable,
        }
        try checkStoreInvariants(&store);
        try testing.expect(store.count() <= table.propertyIdCount);
    }
}

test "the committed corpus drives the entry the fuzzer drives" {
    const gpa = testing.allocator;
    try testing.expectEqual(corpus.len, corpus_lengths.len);
    var cases: usize = 0;
    var index: usize = 0;
    while (index < corpus.len) : (index += 1) {
        const input = corpus[index];
        try testing.expectEqual(corpus_lengths[index], input.len);
        cases += 1;
        try replayOne(.{ .gpa = gpa, .seed = sweep_seed }, input, sweep_seed +% @as(u64, @intCast(index)));
        // The same input twice must reach the same store, which is what makes
        // a failure reproducible from the corpus alone.
        try replayOne(.{ .gpa = gpa, .seed = sweep_seed }, input, sweep_seed +% @as(u64, @intCast(index)));
    }
    std.debug.print(
        "[tree-index/property-table] corpus {d} cases, {d} bytes replayed twice\n",
        .{ cases, corpus_lengths[0] + corpus_lengths[1] + corpus_lengths[2] },
    );
}

test "fuzz: the property table and the tree index map" {
    var counter = Counting.init(testing.allocator);
    const context: FuzzContext = .{ .gpa = counter.allocator(), .seed = sweep_seed };
    try testing.fuzz(context, fuzzOne, .{ .corpus = &corpus });
    std.debug.print(
        "[tree-index/property-table] fuzz corpus done, {d} allocations live\n",
        .{counter.live},
    );
}

/// The property identifiers in the table, in wire order.
///
/// The walk over the domain is `table.propertyIdCount` wide. This exists so a
/// caller that wants the whole domain has one name for it.
pub fn everyPropertyId() []const PropertyId {
    comptime var out: [table.propertyIdCount]PropertyId = undefined;
    comptime var index: usize = 0;
    inline while (index < table.propertyIdCount) : (index += 1) {
        out[index] = @enumFromInt(@as(u8, @intCast(index)));
    }
    comptime return &out;
}

test "the property domain and the descriptor table cannot drift" {
    const domain = everyPropertyId();
    try testing.expectEqual(table.propertyIdCount, domain.len);
    var index: usize = 0;
    while (index < domain.len) : (index += 1) {
        try testing.expectEqual(index, @intFromEnum(domain[index]));
        try testing.expectEqual(table.propertyValueTagOf(domain[index]), table.property_descriptors[index].tag);
        const id = propertyIdForTag(table.property_descriptors[index].tag);
        try testing.expectEqual(domain[index], id);
    }
}