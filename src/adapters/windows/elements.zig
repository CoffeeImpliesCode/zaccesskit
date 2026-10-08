//! Stable, reference-counted provider slots for mapped nodes and the unspecified root.
//!
//! This ports `Context::get_or_create_platform_node` and `remove_platform_node`
//! at `adapters/windows/src/context.rs:80-97` in the pinned upstream tree.
//! Removed-node construction maps to `adapter.rs:86-98`. The unspecified root
//! maps to `adapter.rs:575` and `node.rs:819-825`.
//!
//! A map entry owns one slot reference. A retained event reference keeps the
//! heap slot and its COM provider alive after removal or registry teardown.
//! Providers own weak context handles, so they do not keep the adapter alive.
//! Native creation errors propagate unchanged. A null interface is not success.
//!
//! The adapter serializes registry access. Factories must not reenter the
//! registry, query the tree, or call application code. Only slot reference
//! operations are atomic. Teardown walks the map's fixed entry count.

const std = @import("std");

const consumer = @import("../../consumer/root.zig");
const context = @import("context.zig");
const syscalls = @import("syscalls.zig");

const FullNodeId = consumer.tree_index.FullNodeId;
const Platform = syscalls.Platform;
const ProviderSlot = syscalls.ProviderSlot;

/// Owns the provider map, one baseline per slot, and one weak context handle.
///
/// Do not deinitialize independent copies. An ownership transfer must reset
/// the source. Retain borrowed slots before removal or teardown can occur.
/// The allocator and platform must outlive every retained slot, not only this
/// registry. The context's allocator, runtime, and factory table must outlive
/// its weak handles.
pub const Registry = struct {
    /// Borrowed allocator for the map and every slot allocation.
    gpa: std.mem.Allocator,

    /// Owned weak handle. Null means this registry has been deinitialized.
    weak: ?context.WeakContext = null,

    /// Heap pointers preserve slot addresses when map storage moves.
    slots: std.array_hash_map.Auto(FullNodeId, *ProviderSlot) = .empty,

    /// Owned baseline for the lazily constructed unspecified root.
    placeholder_root: ?*ProviderSlot = null,

    /// Consumes `weak` without allocation. The caller must not release that handle.
    pub fn init(gpa: std.mem.Allocator, weak: context.WeakContext) Registry {
        return .{ .gpa = gpa, .weak = weak };
    }

    /// Releases map and placeholder baselines, map storage, and the owned weak handle.
    ///
    /// Retained slots remain valid until their own final release. Repeated
    /// teardown of this same variable is safe. New construction then returns
    /// `error.ElementNotAvailable`.
    pub fn deinit(self: *Registry, platform: Platform) void {
        const gpa = self.gpa;
        for (self.slots.values()) |slot| {
            releaseSlot(gpa, platform, slot);
        }
        self.slots.deinit(gpa);
        if (self.placeholder_root) |slot| {
            releaseSlot(gpa, platform, slot);
        }
        if (self.weak) |*weak| weak.deinit();
        self.slots = .empty;
        self.placeholder_root = null;
        self.weak = null;
    }

    /// Adds one owned slot reference without adding a separate COM reference.
    ///
    /// The caller must already hold a live reference and must balance this
    /// call with `releaseSlot`. The count must remain below `maxInt(u32)`.
    pub fn retainSlot(slot: *const ProviderSlot) void {
        const previous = @constCast(slot).ref_count.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0);
        std.debug.assert(previous < std.math.maxInt(u32));
    }

    /// Drops one owned reference. The final release destroys the COM provider and slot.
    ///
    /// Use the slot's original allocator and platform. This operation does
    /// not require a live registry or adapter.
    pub fn releaseSlot(
        gpa: std.mem.Allocator,
        platform: Platform,
        slot: *const ProviderSlot,
    ) void {
        const mutable = @constCast(slot);
        const previous = mutable.ref_count.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        platform.destroy_provider(gpa, mutable.node_id orelse placeholderId(), mutable);
        gpa.destroy(mutable);
    }

    /// Returns a borrowed mapped slot, constructing its provider on the first request.
    ///
    /// Allocation and factory errors propagate unchanged. Failure leaves no
    /// new entry and preserves existing providers. The returned reference
    /// belongs to the map until retained by its caller.
    pub fn slotFor(
        self: *Registry,
        platform: Platform,
        node_id: FullNodeId,
    ) context.ProviderError!*ProviderSlot {
        if (self.slots.getPtr(node_id)) |existing| return existing.*;
        const slot = try self.detachedSlotFor(platform, node_id);
        errdefer releaseSlot(self.gpa, platform, slot);

        // Publish only after construction. No map pointer crosses a factory call.
        const entry = try self.slots.getOrPut(self.gpa, node_id);
        std.debug.assert(!entry.found_existing);
        entry.value_ptr.* = slot;
        return slot;
    }

    /// Returns a borrowed mapped slot, or null when no entry exists.
    ///
    /// Retain the result before removal or teardown can release its baseline.
    pub fn existingSlot(self: *const Registry, node_id: FullNodeId) ?*const ProviderSlot {
        const entry = self.slots.getPtr(node_id) orelse return null;
        return entry.*;
    }

    /// Removes an entry and releases only its map-owned reference.
    ///
    /// Retained events and other consumers may still use the slot. False
    /// means no entry existed.
    pub fn removeSlot(self: *Registry, platform: Platform, node_id: FullNodeId) bool {
        const slot = (self.slots.getPtr(node_id) orelse return false).*;
        const removed = self.slots.orderedRemove(node_id);
        std.debug.assert(removed);
        releaseSlot(self.gpa, platform, slot);
        return true;
    }

    /// Constructs an independently owned slot without adding a map entry.
    ///
    /// This is the removed-node path at `adapter.rs:94-97`. A new mapped
    /// provider for the same identifier remains independent. Transfer the
    /// baseline to the queue or release it with `releaseSlot`.
    /// Allocation and factory errors propagate unchanged and leave no slot.
    pub fn detachedSlotFor(
        self: *const Registry,
        platform: Platform,
        node_id: FullNodeId,
    ) context.ProviderError!*ProviderSlot {
        const weak = self.weak orelse return error.ElementNotAvailable;
        const slot = try self.gpa.create(ProviderSlot);
        slot.* = .{ .interface = null, .node_id = node_id };
        errdefer releaseSlot(self.gpa, platform, slot);
        try platform.create_provider(self.gpa, weak, node_id, slot);
        std.debug.assert(slot.interface != null);
        return slot;
    }

    /// Returns a borrowed, lazily constructed unspecified-root provider.
    ///
    /// The factory receives null, not the synthetic teardown identifier.
    /// Failure propagates unchanged and leaves no placeholder allocation.
    pub fn placeholderSlot(
        self: *Registry,
        platform: Platform,
    ) context.ProviderError!*const ProviderSlot {
        if (self.placeholder_root) |slot| return slot;
        const weak = self.weak orelse return error.ElementNotAvailable;
        const slot = try self.gpa.create(ProviderSlot);
        slot.* = .{ .interface = null };
        errdefer releaseSlot(self.gpa, platform, slot);
        slot.interface = try weak.createNode(null);
        self.placeholder_root = slot;
        return slot;
    }

    /// Counts mapped providers, excluding the unspecified root and detached slots.
    pub fn nodeCount(self: *const Registry) usize {
        return self.slots.count();
    }

    /// Supplies the synthetic identifier for platform teardown of an unspecified root.
    /// Provider construction uses null instead. This identifier is not a map entry.
    pub fn placeholderId() FullNodeId {
        return .init(.{ .value = 0 }, .init(0));
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

const adapter = @import("adapter.zig");
const bindings = @import("bindings.zig");
const queued_events = @import("queued_events.zig");

fn nodeId(value: u64) FullNodeId {
    return .init(.{ .value = value }, .init(0));
}

fn unknownFor(slot: *const ProviderSlot) *bindings.IUnknown {
    return @ptrCast(@alignCast(slot.interface.?));
}

fn ErrorFactory(comptime expected: context.ProviderError) type {
    return struct {
        fn createNode(
            _: std.mem.Allocator,
            _: context.WeakContext,
            _: ?FullNodeId,
        ) context.ProviderError!*bindings.IRawElementProviderSimple {
            return expected;
        }

        fn factory() context.ProviderFactory {
            var result = adapter.testProviderFactory();
            result.create_node = createNode;
            return result;
        }
    };
}

const FailingPlatform = struct {
    fn createProvider(
        _: std.mem.Allocator,
        _: context.WeakContext,
        _: FullNodeId,
        _: *ProviderSlot,
    ) context.ProviderError!void {
        return error.InvalidOperation;
    }

    fn platform() Platform {
        var result = adapter.testPlatform();
        result.create_provider = createProvider;
        return result;
    }
};

const UnspecifiedFactory = struct {
    fn createNode(
        gpa: std.mem.Allocator,
        weak: context.WeakContext,
        node_id: ?FullNodeId,
    ) context.ProviderError!*bindings.IRawElementProviderSimple {
        if (node_id != null) return error.InvalidOperation;
        return adapter.testProviderFactory().create_node(gpa, weak, node_id);
    }

    fn factory() context.ProviderFactory {
        var result = adapter.testProviderFactory();
        result.create_node = createNode;
        return result;
    }
};

test "a new registry holds no node and no placeholder provider" {
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const owner = try adapter.testOwner(
        testing.allocator,
        runtime.io(),
        queued_events.testAutomationApi(),
    );
    defer owner.deinit();
    const platform = adapter.testPlatform();
    var registry = Registry.init(testing.allocator, owner.context.weak());
    defer registry.deinit(platform);

    try testing.expectEqual(@as(usize, 0), registry.nodeCount());
    try testing.expectEqual(@as(?*const ProviderSlot, null), registry.existingSlot(nodeId(1)));
    try testing.expect(registry.placeholder_root == null);
}

test "the first request builds a real provider and the second answers the same slot" {
    if (!bindings.winapi_resolves) return error.SkipZigTest;
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const owner = try adapter.testOwner(
        testing.allocator,
        runtime.io(),
        queued_events.testAutomationApi(),
    );
    defer owner.deinit();
    const platform = adapter.testPlatform();
    var registry = Registry.init(testing.allocator, owner.context.weak());
    defer registry.deinit(platform);

    const first = try registry.slotFor(platform, nodeId(1));
    const second = try registry.slotFor(platform, nodeId(1));
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(usize, 1), registry.nodeCount());
    try testing.expect(std.meta.eql(nodeId(1), first.node_id.?));
    try testing.expectEqual(@as(u32, 1), first.ref_count.load(.acquire));
    const unknown = unknownFor(first);
    try testing.expectEqual(@as(u32, 2), unknown.vtable.AddRef(unknown));
    try testing.expectEqual(@as(u32, 1), unknown.vtable.Release(unknown));
}

test "two nodes hold distinct slots and distinct providers" {
    if (!bindings.winapi_resolves) return error.SkipZigTest;
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const owner = try adapter.testOwner(
        testing.allocator,
        runtime.io(),
        queued_events.testAutomationApi(),
    );
    defer owner.deinit();
    const platform = adapter.testPlatform();
    var registry = Registry.init(testing.allocator, owner.context.weak());
    defer registry.deinit(platform);

    const first = try registry.slotFor(platform, nodeId(1));
    const second = try registry.slotFor(platform, nodeId(2));
    try testing.expect(first != second);
    try testing.expect(first.interface.? != second.interface.?);
    try testing.expectEqual(@as(usize, 2), registry.nodeCount());
}

test "the same local identifier in two trees is two providers" {
    if (!bindings.winapi_resolves) return error.SkipZigTest;
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const owner = try adapter.testOwner(
        testing.allocator,
        runtime.io(),
        queued_events.testAutomationApi(),
    );
    defer owner.deinit();
    const platform = adapter.testPlatform();
    var registry = Registry.init(testing.allocator, owner.context.weak());
    defer registry.deinit(platform);

    const in_root = try registry.slotFor(platform, nodeId(7));
    const graft_id: FullNodeId = .init(.{ .value = 7 }, .init(1));
    const in_graft = try registry.slotFor(platform, graft_id);
    try testing.expect(in_root != in_graft);
    try testing.expect(in_root.interface.? != in_graft.interface.?);
    try testing.expect(std.meta.eql(graft_id, in_graft.node_id.?));
    try testing.expectEqual(@as(usize, 2), registry.nodeCount());
}

test "a fresh lookup preserves the slot and provider after map growth" {
    if (!bindings.winapi_resolves) return error.SkipZigTest;
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const owner = try adapter.testOwner(
        testing.allocator,
        runtime.io(),
        queued_events.testAutomationApi(),
    );
    defer owner.deinit();
    const platform = adapter.testPlatform();
    var registry = Registry.init(testing.allocator, owner.context.weak());
    defer registry.deinit(platform);

    const first = try registry.slotFor(platform, nodeId(1));
    const provider = first.interface.?;
    const inserted_node_count = 64;
    for (2..inserted_node_count + 1) |index| {
        _ = try registry.slotFor(platform, nodeId(index));
    }
    const fresh = registry.existingSlot(nodeId(1)).?;
    try testing.expectEqual(first, fresh);
    try testing.expectEqual(provider, fresh.interface.?);
    try testing.expectEqual(inserted_node_count, registry.nodeCount());
    try testing.expectEqual(@as(?*const ProviderSlot, null), registry.existingSlot(nodeId(65)));
}

test "removeSlot drops only the registry baseline and a retained slot survives owner close" {
    if (!bindings.winapi_resolves) return error.SkipZigTest;
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    var owner: ?*adapter.WindowsAdapter = try adapter.testOwner(
        testing.allocator,
        runtime.io(),
        queued_events.testAutomationApi(),
    );
    defer if (owner) |held| held.deinit();
    var weak = owner.?.context.weak();
    defer weak.deinit();
    const platform = adapter.testPlatform();
    var registry = Registry.init(testing.allocator, owner.?.context.weak());
    defer registry.deinit(platform);

    const retained = try registry.slotFor(platform, nodeId(5));
    Registry.retainSlot(retained);
    defer Registry.releaseSlot(testing.allocator, platform, retained);
    try testing.expectEqual(@as(u32, 2), retained.ref_count.load(.acquire));
    try testing.expect(registry.removeSlot(platform, nodeId(5)));
    try testing.expect(!registry.removeSlot(platform, nodeId(5)));
    try testing.expectEqual(@as(?*const ProviderSlot, null), registry.existingSlot(nodeId(5)));
    try testing.expectEqual(@as(u32, 1), retained.ref_count.load(.acquire));

    registry.deinit(platform);
    owner.?.deinit();
    owner = null;
    try testing.expectError(error.ElementNotAvailable, weak.lease());
    const unknown = unknownFor(retained);
    try testing.expectEqual(@as(u32, 2), unknown.vtable.AddRef(unknown));
    try testing.expectEqual(@as(u32, 1), unknown.vtable.Release(unknown));
    try testing.expectError(error.ElementNotAvailable, registry.slotFor(platform, nodeId(5)));
    try testing.expectError(error.ElementNotAvailable, registry.placeholderSlot(platform));
    try testing.expectError(error.ElementNotAvailable, registry.detachedSlotFor(platform, nodeId(5)));
}

test "registry teardown preserves a retained mapped slot until its final release" {
    if (!bindings.winapi_resolves) return error.SkipZigTest;
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const owner = try adapter.testOwner(
        testing.allocator,
        runtime.io(),
        queued_events.testAutomationApi(),
    );
    defer owner.deinit();
    const platform = adapter.testPlatform();
    var registry = Registry.init(testing.allocator, owner.context.weak());
    defer registry.deinit(platform);
    const slot = try registry.slotFor(platform, nodeId(6));
    Registry.retainSlot(slot);
    defer Registry.releaseSlot(testing.allocator, platform, slot);

    registry.deinit(platform);
    try testing.expectEqual(@as(usize, 0), registry.nodeCount());
    try testing.expectEqual(@as(u32, 1), slot.ref_count.load(.acquire));
    const unknown = unknownFor(slot);
    try testing.expectEqual(@as(u32, 2), unknown.vtable.AddRef(unknown));
    try testing.expectEqual(@as(u32, 1), unknown.vtable.Release(unknown));
}

test "the lazy unspecified root keeps its heap address across registry ownership transfer" {
    if (!bindings.winapi_resolves) return error.SkipZigTest;
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const owner = try adapter.testOwner(
        testing.allocator,
        runtime.io(),
        queued_events.testAutomationApi(),
    );
    defer owner.deinit();
    const control = try context.Context.create(
        testing.allocator,
        runtime.io(),
        owner,
        UnspecifiedFactory.factory(),
        queued_events.testAutomationApi(),
    );
    var control_open = true;
    defer if (control_open) control.close();
    const platform = adapter.testPlatform();
    var registry = Registry.init(testing.allocator, control.weak());
    defer registry.deinit(platform);
    try testing.expect(registry.placeholder_root == null);
    const first = try registry.placeholderSlot(platform);
    try testing.expect(first.interface != null);
    try testing.expect(first.node_id == null);
    Registry.retainSlot(first);
    defer Registry.releaseSlot(testing.allocator, platform, first);

    var moved = registry;
    registry = .{ .gpa = testing.allocator };
    defer moved.deinit(platform);
    const second = try moved.placeholderSlot(platform);
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(usize, 0), moved.nodeCount());
    try testing.expectEqual(
        @as(?*const ProviderSlot, null),
        moved.existingSlot(Registry.placeholderId()),
    );
    moved.deinit(platform);
    control.close();
    control_open = false;
    try testing.expectEqual(@as(u32, 1), first.ref_count.load(.acquire));
    const unknown = unknownFor(first);
    try testing.expectEqual(@as(u32, 2), unknown.vtable.AddRef(unknown));
    try testing.expectEqual(@as(u32, 1), unknown.vtable.Release(unknown));
}

test "a detached slot owns its baseline without replacing a mapped provider" {
    if (!bindings.winapi_resolves) return error.SkipZigTest;
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const owner = try adapter.testOwner(
        testing.allocator,
        runtime.io(),
        queued_events.testAutomationApi(),
    );
    defer owner.deinit();
    const platform = adapter.testPlatform();
    var registry = Registry.init(testing.allocator, owner.context.weak());
    defer registry.deinit(platform);

    const detached = try registry.detachedSlotFor(platform, nodeId(8));
    var baseline_owned = true;
    defer if (baseline_owned) Registry.releaseSlot(registry.gpa, platform, detached);
    try testing.expectEqual(@as(usize, 0), registry.nodeCount());
    const mapped = try registry.slotFor(platform, nodeId(8));
    try testing.expect(detached != mapped);
    try testing.expect(detached.interface.? != mapped.interface.?);
    try testing.expect(std.meta.eql(nodeId(8), detached.node_id.?));
    Registry.retainSlot(detached);
    defer Registry.releaseSlot(testing.allocator, platform, detached);
    try testing.expectEqual(@as(u32, 2), detached.ref_count.load(.acquire));
    try testing.expectEqual(mapped, registry.existingSlot(nodeId(8)).?);
    Registry.releaseSlot(registry.gpa, platform, detached);
    baseline_owned = false;
    try testing.expectEqual(@as(u32, 1), detached.ref_count.load(.acquire));
    const unknown = unknownFor(detached);
    try testing.expectEqual(@as(u32, 2), unknown.vtable.AddRef(unknown));
    try testing.expectEqual(@as(u32, 1), unknown.vtable.Release(unknown));
}

test "all provider factory errors preserve exact tags without publishing slots" {
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const owner = try adapter.testOwner(
        testing.allocator,
        runtime.io(),
        queued_events.testAutomationApi(),
    );
    defer owner.deinit();
    const platform = adapter.testPlatform();
    inline for (@typeInfo(context.ProviderError).error_set.?) |error_info| {
        const expected: context.ProviderError = @field(anyerror, error_info.name);
        const control = try context.Context.create(
            testing.allocator,
            runtime.io(),
            owner,
            ErrorFactory(expected).factory(),
            queued_events.testAutomationApi(),
        );
        defer control.close();
        var registry = Registry.init(testing.allocator, control.weak());
        defer registry.deinit(platform);
        try testing.expectError(expected, registry.slotFor(platform, nodeId(9)));
        try testing.expectError(expected, registry.detachedSlotFor(platform, nodeId(9)));
        try testing.expectError(expected, registry.placeholderSlot(platform));
        try testing.expectEqual(@as(usize, 0), registry.nodeCount());
        try testing.expectEqual(@as(?*const ProviderSlot, null), registry.existingSlot(nodeId(9)));
        try testing.expect(registry.placeholder_root == null);
    }
}

test "factory failure preserves existing entries and the failed identifier can be retried" {
    if (!bindings.winapi_resolves) return error.SkipZigTest;
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const owner = try adapter.testOwner(
        testing.allocator,
        runtime.io(),
        queued_events.testAutomationApi(),
    );
    defer owner.deinit();
    const platform = adapter.testPlatform();
    var registry = Registry.init(testing.allocator, owner.context.weak());
    defer registry.deinit(platform);
    const existing = try registry.slotFor(platform, nodeId(1));
    try testing.expectError(
        error.InvalidOperation,
        registry.slotFor(FailingPlatform.platform(), nodeId(2)),
    );
    try testing.expectEqual(@as(usize, 1), registry.nodeCount());
    try testing.expectEqual(existing, registry.existingSlot(nodeId(1)).?);
    try testing.expectEqual(@as(?*const ProviderSlot, null), registry.existingSlot(nodeId(2)));
    const recovered = try registry.slotFor(platform, nodeId(2));
    try testing.expectEqual(recovered, registry.existingSlot(nodeId(2)).?);
    try testing.expect(recovered.interface != null);
}

test "unavailable native provider creation returns NotImplemented without a stale entry" {
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const owner = try adapter.testOwner(
        testing.allocator,
        runtime.io(),
        queued_events.testAutomationApi(),
    );
    defer owner.deinit();
    const platform = syscalls.unavailablePlatform();
    var registry = Registry.init(testing.allocator, owner.context.weak());
    defer registry.deinit(platform);
    try testing.expectError(error.NotImplemented, registry.slotFor(platform, nodeId(1)));
    try testing.expectError(error.NotImplemented, registry.detachedSlotFor(platform, nodeId(1)));
    try testing.expectEqual(@as(usize, 0), registry.nodeCount());
    try testing.expectEqual(@as(?*const ProviderSlot, null), registry.existingSlot(nodeId(1)));
}

test "the placeholder identifier is the one upstream names at adapter.rs:374" {
    try testing.expectEqual(@as(u64, 0), Registry.placeholderId().local.value);
    try testing.expectEqual(@as(u32, 0), Registry.placeholderId().tree_index.value());
}

test "fail-N covers slots maps real provider allocation placeholder and detached ownership" {
    if (!bindings.winapi_resolves) return error.SkipZigTest;
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const platform = adapter.testPlatform();
    const allocation_failure_bound = 256;
    const inserted_node_count = 32;
    var completed = false;
    failures: for (0..allocation_failure_bound) |fail_index| {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const gpa = failing.allocator();
        const owner = adapter.testOwner(gpa, runtime.io(), queued_events.testAutomationApi()) catch |err|
            {
                try testing.expectEqual(error.OutOfMemory, err);
                continue :failures;
            };
        defer owner.deinit();
        var registry = Registry.init(gpa, owner.context.weak());
        defer registry.deinit(platform);
        var first: ?*ProviderSlot = null;
        for (0..inserted_node_count) |index| {
            const id = nodeId(index + 1);
            const slot = registry.slotFor(platform, id) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                try testing.expectEqual(index, registry.nodeCount());
                try testing.expectEqual(@as(?*const ProviderSlot, null), registry.existingSlot(id));
                if (first) |held| {
                    try testing.expectEqual(held, registry.existingSlot(nodeId(1)).?);
                    try testing.expect(held.interface != null);
                }
                failing.fail_index = std.math.maxInt(usize);
                const recovered = try registry.slotFor(platform, id);
                try testing.expectEqual(recovered, registry.existingSlot(id).?);
                try testing.expect(recovered.interface != null);
                continue :failures;
            };
            if (first == null) first = slot;
            try testing.expectEqual(slot, registry.existingSlot(id).?);
        }
        _ = registry.placeholderSlot(platform) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(registry.placeholder_root == null);
            try testing.expectEqual(inserted_node_count, registry.nodeCount());
            failing.fail_index = std.math.maxInt(usize);
            _ = try registry.placeholderSlot(platform);
            continue :failures;
        };
        const detached = registry.detachedSlotFor(platform, nodeId(64)) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(inserted_node_count, registry.nodeCount());
            try testing.expectEqual(
                @as(?*const ProviderSlot, null),
                registry.existingSlot(nodeId(64)),
            );
            failing.fail_index = std.math.maxInt(usize);
            const recovered = try registry.detachedSlotFor(platform, nodeId(64));
            Registry.releaseSlot(registry.gpa, platform, recovered);
            continue :failures;
        };
        Registry.releaseSlot(registry.gpa, platform, detached);
        completed = true;
        break;
    }
    if (!completed) return error.AllocationFailureSweepExhausted;
}

test "a foreign registry allocator covers every slot and map rollback" {
    if (!bindings.winapi_resolves) return error.SkipZigTest;
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const owner = try adapter.testOwner(
        testing.allocator,
        runtime.io(),
        queued_events.testAutomationApi(),
    );
    defer owner.deinit();
    const platform = adapter.testPlatform();
    const allocation_failure_bound = 128;
    const inserted_node_count = 32;
    var completed = false;
    failures: for (0..allocation_failure_bound) |fail_index| {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var registry = Registry.init(failing.allocator(), owner.context.weak());
        defer registry.deinit(platform);
        for (0..inserted_node_count) |index| {
            const id = nodeId(index + 1);
            _ = registry.slotFor(platform, id) catch |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                try testing.expectEqual(index, registry.nodeCount());
                try testing.expectEqual(@as(?*const ProviderSlot, null), registry.existingSlot(id));
                failing.fail_index = std.math.maxInt(usize);
                const recovered = try registry.slotFor(platform, id);
                try testing.expectEqual(recovered, registry.existingSlot(id).?);
                continue :failures;
            };
        }
        completed = true;
        break;
    }
    if (!completed) return error.AllocationFailureSweepExhausted;
}

test "registry deinit releases all baselines exactly once including the lazy root" {
    if (!bindings.winapi_resolves) return error.SkipZigTest;
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const owner = try adapter.testOwner(
        testing.allocator,
        runtime.io(),
        queued_events.testAutomationApi(),
    );
    defer owner.deinit();
    const platform = adapter.testPlatform();
    var registry = Registry.init(testing.allocator, owner.context.weak());
    defer registry.deinit(platform);
    const inserted_node_count = 32;
    for (1..inserted_node_count + 1) |index| {
        _ = try registry.slotFor(platform, nodeId(index));
    }
    const mapped = unknownFor(registry.existingSlot(nodeId(1)).?);
    try testing.expectEqual(@as(u32, 2), mapped.vtable.AddRef(mapped));
    defer _ = mapped.vtable.Release(mapped);
    const placeholder = unknownFor(try registry.placeholderSlot(platform));
    try testing.expectEqual(@as(u32, 2), placeholder.vtable.AddRef(placeholder));
    defer _ = placeholder.vtable.Release(placeholder);
    try testing.expect(registry.removeSlot(platform, nodeId(7)));
    try testing.expectEqual(inserted_node_count - 1, registry.nodeCount());

    registry.deinit(platform);
    registry.deinit(platform);
    try testing.expectEqual(@as(usize, 0), registry.nodeCount());
    try testing.expect(registry.placeholder_root == null);
    try testing.expect(registry.weak == null);
    try testing.expectEqual(@as(u32, 2), mapped.vtable.AddRef(mapped));
    try testing.expectEqual(@as(u32, 1), mapped.vtable.Release(mapped));
    try testing.expectEqual(@as(u32, 2), placeholder.vtable.AddRef(placeholder));
    try testing.expectEqual(@as(u32, 1), placeholder.vtable.Release(placeholder));
}
