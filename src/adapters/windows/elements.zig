//! The provider registry: one stable slot per node the adapter has published.
//!
//! **What this file ports.** `Context::get_or_create_platform_node` and
//! `Context::remove_platform_node` from
//! `adapters/windows/src/context.rs:31-58` in the pinned upstream tree, and
//! the two root lookups that `adapter.rs:559` and `adapter.rs:582` make
//! against them. Upstream keeps a `HashMap<FullNodeId, PlatformNode>` behind a
//! mutex and every `PlatformNode` is an `Arc`.
//!
//! **What the port does differently, and why.** A queued event holds the
//! provider it names, and it holds it past the end of the update that produced
//! it: `QueuedEvents::raise` runs after the adapter has let go of its own state
//! at `adapter.rs:643-667`. So the object an event names must outlive every map
//! operation that follows. `std.array_hash_map` stores its values inside one
//! array, and growing that array moves them, so the port stores a **pointer**
//! per node and allocates each slot on its own. A pointer into the map would
//! dangle on the first insert that grows the map, and the failure would be a
//! use-after-free on a screen reader rather than a build failure.
//!
//! **What a slot is.** `syscalls.ProviderSlot`. The node layer writes the
//! `IRawElementProviderSimple` it built into `interface`; the adapter never
//! reads that field and only the platform calls do. On a target with no node
//! layer `interface` stays `null` and the slot is still a distinct address, so
//! the adapter's own protocol — which node an event names, and in what order —
//! is the same on every host and is testable here.
//!
//! **Loop bounds.** The one loop outside a test is `deinit`, and its bound is
//! the map's own entry count at the moment the walk starts. The map is not
//! modified during the walk, so the bound holds for the whole of it.

const std = @import("std");

const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const syscalls = @import("syscalls.zig");

const FullNodeId = consumer.tree_index.FullNodeId;
const Platform = syscalls.Platform;
const PropertyValue = schema.PropertyValue;
const ProviderSlot = syscalls.ProviderSlot;

/// The nodes the adapter has published a provider for.
///
/// The value owns one allocation per node plus the map that indexes them, and
/// `deinit` releases both through the allocator `init` was given. There is no
/// copy operation, because two owners of one slot release it twice, so the only
/// way to hand a registry to a callee is a pointer.
pub const Registry = struct {
    /// The allocator that grew every slot and the map. It must stay valid for
    /// the life of the registry, and it must be the allocator `init` was given.
    gpa: std.mem.Allocator,

    /// The slot per node. The value is a pointer so the slot keeps its address
    /// when the map grows, which is the whole reason the map does not store the
    /// slot inline.
    slots: std.array_hash_map.Auto(FullNodeId, *ProviderSlot) = .empty,

    /// The provider `handleWmGetobject` names while the adapter holds a
    /// placeholder tree. It is a field rather than a map entry because it has
    /// no node: upstream builds it at `adapter.rs:575` with
    /// `PlatformNode::unspecified_root`, which names no node at all.
    placeholder_root: ProviderSlot = .{ .interface = null },

    /// An empty registry.
    ///
    /// Nothing is allocated, so this call cannot fail.
    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .gpa = gpa };
    }

    /// Releases every provider and the map that indexes them.
    ///
    /// `platform` is the seam the slots were built with, because releasing a
    /// provider is a platform call. Every queued event must already have been
    /// raised: a raise reads a slot, so a slot released here is a slot an event
    /// still names.
    ///
    /// The registry is left in its empty form, so a second call releases
    /// nothing and a read after the call answers the empty registry rather than
    /// a freed map.
    pub fn deinit(self: *Registry, platform: Platform) void {
        const gpa = self.gpa;
        var it = self.slots.iterator();
        while (it.next()) |entry| {
            platform.destroy_provider(gpa, entry.key_ptr.*, entry.value_ptr.*);
            gpa.destroy(entry.value_ptr.*);
        }
        self.slots.deinit(gpa);
        platform.destroy_provider(gpa, placeholderId(), &self.placeholder_root);
        self.* = .{ .gpa = gpa };
    }

    /// The slot for `node_id`, building the provider the first time.
    ///
    /// This is the port of `get_or_create_platform_node`. The second call for
    /// the same node answers the same slot and does not build a second
    /// provider, because a second provider for one node would be two COM
    /// objects answering for one runtime identifier.
    ///
    /// `error.OutOfMemory` when the slot or the map entry cannot be allocated.
    /// The registry is unchanged on that path and the caller owns nothing.
    pub fn slotFor(self: *Registry, platform: Platform, node_id: FullNodeId) !*ProviderSlot {
        const gpa = self.gpa;
        const entry = try self.slots.getOrPut(gpa, node_id);
        if (entry.found_existing) return entry.value_ptr.*;

        // `getOrPut` already indexed the key, so a failure below must unindex
        // it: a later request would otherwise find an entry whose provider was
        // never built, and `deinit` would walk a slot pointer that was never
        // written.
        errdefer {
            const removed = self.slots.orderedRemove(node_id);
            std.debug.assert(removed);
        }
        const slot = try gpa.create(ProviderSlot);
        errdefer gpa.destroy(slot);
        slot.* = .{ .interface = null };
        platform.create_provider(gpa, node_id, slot);
        entry.value_ptr.* = slot;
        return slot;
    }

    /// The slot for `node_id`, or `null` when the adapter holds none.
    ///
    /// This is the read half of `get_or_create_platform_node` and the port of
    /// `element_for_possibly_removed_node`'s first branch at `adapter.rs:87-92`:
    /// a node the tree still holds has a slot, and a node the tree has dropped
    /// does not.
    pub fn existingSlot(self: *const Registry, node_id: FullNodeId) ?*const ProviderSlot {
        const entry = self.slots.getPtr(node_id) orelse return null;
        return entry.*;
    }

    /// Releases the provider for `node_id` and drops it from the map.
    ///
    /// This is the port of `remove_platform_node`, which `node_removed` calls at
    /// `adapter.rs:349`. A `false` answer means the adapter held no provider for
    /// the node, which is an ordinary answer and not a failure.
    ///
    /// A caller must not remove a node whose event is already queued. That is
    /// what `detachedSlotFor` is for: it gives the event a provider of its own
    /// to name, and the queue releases it.
    pub fn removeSlot(self: *Registry, platform: Platform, node_id: FullNodeId) bool {
        const gpa = self.gpa;
        const slot = (self.slots.getPtr(node_id) orelse return false).*;
        platform.destroy_provider(gpa, node_id, slot);
        gpa.destroy(slot);
        // The entry was read above, so the map must still hold it.
        const removed = self.slots.orderedRemove(node_id);
        std.debug.assert(removed);
        return true;
    }

    /// A provider slot for a node the tree no longer holds, which the caller
    /// owns.
    ///
    /// This is the port of `element_for_possibly_removed_node`'s second branch
    /// at `adapter.rs:94-97`, where a node the tree has dropped still needs a
    /// provider because an event about it is about to be raised. The slot is
    /// deliberately **not** in the map: it names a node the tree does not
    /// hold, and a later update that adds the same node must build a new
    /// provider rather than find this one.
    ///
    /// The caller owns the result and must hand it to
    /// `QueuedEvents.takeOwnership` or release it with `releaseDetached`. An
    /// event that names a slot outlives the handler that queued it, so the
    /// queue is the natural owner.
    ///
    /// `error.OutOfMemory` leaves nothing behind.
    pub fn detachedSlotFor(
        self: *const Registry,
        platform: Platform,
        node_id: FullNodeId,
    ) std.mem.Allocator.Error!*ProviderSlot {
        const gpa = self.gpa;
        const slot = try gpa.create(ProviderSlot);
        errdefer gpa.destroy(slot);
        slot.* = .{ .interface = null };
        platform.create_provider(gpa, node_id, slot);
        return slot;
    }

    /// Releases a slot `detachedSlotFor` returned. The caller that holds it is
    /// the caller that releases it; the registry does not know about it.
    pub fn releaseDetached(
        self: *const Registry,
        platform: Platform,
        node_id: FullNodeId,
        slot: *ProviderSlot,
    ) void {
        platform.destroy_provider(self.gpa, node_id, slot);
        self.gpa.destroy(slot);
    }

    /// The provider for the placeholder root.
    ///
    /// The slot is a field of the registry and not an entry in the map, so its
    /// address never moves and it needs no lookup.
    pub fn placeholderSlot(self: *const Registry) *const ProviderSlot {
        return &self.placeholder_root;
    }

    /// How many nodes the registry holds a provider for.
    ///
    /// The placeholder root is not counted: it names no node, so counting it
    /// would make a caller that compares this against a node count wrong by one.
    pub fn nodeCount(self: *const Registry) usize {
        return self.slots.count();
    }

    /// The node identifier the placeholder root is filed under.
    ///
    /// It exists so `deinit` and the tests can name the placeholder in a
    /// `FullNodeId` without inventing a second spelling. The value is
    /// `NodeId(0)`, which is `PLACEHOLDER_ROOT_ID` at `adapter.rs:374`, and the
    /// placeholder root does not live in the map, so the identifier names no
    /// entry.
    pub fn placeholderId() FullNodeId {
        return .init(.{ .value = 0 }, .init(0));
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

/// A seam that builds a distinguishable provider without any global state.
///
/// It answers `present` as true so a test can tell a build from a refusal, and
/// it writes an address derived from the node identifier into `interface`, so a
/// test can tell one node's provider from another's. Nothing dereferences that
/// address: only the platform reads `interface`, and this seam is a test seam.
const CountingPlatform = struct {
    fn platform() Platform {
        return .{
            .present = true,
            .init_uia = initUia,
            .create_provider = createProvider,
            .destroy_provider = destroyProvider,
            .return_raw_element_provider = returnRawElementProvider,
            .raise_event = raiseEvent,
            .raise_property_changed = raisePropertyChanged,
        };
    }

    fn createProvider(gpa: std.mem.Allocator, node_id: FullNodeId, slot: *ProviderSlot) void {
        _ = gpa;
        slot.interface = @ptrFromInt(0x1000 + node_id.local.value);
    }

    fn destroyProvider(gpa: std.mem.Allocator, node_id: FullNodeId, slot: *ProviderSlot) void {
        _ = gpa;
        _ = node_id;
        slot.interface = null;
    }

    fn returnRawElementProvider(
        hwnd: syscalls.Hwnd,
        wparam: syscalls.WParam,
        lparam: syscalls.LParam,
        slot: *const ProviderSlot,
    ) syscalls.LResult {
        _ = hwnd;
        _ = wparam;
        _ = lparam;
        _ = slot;
        return 1;
    }

    fn raiseEvent(slot: *const ProviderSlot, event_id: syscalls.EventId) syscalls.RaiseStatus {
        _ = slot;
        _ = event_id;
        return .raised;
    }

    fn raisePropertyChanged(
        slot: *const ProviderSlot,
        property_id: syscalls.PropertyId,
        old: PropertyValue,
        new: PropertyValue,
    ) syscalls.RaiseStatus {
        _ = slot;
        _ = property_id;
        _ = old;
        _ = new;
        return .raised;
    }

    fn initUia() ?i32 {
        return 30001;
    }
};

fn nodeId(value: u64) FullNodeId {
    return .init(.{ .value = value }, .init(0));
}

test "a new registry holds no node and no placeholder provider" {
    const platform = CountingPlatform.platform();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit(platform);

    try testing.expectEqual(@as(usize, 0), registry.nodeCount());
    try testing.expectEqual(@as(?*const ProviderSlot, null), registry.existingSlot(nodeId(1)));
    try testing.expectEqual(@as(?*anyopaque, null), registry.placeholderSlot().interface);
}

test "the first request builds the provider and the second answers the same slot" {
    const platform = CountingPlatform.platform();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit(platform);

    const first = try registry.slotFor(platform, nodeId(1));
    try testing.expectEqual(@as(usize, 1), registry.nodeCount());

    const second = try registry.slotFor(platform, nodeId(1));
    // A registry that built a second provider for one node would leave two
    // COM objects answering for one runtime identifier.
    try testing.expectEqual(first, second);
    try testing.expectEqual(@as(usize, 1), registry.nodeCount());
    try testing.expectEqual(@as(usize, 0x1001), @intFromPtr(first.interface.?));
}

test "two nodes hold two distinct slots" {
    const platform = CountingPlatform.platform();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit(platform);

    const first = try registry.slotFor(platform, nodeId(1));
    const second = try registry.slotFor(platform, nodeId(2));

    try testing.expect(first != second);
    try testing.expectEqual(@as(usize, 2), registry.nodeCount());
}

test "the same local identifier in two trees is two providers" {
    // `FullNodeId` is the tree-and-node pair, so a graft that reuses a local
    // identifier must not collide with the node it shadows. The house rule is
    // `std.meta.eql` and never `==` for this type, so the test compares the two
    // slots it got rather than the identifiers.
    const platform = CountingPlatform.platform();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit(platform);

    const in_root = try registry.slotFor(platform, nodeId(7));
    const in_graft = try registry.slotFor(platform, .init(.{ .value = 7 }, .init(1)));

    try testing.expect(in_root != in_graft);
    try testing.expectEqual(@as(usize, 2), registry.nodeCount());
}

test "a slot keeps its address when the map grows past its first capacity" {
    // The reason the map stores a pointer. An inline value would move on a
    // growth and the address a queued event holds would dangle, which is a
    // use-after-free on a screen reader rather than a build failure.
    const platform = CountingPlatform.platform();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit(platform);

    const first_slot = try registry.slotFor(platform, nodeId(1));
    const held_address = @intFromPtr(first_slot);

    // The bound is the 64 entries this walk inserts, which is several times the
    // map's first capacity and so forces the array behind it to reallocate.
    const inserted_node_count = 64;
    var index: usize = 2;
    while (index <= inserted_node_count) : (index += 1) {
        _ = try registry.slotFor(platform, nodeId(index));
    }

    try testing.expectEqual(held_address, @intFromPtr(first_slot));
    try testing.expectEqual(inserted_node_count, registry.nodeCount());
}

test "existingSlot reads the slot a request already built" {
    const platform = CountingPlatform.platform();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit(platform);

    const built = try registry.slotFor(platform, nodeId(3));
    const read = registry.existingSlot(nodeId(3)) orelse return error.MissingSlot;

    try testing.expectEqual(built, read);
    try testing.expectEqual(@as(?*const ProviderSlot, null), registry.existingSlot(nodeId(4)));
}

test "removeSlot releases the provider and the second call reports that it held none" {
    const platform = CountingPlatform.platform();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit(platform);

    _ = try registry.slotFor(platform, nodeId(5));
    try testing.expectEqual(@as(usize, 1), registry.nodeCount());

    try testing.expect(registry.removeSlot(platform, nodeId(5)));
    try testing.expectEqual(@as(usize, 0), registry.nodeCount());
    // A `false` answer is the ordinary one, not a failure.
    try testing.expect(!registry.removeSlot(platform, nodeId(5)));
    try testing.expectEqual(@as(?*const ProviderSlot, null), registry.existingSlot(nodeId(5)));
}

test "the placeholder slot has one address for the life of the registry" {
    const platform = CountingPlatform.platform();
    var registry = Registry.init(testing.allocator);
    defer registry.deinit(platform);

    const first = registry.placeholderSlot();
    _ = try registry.slotFor(platform, nodeId(1));
    _ = try registry.slotFor(platform, nodeId(2));
    const second = registry.placeholderSlot();

    try testing.expectEqual(first, second);
    // The placeholder names no node, so it is not in the map and the node count
    // does not move.
    try testing.expectEqual(@as(usize, 2), registry.nodeCount());
    try testing.expectEqual(
        @as(?*const ProviderSlot, null),
        registry.existingSlot(Registry.placeholderId()),
    );
}

test "the placeholder identifier is the one upstream names at adapter.rs:374" {
    try testing.expectEqual(@as(u64, 0), Registry.placeholderId().local.value);
    try testing.expectEqual(@as(u32, 0), Registry.placeholderId().tree_index.value());
}

test "every allocation failure leaves the registry as it was" {
    // Fail-N from the first allocation up to the one that succeeds, so every
    // `error.OutOfMemory` path and every `errdefer` runs at least once.
    const failing_allocations = 4;
    var fail_index: usize = 0;
    while (fail_index < failing_allocations) : (fail_index += 1) {
        const platform = CountingPlatform.platform();
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var registry = Registry.init(failing.allocator());
        defer registry.deinit(platform);

        const answer = registry.slotFor(platform, nodeId(1));
        if (answer) |slot| {
            try testing.expectEqual(@as(usize, 1), registry.nodeCount());
            try testing.expectEqual(@as(*ProviderSlot, slot), registry.existingSlot(nodeId(1)).?);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            // A failed insert must leave no node behind, or a later request
            // would find a slot whose provider was never built.
            try testing.expectEqual(@as(usize, 0), registry.nodeCount());
            try testing.expectEqual(
                @as(?*const ProviderSlot, null),
                registry.existingSlot(nodeId(1)),
            );
        }
    }
}

test "the registry releases every slot it built" {
    // `testing.allocator` traps on a leak, so this is the check that `deinit`
    // reaches every entry the walk at `Registry.deinit` claims to reach.
    const platform = CountingPlatform.platform();
    var registry = Registry.init(testing.allocator);

    const inserted_node_count = 32;
    var index: usize = 1;
    while (index <= inserted_node_count) : (index += 1) {
        _ = try registry.slotFor(platform, nodeId(index));
    }
    try testing.expect(registry.removeSlot(platform, nodeId(7)));
    try testing.expectEqual(inserted_node_count - 1, registry.nodeCount());

    registry.deinit(platform);
    try testing.expectEqual(@as(usize, 0), registry.nodeCount());

    // A second release must reach nothing rather than reach a freed map.
    registry.deinit(platform);
    try testing.expectEqual(@as(usize, 0), registry.nodeCount());
}
