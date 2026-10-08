//! Native AppKit C entry points and the pure Host test seam.
//!
//! C handles use c_native.Bridge and real Objective-C objects on macOS.
//! Other targets refuse with NativeUnsupported before inspecting host pointers
//! or allocating. Pure Host helpers exercise tree and ownership behavior only;
//! they are not native providers.
//!
//! Queues own their captured allocator and payload independently of the adapter.
//! Native queues retain Objective-C targets; pure queues retain tree metadata but
//! stop calling the borrowed Host when the adapter closes.

const std = @import("std");

const boundary = @import("../../capi/boundary.zig");
const c_tree_update = @import("../../capi/tree_update.zig");
const action_request = @import("../../capi/action_request.zig");
const allocation = @import("../../capi/allocation.zig");
const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");

const attributes_mod = @import("attributes.zig");
const events_mod = @import("events.zig");
const literals_mod = @import("literals.zig");
const roles_mod = @import("roles.zig");
const native = @import("native.zig");
const c_native = @import("c_native.zig");
/// Checked real native class patch installers; no C diagnostic suppression.
pub const patch = @import("patch.zig");
/// Canonical typed native runtime used by AppKit clients.
pub const objc = @import("objc.zig");
pub const foundation = @import("foundation.zig");
const builtin = @import("builtin");

const ActivationHandler = boundary.ActivationHandler;
const ActionHandler = boundary.ActionHandler;
const CTreeUpdate = boundary.CTreeUpdate;
const TreeUpdateFactory = boundary.TreeUpdateFactory;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const FullNodeId = consumer.tree_index.FullNodeId;
const NodeRef = consumer.node_id.NodeRef;
const TreeUpdateError = consumer.tree.UpdateError;
const testing = std.testing;

/// The role tables, the literal tables, the selector table and the event
/// tables, re-exported so `src/capi/platform.zig` and a caller can reach them
/// from one module.
pub const literals = literals_mod;
pub const roles = roles_mod;
pub const attributes = attributes_mod;
pub const events = events_mod;

pub const NativeAdapter = native.NativeAdapter;
pub const Options = native.Options;
pub const ActivationSink = native.ActivationSink;
pub const FullTreeSupplier = native.FullTreeSupplier;
pub const AttachTarget = native.AttachTarget;
pub const NativeError = native.NativeError;
pub const CreateError = native.CreateError;
pub const AttachError = native.AttachError;
pub const CloseError = native.CloseError;
pub const UpdateError = native.UpdateError;
pub const NotificationError = native.NotificationError;
pub const UpdateOutcome = native.UpdateOutcome;
pub const PreparedUpdateOutcome = native.PreparedUpdateOutcome;
pub const RuntimeRelease = native.RuntimeRelease;
pub const NativeNotifications = native.NativeNotifications;

/// The one allocator this adapter uses for its own lifetimes.
///
/// It is `allocation.allocator()` and not a fresh allocator, because the C
/// header releases the debug string with `accesskit_string_free`, which is
/// `marshal.string_free(allocation.allocator(), value)`. A block from a
/// different allocator released through that one is a mismatched free, so the
/// adapter must take its allocator from the same place.
fn heap() Allocator {
    return allocation.allocator();
}

/// The pure notification and geometry seam used by deterministic source tests.
/// Native C handles never hold or call this vtable.
pub const Host = struct {
    /// The callee's own state, passed to every call unchanged.
    ptr: ?*anyopaque,
    /// `NSAccessibilityPostNotification(node, notification)`.
    post: *const fn (?*anyopaque, ?*anyopaque, [:0]const u8) void,
    /// `NSAccessibilityPostNotificationWithUserInfo(window, notification,
    /// user_info)`, with the two keys and the priority already flattened into
    /// the three arguments.
    post_with_user_info: *const fn (
        ?*anyopaque,
        ?*anyopaque,
        [:0]const u8,
        []const u8,
        i32,
    ) void,
    /// The view a context holds, or `null` when it is gone.
    view_of: *const fn (?*anyopaque) ?*anyopaque,
    /// The window that holds `view`, or `null` when there is none.
    window_of: *const fn (?*anyopaque, ?*anyopaque) ?*anyopaque,
    /// The node at a point in `view`'s coordinates, or `null` when nothing is
    /// there.
    hit_test: *const fn (?*anyopaque, f64, f64) ?*anyopaque,
};

/// One platform node: the object a client sends messages to.
///
/// Upstream this is an `Id<PlatformNode>`, a real Objective-C object. Here it is
/// a value the context owns, allocated from the context's arena so that the
/// pointer stays valid for as long as the context does, which is the property
/// the arena is for. **A `PlatformNode` carries no Objective-C behaviour on this
/// host**: the 54 selectors live in `attributes.zig` as tables and pure
/// functions, and answering them through a real `NSObject` needs AppKit.
pub const PlatformNode = struct {
    /// The tree node this object stands for.
    id: FullNodeId,
};

/// A list of platform nodes, standing in for the `NSArray` upstream returns
/// from `view_children`.
///
/// It lives in the context's arena and holds a copy of the pointers, so it is
/// released with the context and needs no release of its own.
pub const NodeList = struct {
    /// The nodes, in the order the filtered walk produced them.
    nodes: []const *PlatformNode,
};

/// What `Context.doAction` can report.
///
/// The two members are the conversion and raw allocator errors from
/// `boundary.createActionRequest`. The set is named rather than inferred at the
/// call, so a caller can tell an exhausted allocator from a text no C string
/// can spell.
pub const DoActionError = error{
    /// The declared allocator could not supply the request block or the buffer
    /// a `value` payload owns. The handler was not called.
    OutOfMemory,
    /// The `value` bytes hold a 0 byte, so no `char *` spells the rest of the
    /// text. The handler was not called.
    InteriorNul,
};

/// The tree, the platform nodes and the handler, reference counted.
///
/// Upstream `Context`, at `AK/macos/src/context.rs:26-102`. It owns the
/// materialized tree, the map from a `FullNodeId` to a platform node, and one
/// reference to the action handler. It holds no view strongly: `view` is the
/// `?*anyopaque` the caller gave the adapter and it stays valid until the
/// adapter is freed, exactly as the header requires.
const Context = struct {
    /// The allocator that grew the tree and the node map.
    allocator: Allocator,
    /// How many owners this context has. It reaches zero only when the adapter
    /// and every queued-events handle have let it go.
    refs: usize,
    /// Closing ends every borrowed Host and callback lifetime, not tree ownership.
    closed: bool = false,
    /// The tree an application reads.
    tree: consumer.tree.Tree,
    /// Metadata strings borrowed by the tree, retained with queued contexts.
    metadata_owners: c_tree_update.LiveMetadataOwners,
    /// The platform seam.
    host: Host,
    /// The handler an action request reaches.
    action_handler: ActionHandler,
    /// The callee's context for `action_handler`.
    action_userdata: ?*anyopaque,
    /// The view this context's nodes belong to.
    view: ?*anyopaque,
    /// One platform node per tree node the client has asked about.
    nodes: std.AutoHashMapUnmanaged(FullNodeId, *PlatformNode),
    /// The arena every `PlatformNode` is allocated from, so a pointer handed to
    /// a client stays valid while the context lives.
    arena: std.heap.ArenaAllocator,

    /// Builds a context over `update`, which is transferred to the call.
    ///
    /// **Returns.** `error.OutOfMemory`, `error.NoRootTree` and
    /// `error.NotTheRootTree` from `consumer.tree.Tree.init`, and every tag in
    /// `consumer.tree.UpdateError`. On any failure nothing survives: the arena
    /// and the node map are released before the call returns.
    fn init(
        allocator: Allocator,
        update: schema.TreeUpdate,
        owners: c_tree_update.LiveMetadataOwners,
        is_view_focused: bool,
        host: Host,
        action_handler: ActionHandler,
        action_userdata: ?*anyopaque,
        view: ?*anyopaque,
    ) (TreeUpdateError || Allocator.Error)!*Context {
        var metadata_owners = owners;
        errdefer metadata_owners.deinit();
        var tree = consumer.tree.Tree.init(allocator, update, is_view_focused) catch |err| {
            metadata_owners.reap(null);
            return err;
        };
        metadata_owners.reap(&tree);
        // Registered before the first fallible allocation, so every path below
        // that fails releases the tree rather than leaking it.
        errdefer tree.deinit();

        const context = try allocator.create(Context);
        errdefer allocator.destroy(context);

        context.* = .{
            .allocator = allocator,
            .refs = 1,
            .tree = tree,
            .metadata_owners = metadata_owners,
            .host = host,
            .action_handler = action_handler,
            .action_userdata = action_userdata,
            .view = view,
            .nodes = .empty,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        return context;
    }

    /// Consumes an actual C handle into a context with its own metadata owners.
    fn initOwned(
        allocator: Allocator,
        owned: *CTreeUpdate,
        is_view_focused: bool,
        host: Host,
        action_handler: ActionHandler,
        action_userdata: ?*anyopaque,
        view: ?*anyopaque,
    ) (TreeUpdateError || Allocator.Error)!*Context {
        var owners: c_tree_update.LiveMetadataOwners = .{};
        const update = owners.consume(allocator, owned, null) catch |err| {
            owners.deinit();
            return err;
        };
        return init(
            allocator,
            update,
            owners,
            is_view_focused,
            host,
            action_handler,
            action_userdata,
            view,
        );
    }

    /// Adds one reference.
    fn retain(self: *Context) void {
        self.refs += 1;
    }

    /// Drops the tree and metadata after the final adapter or queue reference.
    fn release(self: *Context) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        const allocator = self.allocator;
        self.close();
        var nodes = self.nodes;
        nodes.deinit(allocator);
        var arena = self.arena;
        arena.deinit();
        self.tree.deinit();
        self.metadata_owners.deinit();
        allocator.destroy(self);
    }

    /// Posts destruction while the Host is still live, exactly once.
    fn close(self: *Context) void {
        if (self.closed) return;
        self.closed = true;
        self.postDestroyedForEveryNode();
    }

    /// Posts one destruction per live platform node, upstream `context.rs:91`.
    ///
    /// The walk is over `nodes`, whose length is the number of platform nodes
    /// this context created, and the map does not change while it is walked.
    fn postDestroyedForEveryNode(self: *Context) void {
        const name = events_mod.notificationFor(.node_destroyed) orelse return;
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            self.host.post(self.host.ptr, entry.value_ptr.*, name);
        }
    }

    /// A list of platform nodes, standing in for the `NSArray` upstream returns
    /// from `view_children`.
    ///
    /// It is allocated in the context's arena and holds a copy of `nodes`, so
    /// the pointer a caller holds stays valid and the contents stay stable: the
    /// arena is append-only for the life of the context, so a later `create`
    /// never moves what this list points at.
    fn newNodeList(self: *Context, allocator: Allocator, nodes: []const *PlatformNode) !*NodeList {
        const arena = self.arena.allocator();
        const list = try arena.create(NodeList);
        const owned = try arena.dupe(*PlatformNode, nodes);
        list.* = .{ .nodes = owned };
        _ = allocator;
        return list;
    }

    /// The platform node for `id`, creating it if the client has not asked for
    /// it, upstream `get_or_create_platform_node`.
    ///
    /// **Returns.** `error.OutOfMemory` from the arena and the map.
    fn getOrCreatePlatformNode(self: *Context, id: FullNodeId) !*PlatformNode {
        if (self.nodes.get(id)) |existing| return existing;
        const node = try self.arena.allocator().create(PlatformNode);
        node.* = .{ .id = id };
        try self.nodes.put(self.allocator, id, node);
        return node;
    }

    /// The platform node for `id`, or `null` when the context has none.
    ///
    /// This is the `remove_platform_node` of `AK/macos/src/event.rs:57-64`:
    /// a destruction removes the node and reports whether it removed one.
    fn removePlatformNode(self: *Context, id: FullNodeId) ?*PlatformNode {
        const removed = self.nodes.fetchRemove(id) orelse return null;
        return removed.value;
    }

    /// Converts a borrowed producer request into an owned raw C request.
    /// The callback releases payload and outer box with the configured allocator.
    fn doAction(self: *Context, request: schema.ActionRequest) DoActionError!void {
        const built = boundary.createActionRequest(allocation.allocator(), request) catch |err| {
            allocation.failWithError(err);
            return err;
        };
        action_request.callActionHandler(self.action_handler, built, self.action_userdata);
    }
};

/// The events one update produced, and the context they are raised against.
///
/// Upstream `QueuedEvents`, at `AK/macos/src/event.rs:110-131`. It is a handle,
/// not a value: the caller owns a `*MacosQueuedEvents` and must pass it to
/// `macosQueuedEventsRaise`, which raises the events and releases the handle.
pub const MacosQueuedEvents = struct {
    /// Captured at construction, including for the stable outer box.
    allocator: Allocator,
    payload: union(enum) {
        pure: struct {
            context: *Context,
            events: ArrayList(events_mod.QueuedEvent),
        },
        native: *native.NativeNotifications,
    },

    /// Raises every event and releases the handle.
    ///
    /// Raising posts each event against its node or its window and then releases
    /// the list and the context reference. It is the only release for the
    /// handle: a second call is a use-after-free and a `null` pointer is a
    /// contract violation, both as `include/zaccesskit.h:6048` states.
    ///
    /// Exact checked native posting failures are latched in the C diagnostic.
    /// WrongThread refuses before consuming; admitted success or failure
    /// spends the payload and box.
    pub fn raiseAndRelease(self: *MacosQueuedEvents) void {
        if (self.payload == .native and !foundation.isMainThread()) {
            allocation.failWithError(error.WrongThread);
            return;
        }
        self.raise();
        self.destroy();
    }

    /// Raises every event, leaving the handle valid.
    ///
    /// It is separated from `raiseAndRelease` so a test can observe the same
    /// posting without spending the handle. A caller on the C seam uses
    /// `raiseAndRelease`, which is the only release.
    pub fn raise(self: *MacosQueuedEvents) void {
        const pure = switch (self.payload) {
            .native => |notifications| {
                notifications.raise() catch |err| allocation.failWithError(err);
                return;
            },
            .pure => |*value| value,
        };
        if (pure.context.closed) return;
        for (pure.events.items) |*event| {
            switch (event.*) {
                .generic => |generic| {
                    const node = pure.context.getOrCreatePlatformNode(generic.node_id) catch |err| {
                        allocation.failWithError(err);
                        continue;
                    };
                    pure.context.host.post(
                        pure.context.host.ptr,
                        node,
                        generic.notification,
                    );
                },
                .node_destroyed => |id| {
                    // A node with no platform node was never shown to a client,
                    // so there is nothing to tell it about.
                    const node = pure.context.removePlatformNode(id) orelse continue;
                    const name = events_mod.notificationFor(.node_destroyed) orelse continue;
                    pure.context.host.post(pure.context.host.ptr, node, name);
                },
                .announcement => |announcement| {
                    const view = pure.context.host.view_of(pure.context.host.ptr) orelse continue;
                    const window = pure.context.host.window_of(
                        pure.context.host.ptr,
                        view,
                    ) orelse continue;
                    const name = literals_mod.announcement_requested_notification.value;
                    pure.context.host.post_with_user_info(
                        pure.context.host.ptr,
                        window,
                        name,
                        announcement.text,
                        @intFromEnum(announcement.priority),
                    );
                },
            }
        }
    }

    /// Releases the list and the context reference, without raising.
    ///
    /// It exists so that a caller which never raises still releases what it
    /// owns. A caller on the C seam does not have it: the header gives one
    /// release and `macosQueuedEventsRaise` is it.
    pub fn destroy(self: *MacosQueuedEvents) void {
        const allocator = self.allocator;
        switch (self.payload) {
            .pure => |*pure| {
                events_mod.releaseEvents(allocator, &pure.events);
                pure.context.release();
            },
            .native => |notifications| notifications.deinit(),
        }
        allocator.destroy(self);
    }
};

/// The state an adapter is in, upstream `AK/macos/src/adapter.rs:26-38`.
///
/// Three pure tree phases, or an independently owned genuine native bridge.
const State = union(enum) {
    /// No tree has been asked for. Upstream `State::Inactive`.
    inactive: Inactive,
    /// The activation handler answered `null`, so a one-node placeholder window
    /// stands in until a tree update arrives. Upstream `State::Placeholder`.
    placeholder: Placeholder,
    /// A tree is active. Upstream `State::Active`.
    active: *Context,
    /// Genuine native provider; never carries a fake Host.
    native: *c_native.Bridge,

    /// The part of `inactive` and `placeholder` that both carry.
    const Common = struct {
        /// Whether the view holds focus, kept here so a focus update before the
        /// first tree still reaches the tree when it arrives.
        is_view_focused: bool,
        /// The handler an action request reaches.
        action_handler: ActionHandler,
        /// The callee's context for `action_handler`.
        action_userdata: ?*anyopaque,
    };

    /// The fields of `State::Inactive`.
    const Inactive = struct {
        /// The view, which the caller keeps valid until the adapter is freed.
        view: ?*anyopaque,
        /// The three fields both non-active states carry.
        common: Common,
    };

    /// The fields of `State::Placeholder`.
    const Placeholder = struct {
        /// The placeholder context, which the queued events of the first real
        /// update are raised against.
        context: *Context,
        /// The three fields both non-active states carry.
        common: Common,
    };
};

/// A macOS adapter over `view`.
///
/// Upstream `Adapter`, at `AK/macos/src/adapter.rs:76-295`. The caller owns it
/// and releases it with `macosAdapterFree`, exactly once. This type takes no
/// activation handler because AppKit asks for the tree itself; the three
/// tree-facing calls take one per call instead.
pub const MacosAdapter = struct {
    /// The allocator the state was built with.
    allocator: Allocator,
    /// Only pure adapters have a borrowed Host.
    host: ?Host,
    /// Pure tree state or a genuine native owner.
    state: State,

    /// A recorder owned by an explicitly pure test helper, never a C constructor.
    owned_host: ?*RecordingHost = null,

    /// Asks `factory` for a tree and hands it to the adapter.
    ///
    /// Upstream `Adapter::update_if_active`, at `adapter.rs:110-146`. **Returns**
    /// the events the answer produced, or `null` when the adapter is not active.
    /// The caller owns a non-null result and must pass it to
    /// `macosQueuedEventsRaise`.
    ///
    /// Native rejection and postcommit notification failures latch the exact
    /// diagnostic. A queue-box failure drops notifications, never the committed
    /// native baseline. Pure fixtures retain their source-only optional result.
    pub fn updateIfActive(
        self: *MacosAdapter,
        factory: TreeUpdateFactory,
        factory_userdata: ?*anyopaque,
    ) ?*MacosQueuedEvents {
        switch (self.state) {
            .native => |bridge| return self.nativeQueuedEvents(
                bridge.update(factory, factory_userdata),
            ),
            .inactive => return null,
            .placeholder => |*placeholder| {
                const update = treeUpdateFromFactory(factory, factory_userdata);
                const context = Context.initOwned(
                    self.allocator,
                    update,
                    placeholder.common.is_view_focused,
                    self.host.?,
                    placeholder.common.action_handler,
                    placeholder.common.action_userdata,
                    placeholder.context.view,
                ) catch return null;
                var list: ArrayList(events_mod.QueuedEvent) = .empty;
                if (context.tree.stateOf().focus()) |focused| {
                    const id = focused.id();
                    list.append(self.allocator, .{
                        .generic = .{
                            .node_id = id,
                            .notification = events_mod.notificationFor(.focus_moved) orelse {
                                list.deinit(self.allocator);
                                context.release();
                                return null;
                            },
                        },
                    }) catch {
                        list.deinit(self.allocator);
                        context.release();
                        return null;
                    };
                }
                placeholder.context.close();
                placeholder.context.release();
                self.state = .{ .active = context };
                return self.newQueuedEvents(context, list);
            },
            .active => |context| {
                var generator = events_mod.EventGenerator.init(self.allocator);
                defer generator.deinit();
                const handler = events_mod.slotsOf(&generator);
                const owned = treeUpdateFromFactory(factory, factory_userdata);
                const update = context.metadata_owners.consume(
                    self.allocator,
                    owned,
                    &context.tree,
                ) catch return null;
                defer context.metadata_owners.reap(&context.tree);
                context.tree.updateAndProcessChanges(update, &handler) catch return null;
                // A slot that failed leaves a partial list, so the handle is
                // withheld rather than raised short.
                if (generator.failure != null) return null;
                return self.newQueuedEvents(context, generator.takeEvents());
            },
        }
    }

    /// Records whether `view` holds focus, and returns the events it produced.
    ///
    /// Upstream `Adapter::update_view_focus_state`, at `adapter.rs:152-175`.
    /// **Returns** `null` when the adapter is not active, which is upstream's
    /// answer for both non-active states, and when the handle cannot be
    /// allocated. The tree keeps the focus it was given either way.
    pub fn updateViewFocusState(
        self: *MacosAdapter,
        is_focused: bool,
    ) ?*MacosQueuedEvents {
        switch (self.state) {
            .native => |bridge| return self.nativeQueuedEvents(bridge.updateFocus(is_focused)),
            .inactive => |*inactive| {
                inactive.common.is_view_focused = is_focused;
                return null;
            },
            .placeholder => |*placeholder| {
                placeholder.common.is_view_focused = is_focused;
                return null;
            },
            .active => |context| {
                var generator = events_mod.EventGenerator.init(self.allocator);
                defer generator.deinit();
                const handler = events_mod.slotsOf(&generator);
                context.tree.updateHostFocusStateAndProcessChanges(is_focused, &handler) catch {
                    return null;
                };
                if (generator.failure != null) return null;
                return self.newQueuedEvents(context, generator.takeEvents());
            },
        }
    }

    /// Returns the context, asking `activation_handler` for a tree if the
    /// adapter has none. Upstream `get_or_init_context`, at `adapter.rs:180-233`.
    ///
    /// **Returns.** `null` only when the activation handler answered `null` and
    /// the placeholder tree could not be built. A `null` answer from an
    /// activation handler is ordinary; it is the answer that installs the
    /// placeholder.
    fn getOrInitContext(
        self: *MacosAdapter,
        activation_handler: ActivationHandler,
        activation_userdata: ?*anyopaque,
    ) ?*Context {
        switch (self.state) {
            .native => return null,
            .inactive => |inactive| {
                const boxed = activation_handler(activation_userdata);
                if (boxed) |initial| {
                    const context = Context.initOwned(
                        self.allocator,
                        initial,
                        inactive.common.is_view_focused,
                        self.host.?,
                        inactive.common.action_handler,
                        inactive.common.action_userdata,
                        inactive.view,
                    ) catch return null;
                    self.state = .{ .active = context };
                    return context;
                }
                // No tree: stand in a one-node placeholder window, upstream
                // `adapter.rs:236-259`.
                // No `deinit` here: `Context.init` transfers the update to
                // `Tree.init`, which consumes its node list, so releasing it
                // again would free nodes the tree now owns.
                const placeholder = blankPlaceholderUpdate(self.allocator) catch return null;
                const context = Context.init(
                    self.allocator,
                    placeholder,
                    .{},
                    false,
                    self.host.?,
                    inactive.common.action_handler,
                    inactive.common.action_userdata,
                    inactive.view,
                ) catch return null;
                self.state = .{ .placeholder = .{
                    .context = context,
                    .common = inactive.common,
                } };
                return context;
            },
            .placeholder => |placeholder| return placeholder.context,
            .active => |context| return context,
        }
    }

    /// The platform objects that name the view's children, upstream
    /// `view_children`, at `adapter.rs:235-262`.
    ///
    /// **Returns.** An opaque pointer to a `NodeList`, or `null` when the adapter
    /// has no tree or could not build the list. The pointer is in the context's
    /// arena and stays valid until the adapter is freed. The caller does not own
    /// it and must not release it.
    pub fn viewChildren(
        self: *MacosAdapter,
        activation_handler: ActivationHandler,
        activation_userdata: ?*anyopaque,
    ) ?*anyopaque {
        if (self.state == .native) {
            return self.state.native.children(activation_handler, activation_userdata) catch |err| {
                allocation.failWithError(err);
                return null;
            };
        }
        const context = self.getOrInitContext(activation_handler, activation_userdata) orelse
            return null;
        const state = context.tree.stateOf();
        const root = state.root();

        // An included root stands for the view itself, so the list is the root
        // alone. An excluded root is replaced by its filtered children. This is
        // upstream `adapter.rs:242-259`.
        if ((consumer.filter.commonFilter(root) catch return null) == .include) {
            const node = context.getOrCreatePlatformNode(root.id()) catch return null;
            return context.newNodeList(self.allocator, &.{node}) catch null;
        }
        var list: ArrayList(*PlatformNode) = .empty;
        // `defer`, not `errdefer`. This function returns `?*anyopaque`, never
        // an error, so an `errdefer` here has no error return to fire on and
        // releases nothing on the three `catch return null` arms below. Those
        // arms run after at least one `append`, so a `defer` is what makes the
        // list release on every path out of the loop.
        defer list.deinit(self.allocator);
        var children = consumer.node_ref.hierarchy.filteredChildren(root, root_filter) catch
            return null;
        while (children.next() catch return null) |child| {
            const node = context.getOrCreatePlatformNode(child.id()) catch return null;
            list.append(self.allocator, node) catch return null;
        }
        return context.newNodeList(self.allocator, list.items) catch null;
    }

    /// The platform object that holds focus, upstream `focus`, at `adapter.rs:264-275`.
    ///
    /// **Returns.** An opaque pointer the caller does not own, or `null` when
    /// nothing holds focus.
    pub fn focus(
        self: *MacosAdapter,
        activation_handler: ActivationHandler,
        activation_userdata: ?*anyopaque,
    ) ?*anyopaque {
        if (self.state == .native) {
            return self.state.native.focus(activation_handler, activation_userdata) catch |err| {
                allocation.failWithError(err);
                return null;
            };
        }
        const context = self.getOrInitContext(activation_handler, activation_userdata) orelse
            return null;
        const state = context.tree.stateOf();
        const focused = state.focus() orelse return null;
        // A window cannot hold focus in this protocol, upstream `node.rs:298-300`.
        if (consumer.node_ref.properties.role(focused) == .window) return null;
        const node = context.getOrCreatePlatformNode(focused.id()) catch return null;
        return node;
    }

    /// The platform object at `(x, y)`, upstream `hit_test`, at `adapter.rs:283-295`.
    ///
    /// **Returns.** An opaque pointer the caller does not own, or `null` when
    /// the view is gone. Upstream falls back to the root when no node is at the
    /// point, and so does this call.
    pub fn hitTest(
        self: *MacosAdapter,
        x: f64,
        y: f64,
        activation_handler: ActivationHandler,
        activation_userdata: ?*anyopaque,
    ) ?*anyopaque {
        if (self.state == .native) {
            return self.state.native.hitTest(
                .{ .x = x, .y = y },
                activation_handler,
                activation_userdata,
            ) catch |err| {
                allocation.failWithError(err);
                return null;
            };
        }
        const view = self.host.?.view_of(self.host.?.ptr) orelse return null;
        _ = view;
        const context = self.getOrInitContext(activation_handler, activation_userdata) orelse
            return null;
        const state = context.tree.stateOf();
        const root = state.root();

        // The platform is asked first, because only it knows the view's own
        // coordinate system. When it has nothing, the tree is asked, and the
        // root is the fallback.
        const point: schema.Point = .{ .x = x, .y = y };
        if (self.host.?.hit_test(self.host.?.ptr, point.x, point.y)) |hit| return hit;

        const found = consumer.node_ref.geometry.nodeAtPoint(
            self.allocator,
            root,
            point,
            root_filter,
        ) catch null;
        const target = found orelse root;
        const node = context.getOrCreatePlatformNode(target.id()) catch return null;
        return node;
    }

    /// Builds a queued-events handle over `context` and `events`.
    ///
    /// The handle takes one context reference, so it stays valid after
    /// `macosAdapterFree`.
    ///
    /// **Returns.** `null` when the handle cannot be allocated. That is the
    /// only answer the header allows: this call sits behind a return type of
    /// `?*MacosQueuedEvents`, so a non-optional handle answered with
    /// `undefined` reaches the C caller as a non-null pointer to nothing, and
    /// `macosQueuedEventsRaise` would read it. On this path `events` is
    /// released and the context reference is **not** taken, so the adapter
    /// keeps exactly the references it held and the caller owns nothing.
    fn newQueuedEvents(
        self: *MacosAdapter,
        context: *Context,
        list: ArrayList(events_mod.QueuedEvent),
    ) ?*MacosQueuedEvents {
        const handle = self.allocator.create(MacosQueuedEvents) catch |err| {
            var owned = list;
            events_mod.releaseEvents(self.allocator, &owned);
            allocation.failWithError(err);
            return null;
        };
        context.retain();
        handle.* = .{
            .allocator = self.allocator,
            .payload = .{ .pure = .{ .context = context, .events = list } },
        };
        return handle;
    }

    /// Publication has already committed before the C queue box is allocated.
    fn nativeQueuedEvents(
        self: *MacosAdapter,
        outcome: native.PreparedUpdateOutcome,
    ) ?*MacosQueuedEvents {
        switch (outcome) {
            .inactive => return null,
            .rejected => |err| {
                allocation.failWithError(err);
                return null;
            },
            .committed => |committed| {
                if (committed.notification_error) |err| allocation.failWithError(err);
                const notifications = committed.events orelse return null;
                const handle = self.allocator.create(MacosQueuedEvents) catch |err| {
                    notifications.deinit();
                    allocation.failWithError(err);
                    return null;
                };
                handle.* = .{
                    .allocator = self.allocator,
                    .payload = .{ .native = notifications },
                };
                return handle;
            },
        }
    }
};

/// A macOS adapter that installs the four accesskit selectors on the host view.
///
/// Upstream `subclass.rs:160-200`. It holds a `MacosAdapter` and the window it
/// was built for, and it forwards the four tree-facing calls.
pub const MacosSubclassingAdapter = struct {
    /// The allocator the adapter was built with.
    allocator: Allocator,
    /// Only pure adapters have a Host.
    host: ?Host,
    /// The adapter that does the work.
    adapter: MacosAdapter,
    /// The window this adapter was built for, or `null` when it was built for a
    /// view. It is what the four installed selectors are reached through.
    window: ?*anyopaque,
};

/// The filter the tree-facing calls read, upstream
/// `AK/macos/src/filters.rs:54-92`.
const root_filter: consumer.filter.FilterFn = .{ .context = null, .filter = rootFilterThunk };

/// Adapts `consumer.filter.commonFilter` to the `FilterFn` shape.
///
/// `context` is `null` for this filter because `commonFilter` reads only the
/// node. The walk it performs is bounded by `commonFilterStepBound` of the node
/// count, which the consumer layer derives.
const QueryError = consumer.tree_state.QueryError;
const FilterResult = consumer.filter.FilterResult;

fn rootFilterThunk(context: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    _ = context;
    return consumer.filter.commonFilter(node);
}

/// The root identifier the placeholder tree uses, upstream
/// `AK/macos/src/adapter.rs:24`.
const placeholder_root_id: schema.NodeId = .{ .value = 0 };

/// The one-node placeholder tree, upstream `AK/macos/src/adapter.rs:236-246`.
///
/// **Returns.** `error.OutOfMemory` from `pushNode`. The update is transferred
/// to the call and released by `Context.init`, so the caller must not release it.
fn blankPlaceholderUpdate(allocator: Allocator) !schema.TreeUpdate {
    var update: schema.TreeUpdate = .{};
    update.tree = .{ .root = placeholder_root_id, .toolkit_name = null, .toolkit_version = null };
    update.focus = placeholder_root_id;
    try update.pushNode(allocator, placeholder_root_id, schema.Node.init(allocator, .window));
    return update;
}

/// The tree `factory` built, or a trap.
///
/// **The trap is the contract, not an assertion.**
/// `boundary.TreeUpdateFactory` states that the factory must not return `null`,
/// because it transfers ownership of the tree it builds and a `null` return
/// leaves the library holding nothing. Upstream aborts there, and this call
/// traps rather than printing first: the process stops rather than the adapter
/// continuing with no tree, and the house rules forbid a diagnostic here. **A
/// `null` return from an activation handler is a different thing** and is an
/// ordinary answer that installs the placeholder; `getOrInitContext` treats it
/// that way.
fn treeUpdateFromFactory(
    factory: TreeUpdateFactory,
    factory_userdata: ?*anyopaque,
) *CTreeUpdate {
    return factory(factory_userdata) orelse @trap();
}

/// One posted notification, as `RecordingHost` sees it.
pub const PostedNotification = struct {
    /// The node the notification was posted against, or `null` for a window.
    node: ?*anyopaque,
    /// The window the notification was posted against, or `null` for a node.
    window: ?*anyopaque,
    /// The notification name.
    notification: [:0]const u8,
    /// The announcement text, for the one notification that carries one.
    text: []const u8 = "",
    /// The announcement priority, for the same notification.
    priority: i32 = 0,
};

/// A `Host` that records every call instead of reaching AppKit.
///
/// It is a complete implementation of the interface, not a stub: every call is
/// accepted, applied and left visible, which is what makes the adapter's
/// protocol testable on a host with no macOS. **What it cannot do is reach an
/// assistive technology**, because there is none to reach.
///
/// The caller owns the value and must keep it alive for as long as any adapter
/// uses it. `posts` grows with the allocator `init` is given, so a test
/// allocator proves every post was released.
pub const RecordingHost = struct {
    /// The allocator that grew `posts`.
    allocator: Allocator,
    /// Every notification the adapter posted, in order.
    posts: ArrayList(PostedNotification) = .empty,
    /// The view `view_of` answers, and `null` for none.
    view: ?*anyopaque = null,
    /// What `window_of` answers for any view, and `null` for none.
    window: ?*anyopaque = null,
    /// What `hit_test` answers for any point, and `null` for none.
    hit: ?*anyopaque = null,

    /// Set when a post could not be recorded because the allocator ran out.
    ///
    /// The two post paths are reached through the `Host` vtable, which returns
    /// nothing, so there is no error to hand back. Recording the failure here
    /// is what keeps it from being a silent drop: a test that asserts a count
    /// fails on the flag instead of passing one notification short.
    failed: bool = false,

    /// An empty recorder over `allocator`.
    pub fn init(allocator: Allocator) RecordingHost {
        return .{ .allocator = allocator };
    }

    /// Releases the recorded posts.
    pub fn deinit(self: *RecordingHost) void {
        var posts = self.posts;
        posts.deinit(self.allocator);
        // SAFETY: `posts.deinit` above released the only allocation this
        // recorder owned; `allocator` is a borrowed handle and is not released.
        // A `Host` vtable pointer handed out by `host()` still points here
        // after the deinit, so the poison is what makes a post that arrives
        // late trap rather than write into freed memory.
        self.* = undefined;
    }

    /// How many notifications the recorder has seen.
    pub fn count(self: *const RecordingHost) usize {
        return self.posts.items.len;
    }

    /// The `Host` this recorder is reached through.
    pub fn host(self: *RecordingHost) Host {
        return .{
            .ptr = self,
            .post = post,
            .post_with_user_info = postWithUserInfo,
            .view_of = viewOf,
            .window_of = windowOf,
            .hit_test = hitTest,
        };
    }

    fn post(context: ?*anyopaque, node: ?*anyopaque, notification: [:0]const u8) void {
        const self: *RecordingHost = @ptrCast(@alignCast(context orelse return));
        self.posts.append(self.allocator, .{
            .node = node,
            .window = null,
            .notification = notification,
        }) catch |err| self.record(err);
    }

    fn postWithUserInfo(
        context: ?*anyopaque,
        window: ?*anyopaque,
        notification: [:0]const u8,
        text: []const u8,
        priority: i32,
    ) void {
        const self: *RecordingHost = @ptrCast(@alignCast(context orelse return));
        self.posts.append(self.allocator, .{
            .node = null,
            .window = window,
            .notification = notification,
            .text = text,
            .priority = priority,
        }) catch |err| self.record(err);
    }

    /// Records that a post could not be recorded.
    ///
    /// `ArrayList.append` has `error.OutOfMemory` as its only tag, so the flag
    /// says everything the payload could. The switch is written out anyway:
    /// it is the compiler-checked statement of that, so a second tag reaching a
    /// post becomes a build failure here rather than a failure the recorder
    /// files under the allocator.
    fn record(self: *RecordingHost, err: std.mem.Allocator.Error) void {
        switch (err) {
            error.OutOfMemory => self.failed = true,
        }
    }

    fn viewOf(context: ?*anyopaque) ?*anyopaque {
        const self: *RecordingHost = @ptrCast(@alignCast(context orelse return null));
        return self.view;
    }

    fn windowOf(context: ?*anyopaque, view: ?*anyopaque) ?*anyopaque {
        _ = view;
        const self: *RecordingHost = @ptrCast(@alignCast(context orelse return null));
        return self.window;
    }

    fn hitTest(context: ?*anyopaque, x: f64, y: f64) ?*anyopaque {
        _ = x;
        _ = y;
        const self: *RecordingHost = @ptrCast(@alignCast(context orelse return null));
        return self.hit;
    }
};

// --- the sixteen C entry points ---------------------------------------------

/// Raises the queued events on the platform and releases the handle.
///
/// `accesskit_macos_queued_events_raise`, `include/zaccesskit.h:6048`, upstream
/// `src/lib.rs:2803`.
///
/// **This call is the only way to release the handle.** A second call is a
/// use-after-free and `events` must not be `null`.
pub fn macosQueuedEventsRaise(queued: *MacosQueuedEvents) void {
    if (!requireNativePlatform()) return;
    if (queued.payload != .native) {
        allocation.failWithError(error.NativeUnsupported);
        return;
    }
    queued.raiseAndRelease();
}

/// Returns a macOS adapter for `view`, or `null` when the allocation failed.
///
/// `accesskit_macos_adapter_new`, `include/zaccesskit.h:6059`, upstream
/// `src/lib.rs:2813`.
///
/// `view` and `action_handler_userdata` must stay valid until the adapter is
/// released. This adapter takes no activation or deactivation handler: AppKit
/// asks for the tree itself, so the three tree-facing calls take a handler per
/// call instead. The caller owns the adapter and releases it with
/// `accesskit_macos_adapter_free`.
pub fn macosAdapterNew(
    view: ?*anyopaque,
    is_view_focused: bool,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
) ?*MacosAdapter {
    if (!requireNativePlatform()) return null;
    const target = view orelse {
        allocation.failWithError(error.InvalidView);
        return null;
    };
    const gpa = heap();
    const adapter = gpa.create(MacosAdapter) catch |err| {
        allocation.failWithError(err);
        return null;
    };
    const bridge = c_native.Bridge.create(
        gpa,
        .{ .view = target },
        is_view_focused,
        false,
        null,
        null,
        action_handler,
        action_handler_userdata,
    ) catch |err| {
        gpa.destroy(adapter);
        allocation.failWithError(err);
        return null;
    };
    adapter.* = .{ .allocator = gpa, .host = null, .state = .{ .native = bridge } };
    return adapter;
}

/// Returns a macOS adapter for `view` over `host`, or `null` when the allocation
/// failed.
///
/// Source-only Host constructor. It does not attach an AppKit provider.
/// `host.ptr` must stay valid until the adapter closes.
pub fn newAdapter(
    view: ?*anyopaque,
    is_view_focused: bool,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
    host: Host,
) ?*MacosAdapter {
    const adapter = heap().create(MacosAdapter) catch return null;
    adapter.* = .{
        .allocator = heap(),
        .host = host,
        .state = .{ .inactive = .{
            .view = view,
            .common = .{
                .is_view_focused = is_view_focused,
                .action_handler = action_handler,
                .action_userdata = action_handler_userdata,
            },
        } },
    };
    return adapter;
}

/// Releases the adapter and every tree it holds, exactly once.
///
/// `accesskit_macos_adapter_free`, `include/zaccesskit.h:6068`, upstream
/// `src/lib.rs:2820`.
///
/// A queued-events handle the caller still holds stays valid: it holds its own
/// context reference. `adapter` must not be `null`.
pub fn macosAdapterFree(adapter: *MacosAdapter) void {
    if (!requireNativeAdapter(adapter)) return;
    const gpa = adapter.allocator;
    releaseState(adapter) catch |err| {
        allocation.failWithError(err);
        if (err != error.WrongThread) gpa.destroy(adapter);
        return;
    };
    gpa.destroy(adapter);
}

/// Releases whatever state `adapter` holds, without releasing `adapter` itself.
///
/// `MacosSubclassingAdapter` embeds a `MacosAdapter` by value, so its release
/// calls this rather than `macosAdapterFree`: destroying the embedded struct
/// would free memory that belongs to the outer allocation.
fn releaseState(self: *MacosAdapter) NativeError!void {
    var close_error: ?NativeError = null;
    switch (self.state) {
        .native => |bridge| bridge.closeAndDestroy() catch |err| {
            // Only thread refusal leaves the bridge open for a main-thread retry.
            // A postclose notification error spends the bridge, not the baseline.
            if (err == error.WrongThread) return err;
            close_error = err;
        },
        .inactive => {},
        .placeholder => |placeholder| {
            placeholder.context.close();
            placeholder.context.release();
        },
        .active => |context| {
            context.close();
            context.release();
        },
    }
    if (self.owned_host) |recorder| {
        recorder.deinit();
        self.allocator.destroy(recorder);
    }
    self.* = undefined;
    if (close_error) |err| return err;
}

/// Asks `update_factory` for a tree and hands it to the adapter.
///
/// `accesskit_macos_adapter_update_if_active`, `include/zaccesskit.h:6080`,
/// upstream `src/lib.rs:2828`.
///
/// **Returns** the events the answer produced, or `null` when the adapter is not
/// active. The caller owns a non-null result and must pass it to
/// `accesskit_macos_queued_events_raise`.
pub fn macosAdapterUpdateIfActive(
    adapter: *MacosAdapter,
    update_factory: TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) ?*MacosQueuedEvents {
    if (!requireNativeAdapter(adapter)) return null;
    return adapter.updateIfActive(update_factory, update_factory_userdata);
}

/// Tells the adapter whether `view` holds focus, and returns the events the
/// answer produced.
///
/// `accesskit_macos_adapter_update_view_focus_state`,
/// `include/zaccesskit.h:6093`, upstream `src/lib.rs:2842`.
///
/// **Returns** `null` when the adapter is not active.
pub fn macosAdapterUpdateViewFocusState(
    adapter: *MacosAdapter,
    is_focused: bool,
) ?*MacosQueuedEvents {
    if (!requireNativeAdapter(adapter)) return null;
    return adapter.updateViewFocusState(is_focused);
}

/// Returns the platform object that names the view's children, or `null` when
/// there is none.
///
/// `accesskit_macos_adapter_view_children`, `include/zaccesskit.h:6107`, upstream
/// `src/lib.rs:2851`.
///
/// **Ownership does not transfer.** The activation handler is supplied on this
/// call and dropped when it returns.
pub fn macosAdapterViewChildren(
    adapter: *MacosAdapter,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
) ?*anyopaque {
    if (!requireNativeAdapter(adapter)) return null;
    return adapter.viewChildren(activation_handler, activation_handler_userdata);
}

/// Returns the platform object that holds focus, or `null` when nothing holds it.
///
/// `accesskit_macos_adapter_focus`, `include/zaccesskit.h:6121`, upstream
/// `src/lib.rs:2862`.
///
/// **Ownership does not transfer.** The activation handler is supplied on this
/// call and dropped when it returns.
pub fn macosAdapterFocus(
    adapter: *MacosAdapter,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
) ?*anyopaque {
    if (!requireNativeAdapter(adapter)) return null;
    return adapter.focus(activation_handler, activation_handler_userdata);
}

/// Returns the platform object at `(x, y)`, or `null` when nothing is there.
///
/// `accesskit_macos_adapter_hit_test`, `include/zaccesskit.h:6135`, upstream
/// `src/lib.rs:2873`.
///
/// **Ownership does not transfer.** The activation handler is supplied on this
/// call and dropped when it returns.
pub fn macosAdapterHitTest(
    adapter: *MacosAdapter,
    x: f64,
    y: f64,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
) ?*anyopaque {
    if (!requireNativeAdapter(adapter)) return null;
    return adapter.hitTest(x, y, activation_handler, activation_handler_userdata);
}

/// Returns a text rendering of the adapter, or `null` when the text could not be
/// built.
///
/// `accesskit_macos_adapter_debug`, `include/zaccesskit.h:6149`, upstream
/// `src/lib.rs:2883`.
///
/// **Release the result with `accesskit_string_free`, once.** The text borrows
/// nothing from the adapter once the call returns, so the adapter may be freed
/// first.
pub fn macosAdapterDebug(adapter: *const MacosAdapter) ?[*:0]u8 {
    if (!requireNativeAdapter(adapter)) return null;
    return renderDebug(adapter, heap()) catch |err| {
        allocation.failWithError(err);
        return null;
    };
}

/// Returns a subclassing adapter for `view`, or `null` when the allocation
/// failed.
///
/// `accesskit_macos_subclassing_adapter_new`, `include/zaccesskit.h:6160`,
/// upstream `src/lib.rs:2894`.
///
/// `view` and every handler pointer must stay valid until the adapter is
/// released. The caller owns the adapter and releases it with
/// `accesskit_macos_subclassing_adapter_free`.
pub fn macosSubclassingAdapterNew(
    view: ?*anyopaque,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
) ?*MacosSubclassingAdapter {
    if (!requireNativePlatform()) return null;
    const target = view orelse {
        allocation.failWithError(error.InvalidView);
        return null;
    };
    return newNativeSubclassingAdapter(
        .{ .view = target },
        activation_handler,
        activation_handler_userdata,
        action_handler,
        action_handler_userdata,
    );
}

/// Returns a subclassing adapter for `window`, or `null` when the allocation
/// failed.
///
/// `accesskit_macos_subclassing_adapter_for_window`, `include/zaccesskit.h:6174`,
/// upstream `src/lib.rs:2913`.
///
/// The conditions are the ones `accesskit_macos_subclassing_adapter_new` states.
pub fn macosSubclassingAdapterForWindow(
    window: ?*anyopaque,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
) ?*MacosSubclassingAdapter {
    if (!requireNativePlatform()) return null;
    const target = window orelse {
        allocation.failWithError(error.InvalidView);
        return null;
    };
    return newNativeSubclassingAdapter(
        .{ .window = target },
        activation_handler,
        activation_handler_userdata,
        action_handler,
        action_handler_userdata,
    );
}

/// Returns a subclassing adapter for `view` over `host`, or `null` when the
/// allocation failed.
///
/// Source-only Host constructor; no Objective-C subclass is installed.
pub fn newSubclassingAdapter(
    view: ?*anyopaque,
    window: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
    host: Host,
) ?*MacosSubclassingAdapter {
    const adapter = heap().create(MacosSubclassingAdapter) catch return null;
    const inner = newAdapter(
        view,
        false,
        action_handler,
        action_handler_userdata,
        host,
    ) orelse {
        heap().destroy(adapter);
        return null;
    };
    adapter.* = .{
        .allocator = heap(),
        .host = host,
        .adapter = inner.*,
        .window = window,
    };
    heap().destroy(inner);
    return adapter;
}

/// Releases the adapter and every tree it holds, exactly once.
///
/// `accesskit_macos_subclassing_adapter_free`, `include/zaccesskit.h:6186`,
/// upstream `src/lib.rs:2921`.
///
/// The adapter must not be `null`.
pub fn macosSubclassingAdapterFree(adapter: *MacosSubclassingAdapter) void {
    if (!requireNativePlatform()) return;
    if (!requireNativeAdapter(&adapter.adapter)) return;
    const gpa = adapter.allocator;
    releaseState(&adapter.adapter) catch |err| {
        allocation.failWithError(err);
        if (err != error.WrongThread) gpa.destroy(adapter);
        return;
    };
    gpa.destroy(adapter);
}

/// Asks `update_factory` for a tree and hands it to the adapter.
///
/// `accesskit_macos_subclassing_adapter_update_if_active`,
/// `include/zaccesskit.h:6199`, upstream `src/lib.rs:2931`.
///
/// **Returns** the events the answer produced, or `null` when the adapter is not
/// active. The caller owns a non-null result.
pub fn macosSubclassingAdapterUpdateIfActive(
    adapter: *MacosSubclassingAdapter,
    update_factory: TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) ?*MacosQueuedEvents {
    if (!requireNativePlatform()) return null;
    if (!requireNativeAdapter(&adapter.adapter)) return null;
    return adapter.adapter.updateIfActive(update_factory, update_factory_userdata);
}

/// Tells the adapter whether `view` holds focus, and returns the events the
/// answer produced.
///
/// `accesskit_macos_subclassing_adapter_update_view_focus_state`,
/// `include/zaccesskit.h:6212`, upstream `src/lib.rs:2945`.
///
/// **Returns** `null` when the adapter is not active.
pub fn macosSubclassingAdapterUpdateViewFocusState(
    adapter: *MacosSubclassingAdapter,
    is_focused: bool,
) ?*MacosQueuedEvents {
    if (!requireNativePlatform()) return null;
    if (!requireNativeAdapter(&adapter.adapter)) return null;
    return adapter.adapter.updateViewFocusState(is_focused);
}

/// Adds a focus forwarder to the `NSWindow` subclass named by the
/// NUL-terminated `class_name`.
///
/// `accesskit_macos_add_focus_forwarder_to_window_class`,
/// `include/zaccesskit.h:6228`, upstream `src/lib.rs:2966`.
///
/// The caller owns the buffer and may release it when this call returns.
/// Repeated installation on one class has no additional effect.
/// **The change cannot be undone**, so
/// the library must stay loaded for the life of the process: link it statically
/// into the main executable.
pub fn macosAddFocusForwarderToWindowClass(class_name: [*:0]const u8) void {
    if (!requireNativePlatform()) return;
    patch.installFocusForwarderForClassNamed(heap(), std.mem.span(class_name)) catch |err|
        allocation.failWithError(err);
}

/// Adds a focus forwarder to the `NSWindow` subclass named by `class_name`,
/// which is `length` bytes and is not NUL-terminated.
///
/// `accesskit_macos_add_focus_forwarder_to_window_class_with_length`,
/// `include/zaccesskit.h:6242`, upstream `src/lib.rs:2988`.
///
/// The buffer need not be NUL-terminated, so the pointer carries no sentinel and
/// `length` is the only bound. The rest of the contract is the one
/// `accesskit_macos_add_focus_forwarder_to_window_class` states.
pub fn macosAddFocusForwarderToWindowClassWithLength(
    class_name: [*]const u8,
    length: usize,
) void {
    if (!requireNativePlatform()) return;
    const bytes = class_name[0..length];
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) {
        allocation.failWithError(error.InteriorNul);
        return;
    }
    const gpa = heap();
    const name = gpa.dupeZ(u8, bytes) catch |err| {
        allocation.failWithError(err);
        return;
    };
    defer gpa.free(name);
    patch.installFocusForwarderForClassNamed(gpa, name) catch |err|
        allocation.failWithError(err);
}

/// The four selectors the subclassing adapter installs on the host view.
///
/// Re-exported so that the entry points above and the table below cannot drift:
/// the adapter installs `attributes_mod.host_view_selectors` and nothing else.
pub fn hostViewSelectors() []const [:0]const u8 {
    return &attributes_mod.host_view_selectors;
}

/// Writes the text rendering of `adapter` with `allocator`, returning the
/// sentinel-terminated pointer.
///
/// It is the body of `macosAdapterDebug`, split so that a test can render with
/// a failing allocator and see the `null` path.
///
/// **Returns.** `error.OutOfMemory` from `gpa.dupe`. On any error nothing is
/// allocated, so a caller that gets `null` owns nothing.
fn renderDebug(adapter: *const MacosAdapter, allocator: Allocator) ![*:0]u8 {
    if (adapter.state == .native) {
        const snapshot = adapter.state.native.adapter.debugSnapshot();
        var buffer: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(
            &buffer,
            "NativeAdapter {{ state: {s}, nodes: {d} }}",
            .{ @tagName(snapshot.state), snapshot.provider_count },
        );
        return (try allocator.dupeZ(u8, text)).ptr;
    }
    // SAFETY: `bufPrint` below is the only writer and it writes exactly the
    // bytes it returns, so `rendered` never names a byte this buffer did not
    // receive. The `error.NoRoom` path returns before anything reads the
    // buffer, which is why an unwritten tail is not a problem.
    var buffer: [512]u8 = undefined;
    const state_name = switch (adapter.state) {
        .inactive => "Inactive",
        .placeholder => "Placeholder",
        .active => "Active",
        .native => unreachable, // Native formatting returned above.
    };
    var nodes: usize = 0;
    switch (adapter.state) {
        .inactive => {},
        .placeholder => |placeholder| nodes = placeholder.context.nodes.count(),
        .active => |context| nodes = context.nodes.count(),
        .native => unreachable, // Native formatting returned above.
    }
    const rendered = std.fmt.bufPrint(
        &buffer,
        "MacosAdapter {{ state: {s}, nodes: {d} }}",
        .{ state_name, nodes },
    ) catch return error.NoRoom;
    const owned = try allocator.dupeZ(u8, rendered);
    return owned.ptr;
}

fn requireNativePlatform() bool {
    if (builtin.os.tag == .macos) return true;
    allocation.failWithError(error.NativeUnsupported);
    return false;
}

fn requireNativeAdapter(adapter: *const MacosAdapter) bool {
    if (!requireNativePlatform()) return false;
    if (adapter.state == .native) return true;
    allocation.failWithError(error.NativeUnsupported);
    return false;
}

fn newNativeSubclassingAdapter(
    target: AttachTarget,
    activation_handler: ActivationHandler,
    activation_userdata: ?*anyopaque,
    action_handler: ActionHandler,
    action_userdata: ?*anyopaque,
) ?*MacosSubclassingAdapter {
    const gpa = heap();
    const adapter = gpa.create(MacosSubclassingAdapter) catch |err| {
        allocation.failWithError(err);
        return null;
    };
    const bridge = c_native.Bridge.create(
        gpa,
        target,
        false,
        true,
        activation_handler,
        activation_userdata,
        action_handler,
        action_userdata,
    ) catch |err| {
        gpa.destroy(adapter);
        allocation.failWithError(err);
        return null;
    };
    adapter.* = .{
        .allocator = gpa,
        .host = null,
        .adapter = .{ .allocator = gpa, .host = null, .state = .{ .native = bridge } },
        .window = switch (target) {
            .window => |window| window,
            .view => null,
        },
    };
    return adapter;
}

comptime {
    // The 16 declarations `src/capi/platform.zig:926-1199` calls. Each is
    // named here so that a renamed entry point is a compile error at the seam
    // rather than a missing C symbol.
    const entry_points = .{
        &macosQueuedEventsRaise,
        &macosAdapterNew,
        &macosAdapterFree,
        &macosAdapterUpdateIfActive,
        &macosAdapterUpdateViewFocusState,
        &macosAdapterViewChildren,
        &macosAdapterFocus,
        &macosAdapterHitTest,
        &macosAdapterDebug,
        &macosSubclassingAdapterNew,
        &macosSubclassingAdapterForWindow,
        &macosSubclassingAdapterFree,
        &macosSubclassingAdapterUpdateIfActive,
        &macosSubclassingAdapterUpdateViewFocusState,
        &macosAddFocusForwarderToWindowClass,
        &macosAddFocusForwarderToWindowClassWithLength,
    };
    if (entry_points.len != 16) @compileError("the macOS C ABI holds 16 declarations");
    for (entry_points, 0..) |entry, i| {
        const info = @typeInfo(@TypeOf(entry));
        if (info != .pointer) @compileError("an entry point must be a pointer");
        _ = i;
    }
    if (@typeInfo(State).@"union".fields.len != 4) {
        @compileError("the adapter has three pure states and one native owner");
    }
}

// --- tests -------------------------------------------------------------------

/// Pure fixtures deliberately bypass the native-only C edge.
fn freePureAdapter(adapter: *MacosAdapter) void {
    std.debug.assert(adapter.state != .native);
    releaseState(adapter) catch @panic("pure state release cannot fail");
    heap().destroy(adapter);
}

fn freePureSubclassingAdapter(adapter: *MacosSubclassingAdapter) void {
    std.debug.assert(adapter.adapter.state != .native);
    releaseState(&adapter.adapter) catch @panic("pure state release cannot fail");
    heap().destroy(adapter);
}

fn newPureRecordedAdapter(
    view: ?*anyopaque,
    focused: bool,
    action_handler: ActionHandler,
    userdata: ?*anyopaque,
) ?*MacosAdapter {
    const gpa = heap();
    const recorder = gpa.create(RecordingHost) catch return null;
    recorder.* = RecordingHost.init(gpa);
    recorder.view = view;
    const adapter = newAdapter(view, focused, action_handler, userdata, recorder.host()) orelse {
        recorder.deinit();
        gpa.destroy(recorder);
        return null;
    };
    adapter.owned_host = recorder;
    return adapter;
}

test "the attribute and role tables are reachable and analysed" {
    // `attributes.zig` and `roles.zig` are reached only through this file, and
    // the one reference each carries sits inside a function nothing calls:
    // `hostViewSelectors` is the only reader of `attributes_mod`, and nothing
    // calls it. An import alone analyses nothing, so both files declare tests
    // that no run executes, which is the defect `AGENTS.md` section 5 records
    // for `src/root.zig` and which a link confirms: a test binary built from
    // `src/root.zig` collects 0 tests from these two files and every one from
    // the three beside them. `refAllDecls` on each is what forces them.
    std.testing.refAllDecls(attributes_mod);
    std.testing.refAllDecls(roles_mod);
}

/// An activation handler that answers with a two-node tree, or with nothing.
///
/// It is `callconv(.c)` because `boundary.ActivationHandler` is, and a handler
/// whose calling convention differs from the one in the pointer type crashes in
/// the platform's code rather than in the adapter's.
const AnsweringActivation = struct {
    /// The tree the handler hands over. `null` means it answers "no tree", which
    /// is an ordinary answer and not a failure.
    tree: ?*c_tree_update.accesskit_tree_update,
    /// How many times the handler ran.
    calls: usize,
};

fn answeringActivation(context: ?*anyopaque) callconv(.c) ?*CTreeUpdate {
    const self: *AnsweringActivation = @ptrCast(@alignCast(context orelse return null));
    self.calls += 1;
    const owned = self.tree orelse return null;
    self.tree = null;
    return @ptrCast(owned);
}

/// An action handler that counts the requests it received and reads none of
/// them.
///
/// It does not release the request, which `boundary.ActionHandler` requires of
/// every handler, so only a test that never sends one may register it. The test
/// that does send one registers `RequestProbe` instead, which releases.
///
/// **The assertion that matters is on `RequestProbe` and not on this type.** The
/// count here proves that a handler was reached; the values there prove what it
/// was handed.
const RecordingAction = struct {
    /// How many requests arrived.
    received: usize = 0,
};

fn recordingAction(request: *boundary.CActionRequest, context: ?*anyopaque) callconv(.c) void {
    const self: *RecordingAction = @ptrCast(@alignCast(context orelse return));
    _ = request;
    self.received += 1;
}

/// An action handler that reads one request and then releases it the way a C
/// caller must.
///
/// `boundary.ActionHandler` hands the request over, so a handler that recorded a
/// pointer and not the values would be reading freed memory. This copies the
/// three scalars and the payload text out first, then runs the two releases
/// `accesskit_action_request_free` runs, in that order.
const RequestProbe = struct {
    /// How many requests arrived.
    calls: usize = 0,
    /// The action the last request carried.
    action: schema.Action = .click,
    /// The tree the last request carried.
    target_tree: schema.TreeId = schema.tree_id_root,
    /// The node the last request carried.
    target_node: schema.NodeId = .{ .value = 0 },
    /// Whether the last request carried a payload.
    has_value: bool = false,
    /// The payload tag the last request carried.
    value_tag: c_uint = 0,
    /// How many bytes of text the last payload held.
    value_length: usize = 0,
    /// The first 64 bytes of the last payload's text, which is longer than any
    /// text these tests send.
    value_text: [64]u8 = @splat(0),

    /// Reads one request and releases it.
    fn call(request: *boundary.CActionRequest, context: ?*anyopaque) callconv(.c) void {
        const self: *RequestProbe = @ptrCast(@alignCast(context orelse return));
        const gpa = allocation.allocator();
        defer gpa.destroy(request);
        defer schema.cActionRequestDeinit(gpa, request);
        self.calls += 1;
        self.action = request.action;
        self.target_tree = request.target_tree;
        self.target_node = request.target_node;
        self.has_value = request.data.has_value;
        self.value_tag = request.data.value.tag;
        if (request.data.has_value) {
            var copied = schema.actionDataFromC(gpa, request.data.value) catch |err| switch (err) {
                error.OutOfMemory => return,
                error.UnknownTag => return,
                error.NullValuePointer => return,
            };
            defer schema.actionDataDeinit(gpa, &copied);
            switch (copied) {
                .value => |payload| {
                    self.value_length = payload.len;
                    const room = @min(payload.len, self.value_text.len);
                    @memcpy(self.value_text[0..room], payload[0..room]);
                },
                else => {},
            }
        }
    }

    /// The text the last payload carried, as a slice of the fixed buffer.
    fn text(self: *const RequestProbe) []const u8 {
        return self.value_text[0..self.value_length];
    }
};

/// A tree update holding `root` and one child, which is enough to drive the
/// three states and the destruction path.
///
/// The update is transferred to the caller, which owns it. **Returns.**
/// `error.OutOfMemory` from `pushNode` and from `box`.
fn boxTwoNodeTree(
    allocator: Allocator,
    focus: schema.NodeId,
) !*c_tree_update.accesskit_tree_update {
    const owned = try allocator.create(c_tree_update.accesskit_tree_update);
    errdefer allocator.destroy(owned);
    owned.* = .{ .gpa = allocator, .update = .{}, .info = null };
    const update = &owned.update;
    errdefer update.deinit(allocator);
    // The child goes in first, and the root declares it, because
    // `consumer.tree_apply` rejects an update that leaves a node unattached.
    try update.pushNode(allocator, child_id, schema.Node.init(allocator, .button));
    const root_data = blk: {
        var node = schema.Node.init(allocator, .window);
        errdefer node.deinit();
        try schema.ids_props.setChildren(&node.properties, &.{child_id});
        break :blk node;
    };
    try update.pushNode(allocator, root_id, root_data);
    update.tree = schema.TreeInfo.init(root_id);
    update.focus = focus;
    return owned;
}

/// A tree update holding an excluded root and `child_count` children under it.
///
/// Two properties make this the tree the `viewChildren` leak test needs.
///
/// **The root is a `generic_container`.** `consumer.filter.commonFilter`
/// excludes that role, so `viewChildren` takes the child-walk branch and grows
/// its list. A `window` root is included, and the included-root branch answers
/// before the list exists at all, so a tree with an included root never
/// exercises the line under test.
///
/// **`child_count` children.** `ArrayList` grows super-linearly, so the first
/// append takes a capacity well above one and a handful of children never
/// reallocate. A later append that fails is what leaves a buffer held by a
/// list the function is about to answer `null` from, and reaching one needs
/// more children than that first capacity.
///
/// The update is transferred to the caller, which owns it. **Returns.**
/// `error.OutOfMemory` from `pushNode` and from `box`.
fn boxExcludedRootTree(
    allocator: Allocator,
    child_count: usize,
) !*c_tree_update.accesskit_tree_update {
    const owned = try allocator.create(c_tree_update.accesskit_tree_update);
    errdefer allocator.destroy(owned);
    owned.* = .{ .gpa = allocator, .update = .{}, .info = null };
    const update = &owned.update;
    errdefer update.deinit(allocator);

    // The ids are built in place and then handed to `setChildren`, which copies
    // them into the tree's own storage, so this buffer is released by the
    // `defer` and nothing keeps a pointer into it.
    const children = try allocator.alloc(schema.NodeId, child_count);
    defer allocator.free(children);
    // The children go in first, and the root declares them, because
    // `consumer.tree_apply` rejects an update that leaves a node unattached.
    for (children, 0..) |*id, index| {
        id.* = .{ .value = @intCast(2 + index) };
        try update.pushNode(allocator, id.*, schema.Node.init(allocator, .button));
    }

    const root_data = blk: {
        var node = schema.Node.init(allocator, .generic_container);
        errdefer node.deinit();
        try schema.ids_props.setChildren(&node.properties, children);
        break :blk node;
    };
    try update.pushNode(allocator, root_id, root_data);
    update.tree = schema.TreeInfo.init(root_id);
    update.focus = children[0];
    return owned;
}

fn callbackFixtureAllocationFailure(allocator: Allocator) !void {
    const included = try boxTwoNodeTree(allocator, child_id);
    defer included.deinit();
    const excluded = try boxExcludedRootTree(allocator, 16);
    defer excluded.deinit();
}

test "callback fixture construction releases partial nodes at every allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        callbackFixtureAllocationFailure,
        .{},
    );
}

/// The root identifier the tests build their trees with.
const root_id: schema.NodeId = .{ .value = 1 };

/// The child identifier the tests build their trees with.
const child_id: schema.NodeId = .{ .value = 2 };

/// A tree update factory that answers with the update it was given.
fn oneShotFactory(context: ?*anyopaque) callconv(.c) ?*CTreeUpdate {
    const owned: *c_tree_update.accesskit_tree_update =
        @ptrCast(@alignCast(context orelse return null));
    return @ptrCast(owned);
}

test "an inactive adapter produces no events and no tree" {
    // Upstream `adapter.rs:112`: `State::Inactive` answers `None` to both
    // update calls, because nothing has asked for a tree yet.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action: RecordingAction = .{};
    const adapter = newAdapter(null, false, recordingAction, &action, recorder.host()) orelse
        return error.NoAdapter;
    defer freePureAdapter(adapter);

    try testing.expect(adapter.updateIfActive(oneShotFactory, null) == null);
    try testing.expect(adapter.updateViewFocusState(true) == null);
    // Both calls record nothing, because nothing was posted.
    try testing.expectEqual(@as(usize, 0), recorder.count());
}

test "a focus update before the first tree is kept for the tree that arrives" {
    // The two non-active states both carry the flag, upstream `adapter.rs:29-37`,
    // so a focus change that arrives before any tree is not lost.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action: RecordingAction = .{};
    const adapter = newAdapter(null, false, recordingAction, &action, recorder.host()) orelse
        return error.NoAdapter;
    defer freePureAdapter(adapter);

    try testing.expect(adapter.updateViewFocusState(true) == null);
    try testing.expect(adapter.state.inactive.common.is_view_focused);
    try testing.expect(adapter.updateViewFocusState(false) == null);
    try testing.expect(!adapter.state.inactive.common.is_view_focused);
}

test "a null answer from an activation handler installs the placeholder" {
    // `boundary.ActivationHandler` states that a `null` return is an ordinary
    // answer meaning "no tree", and upstream `adapter.rs:246-259` answers it
    // with a one-node placeholder window rather than a failure.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action: RecordingAction = .{};
    var activation: AnsweringActivation = .{ .tree = null, .calls = 0 };
    const adapter = newAdapter(null, false, recordingAction, &action, recorder.host()) orelse
        return error.NoAdapter;
    defer freePureAdapter(adapter);

    // A placeholder makes `focus` answer the placeholder root, which is a
    // window, and a window cannot hold focus.
    const held = adapter.focus(answeringActivation, &activation);
    try testing.expectEqual(@as(usize, 1), activation.calls);
    try testing.expect(held == null);
    try testing.expect(adapter.state == .placeholder);

    // The placeholder is still not active, so an update answers nothing.
    try testing.expect(adapter.updateViewFocusState(true) == null);
}

test "a tree from an activation handler makes the adapter active" {
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action: RecordingAction = .{};
    const tree = try boxTwoNodeTree(allocation.allocator(), child_id);
    var activation: AnsweringActivation = .{ .tree = tree, .calls = 0 };
    const adapter = newAdapter(null, true, recordingAction, &action, recorder.host()) orelse
        return error.NoAdapter;
    defer freePureAdapter(adapter);

    const focused = adapter.focus(answeringActivation, &activation);
    try testing.expect(focused != null);
    try testing.expectEqual(@as(usize, 1), activation.calls);
    try testing.expect(adapter.state == .active);
    // The activation handler is not called again while the tree is active.
    try testing.expect(adapter.focus(answeringActivation, &activation) != null);
    try testing.expectEqual(@as(usize, 1), activation.calls);
}

test "the first update over a placeholder yields the focus event" {
    // Upstream `adapter.rs:118-131`: the placeholder's first update builds the
    // real tree and returns a focus event when the new tree has a focus.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action: RecordingAction = .{};
    var activation: AnsweringActivation = .{ .tree = null, .calls = 0 };
    const adapter = newAdapter(null, true, recordingAction, &action, recorder.host()) orelse
        return error.NoAdapter;
    defer freePureAdapter(adapter);

    _ = adapter.focus(answeringActivation, &activation);
    try testing.expect(adapter.state == .placeholder);

    const tree = try boxTwoNodeTree(allocation.allocator(), child_id);
    const handle = adapter.updateIfActive(oneShotFactory, tree) orelse
        return error.NoQueuedEvents;
    try testing.expect(adapter.state == .active);
    try testing.expectEqual(@as(usize, 1), handle.payload.pure.events.items.len);
    try testing.expectEqualStrings(
        events_mod.notificationFor(.focus_moved) orelse return error.NoSuchNotification,
        handle.payload.pure.events.items[0].generic.notification,
    );
    handle.raiseAndRelease();
}

test "raising the handle posts the event and the handle is then spent" {
    // Explicit raise spends the pure fixture's owned queue.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action: RecordingAction = .{};
    var activation: AnsweringActivation = .{ .tree = null, .calls = 0 };
    const adapter = newAdapter(null, true, recordingAction, &action, recorder.host()) orelse
        return error.NoAdapter;
    defer freePureAdapter(adapter);

    _ = adapter.focus(answeringActivation, &activation);
    const tree = try boxTwoNodeTree(allocation.allocator(), child_id);
    const handle = adapter.updateIfActive(oneShotFactory, tree) orelse
        return error.NoQueuedEvents;
    try testing.expectEqual(@as(usize, 0), recorder.count());
    handle.raiseAndRelease();
    try testing.expectEqual(@as(usize, 1), recorder.count());
    try testing.expectEqualStrings(
        events_mod.notificationFor(.focus_moved) orelse return error.NoSuchNotification,
        recorder.posts.items[0].notification,
    );
}

test "dropping a context posts one destroyed notification per live node" {
    // Upstream `context.rs:91-102`. The count and the name are the whole claim.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action: RecordingAction = .{};
    const tree = try boxTwoNodeTree(allocation.allocator(), child_id);
    var activation: AnsweringActivation = .{ .tree = tree, .calls = 0 };
    const adapter = newAdapter(null, true, recordingAction, &action, recorder.host()) orelse
        return error.NoAdapter;

    // Two platform nodes, one for the root and one for the focus.
    try testing.expect(adapter.focus(answeringActivation, &activation) != null);
    const children = adapter.viewChildren(answeringActivation, &activation);
    try testing.expect(children != null);
    const context = switch (adapter.state) {
        .active => |held| held,
        else => return error.NotActive,
    };
    try testing.expectEqual(@as(usize, 2), context.nodes.count());

    const before = recorder.count();
    freePureAdapter(adapter);
    try testing.expectEqual(@as(usize, 2), recorder.count() - before);
    try testing.expectEqualStrings(
        events_mod.notificationFor(.node_destroyed) orelse return error.NoSuchNotification,
        recorder.posts.items[recorder.count() - 1].notification,
    );
}

test "queued events retain callback metadata after the adapter is freed" {
    const tree_info = @import("../../capi/tree_info.zig");
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action: RecordingAction = .{};
    const adapter = newAdapter(null, true, recordingAction, &action, recorder.host()) orelse
        return error.NoAdapter;
    var adapter_live = true;
    defer if (adapter_live) freePureAdapter(adapter);

    const owned = try boxTwoNodeTree(std.testing.allocator, child_id);
    var pending: ?*c_tree_update.accesskit_tree_update = owned;
    defer if (pending) |update| c_tree_update.treeUpdateFree(update);
    const info = try tree_info.treeInfoNew(std.testing.allocator, root_id.value);
    {
        errdefer info.deinit();
        try tree_info.treeInfoSetToolkitName(info, "queued toolkit");
    }
    owned.setTreeInfo(info);
    var activation: AnsweringActivation = .{ .tree = owned, .calls = 0 };
    pending = null;
    try testing.expect(adapter.focus(answeringActivation, &activation) != null);
    const queued = adapter.updateViewFocusState(false) orelse
        return error.NoQueuedEvents;
    defer queued.raiseAndRelease();
    freePureAdapter(adapter);
    adapter_live = false;
    const metadata = queued.payload.pure.context.tree.state.info;
    try testing.expectEqualStrings(
        "queued toolkit",
        metadata.toolkit_name orelse return error.NoToolkitName,
    );
}

/// Builds an active adapter over `probe` and answers its context.
///
/// `getOrInitContext` is what turns the adapter's inactive state into a
/// `Context`, and a `focus` call is what makes that happen without an update, so
/// this asks for the focus of the two-node tree and then reads the context back
/// out of the state the call left behind.
fn activeContextWith(
    probe: *RequestProbe,
    recorder: *RecordingHost,
) !struct { adapter: *MacosAdapter, context: *Context } {
    var activation: AnsweringActivation = .{
        .tree = try boxTwoNodeTree(allocation.allocator(), child_id),
        .calls = 0,
    };
    const adapter = newAdapter(null, true, RequestProbe.call, probe, recorder.host()) orelse
        return error.NoAdapter;
    errdefer freePureAdapter(adapter);
    if (adapter.focus(answeringActivation, &activation) == null) {
        return error.NoFocus;
    }
    const context = switch (adapter.state) {
        .active => |held| held,
        else => return error.NotActive,
    };
    return .{ .adapter = adapter, .context = context };
}

test "an action reaches the handler with the request it was given" {
    // `AK/macos/src/context.rs:86-88` is one call, and the whole of it is the
    // transfer: the handler receives the action, the tree and the node, and owns
    // the block until it releases it. The probe releases it the way
    // `accesskit_action_request_free` does, so a leak here fails the run.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var probe: RequestProbe = .{};
    const built = try activeContextWith(&probe, &recorder);
    defer freePureAdapter(built.adapter);

    try built.context.doAction(.{
        .action = .click,
        .target_tree = schema.tree_id_root,
        .target_node = child_id,
        .data = null,
    });

    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(schema.Action.click, probe.action);
    try testing.expectEqual(schema.tree_id_root, probe.target_tree);
    try testing.expectEqual(child_id, probe.target_node);
    try testing.expect(!probe.has_value);
}

test "a payload crosses as the value tag and the text it carries" {
    // `AK/macos/src/context.rs:86-88` passes the whole request, so the payload
    // is not dropped on the way to the handler. `SetValue` is the action whose
    // payload upstream is a string, at `accesskit/src/lib.rs:3300-3321`.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var probe: RequestProbe = .{};
    const built = try activeContextWith(&probe, &recorder);
    defer freePureAdapter(built.adapter);

    var typed: [5]u8 = "typed".*;
    try built.context.doAction(.{
        .action = .set_value,
        .target_tree = schema.tree_id_root,
        .target_node = child_id,
        .data = .{ .value = typed[0..] },
    });

    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(schema.Action.set_value, probe.action);
    try testing.expect(probe.has_value);
    try testing.expectEqual(
        @as(c_uint, @intFromEnum(schema.ActionDataTag.value)),
        probe.value_tag,
    );
    try testing.expectEqualStrings("typed", probe.text());
}

test "a text with an interior zero reports InteriorNul and sends nothing" {
    // `schema.actionDataToC` refuses the bytes at `accesskit-c/src/common.rs:1098`
    // because a C string ends at the first 0 byte. The handler must not be
    // called at all on that path, or the application receives a request whose
    // text is truncated without being told.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var probe: RequestProbe = .{};
    const built = try activeContextWith(&probe, &recorder);
    defer freePureAdapter(built.adapter);

    var text: [5]u8 = "ty\x00ed".*;
    allocation.clearError();
    try testing.expectError(error.InteriorNul, built.context.doAction(.{
        .action = .set_value,
        .target_tree = schema.tree_id_root,
        .target_node = child_id,
        .data = .{ .value = &text },
    }));
    try testing.expectEqual(@as(usize, 0), probe.calls);
    try testing.expectEqual(allocation.Tag.operation_failed, allocation.lastError());
    try testing.expectEqualStrings("InteriorNul", std.mem.span(allocation.lastErrorName().?));
}

test "a view-children call that cannot grow its list releases what it took" {
    // The list in `viewChildren` grows under a `defer`, not an `errdefer`. The
    // function returns `?*anyopaque` and never an error, so an `errdefer` has
    // no error return to fire on: each `catch return null` below the `defer`
    // answered while holding a list it had already grown, and released nothing.
    //
    // The tree is the one `boxExcludedRootTree` builds, and both of its
    // properties are load-bearing. An included root takes the other branch and
    // never creates the list. Too few children and the first `append` takes a
    // capacity that covers every child, so no later append reallocates and no
    // failure lands on a list that already holds a buffer.
    //
    // `fail_index` is swept rather than pinned. `viewChildren` allocates the
    // list buffer, then the arena copy inside `newNodeList`, and `ArrayList`
    // over-allocates, so which allocation is "the second one" is not a thing to
    // guess. Every index in the sweep is exercised, so whichever lands on a
    // regrowth of a non-empty list is covered.
    //
    // `std.testing.allocator` is the assertion. A restored `errdefer` fails this
    // test with `leaked memory`, because the buffer the list took is still held
    // when the function answers `null`.
    var recorder = RecordingHost.init(testing.allocator);
    defer recorder.deinit();
    var action: RecordingAction = .{};
    // Sixty children is well past the first `append`'s capacity, so the list
    // regrows several times and a failing regrowth is reachable.
    const tree = try boxExcludedRootTree(allocation.allocator(), 60);
    var activation: AnsweringActivation = .{ .tree = tree, .calls = 0 };
    const adapter = newAdapter(null, true, recordingAction, &action, recorder.host()) orelse
        return error.NoAdapter;
    defer freePureAdapter(adapter);

    // Activate the adapter on the real allocator first. Swapping in the failing
    // one before this point spends every index on the tree the activation
    // handler builds and leaves the list below unexercised.
    const built = adapter.viewChildren(answeringActivation, &activation);
    try testing.expect(built != null);
    const context = switch (adapter.state) {
        .active => |held| held,
        else => return error.NotActive,
    };
    const live = context.tree.stateOf().nodes.count();

    var index: usize = 0;
    while (index < 16) : (index += 1) {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{
            .fail_index = index,
        });
        adapter.allocator = failing.allocator();
        // The answer is `null` for the indices that land on an allocation and a
        // real list for the ones past the end. Neither is asserted here: the
        // claim under test is that nothing is held after either, and only the
        // leak detector can see that.
        _ = adapter.viewChildren(answeringActivation, &activation);
        adapter.allocator = testing.allocator;
    }

    // The adapter survived every failed call and still holds the same tree.
    try testing.expect(adapter.state == .active);
    try testing.expectEqual(live, context.tree.stateOf().nodes.count());
    try testing.expect(live > 1);
}

/// Counts the bytes `heap()` has handed out and not taken back.
///
/// **Why not `std.testing.allocator`.** `heap()` is `allocation.allocator()`,
/// which reads a replaceable pair, and the pair's `FreeFn` receives a bare
/// `?*anyopaque` with no length. `Allocator.free` needs a length, so a test
/// cannot forward to `std.testing.allocator` and get its leak detector; the
/// length has to be remembered here. That makes this the detector: `outstanding`
/// is zero exactly when every block the pair handed out has come back.
///
/// `live` maps a pointer to its length. `pairFree` at `capi/allocation.zig`
/// passes the pointer the matching `alloc` returned and nothing else, so the
/// lookup is the only way to learn the size. `pairResize` and `pairRemap` are
/// stubs that always fail, so no free ever arrives through them and the map
/// balances exactly.
///
/// The map's own bookkeeping is allocated from `testing.allocator` and not from
/// `gpa`, so it never counts against `outstanding`.
const HeapCounter = struct {
    /// Where the counted blocks come from.
    gpa: std.mem.Allocator,
    /// Every block handed out and not yet released, keyed by address.
    live: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    /// The summed length of `live`. Zero means nothing is outstanding.
    outstanding: usize = 0,

    fn init(gpa: std.mem.Allocator) HeapCounter {
        return .{ .gpa = gpa };
    }

    /// Releases the bookkeeping map. **The counted blocks are not released
    /// here**: a non-zero `outstanding` at this point is the leak the test
    /// reports, and taking them back here would hide exactly what it is for.
    fn deinit(self: *HeapCounter) void {
        self.live.deinit(std.testing.allocator);
        // SAFETY: the line above released the one allocation this value owned.
        // The poison is what a stale read sees, and no statement below reads
        // `self`.
        self.* = undefined;
    }

    /// Hands out one block and records its length.
    fn alloc(self: *HeapCounter, size: usize) ?*anyopaque {
        const bytes = self.gpa.alloc(u8, size) catch return null;
        self.live.put(std.testing.allocator, @intFromPtr(bytes.ptr), size) catch {
            self.gpa.free(bytes);
            return null;
        };
        self.outstanding += size;
        return @ptrCast(bytes.ptr);
    }

    /// Takes back one block. An address the map does not hold is left alone,
    /// which is what a `null` from the pair means.
    fn release(self: *HeapCounter, ptr: *anyopaque) void {
        const entry = self.live.fetchRemove(@intFromPtr(ptr)) orelse return;
        self.outstanding -= entry.value;
        self.gpa.free(@as([*]u8, @ptrCast(ptr))[0..entry.value]);
    }
};

/// The `AllocFn` half of the pair the leak tests install.
fn countedAlloc(size: usize, context: ?*anyopaque) callconv(.c) ?*anyopaque {
    const counter: *HeapCounter = @ptrCast(@alignCast(context orelse return null));
    return counter.alloc(size);
}

/// The `FreeFn` half of the pair the leak tests install.
fn countedFree(ptr: ?*anyopaque, context: ?*anyopaque) callconv(.c) void {
    const counter: *HeapCounter = @ptrCast(@alignCast(context orelse return));
    counter.release(ptr orelse return);
}

test "the pure owned recorder comes back, box and posts" {
    // An explicit pure helper owns both recorder allocations; C never uses it.
    var counter = HeapCounter.init(std.heap.c_allocator);
    defer counter.deinit();
    allocation.installAllocator(countedAlloc, countedFree, &counter);
    // Restored before any assertion below can fail, because a failing `expect`
    // returns early and would otherwise leave the pair installed for every later
    // test in the binary.
    defer allocation.installAllocator(null, null, null);

    var recorder_view: u8 = 0;
    const adapter = newPureRecordedAdapter(&recorder_view, true, recordingAction, null) orelse
        return error.NoAdapter;

    // The adapter is holding a recorder, which is the fact the release turns on.
    const recorder = adapter.owned_host orelse return error.NoOwnedRecorder;
    try testing.expect(adapter.host.?.ptr == @as(?*anyopaque, recorder));

    // Grow `posts`, so the leak under test is the buffer and not only the box.
    //
    // The appends go through `recorder.allocator`, which is the installed pair,
    // and that is the whole point. An earlier version of this test appended
    // through `std.heap.c_allocator` directly, which put `posts` outside the
    // counter: dropping the `deinit` and freeing only the box still passed,
    // because the posts buffer was invisible to the detector. Main's warning
    // was that a test checking only the box would pass while `posts` still grew,
    // and it was right — this is what it took to actually catch it.
    //
    // Eight notifications is more than one buffer, so the growth is a realloc
    // and the remaining count differs from the box alone.
    for (0..8) |index| {
        recorder.posts.append(recorder.allocator, .{
            .node = null,
            .window = null,
            .notification = "AXFocusedUIElement",
            .text = "",
            .priority = @intCast(index),
        }) catch return error.NoRoom;
    }
    try testing.expectEqual(@as(usize, 8), recorder.count());
    try testing.expect(counter.outstanding > 0);

    // Releasing the adapter must release the recorder with it, and a `deinit`
    // before the `destroy` is what takes `posts` back. The other order would
    // leave a positive count here, which is the assertion that distinguishes the
    // two from a test that only proved the box came back.
    freePureAdapter(adapter);
    try testing.expectEqual(@as(usize, 0), counter.outstanding);
}

test "an adapter built over a caller's host never frees that host" {
    // The other half of `owned_host`: a borrowed host must stay the caller's.
    // `newAdapter` leaves the field null, and `releaseState` only frees a
    // recorder when it is set, so the recorder below is still readable after
    // the adapter is gone. Reading it is the assertion: if `releaseState` freed
    // a borrowed host this would be a use-after-free rather than a value.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action: RecordingAction = .{};
    const adapter = newAdapter(null, false, recordingAction, &action, recorder.host()) orelse
        return error.NoAdapter;
    try testing.expect(adapter.owned_host == null);

    freePureAdapter(adapter);

    // Still ours, still usable, and its own count still reads zero.
    try testing.expectEqual(@as(usize, 0), recorder.count());
    recorder.posts.append(std.testing.allocator, .{
        .node = null,
        .window = null,
        .notification = "AXFocusedUIElement",
    }) catch return error.NoRoom;
    try testing.expectEqual(@as(usize, 1), recorder.count());
}

test "a queued-events handle that cannot be allocated answers null" {
    // The handle is the one allocation `newQueuedEvents` makes, so failing it
    // is the whole null path. Before the return type carried the optional, the
    // same failure answered `undefined` and the C caller held a non-null
    // pointer to nothing.
    var recorder = RecordingHost.init(testing.allocator);
    defer recorder.deinit();
    var action: RecordingAction = .{};
    const tree = try boxTwoNodeTree(allocation.allocator(), child_id);
    var activation: AnsweringActivation = .{ .tree = tree, .calls = 0 };
    const adapter = newAdapter(null, true, recordingAction, &action, recorder.host()) orelse
        return error.NoAdapter;
    defer freePureAdapter(adapter);

    // A live tree, so the handle allocation is the only thing left to fail.
    _ = adapter.focus(answeringActivation, &activation);
    const context = switch (adapter.state) {
        .active => |held| held,
        else => return error.NotActive,
    };

    // Only queue allocation uses the failing allocator; restore it before free.
    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 0,
    });
    adapter.allocator = failing.allocator();
    defer adapter.allocator = heap();

    try testing.expect(adapter.newQueuedEvents(context, .empty) == null);
    // The context is untouched, so the adapter still owns exactly one
    // reference and the deferred free releases it once.
    try testing.expectEqual(@as(usize, 1), context.refs);
}

test "a recorder that cannot grow records the failure instead of dropping it" {
    // `Host.post` and `Host.post_with_user_info` return nothing, so an
    // allocation failure has nowhere to go but the recorder. Each gets its own
    // failing allocator, because `FailingAllocator` fails one index and lets
    // the rest through: one shared instance would let the second post succeed
    // and hide the path under test.
    var node_failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 0,
    });
    var nodes = RecordingHost.init(node_failing.allocator());
    defer nodes.deinit();
    RecordingHost.post(&nodes, null, "AXFocusedUIElement");
    try testing.expect(nodes.failed);
    try testing.expectEqual(@as(usize, 0), nodes.count());

    var window_failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 0,
    });
    var windows = RecordingHost.init(window_failing.allocator());
    defer windows.deinit();
    RecordingHost.postWithUserInfo(&windows, null, "AXAnnouncementRequested", "text", 0);
    try testing.expect(windows.failed);
    try testing.expectEqual(@as(usize, 0), windows.count());
}

test "the entry points take the handlers platform.zig passes them" {
    // The shapes, not the behaviour: each pointer is named here with its own
    // type, so a changed parameter list at the seam is a compile error.
    const raise: *const fn (*MacosQueuedEvents) void = &macosQueuedEventsRaise;
    const new: *const fn (?*anyopaque, bool, ActionHandler, ?*anyopaque) ?*MacosAdapter =
        &macosAdapterNew;
    const free: *const fn (*MacosAdapter) void = &macosAdapterFree;
    const update: *const fn (*MacosAdapter, TreeUpdateFactory, ?*anyopaque) ?*MacosQueuedEvents =
        &macosAdapterUpdateIfActive;
    const focus: *const fn (*MacosAdapter, bool) ?*MacosQueuedEvents =
        &macosAdapterUpdateViewFocusState;
    const children: *const fn (*MacosAdapter, ActivationHandler, ?*anyopaque) ?*anyopaque =
        &macosAdapterViewChildren;
    const held_focus: *const fn (*MacosAdapter, ActivationHandler, ?*anyopaque) ?*anyopaque =
        &macosAdapterFocus;
    const hit: *const fn (*MacosAdapter, f64, f64, ActivationHandler, ?*anyopaque) ?*anyopaque =
        &macosAdapterHitTest;
    const debug: *const fn (*const MacosAdapter) ?[*:0]u8 = &macosAdapterDebug;
    const subclass_new: *const fn (
        ?*anyopaque,
        ActivationHandler,
        ?*anyopaque,
        ActionHandler,
        ?*anyopaque,
    ) ?*MacosSubclassingAdapter = &macosSubclassingAdapterNew;
    const window_new: *const fn (
        ?*anyopaque,
        ActivationHandler,
        ?*anyopaque,
        ActionHandler,
        ?*anyopaque,
    ) ?*MacosSubclassingAdapter = &macosSubclassingAdapterForWindow;
    const subclass_free: *const fn (*MacosSubclassingAdapter) void =
        &macosSubclassingAdapterFree;
    const subclass_update: *const fn (
        *MacosSubclassingAdapter,
        TreeUpdateFactory,
        ?*anyopaque,
    ) ?*MacosQueuedEvents = &macosSubclassingAdapterUpdateIfActive;
    const subclass_focus: *const fn (*MacosSubclassingAdapter, bool) ?*MacosQueuedEvents =
        &macosSubclassingAdapterUpdateViewFocusState;
    const forward: *const fn ([*:0]const u8) void = &macosAddFocusForwarderToWindowClass;
    const forward_length: *const fn ([*]const u8, usize) void =
        &macosAddFocusForwarderToWindowClassWithLength;
    _ = .{
        raise,        new,        free,          update,          focus,          children, held_focus,     hit, debug,
        subclass_new, window_new, subclass_free, subclass_update, subclass_focus, forward,  forward_length,
    };
}

test "native AppKit constructor refuses non-macOS before borrowing callbacks" {
    if (@import("builtin").os.tag == .macos) return error.SkipZigTest;
    const Probe = struct {
        fn action(_: ?*anyopaque, _: *const schema.ActionRequest) void {
            @panic("a refused native adapter must not call its borrowed action callback");
        }
        fn activate(_: ?*anyopaque) void {
            @panic("a refused native adapter must not call its activation callback");
        }
    };
    try testing.expectError(
        error.NativeUnsupported,
        @field(@This(), "NativeAdapter").create(testing.allocator, testing.io, .{
            .action_handler = Probe.action,
            .activation_sink = .{ .native = .{
                .callback = Probe.activate,
                .userdata = null,
            } },
            .userdata = null,
        }),
    );
}

test "queued notifications do not use a borrowed host after adapter close" {
    var recorder = RecordingHost.init(testing.allocator);
    defer recorder.deinit();
    var probe: RequestProbe = .{};
    const built = try activeContextWith(&probe, &recorder);
    const fixture = try boxTwoNodeTree(allocation.allocator(), root_id);
    const queued = built.adapter.updateIfActive(oneShotFactory, fixture) orelse
        return error.NoEvents;
    freePureAdapter(built.adapter);
    const closed_post_count = recorder.posts.items.len;
    queued.raiseAndRelease();
    try testing.expectEqual(closed_post_count, recorder.posts.items.len);
}

test "C action producer transfers a raw configured allocator request" {
    const RawRequestProbe = struct {
        calls: usize = 0,
        fn call(request: *boundary.CActionRequest, userdata: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.calls += 1;
            const gpa = allocation.allocator();
            schema.cActionRequestDeinit(gpa, request);
            gpa.destroy(request);
        }
    };
    var counter = HeapCounter.init(std.heap.c_allocator);
    defer counter.deinit();
    allocation.installAllocator(countedAlloc, countedFree, &counter);
    defer allocation.installAllocator(null, null, null);
    var recorder = RecordingHost.init(testing.allocator);
    defer recorder.deinit();
    var probe: RawRequestProbe = .{};
    var activation: AnsweringActivation = .{
        .tree = try boxTwoNodeTree(allocation.allocator(), child_id),
        .calls = 0,
    };
    const adapter = newAdapter(null, true, RawRequestProbe.call, &probe, recorder.host()) orelse
        return error.NoAdapter;
    defer freePureAdapter(adapter);
    _ = adapter.focus(answeringActivation, &activation);
    const context = switch (adapter.state) {
        .active => |value| value,
        else => return error.NotActive,
    };
    const bytes_before_request = counter.outstanding;
    try context.doAction(.{
        .action = .click,
        .target_tree = schema.tree_id_root,
        .target_node = child_id,
        .data = null,
    });
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(bytes_before_request, counter.outstanding);
    var text: [5]u8 = "owned".*;
    try context.doAction(.{
        .action = .set_value,
        .target_tree = schema.tree_id_root,
        .target_node = child_id,
        .data = .{ .value = &text },
    });
    try testing.expectEqual(@as(usize, 2), probe.calls);
    try testing.expectEqual(bytes_before_request, counter.outstanding);
    try testing.expectEqualStrings("owned", &text);
}

test "C macOS constructor refuses a non-native platform instead of returning a recorder" {
    if (@import("builtin").os.tag == .macos) return error.SkipZigTest;
    var counter = HeapCounter.init(std.heap.c_allocator);
    defer counter.deinit();
    allocation.installAllocator(countedAlloc, countedFree, &counter);
    defer allocation.installAllocator(null, null, null);
    var borrowed_view: u8 = 0;
    var action: RecordingAction = .{};
    allocation.clearError();
    const result = macosAdapterNew(&borrowed_view, false, recordingAction, &action);
    defer if (result) |adapter| macosAdapterFree(adapter);
    try testing.expect(result == null);
    try testing.expectEqual(allocation.Tag.operation_failed, allocation.lastError());
    try testing.expectEqualStrings("NativeUnsupported", std.mem.span(allocation.lastErrorName().?));
    try testing.expectEqual(@as(usize, 0), counter.outstanding);
    try testing.expectEqual(@as(usize, 0), action.received);
    allocation.clearError();
    try testing.expect(macosAdapterNew(null, false, recordingAction, &action) == null);
    try testing.expectEqualStrings("NativeUnsupported", std.mem.span(allocation.lastErrorName().?));
    var activation: AnsweringActivation = .{ .tree = null, .calls = 0 };
    allocation.clearError();
    try testing.expect(macosSubclassingAdapterNew(
        null,
        answeringActivation,
        &activation,
        recordingAction,
        &action,
    ) == null);
    try testing.expectEqual(allocation.Tag.operation_failed, allocation.lastError());
    try testing.expectEqualStrings("NativeUnsupported", std.mem.span(allocation.lastErrorName().?));
    allocation.clearError();
    try testing.expect(macosSubclassingAdapterForWindow(
        null,
        answeringActivation,
        &activation,
        recordingAction,
        &action,
    ) == null);
    try testing.expectEqual(allocation.Tag.operation_failed, allocation.lastError());
    try testing.expectEqualStrings("NativeUnsupported", std.mem.span(allocation.lastErrorName().?));
    try testing.expectEqual(@as(usize, 0), counter.outstanding);
    try testing.expectEqual(@as(usize, 0), action.received);
    try testing.expectEqual(@as(usize, 0), activation.calls);
}

test "C focus forwarders refuse a non-native platform instead of recording success" {
    if (@import("builtin").os.tag == .macos) return error.SkipZigTest;
    allocation.clearError();
    macosAddFocusForwarderToWindowClass("AccessKitSourceOnlyRefusal");
    try testing.expectEqual(allocation.Tag.operation_failed, allocation.lastError());
    try testing.expectEqualStrings("NativeUnsupported", std.mem.span(allocation.lastErrorName().?));
    const class_name = "AccessKitSourceOnlyLengthRefusal";
    allocation.clearError();
    macosAddFocusForwarderToWindowClassWithLength(class_name.ptr, class_name.len);
    try testing.expectEqual(allocation.Tag.operation_failed, allocation.lastError());
    try testing.expectEqualStrings("NativeUnsupported", std.mem.span(allocation.lastErrorName().?));
}

test "pure queue releases its stable box through its captured allocator exactly once" {
    var counter = HeapCounter.init(std.heap.c_allocator);
    defer counter.deinit();
    allocation.installAllocator(countedAlloc, countedFree, &counter);
    defer allocation.installAllocator(null, null, null);
    var recorder = RecordingHost.init(testing.allocator);
    defer recorder.deinit();
    var probe: RequestProbe = .{};
    const built = try activeContextWith(&probe, &recorder);
    var adapter_live = true;
    defer if (adapter_live) freePureAdapter(built.adapter);

    const before_queue = counter.outstanding;
    const queue = built.adapter.newQueuedEvents(built.context, .empty) orelse
        return error.NoQueuedEvents;
    try testing.expect(counter.outstanding > before_queue);
    try testing.expectEqual(@as(usize, 2), built.context.refs);
    built.adapter.allocator = testing.allocator;
    queue.destroy();
    built.adapter.allocator = heap();
    try testing.expectEqual(before_queue, counter.outstanding);
    try testing.expectEqual(@as(usize, 1), built.context.refs);

    const surviving = built.adapter.newQueuedEvents(built.context, .empty) orelse
        return error.NoQueuedEvents;
    freePureAdapter(built.adapter);
    adapter_live = false;
    try testing.expect(counter.outstanding > 0);
    const closed_posts = recorder.count();
    surviving.raiseAndRelease();
    try testing.expectEqual(closed_posts, recorder.count());
    try testing.expectEqual(@as(usize, 0), counter.outstanding);
}

test "native C queue wrong-thread refusal preserves retained targets and main-thread retry" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const native_objc = @import("objc.zig");
    var pool = try native_objc.AutoreleasePool.init();
    defer pool.deinit();
    var io_provider = std.Io.Threaded.init(testing.allocator, .{});
    defer io_provider.deinit();
    const Counts = struct {
        actions: u32 = 0,
        activations: u32 = 0,
        runtime_releases: u32 = 0,

        fn action(userdata: ?*anyopaque, _: *const schema.ActionRequest) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.actions += 1;
        }
        fn activate(userdata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.activations += 1;
        }
        fn release(userdata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.runtime_releases += 1;
        }
    };
    var counts: Counts = .{};
    const owner = try NativeAdapter.create(testing.allocator, io_provider.io(), .{
        .action_handler = Counts.action,
        .userdata = &counts,
        .activation_sink = .{ .native = .{ .callback = Counts.activate, .userdata = &counts } },
        .runtime_release = .{ .userdata = &counts, .release = Counts.release },
    });
    var owner_alive = true;
    defer if (owner_alive) {
        owner.close() catch @panic("native queue fixture close failed");
        owner.deinit();
    };
    const application_class = native_objc.getClass("NSApplication") orelse
        return error.ObjectiveCUnavailable;
    const application = native_objc.send(
        ?native_objc.Object,
        application_class,
        "sharedApplication",
        .{},
    ) orelse return error.NativeObjectCreationFailed;
    _ = application;
    const view_class = native_objc.getClass("NSView") orelse return error.ObjectiveCUnavailable;
    const view = native_objc.send(?native_objc.Object, view_class, "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    defer native_objc.release(view);
    const window_class = native_objc.getClass("NSWindow") orelse return error.ObjectiveCUnavailable;
    const allocated_window = native_objc.send(
        ?native_objc.Object,
        window_class,
        "alloc",
        .{},
    ) orelse return error.NativeObjectCreationFailed;
    const window = native_objc.send(
        ?native_objc.Object,
        allocated_window,
        "initWithContentRect:styleMask:backing:defer:",
        .{
            native_objc.NSRect{
                .origin = .{ .x = 0, .y = 0 },
                .size = .{ .width = 64, .height = 64 },
            },
            @as(usize, 0),
            @as(usize, 2),
            @as(u8, 0),
        },
    ) orelse return error.NativeObjectCreationFailed;
    defer native_objc.release(window);
    const view_baseline = native_objc.send(usize, view, "retainCount", .{});
    const window_baseline = native_objc.send(usize, window, "retainCount", .{});
    var weak = owner.context.weak();
    var weak_alive = true;
    defer if (weak_alive) weak.deinit();
    const queued = blk: {
        const notifications = try NativeNotifications.create(testing.allocator, weak, .{
            .view = view,
            .window = window,
        });
        errdefer notifications.deinit();
        const wrapper = try testing.allocator.create(MacosQueuedEvents);
        wrapper.* = .{
            .allocator = testing.allocator,
            .payload = .{ .native = notifications },
        };
        break :blk wrapper;
    };
    var queue_alive = true;
    defer if (queue_alive) queued.destroy();
    weak.deinit();
    weak_alive = false;
    try owner.close();
    owner.deinit();
    owner_alive = false;
    try testing.expectEqual(@as(u32, 0), counts.runtime_releases);
    const retained_view_count = native_objc.send(usize, view, "retainCount", .{});
    const retained_window_count = native_objc.send(usize, window, "retainCount", .{});
    try testing.expectEqual(view_baseline + 1, retained_view_count);
    try testing.expectEqual(window_baseline + 1, retained_window_count);
    const Attempt = struct {
        queue: *MacosQueuedEvents,
        diagnostic: allocation.Tag = .none,
        name: ?[*:0]const u8 = null,

        fn run(self: *@This()) void {
            allocation.clearError();
            macosQueuedEventsRaise(self.queue);
            self.diagnostic = allocation.lastError();
            self.name = allocation.lastErrorName();
        }
    };
    var attempted: Attempt = .{ .queue = queued };
    const thread = try std.Thread.spawn(.{}, Attempt.run, .{&attempted});
    thread.join();
    // A consuming regression spends the handle; never repeat its cleanup.
    if (counts.runtime_releases != 0) queue_alive = false;
    try testing.expectEqual(allocation.Tag.operation_failed, attempted.diagnostic);
    try testing.expectEqualStrings("WrongThread", std.mem.span(attempted.name.?));
    try testing.expectEqual(@as(u32, 0), counts.runtime_releases);
    try testing.expectEqual(@as(u32, 0), counts.actions);
    try testing.expectEqual(@as(u32, 0), counts.activations);
    try testing.expectEqual(retained_view_count, native_objc.send(usize, view, "retainCount", .{}));
    try testing.expectEqual(retained_window_count, native_objc.send(usize, window, "retainCount", .{}));
    try testing.expect(queued.payload == .native);
    try testing.expectEqual(view, queued.payload.native.retained_view.?);
    try testing.expectEqual(window, queued.payload.native.retained_window.?);
    allocation.clearError();
    queue_alive = false;
    macosQueuedEventsRaise(queued);
    try testing.expectEqual(allocation.Tag.none, allocation.lastError());
    try testing.expectEqual(@as(u32, 1), counts.runtime_releases);
    try testing.expectEqual(view_baseline, native_objc.send(usize, view, "retainCount", .{}));
    try testing.expectEqual(window_baseline, native_objc.send(usize, window, "retainCount", .{}));
}
