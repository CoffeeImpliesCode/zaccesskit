//! The application context: the one registry of AT-SPI windows, and the four
//! values every window's node answers from.
//!
//! **Upstream.** `accesskit_atspi_common/src/context.rs:89-122` declares
//! `AppContext`, its constructor and its three adapter-list operations.
//! `context.rs:35-40` declares `Context`, the per-window half, and `:76-78` is
//! `Context::do_action`. `docs/41-atspi-build-map.md` section 1.5 records the
//! members that read this registry: `Accessible.GetIndexInParent` through
//! `PlatformNode::index_in_parent` at `node.rs:939-943`, and every
//! `PlatformRoot` member at `node.rs:1816-1928`.
//!
//! **Why `NodeContext` and not `Context`.** Upstream's `Context` is four values
//! behind four locks: the application registry, the tree, the action handler and
//! the window boxes. The port has no locks and no shared ownership, so the four
//! become one plain struct a node holds a pointer to. That is the whole of the
//! change, and it is why `node.zig` never reads a global and never needs one:
//! `AGENTS.md` section 3 asks for `io` to be threaded and for state to be a
//! parameter, and a node's state arrives as `*const NodeContext` at construction.
//!
//! **The registry is a list and the lookup is `binary_search_by`, and that is
//! upstream's pair, not the port's.** `pushAdapter` appends and `adapterIndex`
//! runs the same walk `context.rs:109-111` runs, probe for probe, so the two
//! agree on every input and not only on sorted ones. On a sorted registry the
//! answer is the index; on an unsorted one it is whatever that walk finds,
//! which `removeAdapter` then removes. The reason neither half is "fixed" is
//! observable: `PlatformRoot::child_at_index` numbers its children by list
//! position, so inserting in sorted order would renumber them. The test at the
//! end of this file pins both halves separately, including the unsorted case.
//!
//! **Ownership.** `AppContext` owns three optional texts and its adapter list.
//! `deinit` releases those buffers. The optional application id owns no storage.
//! Registry entries borrow `NodeContext` values and their trees. Their owner must
//! remove the entries before releasing the contexts or trees.
//!
//! **No clock, no runtime, no file-scope variable.** Nothing here reads time and
//! nothing here holds a global.

const std = @import("std");

const adapter_errors = @import("error.zig");
const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const window_bounds = @import("window_bounds.zig");

/// The failures one of these operations reports.
///
/// `adapterIndex` refuses with `error.AdapterNotRegistered` and never fails for
/// any other reason. Registry reservation and text preparation can return
/// `error.OutOfMemory`. Failed preparation leaves published metadata unchanged.
pub const AppContextError = adapter_errors.Error || std.mem.Allocator.Error;

/// The place a raised action request goes.
///
/// Upstream's `Context::do_action` at `context.rs:76-78` forwards one
/// `ActionRequest` to the handler the application installed. The port keeps the
/// request by value and passes it to a function pointer, which is the shape
/// `AGENTS.md` section 2 asks for and the shape `src/capi/boundary.zig:71`
/// already declares for the C side.
///
/// **The handler owns the request.** `schema.ActionRequest.deinit` at
/// `update.zig:267` says the receiver releases the buffer the `value` variant
/// owns, once, with the allocator that produced it. A handler that does not
/// release it leaks, and a handler that releases it twice double-frees, so the
/// contract travels with the type and not with this struct.
///
/// `context` is the handler's own userdata and reaches `raise` unchanged. It
/// must outlive every call.
pub const ActionSink = struct {
    /// What `raise` hands back to the handler that installed it.
    context: ?*anyopaque,
    /// The call itself. It takes the request by value and takes ownership of it.
    raise: *const fn (context: ?*anyopaque, request: schema.ActionRequest) void,
};

/// The four values one AT-SPI window's node answers from.
///
/// Every field is a pointer or a by-value box, so the struct itself owns nothing
/// and has no `deinit`. A `PlatformNode` holds one of these by pointer, and the
/// caller must keep this context and its tree alive while a node borrows them.
/// Upstream keeps the context behind `Weak<Context>`. The owner pump keeps its
/// context at a stable address and removes registered handles before teardown.
///
/// `PlatformNode.resolve` reports `error.Defunct` when the tree no longer holds
/// the node. `app` and `sink` are optional because the registry and action
/// handler can arrive after the tree does.
pub const NodeContext = struct {
    /// The materialised tree every value is read from.
    state: *const consumer.tree_state.TreeState,
    /// The application registry, or `null` while the process has built none.
    app: ?*const AppContext,
    /// The root window's two boxes, which every geometry member converts through.
    bounds: window_bounds.WindowBounds,
    /// Where a raised action goes, or `null` while no handler is installed.
    sink: ?ActionSink,
    /// The allocator every buffer a member of this window builds is grown with.
    /// `setTextContents` copies the text into the request it raises, and the
    /// handler releases it with the same allocator.
    gpa: std.mem.Allocator,

    /// Constructs a borrowed node handle. The context must outlive that handle.
    /// Upstream `adapters/atspi-common/src/adapter.rs:480-482`.
    pub fn platformNode(
        self: *const NodeContext,
        adapter_id: usize,
        id: consumer.tree_index.FullNodeId,
    ) @import("node.zig").PlatformNode {
        return @import("node.zig").PlatformNode.init(self, adapter_id, id);
    }

    /// The full root identity of this materialized tree.
    /// Upstream `adapters/atspi-common/src/adapter.rs:484-486`.
    pub fn rootId(self: *const NodeContext) consumer.tree_index.FullNodeId {
        return self.state.rootId();
    }

    /// Constructs a borrowed application root, or Defunct without an application.
    /// Upstream `adapters/atspi-common/src/adapter.rs:488-490`.
    pub fn platformRoot(self: *const NodeContext) error{Defunct}!@import("node.zig").PlatformRoot {
        const app = self.app orelse return error.Defunct;
        return app.platformRoot();
    }
};

/// One AT-SPI window in the application registry.
///
/// Upstream's entry is the pair `(usize, Arc<Context>)`. The port keeps the
/// number, because `PlatformNode::id` and `index_inParent` both read it, and
/// replaces the `Arc` with a pointer to the window's own context.
pub const AdapterEntry = struct {
    /// The number every object path under this window carries.
    id: usize,
    /// The window. It must outlive the entry, because `PlatformRoot` hands a
    /// `PlatformNode` built from it to every caller of `childAtIndex`.
    context: *const NodeContext,
};

/// Owns both replacement toolkit texts until commit or one deinit call.
/// Copies share storage. Release with the allocator used by prepareToolkitMetadata.
pub const PreparedToolkitMetadata = struct {
    name: []u8,
    /// Null means the toolkit has no version, distinct from an empty version.
    version: ?[]u8,

    /// Releases uncommitted replacements. This value is unusable afterward.
    pub fn deinit(self: *PreparedToolkitMetadata, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.version) |text| gpa.free(text);
        self.* = undefined;
    }
};

/// The registry of AT-SPI windows, three optional texts, and an optional id.
///
/// Upstream `context.rs:90-96`. Text buffers and the adapter list belong to this
/// value and use `gpa`. The optional application id is a number, not a buffer.
pub const AppContext = struct {
    /// The allocator every text and the list itself grew with.
    gpa: std.mem.Allocator,
    /// The application's name, which `Accessible.GetName` on the root reports.
    name: ?[]u8,
    /// The toolkit name, which the registry fills in when a window registers.
    toolkit_name: ?[]u8,
    /// The toolkit version, which is absent when the toolkit states none.
    toolkit_version: ?[]u8,
    /// The number the registry assigned this application, or `null` while the
    /// AT-SPI registry has not told it one. `PlatformRoot::id` answers `-1`
    /// while it is `null`.
    id: ?i32,
    /// The windows, in the order they registered.
    adapters: std.ArrayList(AdapterEntry),

    /// Builds a registry with one name and no windows. Upstream
    /// `AppContext::new` at `context.rs:99-107`.
    ///
    /// The name is copied, so the caller keeps its own buffer and this one is
    /// released by `deinit`.
    ///
    /// **Errors.** `error.OutOfMemory` from the copy and from the list.
    pub fn init(
        gpa: std.mem.Allocator,
        name: ?[]const u8,
    ) std.mem.Allocator.Error!AppContext {
        var out: AppContext = .{
            .gpa = gpa,
            .name = null,
            .toolkit_name = null,
            .toolkit_version = null,
            .id = null,
            .adapters = .empty,
        };
        errdefer out.deinit();
        if (name) |text| out.name = try gpa.dupe(u8, text);
        return out;
    }

    /// Constructs a root handle that borrows this application's live registry.
    pub fn platformRoot(self: *const AppContext) @import("node.zig").PlatformRoot {
        return @import("node.zig").PlatformRoot.init(self);
    }

    /// Releases three optional text buffers and the adapter list. Registry entries
    /// borrow their contexts and trees, which this function does not release.
    ///
    /// **Errors.** This function does not fail.
    pub fn deinit(self: *AppContext) void {
        const gpa = self.gpa;
        for ([_]?[]u8{ self.name, self.toolkit_name, self.toolkit_version }) |text| {
            if (text) |held| gpa.free(held);
        }
        self.adapters.deinit(gpa);
        self.* = undefined;
    }

    /// The list position of the window numbered `id`, or
    /// `error.AdapterNotRegistered`.
    ///
    /// Upstream `context.rs:109-111` is `binary_search_by_key` over the
    /// identifier of each entry and returns `Err(insertion_point)` for a
    /// number the registry does not hold. Both callers drop that payload: the
    /// one at `node.rs:941-942` maps it to `Error::Defunct` and the one at
    /// `remove_adapter` tests it. So the port declares the failure as a tag and
    /// does not carry the insertion point, which no caller reads.
    ///
    /// **Bound.** `binarySearchStepBound`, which is the number of times the
    /// width can be halved before it reaches zero, plus the one comparison
    /// after the loop. The assertion names the bound rather than leaving the
    /// loop to run past it.
    ///
    /// **Errors.** `error.AdapterNotRegistered` when no window carries `id`.
    pub fn adapterIndex(self: AppContext, id: usize) error{AdapterNotRegistered}!usize {
        // Upstream `context.rs:109-111` is `self.adapters.binary_search_by`,
        // so this is that algorithm and not a lower-bound search: equality
        // returns at the probe, and the miss answers the insertion point.
        // The two agree on every sorted registry, and they agree on an
        // unsorted one too, because this is the same walk and not an
        // equivalent one. A lower-bound search was here before and answered
        // differently on unsorted input.
        const search_step_bound = binarySearchStepBound(self.adapters.items.len);
        var size: usize = self.adapters.items.len;
        var left: usize = 0;
        var right: usize = size;
        var step: usize = 0;
        while (left < right) {
            step += 1;
            assert(step <= search_step_bound);
            const middle = left + size / 2;
            const probe = self.adapters.items[middle].id;
            if (probe < id) {
                left = middle + 1;
            } else if (probe > id) {
                right = middle;
            } else {
                return middle;
            }
            size = right - left;
        }
        return error.AdapterNotRegistered;
    }

    /// Registers `context` under `id`. Upstream `context.rs:113-115`.
    ///
    /// The entry is appended and not inserted in sorted position, which is what
    /// `Vec::push` does upstream. See the module doc for why the pair with
    /// `adapterIndex` is ported as it is.
    ///
    /// **Errors.** `error.OutOfMemory` from the list.
    pub fn pushAdapter(
        self: *AppContext,
        id: usize,
        context: *const NodeContext,
    ) std.mem.Allocator.Error!void {
        try self.adapters.append(self.gpa, .{ .id = id, .context = context });
    }

    /// Reserves one registry slot before tree acceptance. The list length and
    /// existing entries remain unchanged, including on OutOfMemory.
    pub fn reserveAdapter(self: *AppContext) std.mem.Allocator.Error!void {
        try self.adapters.ensureUnusedCapacity(self.gpa, 1);
    }

    /// Publishes a borrowed context without allocation after reserveAdapter.
    /// The registry must be sorted, and id must exceed every registered id.
    /// The context must outlive its registry entry. These are caller preconditions.
    pub fn pushAdapterAssumeCapacity(
        self: *AppContext,
        id: usize,
        context: *const NodeContext,
    ) void {
        assert(self.adapters.items.len < self.adapters.capacity);
        if (self.adapters.items.len != 0) {
            assert(self.adapters.items[self.adapters.items.len - 1].id < id);
        }
        self.adapters.appendAssumeCapacity(.{ .id = id, .context = context });
    }

    /// Removes the window numbered `id`, and does nothing when the registry
    /// holds no such window. Upstream `context.rs:117-121`.
    ///
    /// The entries after the removed one shift down by one, because
    /// `PlatformRoot::childAtIndex` numbers children by list position.
    ///
    /// **Bound.** `adapters.items.len` minus one, which is the shift loop's own
    /// bound and does not change while it runs.
    ///
    /// **Errors.** This function does not fail. A number the registry does not
    /// hold is an ordinary answer and not a failure.
    pub fn removeAdapter(self: *AppContext, id: usize) void {
        const index = self.adapterIndex(id) catch return;
        var cursor = index;
        while (cursor + 1 < self.adapters.items.len) : (cursor += 1) {
            self.adapters.items[cursor] = self.adapters.items[cursor + 1];
        }
        self.adapters.items.len -= 1;
    }

    /// The entry at `index`, or `null` when `index` is past the last one.
    ///
    /// Upstream `context.adapters.get(index)` at `node.rs:1862` and `:1872`.
    ///
    /// **Errors.** This function does not fail.
    pub fn entryAt(self: AppContext, index: usize) ?AdapterEntry {
        if (index >= self.adapters.items.len) return null;
        return self.adapters.items[index];
    }

    /// How many windows the registry holds, as the `i32` a client reads.
    ///
    /// Upstream `node.rs:1836-1840` converts the length and reports
    /// `Error::TooManyChildren` when it does not fit.
    ///
    /// **Errors.** `error.TooManyChildren` when the length exceeds `i32`.
    pub fn childCount(self: AppContext) adapter_errors.Error!i32 {
        return std.math.cast(i32, self.adapters.items.len) orelse error.TooManyChildren;
    }

    /// Records `text` as the toolkit name, replacing what was there.
    ///
    /// Upstream `adapter.rs:461` assigns `app_context.toolkit_name` while a
    /// window registers its tree. The port copies, so the caller keeps its own
    /// buffer.
    ///
    /// Unchanged text allocates nothing. OutOfMemory leaves both fields unchanged.
    pub fn setToolkitName(self: *AppContext, text: []const u8) std.mem.Allocator.Error!void {
        if (self.toolkit_name) |held| {
            if (std.mem.eql(u8, held, text)) return;
        }
        const replacement = try self.gpa.dupe(u8, text);
        if (self.toolkit_name) |held| self.gpa.free(held);
        self.toolkit_name = replacement;
    }

    /// Records `text` as the toolkit version, replacing what was there, and
    /// releases the previous one.
    ///
    /// Upstream `adapter.rs:462` assigns `Option<String>`, so `null` is an
    /// ordinary answer and not a failure.
    ///
    /// Unchanged text allocates nothing. OutOfMemory leaves both fields unchanged.
    pub fn setToolkitVersion(
        self: *AppContext,
        text: ?[]const u8,
    ) std.mem.Allocator.Error!void {
        if (self.toolkit_version) |held| {
            if (text) |value| {
                if (std.mem.eql(u8, held, value)) return;
            }
        } else if (text == null) {
            return;
        }
        const replacement = if (text) |value| try self.gpa.dupe(u8, value) else null;
        if (self.toolkit_version) |held| self.gpa.free(held);
        self.toolkit_version = replacement;
    }

    /// Replaces both toolkit texts together. Inputs may borrow the old texts.
    /// OutOfMemory leaves both previous values unchanged. Null clears the version.
    /// Upstream `adapters/atspi-common/src/adapter.rs:461-462`.
    pub fn setToolkitMetadata(
        self: *AppContext,
        toolkit_name: []const u8,
        toolkit_version: ?[]const u8,
    ) std.mem.Allocator.Error!void {
        if (try self.prepareToolkitMetadata(toolkit_name, toolkit_version)) |prepared| {
            self.commitToolkitMetadata(prepared);
        }
    }

    /// Copies replacements without changing published metadata. Inputs may borrow
    /// either old text. Null means both texts already match, including optional
    /// presence. On OutOfMemory, both old texts remain unchanged.
    /// The caller must commit the result or deinit it with this application's gpa.
    pub fn prepareToolkitMetadata(
        self: *const AppContext,
        toolkit_name: []const u8,
        toolkit_version: ?[]const u8,
    ) std.mem.Allocator.Error!?PreparedToolkitMetadata {
        const name_matches = if (self.toolkit_name) |name|
            std.mem.eql(u8, name, toolkit_name)
        else
            false;
        const version_matches = if (self.toolkit_version) |old_version|
            if (toolkit_version) |new_version|
                std.mem.eql(u8, old_version, new_version)
            else
                false
        else
            toolkit_version == null;
        if (name_matches and version_matches) return null;
        const new_name = try self.gpa.dupe(u8, toolkit_name);
        errdefer self.gpa.free(new_name);
        const new_version = if (toolkit_version) |text|
            try self.gpa.dupe(u8, text)
        else
            null;
        return .{ .name = new_name, .version = new_version };
    }

    /// Takes ownership of replacements prepared with this application's gpa.
    /// Publishes both texts without allocation. Do not deinit prepared afterward.
    pub fn commitToolkitMetadata(self: *AppContext, prepared: PreparedToolkitMetadata) void {
        if (self.toolkit_name) |held| self.gpa.free(held);
        if (self.toolkit_version) |held| self.gpa.free(held);
        self.toolkit_name = prepared.name;
        self.toolkit_version = prepared.version;
    }

    /// The name the root object reports, or the empty slice when the
    /// application states none. Upstream `node.rs:1828-1830`.
    ///
    /// **Errors.** This function does not fail.
    pub fn nameOrEmpty(self: AppContext) []const u8 {
        return self.name orelse "";
    }

    /// The toolkit name the root object reports, or the empty slice. Upstream
    /// `node.rs:1908-1910`.
    ///
    /// **Errors.** This function does not fail.
    pub fn toolkitNameOrEmpty(self: AppContext) []const u8 {
        return self.toolkit_name orelse "";
    }

    /// The toolkit version the root object reports, or the empty slice.
    /// Upstream `node.rs:1912-1914`.
    ///
    /// **Errors.** This function does not fail.
    pub fn toolkitVersionOrEmpty(self: AppContext) []const u8 {
        return self.toolkit_version orelse "";
    }

    /// The number the AT-SPI registry assigned, or `-1` while it has not.
    /// Upstream `node.rs:1916-1918`.
    ///
    /// **Errors.** This function does not fail.
    pub fn idOrMinusOne(self: AppContext) i32 {
        return self.id orelse -1;
    }
};

/// The bound on the binary search over `adapter_count` entries.
///
/// Each iteration halves the width, so the loop runs once per bit of the width
/// and then once more for the comparison after it. The extra step is what makes
/// a width of one cost two rather than one.
pub fn binarySearchStepBound(adapter_count: usize) usize {
    var steps: usize = 0;
    var width = adapter_count;
    while (width > 0) : (width >>= 1) steps += 1;
    return steps + 1;
}

const assert = std.debug.assert;
const testing = std.testing;

/// A tree one window answers from, with no registry and no handler.
fn testContext(state: *const consumer.tree_state.TreeState) NodeContext {
    return .{
        .state = state,
        .app = null,
        .bounds = window_bounds.WindowBounds.empty,
        .sink = null,
        .gpa = testing.allocator,
    };
}

test "a new registry holds one name, no windows and no number" {
    const gpa = testing.allocator;
    var app = try AppContext.init(gpa, "text editor");
    defer app.deinit();

    try testing.expectEqualStrings("text editor", app.nameOrEmpty());
    try testing.expectEqualStrings("", app.toolkitNameOrEmpty());
    try testing.expectEqualStrings("", app.toolkitVersionOrEmpty());
    try testing.expectEqual(@as(i32, -1), app.idOrMinusOne());
    try testing.expectEqual(@as(usize, 0), app.adapters.items.len);
}

test "a registry with no name reports the empty slice and not a null" {
    const gpa = testing.allocator;
    var app = try AppContext.init(gpa, null);
    defer app.deinit();

    try testing.expectEqual(@as(?[]u8, null), app.name);
    try testing.expectEqualStrings("", app.nameOrEmpty());
}

test "three windows register in order and the search finds each one" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    var contexts = [_]NodeContext{
        testContext(&state),
        testContext(&state),
        testContext(&state),
    };
    var app = try AppContext.init(gpa, null);
    defer app.deinit();
    try app.pushAdapter(0, &contexts[0]);
    try app.pushAdapter(1, &contexts[1]);
    try app.pushAdapter(2, &contexts[2]);

    // `context.rs:110`. A binary search over a list whose identifiers ascend
    // answers the list position of each of them.
    try testing.expectEqual(@as(usize, 0), try app.adapterIndex(0));
    try testing.expectEqual(@as(usize, 1), try app.adapterIndex(1));
    try testing.expectEqual(@as(usize, 2), try app.adapterIndex(2));
}

test "the search refuses a number the registry does not hold" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    var context = testContext(&state);
    var app = try AppContext.init(gpa, null);
    defer app.deinit();
    try app.pushAdapter(7, &context);

    try testing.expectEqual(@as(usize, 0), try app.adapterIndex(7));
    try testing.expectError(error.AdapterNotRegistered, app.adapterIndex(6));
    try testing.expectError(error.AdapterNotRegistered, app.adapterIndex(8));
    try testing.expectError(error.AdapterNotRegistered, app.adapterIndex(0));
}

test "an empty registry refuses every number" {
    const gpa = testing.allocator;
    var app = try AppContext.init(gpa, null);
    defer app.deinit();

    try testing.expectError(error.AdapterNotRegistered, app.adapterIndex(0));
    // The bound for a width of zero is one, which is the comparison the loop
    // never reaches.
    try testing.expectEqual(@as(usize, 1), binarySearchStepBound(0));
}

test "removing a middle window shifts the ones after it down by one" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    var contexts = [_]NodeContext{
        testContext(&state),
        testContext(&state),
        testContext(&state),
    };
    var app = try AppContext.init(gpa, null);
    defer app.deinit();
    try app.pushAdapter(0, &contexts[0]);
    try app.pushAdapter(1, &contexts[1]);
    try app.pushAdapter(2, &contexts[2]);

    app.removeAdapter(1);

    // `Vec::remove` shifts, and `PlatformRoot::childAtIndex` numbers children
    // by list position, so the window that was third is now second.
    try testing.expectEqual(@as(usize, 2), app.adapters.items.len);
    try testing.expectEqual(@as(usize, 0), try app.adapterIndex(0));
    try testing.expectEqual(@as(usize, 1), try app.adapterIndex(2));
    try testing.expectError(error.AdapterNotRegistered, app.adapterIndex(1));
}

test "removing a number the registry does not hold changes nothing" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    var context = testContext(&state);
    var app = try AppContext.init(gpa, null);
    defer app.deinit();
    try app.pushAdapter(4, &context);

    app.removeAdapter(5);
    app.removeAdapter(0);

    try testing.expectEqual(@as(usize, 1), app.adapters.items.len);
    try testing.expectEqual(@as(usize, 0), try app.adapterIndex(4));
}

test "the pair upstream writes is the pair the port writes, in both halves" {
    // `push_adapter` appends and `adapter_index` binary-searches, so a registry
    // whose identifiers did not arrive in ascending order is one the search
    // cannot answer. This test is the evidence for that claim rather than an
    // assertion that it is desirable: a port that fixed one half without the
    // other would renumber every child after the first out-of-order push.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    var context = testContext(&state);
    var app = try AppContext.init(gpa, null);
    defer app.deinit();
    try app.pushAdapter(2, &context);
    try app.pushAdapter(0, &context);

    // The list holds both, in push order, which is what `child_at_index` reads.
    // These two entries fit in i32, so childCount cannot return TooManyChildren.
    try testing.expectEqual(@as(i32, 2), app.childCount() catch unreachable);
    try testing.expectEqual(@as(usize, 2), (app.entryAt(0).?).id);
    try testing.expectEqual(@as(usize, 0), (app.entryAt(1).?).id);

    // `binary_search_by` on `[2, 0]` probes index 1 first: id 0 compares
    // equal there and answers 1, while id 2 compares less, walks left past
    // index 0 and misses. That is `Ok(1)` and `Err(2)` upstream, and the port
    // answers the same because it is the same walk.
    try testing.expectEqual(@as(usize, 1), try app.adapterIndex(0));
    try testing.expectError(error.AdapterNotRegistered, app.adapterIndex(2));
}

test "the toolkit texts are copied in and out, and replacing one frees the old" {
    const gpa = testing.allocator;
    var app = try AppContext.init(gpa, null);
    defer app.deinit();

    try app.setToolkitName("GTK");
    try testing.expectEqualStrings("GTK", app.toolkitNameOrEmpty());

    // The caller drops its own buffer after the call and the registry keeps its
    // own, so the second line would read freed memory if the first were stored.
    try app.setToolkitVersion("4.14");
    try testing.expectEqualStrings("4.14", app.toolkitVersionOrEmpty());

    try app.setToolkitVersion(null);
    try testing.expectEqualStrings("", app.toolkitVersionOrEmpty());
}

test "entryAt answers null past the last window and the entry before it" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    var context = testContext(&state);
    var app = try AppContext.init(gpa, null);
    defer app.deinit();

    try testing.expectEqual(@as(?AdapterEntry, null), app.entryAt(0));
    try app.pushAdapter(3, &context);
    try testing.expectEqual(@as(usize, 3), (app.entryAt(0).?).id);
    try testing.expectEqual(@as(?AdapterEntry, null), app.entryAt(1));
}

test "context bridge constructs live node root identity and application root" {
    const gpa = testing.allocator;
    var update: schema.TreeUpdate = .{};
    var transferred = false;
    errdefer if (!transferred) update.deinit(gpa);
    try update.pushNode(gpa, .{ .value = 9 }, schema.Node.init(gpa, .window));
    update.tree = schema.TreeInfo.init(.{ .value = 9 });
    update.focus = .{ .value = 9 };
    transferred = true;
    var tree = try consumer.tree.Tree.init(gpa, update, true);
    defer tree.deinit();
    var app = try AppContext.init(gpa, "Bridge");
    defer app.deinit();
    var context = testContext(tree.stateOf());
    context.app = &app;
    try app.pushAdapter(7, &context);
    const platform = context.platformNode(7, context.rootId());
    try testing.expectEqual(tree.stateOf().rootId(), platform.id);
    try testing.expectEqual(@as(usize, 7), platform.adapter_id);
    try testing.expectEqual(tree.stateOf().rootId(), (try platform.resolve()).id());
    try testing.expect((try context.platformRoot()).eql(app.platformRoot()));
    try testing.expectEqualStrings("Bridge", app.platformRoot().name());
    context.app = null;
    try testing.expectError(error.Defunct, context.platformRoot());
}

fn toolkitMetadataFailure(gpa: std.mem.Allocator, comptime mode: enum {
    name,
    version,
    pair,
}) !void {
    var app = try AppContext.init(gpa, null);
    defer app.deinit();
    try app.setToolkitName("Old toolkit");
    try app.setToolkitVersion("Old version");
    const result = switch (mode) {
        .name => app.setToolkitName("New toolkit"),
        .version => app.setToolkitVersion("New version"),
        .pair => app.setToolkitMetadata("New toolkit", "New version"),
    };
    result catch |err| {
        try testing.expectEqualStrings("Old toolkit", app.toolkitNameOrEmpty());
        try testing.expectEqualStrings("Old version", app.toolkitVersionOrEmpty());
        return err;
    };
    try testing.expectEqualStrings(
        if (mode == .version) "Old toolkit" else "New toolkit",
        app.toolkitNameOrEmpty(),
    );
    try testing.expectEqualStrings(
        if (mode == .name) "Old version" else "New version",
        app.toolkitVersionOrEmpty(),
    );
}

fn toolkitNameFailure(gpa: std.mem.Allocator) !void {
    try toolkitMetadataFailure(gpa, .name);
}

fn toolkitVersionFailure(gpa: std.mem.Allocator) !void {
    try toolkitMetadataFailure(gpa, .version);
}

fn toolkitPairFailure(gpa: std.mem.Allocator) !void {
    try toolkitMetadataFailure(gpa, .pair);
}

test "toolkit metadata replacement fail N preserves the old texts" {
    try testing.checkAllAllocationFailures(testing.allocator, toolkitNameFailure, .{});
    try testing.checkAllAllocationFailures(testing.allocator, toolkitVersionFailure, .{});
}

test "toolkit metadata pair fail N preserves both old texts" {
    try testing.checkAllAllocationFailures(testing.allocator, toolkitPairFailure, .{});
}

test "toolkit metadata pair accepts aliased old inputs and absent version" {
    var app = try AppContext.init(testing.allocator, null);
    defer app.deinit();
    try app.setToolkitName("Toolkit");
    try app.setToolkitVersion("1");
    try app.setToolkitMetadata(app.toolkitNameOrEmpty(), app.toolkitVersionOrEmpty());
    try testing.expectEqualStrings("Toolkit", app.toolkitNameOrEmpty());
    try testing.expectEqualStrings("1", app.toolkitVersionOrEmpty());
    try app.setToolkitMetadata("Other", null);
    try testing.expectEqualStrings("Other", app.toolkitNameOrEmpty());
    try testing.expectEqual(@as(?[]u8, null), app.toolkit_version);
}

fn preparedToolkitFailure(gpa: std.mem.Allocator) !void {
    var app = try AppContext.init(gpa, null);
    defer app.deinit();
    try app.setToolkitMetadata("Old toolkit", "Old version");
    const result = app.prepareToolkitMetadata("New toolkit", "New version") catch |err| {
        try testing.expectEqualStrings("Old toolkit", app.toolkitNameOrEmpty());
        try testing.expectEqualStrings("Old version", app.toolkitVersionOrEmpty());
        return err;
    };
    try testing.expect(result != null);
    var prepared = result.?;
    defer prepared.deinit(gpa);
    try testing.expectEqualStrings("New toolkit", prepared.name);
    try testing.expectEqualStrings("New version", prepared.version.?);
    try testing.expectEqualStrings("Old toolkit", app.toolkitNameOrEmpty());
    try testing.expectEqualStrings("Old version", app.toolkitVersionOrEmpty());
}

test "prepared toolkit metadata fail N leaves published texts unchanged" {
    try testing.checkAllAllocationFailures(testing.allocator, preparedToolkitFailure, .{});
}

test "prepared toolkit metadata skips unchanged values without allocating" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    var app = try AppContext.init(failing.allocator(), null);
    defer app.deinit();
    try app.setToolkitMetadata("Toolkit", "Version");
    try testing.expectEqual(
        @as(?PreparedToolkitMetadata, null),
        try app.prepareToolkitMetadata(app.toolkitNameOrEmpty(), app.toolkitVersionOrEmpty()),
    );
}

test "prepared toolkit metadata commits aliased inputs and distinguishes null version" {
    const gpa = testing.allocator;
    var app = try AppContext.init(gpa, null);
    defer app.deinit();
    try app.setToolkitMetadata("Toolkit", "Version");
    var prepared = (try app.prepareToolkitMetadata(
        app.toolkitVersionOrEmpty(),
        app.toolkitNameOrEmpty(),
    )).?;
    var transferred = false;
    defer if (!transferred) prepared.deinit(gpa);
    try testing.expectEqualStrings("Toolkit", app.toolkitNameOrEmpty());
    try testing.expectEqualStrings("Version", app.toolkitVersionOrEmpty());
    transferred = true;
    app.commitToolkitMetadata(prepared);
    try testing.expectEqualStrings("Version", app.toolkitNameOrEmpty());
    try testing.expectEqualStrings("Toolkit", app.toolkitVersionOrEmpty());
    try app.setToolkitMetadata("Version", null);
    var empty_version = (try app.prepareToolkitMetadata("Version", "")).?;
    var empty_transferred = false;
    defer if (!empty_transferred) empty_version.deinit(gpa);
    try testing.expect(app.toolkit_version == null);
    empty_transferred = true;
    app.commitToolkitMetadata(empty_version);
    try testing.expect(app.toolkit_version != null);
    try testing.expectEqualStrings("", app.toolkitVersionOrEmpty());
}

fn reserveAdapterFailure(gpa: std.mem.Allocator) !void {
    var update: schema.TreeUpdate = .{};
    var transferred = false;
    errdefer if (!transferred) update.deinit(testing.allocator);
    try update.pushNode(testing.allocator, .{ .value = 9 }, schema.Node.init(testing.allocator, .window));
    update.tree = schema.TreeInfo.init(.{ .value = 9 });
    update.focus = .{ .value = 9 };
    transferred = true;
    var tree = try consumer.tree.Tree.init(testing.allocator, update, true);
    defer tree.deinit();
    var app = try AppContext.init(gpa, null);
    defer app.deinit();
    try app.setToolkitMetadata("Toolkit", "Version");
    var context = testContext(tree.stateOf());
    context.app = &app;
    app.reserveAdapter() catch |err| {
        try testing.expectEqual(@as(i32, 0), try app.childCount());
        try testing.expectEqualStrings("Toolkit", app.toolkitNameOrEmpty());
        try testing.expectEqualStrings("Version", app.toolkitVersionOrEmpty());
        return err;
    };
    try testing.expectEqual(@as(i32, 0), try app.childCount());
    app.pushAdapterAssumeCapacity(7, &context);
    const child = app.platformRoot().childAtIndex(0).?;
    try testing.expectEqual(@as(usize, 7), child.adapter_id);
    try testing.expectEqual(tree.stateOf().rootId(), (try child.resolve()).id());
    try testing.expectEqual(@as(i32, 1), try app.childCount());
}

test "adapter reservation fail N publishes a real window only after infallible append" {
    try testing.checkAllAllocationFailures(testing.allocator, reserveAdapterFailure, .{});
}

test "standalone toolkit setters preserve untouched storage and null metadata" {
    var app = try AppContext.init(testing.allocator, null);
    defer app.deinit();
    try app.setToolkitVersion("Version");
    try testing.expectEqual(@as(?[]u8, null), app.toolkit_name);
    const version_pointer = app.toolkit_version.?.ptr;
    try app.setToolkitName(app.toolkitVersionOrEmpty());
    try testing.expect(app.toolkit_version.?.ptr == version_pointer);
    try testing.expectEqualStrings("Version", app.toolkitNameOrEmpty());
    try app.setToolkitName("Other toolkit");
    const name_pointer = app.toolkit_name.?.ptr;
    try app.setToolkitVersion(app.toolkitNameOrEmpty());
    try testing.expect(app.toolkit_name.?.ptr == name_pointer);
    try testing.expectEqualStrings("Other toolkit", app.toolkitVersionOrEmpty());
}

test "standalone unchanged toolkit setters do not allocate" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    var app = try AppContext.init(failing.allocator(), null);
    defer app.deinit();
    try app.setToolkitName("Toolkit");
    try app.setToolkitVersion("Version");
    try app.setToolkitName(app.toolkitNameOrEmpty());
    try app.setToolkitVersion(app.toolkitVersionOrEmpty());
    try testing.expectEqualStrings("Toolkit", app.toolkitNameOrEmpty());
    try testing.expectEqualStrings("Version", app.toolkitVersionOrEmpty());
}
