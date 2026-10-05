//! The macOS adapter: the 16 C entry points, the three handles, and the state
//! machine that sits behind them.
//!
//! **Upstream range.** `accesskit_macos` 0.27.1, the tree at
//! `adapters/macos/src/`: `adapter.rs:24-295` (the state machine and the six
//! tree-facing calls), `context.rs:26-102` (the context and its drop),
//! `event.rs:20-335` (the queued events, behind `events.zig`),
//! `subclass.rs:160-200` (the subclassing adapter) and `patch.rs:39-71` (the
//! focus forwarder). The 16 declarations themselves are
//! `src/capi/platform.zig:926-1199` and are not edited here.
//!
//! **What is compiled-and-tested here, and what needs a Mac.** This host is
//! Linux and has no macOS SDK. `zig build-exe -target aarch64-macos` fails at
//! `-lobjc` with `unable to find dynamic system library 'objc'`, recorded as
//! `docs/16:1780` and as row H5 of `docs/50-verification.md`, and
//! `translate-c` cannot parse an Objective-C header at all, recorded as
//! `docs/16:1784` and analysed in `docs/42` section 2.5. So:
//!
//! **L1, the source type-checks for its target.** This module contributes the
//! state machine, the ownership and lifetime rules, the three handles, the
//! focus-forwarder registry and all 16 signatures, and every platform call sits
//! behind `Host`. All of that is checked on Linux.
//!
//! **L2, the object links against real system libraries. Nothing here.** It
//! needs a Mac with the SDK. The Objective-C runtime call in
//! `install_focus_forwarder` is the one place this tree would reach libobjc, and
//! nothing in this directory has ever been linked against it.
//!
//! **L3, the adapter works against a live assistive technology. Nothing here.**
//! It needs a running application with VoiceOver.
//!
//! A green run on this host is evidence about the state machine, the ownership
//! and the tables. It is not evidence that the adapter builds, and it is not
//! evidence that the adapter works.
//!
//! **The `Host` seam, and why it is not a stub.** Everything the adapter cannot
//! do without AppKit goes through one struct of five function pointers: post a
//! notification against a node, post one with a `userInfo` against a window,
//! read the view, read the window that holds it, and hit-test it. `RecordingHost`
//! is a complete implementation of that interface — it accepts every call and
//! records it, so a test sees exactly which notification reached which node —
//! and the same `MacosAdapter` type drives both. **The one thing no `Host`
//! implementation on this host can do is reach a real assistive technology**, and
//! that is exactly the L3 row above.
//!
//! **Ownership.** `Context` is reference counted, which is the port's `Rc`.
//! Upstream `QueuedEvents` holds an `Rc<Context>` and so outlives the adapter
//! that produced it; a queued-events handle here holds one reference and
//! releases it in `macosQueuedEventsRaise`, and `macosAdapterFree` drops the
//! adapter's. `macosQueuedEventsRaise` is the only release for the handle: a
//! second call is a use-after-free and a `null` pointer is a contract
//! violation, both as the header states.
//!
//! **The 16 signatures.** They are the ones `src/capi/platform.zig:926-1199`
//! calls. Two of them differ from the shape a reader might expect, and
//! `platform.zig` is the authority:
//! `macosAdapterNew` takes `is_view_focused` as a `bool` and not as a function
//! pointer, and `macosSubclassingAdapterNew` and `...ForWindow` take no
//! deactivation handler at all, because AppKit drives activation for this
//! platform.
//!
//! **The loop bound.** Every walk in this file is over one of the five tables in
//! `attributes.zig`, `literals.zig` or the class registry below, each of which
//! has a comptime length. `Context.destroy` walks `nodes`, whose length is the
//! number of platform nodes the tree produced.

const std = @import("std");
const builtin = @import("builtin");

const boundary = @import("../../capi/boundary.zig");
const allocation = @import("../../capi/allocation.zig");
const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");

const attributes_mod = @import("attributes.zig");
const events_mod = @import("events.zig");
const literals_mod = @import("literals.zig");
const roles_mod = @import("roles.zig");

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

/// The one platform seam, and the five calls that go through it.
///
/// Each function pointer is `callconv(.c)` because on a target where these are
/// real AppKit entry points they are. `RecordingHost` implements all five
/// without AppKit.
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
    /// The tree an application reads.
    tree: consumer.tree.Tree,
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
        is_view_focused: bool,
        host: Host,
        action_handler: ActionHandler,
        action_userdata: ?*anyopaque,
        view: ?*anyopaque,
    ) (TreeUpdateError || Allocator.Error)!*Context {
        var tree = try consumer.tree.Tree.init(allocator, update, is_view_focused);
        // Registered before the first fallible allocation, so every path below
        // that fails releases the tree rather than leaking it.
        errdefer tree.deinit();

        const context = try allocator.create(Context);
        errdefer allocator.destroy(context);

        context.* = .{
            .allocator = allocator,
            .refs = 1,
            .tree = tree,
            .host = host,
            .action_handler = action_handler,
            .action_userdata = action_userdata,
            .view = view,
            .nodes = .empty,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        return context;
    }

    /// Adds one reference.
    fn retain(self: *Context) void {
        self.refs += 1;
    }

    /// Drops one reference, releasing the context when the last one goes.
    ///
    /// Upstream `Context::drop` at `context.rs:91-102` posts one
    /// `NSAccessibilityUIElementDestroyedNotification` for every node it still
    /// holds, and this call does the same before it releases anything.
    fn release(self: *Context) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        const allocator = self.allocator;
        self.postDestroyedForEveryNode();
        var nodes = self.nodes;
        nodes.deinit(allocator);
        var arena = self.arena;
        arena.deinit();
        self.tree.deinit();
        allocator.destroy(self);
    }

    /// Posts one destruction per live platform node, upstream `context.rs:91`.
    ///
    /// The walk is over `nodes`, whose length is the number of platform nodes
    /// this context created, and the map does not change while it is walked.
    fn postDestroyedForEveryNode(self: *Context) void {
        const name = events_mod.notificationFor(.node_destroyed).?;
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
};

/// The events one update produced, and the context they are raised against.
///
/// Upstream `QueuedEvents`, at `AK/macos/src/event.rs:110-131`. It is a handle,
/// not a value: the caller owns a `*MacosQueuedEvents` and must pass it to
/// `macosQueuedEventsRaise`, which raises the events and releases the handle.
pub const MacosQueuedEvents = struct {
    /// The allocator that grew `events`.
    allocator: Allocator,
    /// The context the events are raised against, held by reference so that the
    /// handle stays valid after the adapter is freed.
    context: *Context,
    /// The events, in the order they must be raised.
    events: ArrayList(events_mod.QueuedEvent),

    /// Raises every event and releases the handle.
    ///
    /// Raising posts each event against its node or its window and then releases
    /// the list and the context reference. It is the only release for the
    /// handle: a second call is a use-after-free and a `null` pointer is a
    /// contract violation, both as `include/zaccesskit.h:6048` states.
    ///
    /// **Errors.** None. Upstream cannot fail either: a destroyed node is
    /// skipped and an announcement with no window is dropped, because a client
    /// that is not there to hear it must not be sent one.
    pub fn raiseAndRelease(self: *MacosQueuedEvents) void {
        self.raise();
        self.destroy();
    }

    /// Raises every event, leaving the handle valid.
    ///
    /// It is separated from `raiseAndRelease` so a test can observe the same
    /// posting without spending the handle. A caller on the C seam uses
    /// `raiseAndRelease`, which is the only release.
    pub fn raise(self: *MacosQueuedEvents) void {
        for (self.events.items) |*event| {
            switch (event.*) {
                .generic => |generic| {
                    const node = self.context.getOrCreatePlatformNode(generic.node_id) catch
                        continue;
                    self.context.host.post(
                        self.context.host.ptr,
                        node,
                        generic.notification,
                    );
                },
                .node_destroyed => |id| {
                    // A node with no platform node was never shown to a client,
                    // so there is nothing to tell it about.
                    const node = self.context.removePlatformNode(id) orelse continue;
                    const name = events_mod.notificationFor(.node_destroyed).?;
                    self.context.host.post(self.context.host.ptr, node, name);
                },
                .announcement => |announcement| {
                    const view = self.context.host.view_of(self.context.host.ptr) orelse continue;
                    const window = self.context.host.window_of(
                        self.context.host.ptr,
                        view,
                    ) orelse continue;
                    const name = literals_mod.announcement_requested_notification.value;
                    self.context.host.post_with_user_info(
                        self.context.host.ptr,
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
        var list = self.events;
        events_mod.releaseEvents(allocator, &list);
        const context = self.context;
        self.* = undefined;
        context.release();
    }
};

/// The state an adapter is in, upstream `AK/macos/src/adapter.rs:26-38`.
///
/// The three states are: no tree has been asked for yet, the activation handler
/// answered "no tree" so a placeholder stands in, or a real tree is active.
const State = union(enum) {
    /// No tree has been asked for. Upstream `State::Inactive`.
    inactive: Inactive,
    /// The activation handler answered `null`, so a one-node placeholder window
    /// stands in until a tree update arrives. Upstream `State::Placeholder`.
    placeholder: Placeholder,
    /// A tree is active. Upstream `State::Active`.
    active: *Context,

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
    /// The platform seam.
    host: Host,
    /// Which of the three states the adapter is in.
    state: State,

    /// Asks `factory` for a tree and hands it to the adapter.
    ///
    /// Upstream `Adapter::update_if_active`, at `adapter.rs:110-146`. **Returns**
    /// the events the answer produced, or `null` when the adapter is not active.
    /// The caller owns a non-null result and must pass it to
    /// `macosQueuedEventsRaise`.
    ///
    /// **Errors.** None. An update the tree rejects, or a factory that runs out
    /// of memory, leaves the adapter in the state it was in and produces no
    /// handle, because a handle whose tree is stale would be worse than none.
    pub fn updateIfActive(
        self: *MacosAdapter,
        factory: TreeUpdateFactory,
        factory_userdata: ?*anyopaque,
    ) ?*MacosQueuedEvents {
        switch (self.state) {
            .inactive => return null,
            .placeholder => |*placeholder| {
                const update = treeUpdateFromFactory(factory, factory_userdata);
                const context = Context.init(
                    self.allocator,
                    update,
                    placeholder.common.is_view_focused,
                    self.host,
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
                            .notification = events_mod.notificationFor(.focus_moved).?,
                        },
                    }) catch {
                        list.deinit(self.allocator);
                        context.release();
                        return null;
                    };
                }
                placeholder.context.release();
                self.state = .{ .active = context };
                return self.newQueuedEvents(context, list);
            },
            .active => |context| {
                var generator = events_mod.EventGenerator.init(self.allocator);
                defer generator.deinit();
                const handler = events_mod.slotsOf(&generator);
                const update = treeUpdateFromFactory(factory, factory_userdata);
                context.tree.updateAndProcessChanges(update, &handler) catch return null;
                // A slot that ran out of memory leaves a partial list, so the
                // handle is withheld rather than raised short.
                if (generator.failed) return null;
                return self.newQueuedEvents(context, generator.takeEvents());
            },
        }
    }

    /// Records whether `view` holds focus, and returns the events it produced.
    ///
    /// Upstream `Adapter::update_view_focus_state`, at `adapter.rs:152-175`.
    /// **Returns** `null` when the adapter is not active, which is upstream's
    /// answer for both non-active states.
    pub fn updateViewFocusState(
        self: *MacosAdapter,
        is_focused: bool,
    ) ?*MacosQueuedEvents {
        switch (self.state) {
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
                if (generator.failed) return null;
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
            .inactive => |inactive| {
                const boxed = activation_handler(activation_userdata);
                if (boxed) |initial| {
                    const context = Context.init(
                        self.allocator,
                        takeUpdate(initial),
                        inactive.common.is_view_focused,
                        self.host,
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
                    false,
                    self.host,
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
        errdefer list.deinit(self.allocator);
        var children = consumer.node_ref.hierarchy.filteredChildren(root, root_filter) catch
            return null;
        while (children.next() catch return null) |child| {
            const node = context.getOrCreatePlatformNode(child.id()) catch return null;
            list.append(self.allocator, node) catch return null;
        }
        defer list.deinit(self.allocator);
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
        const view = self.host.view_of(self.host.ptr) orelse return null;
        _ = view;
        const context = self.getOrInitContext(activation_handler, activation_userdata) orelse
            return null;
        const state = context.tree.stateOf();
        const root = state.root();

        // The platform is asked first, because only it knows the view's own
        // coordinate system. When it has nothing, the tree is asked, and the
        // root is the fallback.
        const point: schema.Point = .{ .x = x, .y = y };
        if (self.host.hit_test(self.host.ptr, point.x, point.y)) |hit| return hit;

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
    fn newQueuedEvents(
        self: *MacosAdapter,
        context: *Context,
        list: ArrayList(events_mod.QueuedEvent),
    ) *MacosQueuedEvents {
        const handle = self.allocator.create(MacosQueuedEvents) catch {
            var owned = list;
            events_mod.releaseEvents(self.allocator, &owned);
            return undefined;
        };
        context.retain();
        handle.* = .{
            .allocator = self.allocator,
            .context = context,
            .events = list,
        };
        return handle;
    }
};

/// A macOS adapter that installs the four accesskit selectors on the host view.
///
/// Upstream `subclass.rs:160-200`. It holds a `MacosAdapter` and the window it
/// was built for, and it forwards the four tree-facing calls.
pub const MacosSubclassingAdapter = struct {
    /// The allocator the adapter was built with.
    allocator: Allocator,
    /// The platform seam.
    host: Host,
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
    var update = schema.TreeUpdate{};
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
/// leaves the library holding nothing. Upstream aborts there. This call prints
/// the violation and then traps, which is the same outcome: the process stops
/// rather than the adapter continuing with no tree. **A `null` return from an
/// activation handler is a different thing** and is an ordinary answer that
/// installs the placeholder; `getOrInitContext` treats it that way.
fn treeUpdateFromFactory(
    factory: TreeUpdateFactory,
    factory_userdata: ?*anyopaque,
) schema.TreeUpdate {
    const owned = factory(factory_userdata) orelse {
        std.debug.print(
            "accesskit: a tree update factory returned null, which is a contract " ++
                "violation at src/capi/boundary.zig:50 and stops the process\n",
            .{},
        );
        @trap();
    };
    return takeUpdate(owned);
}

/// Takes the update a factory or activation handler returned.
///
/// **Ownership.** The handler's pointer is a box it allocated, and the library
/// owns it: this call copies the value out and frees the box with `gpa`. It
/// does **not** call `TreeUpdate.deinit` on the value, because
/// `consumer.tree.Tree` takes the value by value and consumes its node list, so
/// a `deinit` here would release nodes the tree now owns.
///
/// `boundary.CTreeUpdate` is `schema.TreeUpdate`, so the conversion across the
/// seam is the identity and neither side writes one.
fn takeUpdate(owned: *CTreeUpdate) schema.TreeUpdate {
    const copy = owned.*;
    heap().destroy(owned);
    return copy;
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

    /// An empty recorder over `allocator`.
    pub fn init(allocator: Allocator) RecordingHost {
        return .{ .allocator = allocator };
    }

    /// Releases the recorded posts.
    pub fn deinit(self: *RecordingHost) void {
        var posts = self.posts;
        posts.deinit(self.allocator);
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
        }) catch {};
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
        }) catch {};
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
    return newAdapter(
        view,
        is_view_focused,
        action_handler,
        action_handler_userdata,
        recordingHost(),
    );
}

/// Returns a macOS adapter for `view` over `host`, or `null` when the allocation
/// failed.
///
/// It is `macosAdapterNew` with the seam supplied, and it is what a target with
/// AppKit uses. `host.ptr` must stay valid until the adapter is released.
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
    releaseState(adapter);
    heap().destroy(adapter);
}

/// Releases whatever state `adapter` holds, without releasing `adapter` itself.
///
/// `MacosSubclassingAdapter` embeds a `MacosAdapter` by value, so its release
/// calls this rather than `macosAdapterFree`: destroying the embedded struct
/// would free memory that belongs to the outer allocation.
fn releaseState(self: *MacosAdapter) void {
    switch (self.state) {
        .inactive => {},
        .placeholder => |placeholder| placeholder.context.release(),
        .active => |context| context.release(),
    }
    self.* = undefined;
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
    return renderDebug(adapter, heap()) catch null;
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
    // The activation handler is not stored: this adapter forwards a tree-facing
    // call, and that call carries the handler, so holding one here would be a
    // second lifetime the header does not describe.
    _ = activation_handler;
    _ = activation_handler_userdata;
    return newSubclassingAdapter(
        view,
        view,
        action_handler,
        action_handler_userdata,
        recordingHost(),
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
    _ = activation_handler;
    _ = activation_handler_userdata;
    // A window adapter drives the window's content view, upstream
    // `subclass.rs:120-140`.
    const host = recordingHost();
    var recorder: *RecordingHost = @ptrCast(@alignCast(host.ptr orelse return null));
    recorder.view = window;
    return newSubclassingAdapter(window, window, action_handler, action_handler_userdata, host);
}

/// Returns a subclassing adapter for `view` over `host`, or `null` when the
/// allocation failed.
///
/// It is `macosSubclassingAdapterNew` with the seam supplied, and it is what a
/// target with AppKit uses.
pub fn newSubclassingAdapter(
    view: ?*anyopaque,
    window: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
    host: Host,
) ?*MacosSubclassingAdapter {
    const adapter = heap().create(MacosSubclassingAdapter) catch return null;
    errdefer heap().destroy(adapter);
    const inner = newAdapter(
        view,
        false,
        action_handler,
        action_handler_userdata,
        host,
    ) orelse return null;
    adapter.* = .{
        .allocator = heap(),
        .host = host,
        .adapter = inner.*,
        .window = window,
    };
    return adapter;
}

/// Releases the adapter and every tree it holds, exactly once.
///
/// `accesskit_macos_subclassing_adapter_free`, `include/zaccesskit.h:6186`,
/// upstream `src/lib.rs:2921`.
///
/// The adapter must not be `null`.
pub fn macosSubclassingAdapterFree(adapter: *MacosSubclassingAdapter) void {
    releaseState(&adapter.adapter);
    adapter.* = undefined;
    heap().destroy(adapter);
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
    return adapter.adapter.updateViewFocusState(is_focused);
}

/// Adds a focus forwarder to the `NSWindow` subclass named by the
/// NUL-terminated `class_name`.
///
/// `accesskit_macos_add_focus_forwarder_to_window_class`,
/// `include/zaccesskit.h:6228`, upstream `src/lib.rs:2966`.
///
/// The function keeps its own copy of the name, so the caller keeps ownership of
/// the buffer and must not release it after this call. Calling this twice for
/// one class name has no additional effect. **The change cannot be undone**, so
/// the library must stay loaded for the life of the process: link it statically
/// into the main executable.
pub fn macosAddFocusForwarderToWindowClass(class_name: [*:0]const u8) void {
    patchWindowClass(std.mem.span(class_name));
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
    patchWindowClass(class_name[0..length]);
}

/// How many window class names `patchWindowClass` has recorded.
///
/// It is a comptime bound because the registry is a fixed-size table: the
/// registration is process-lifetime and cannot be undone, so it is not a place
/// where an unbounded list belongs. A caller that names more than this many
/// classes is answered without a second entry, which is what "calling this
/// twice for one class name has no additional effect" means for a full table.
pub const window_class_capacity = 32;

/// How many bytes one recorded window class name may hold.
///
/// It is 64 because an Objective-C class name is a short identifier and the
/// table is fixed. A name longer than this is not recorded, which leaves the
/// class without a forwarder rather than truncating the name into one that names
/// a different class.
pub const class_name_capacity = 64;

/// How many window classes have been registered in this process.
var registered_window_classes: usize = 0;

/// The names, in registration order. It is never released.
///
/// **The count above and this table are the only file-scope `var`s in the
/// adapter, and they are not a runtime handle.** Upstream keeps the same thing
/// in a process-lifetime static at `subclass.rs:157` and the header states why:
/// the modification cannot be undone, so a registration outlives every adapter
/// and every call. There is no other place to put it, because
/// `add_focus_forwarder_to_window_class` takes no adapter and no context.
///
/// A name handed out by `registeredWindowClass` is a view of this table, so it
/// stays readable for the life of the process. A view built on the frame of
/// whichever function called the accessor dangles the moment that function
/// returns, and the fault lands later, in whoever read the name.
var window_class_names: [window_class_capacity][class_name_capacity]u8 = undefined;

/// Records `name` and installs the forwarder, once per name.
///
/// The name is copied into `window_class_names`, so the caller keeps ownership of
/// its buffer. A name already registered is not recorded again, so calling the
/// entry point twice for one class has no additional effect.
fn patchWindowClass(name: []const u8) void {
    for (window_class_names[0..registered_window_classes]) |held| {
        if (std.mem.eql(u8, std.mem.sliceTo(&held, 0), name)) return;
    }
    if (registered_window_classes == window_class_capacity) return;
    if (name.len == 0 or name.len > class_name_capacity) return;
    const slot = &window_class_names[registered_window_classes];
    @memset(slot, 0);
    @memcpy(slot[0..name.len], name);
    registered_window_classes += 1;
    installFocusForwarder(name);
}

/// How many window class names the registry holds.
///
/// The count is at most `window_class_capacity` and only grows, because a
/// registration cannot be undone.
pub fn registeredWindowClassCount() usize {
    return registered_window_classes;
}

/// The name at `index` in registration order, or `null` when `index` is at or
/// past the count.
///
/// The slice points into `window_class_names` and stops at the NUL that follows
/// the name. It is valid for the life of the process, so the caller keeps no
/// reference and releases nothing.
pub fn registeredWindowClass(index: usize) ?[]const u8 {
    if (index >= registered_window_classes) return null;
    const slot: *const [class_name_capacity]u8 = &window_class_names[index];
    return std.mem.sliceTo(slot, 0);
}

/// Installs `accessibilityFocusedUIElement` on the class named `name`.
///
/// Upstream `AK/macos/src/patch.rs:39-71`. **This is the one call in the adapter
/// that needs the Objective-C runtime, and it is the one thing this module does
/// not write.** It needs `<objc/runtime.h>` and the macOS SDK, neither of which
/// is on this host, and a wrong `extern` signature would be a crash inside the
/// runtime rather than a compile error. `docs/42` section 2.5 records that
/// `translate-c` cannot parse an Objective-C header, so the declarations cannot
/// be generated either.
///
/// What is written is the protocol around it: the registration above, the
/// selector name in `attributes.focus_forwarder_selector`, and the observation
/// that a class is registered once. **A target with AppKit supplies the install
/// step**, and this module does not claim the step is done.
///
/// `name` may be a borrowed slice with no sentinel; the install step copies it
/// into the `CString` the runtime reads.
fn installFocusForwarder(name: []const u8) void {
    _ = name;
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
    var buffer: [512]u8 = undefined;
    const state_name = switch (adapter.state) {
        .inactive => "Inactive",
        .placeholder => "Placeholder",
        .active => "Active",
    };
    var nodes: usize = 0;
    switch (adapter.state) {
        .inactive => {},
        .placeholder => |placeholder| nodes = placeholder.context.nodes.count(),
        .active => |context| nodes = context.nodes.count(),
    }
    const rendered = std.fmt.bufPrint(
        &buffer,
        "MacosAdapter {{ state: {s}, nodes: {d} }}",
        .{ state_name, nodes },
    ) catch return error.NoRoom;
    const owned = try allocator.dupeZ(u8, rendered);
    return owned.ptr;
}

/// The `Host` the C entry points install when the caller supplies none.
///
/// It records into a `RecordingHost` the adapter owns, so a caller that never
/// reaches AppKit still gets every notification delivered and observable.
fn recordingHost() Host {
    const recorder = heap().create(RecordingHost) catch {
        // Without a recorder there is nowhere to send a notification, so the
        // adapter cannot be built. The entry points return `null` in that case,
        // which is the one answer that is not a lie.
        return .{
            .ptr = null,
            .post = noopPost,
            .post_with_user_info = noopPostWithUserInfo,
            .view_of = noopView,
            .window_of = noopWindow,
            .hit_test = noopHitTest,
        };
    };
    recorder.* = RecordingHost.init(heap());
    return recorder.host();
}

/// Discards a notification, used when no recorder could be allocated.
fn noopPost(context: ?*anyopaque, node: ?*anyopaque, notification: [:0]const u8) void {
    _ = context;
    _ = node;
    _ = notification;
}

/// Discards an announcement, used when no recorder could be allocated.
fn noopPostWithUserInfo(
    context: ?*anyopaque,
    window: ?*anyopaque,
    notification: [:0]const u8,
    text: []const u8,
    priority: i32,
) void {
    _ = context;
    _ = window;
    _ = notification;
    _ = text;
    _ = priority;
}

/// Answers no view, used when no recorder could be allocated.
fn noopView(context: ?*anyopaque) ?*anyopaque {
    _ = context;
    return null;
}

/// Answers no window, used when no recorder could be allocated.
fn noopWindow(context: ?*anyopaque, view: ?*anyopaque) ?*anyopaque {
    _ = context;
    _ = view;
    return null;
}

/// Answers no hit, used when no recorder could be allocated.
fn noopHitTest(context: ?*anyopaque, x: f64, y: f64) ?*anyopaque {
    _ = context;
    _ = x;
    _ = y;
    return null;
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
    // The registry and the three handles the header names.
    if (@typeInfo(State).@"union".fields.len != 3) {
        @compileError("the adapter has three states");
    }
}

// --- tests -------------------------------------------------------------------

/// An activation handler that answers with a two-node tree, or with nothing.
///
/// It is `callconv(.c)` because `boundary.ActivationHandler` is, and a handler
/// whose calling convention differs from the one in the pointer type crashes in
/// the platform's code rather than in the adapter's.
const AnsweringActivation = struct {
    /// The tree the handler hands over. `null` means it answers "no tree", which
    /// is an ordinary answer and not a failure.
    tree: ?*schema.TreeUpdate,
    /// How many times the handler ran.
    calls: usize,
};

fn answeringActivation(context: ?*anyopaque) callconv(.c) ?*CTreeUpdate {
    const self: *AnsweringActivation = @ptrCast(@alignCast(context orelse return null));
    self.calls += 1;
    return self.tree;
}

/// An action handler that records the requests it received.
///
/// It does not release the request, which `boundary.ActionHandler` requires of
/// every handler, because these tests never send one. The rule is recorded on
/// the type so a caller that does send one has to change this function.
const RecordingAction = struct {
    /// How many requests arrived.
    received: usize = 0,
};

fn recordingAction(request: *boundary.CActionRequest, context: ?*anyopaque) callconv(.c) void {
    const self: *RecordingAction = @ptrCast(@alignCast(context orelse return));
    _ = request;
    self.received += 1;
}

/// A tree update holding `root` and one child, which is enough to drive the
/// three states and the destruction path.
///
/// The update is transferred to the caller, which owns it. **Returns.**
/// `error.OutOfMemory` from `pushNode` and from `box`.
fn boxTwoNodeTree(allocator: Allocator, focus: schema.NodeId) !*schema.TreeUpdate {
    const update = try allocator.create(schema.TreeUpdate);
    errdefer allocator.destroy(update);
    update.* = .{};
    errdefer update.deinit(allocator);
    // The child goes in first, and the root declares it, because
    // `consumer.tree_apply` rejects an update that leaves a node unattached.
    try update.pushNode(allocator, child_id, schema.Node.init(allocator, .button));
    var root_data = schema.Node.init(allocator, .window);
    errdefer root_data.deinit();
    try schema.ids_props.setChildren(&root_data.properties, &.{child_id});
    try update.pushNode(allocator, root_id, root_data);
    update.tree = schema.TreeInfo.init(root_id);
    update.focus = focus;
    return update;
}

/// The root identifier the tests build their trees with.
const root_id: schema.NodeId = .{ .value = 1 };

/// The child identifier the tests build their trees with.
const child_id: schema.NodeId = .{ .value = 2 };

/// A tree update factory that answers with the update it was given.
fn oneShotFactory(context: ?*anyopaque) callconv(.c) ?*CTreeUpdate {
    return @ptrCast(@alignCast(context orelse return null));
}

test "an inactive adapter produces no events and no tree" {
    // Upstream `adapter.rs:112`: `State::Inactive` answers `None` to both
    // update calls, because nothing has asked for a tree yet.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action = RecordingAction{};
    const adapter = newAdapter(null, false, recordingAction, &action, recorder.host()).?;
    defer macosAdapterFree(adapter);

    try testing.expect(macosAdapterUpdateIfActive(adapter, oneShotFactory, null) == null);
    try testing.expect(macosAdapterUpdateViewFocusState(adapter, true) == null);
    // Both calls record nothing, because nothing was posted.
    try testing.expectEqual(@as(usize, 0), recorder.count());
}

test "a focus update before the first tree is kept for the tree that arrives" {
    // The two non-active states both carry the flag, upstream `adapter.rs:29-37`,
    // so a focus change that arrives before any tree is not lost.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action = RecordingAction{};
    const adapter = newAdapter(null, false, recordingAction, &action, recorder.host()).?;
    defer macosAdapterFree(adapter);

    try testing.expect(macosAdapterUpdateViewFocusState(adapter, true) == null);
    try testing.expect(adapter.state.inactive.common.is_view_focused);
    try testing.expect(macosAdapterUpdateViewFocusState(adapter, false) == null);
    try testing.expect(!adapter.state.inactive.common.is_view_focused);
}

test "a null answer from an activation handler installs the placeholder" {
    // `boundary.ActivationHandler` states that a `null` return is an ordinary
    // answer meaning "no tree", and upstream `adapter.rs:246-259` answers it
    // with a one-node placeholder window rather than a failure.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action = RecordingAction{};
    var activation = AnsweringActivation{ .tree = null, .calls = 0 };
    const adapter = newAdapter(null, false, recordingAction, &action, recorder.host()).?;
    defer macosAdapterFree(adapter);

    // A placeholder makes `focus` answer the placeholder root, which is a
    // window, and a window cannot hold focus.
    const held = macosAdapterFocus(adapter, answeringActivation, &activation);
    try testing.expectEqual(@as(usize, 1), activation.calls);
    try testing.expect(held == null);
    try testing.expect(adapter.state == .placeholder);

    // The placeholder is still not active, so an update answers nothing.
    try testing.expect(macosAdapterUpdateViewFocusState(adapter, true) == null);
}

test "a tree from an activation handler makes the adapter active" {
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action = RecordingAction{};
    const tree = try boxTwoNodeTree(allocation.allocator(), child_id);
    var activation = AnsweringActivation{ .tree = tree, .calls = 0 };
    const adapter = newAdapter(null, true, recordingAction, &action, recorder.host()).?;
    defer macosAdapterFree(adapter);

    const focused = macosAdapterFocus(adapter, answeringActivation, &activation);
    try testing.expect(focused != null);
    try testing.expectEqual(@as(usize, 1), activation.calls);
    try testing.expect(adapter.state == .active);
    // The activation handler is not called again while the tree is active.
    try testing.expect(macosAdapterFocus(adapter, answeringActivation, &activation) != null);
    try testing.expectEqual(@as(usize, 1), activation.calls);
}

test "the first update over a placeholder yields the focus event" {
    // Upstream `adapter.rs:118-131`: the placeholder's first update builds the
    // real tree and returns a focus event when the new tree has a focus.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action = RecordingAction{};
    var activation = AnsweringActivation{ .tree = null, .calls = 0 };
    const adapter = newAdapter(null, true, recordingAction, &action, recorder.host()).?;
    defer macosAdapterFree(adapter);

    _ = macosAdapterFocus(adapter, answeringActivation, &activation);
    try testing.expect(adapter.state == .placeholder);

    const tree = try boxTwoNodeTree(allocation.allocator(), child_id);
    const handle = macosAdapterUpdateIfActive(adapter, oneShotFactory, tree);
    try testing.expect(handle != null);
    try testing.expect(adapter.state == .active);
    try testing.expectEqual(@as(usize, 1), handle.?.events.items.len);
    try testing.expectEqualStrings(
        events_mod.notificationFor(.focus_moved).?,
        handle.?.events.items[0].generic.notification,
    );
    macosQueuedEventsRaise(handle.?);
}

test "raising the handle posts the event and the handle is then spent" {
    // `macosQueuedEventsRaise` is the only release. After it the list is gone,
    // so a second call is a use-after-free and this test proves the first one
    // did post what the list held.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action = RecordingAction{};
    var activation = AnsweringActivation{ .tree = null, .calls = 0 };
    const adapter = newAdapter(null, true, recordingAction, &action, recorder.host()).?;
    defer macosAdapterFree(adapter);

    _ = macosAdapterFocus(adapter, answeringActivation, &activation);
    const tree = try boxTwoNodeTree(allocation.allocator(), child_id);
    const handle = macosAdapterUpdateIfActive(adapter, oneShotFactory, tree).?;
    try testing.expectEqual(@as(usize, 0), recorder.count());
    macosQueuedEventsRaise(handle);
    try testing.expectEqual(@as(usize, 1), recorder.count());
    try testing.expectEqualStrings(
        events_mod.notificationFor(.focus_moved).?,
        recorder.posts.items[0].notification,
    );
}

test "dropping a context posts one destroyed notification per live node" {
    // Upstream `context.rs:91-102`. The count and the name are the whole claim.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action = RecordingAction{};
    const tree = try boxTwoNodeTree(allocation.allocator(), child_id);
    var activation = AnsweringActivation{ .tree = tree, .calls = 0 };
    const adapter = newAdapter(null, true, recordingAction, &action, recorder.host()).?;

    // Two platform nodes, one for the root and one for the focus.
    try testing.expect(macosAdapterFocus(adapter, answeringActivation, &activation) != null);
    const children = macosAdapterViewChildren(adapter, answeringActivation, &activation);
    try testing.expect(children != null);
    const context = switch (adapter.state) {
        .active => |held| held,
        else => return error.NotActive,
    };
    try testing.expectEqual(@as(usize, 2), context.nodes.count());

    const before = recorder.count();
    macosAdapterFree(adapter);
    try testing.expectEqual(@as(usize, 2), recorder.count() - before);
    try testing.expectEqualStrings(
        events_mod.notificationFor(.node_destroyed).?,
        recorder.posts.items[recorder.count() - 1].notification,
    );
}

test "the debug text names the state and the platform node count" {
    // The text borrows nothing from the adapter, so the adapter may be freed
    // before the string is released with `accesskit_string_free`.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action = RecordingAction{};
    const adapter = newAdapter(null, true, recordingAction, &action, recorder.host()).?;
    defer macosAdapterFree(adapter);

    const text = macosAdapterDebug(adapter) orelse return error.NoText;
    try testing.expectEqualStrings(
        "MacosAdapter { state: Inactive, nodes: 0 }",
        std.mem.span(text),
    );
    allocation.allocator().free(text[0..std.mem.len(text) :0]);

    var activation = AnsweringActivation{ .tree = null, .calls = 0 };
    _ = macosAdapterFocus(adapter, answeringActivation, &activation);
    const placeholder_text = macosAdapterDebug(adapter) orelse return error.NoText;
    try testing.expectEqualStrings(
        "MacosAdapter { state: Placeholder, nodes: 0 }",
        std.mem.span(placeholder_text),
    );
    allocation.allocator().free(placeholder_text[0..std.mem.len(placeholder_text) :0]);
}

test "the focus forwarder records a class name once" {
    // `include/zaccesskit.h:6228`: the function keeps its own copy, and calling
    // it twice for one class name has no additional effect.
    const before = registeredWindowClassCount();
    macosAddFocusForwarderToWindowClass("AccessKitTestWindow");
    try testing.expectEqual(before + 1, registeredWindowClassCount());
    try testing.expectEqualStrings(
        "AccessKitTestWindow",
        registeredWindowClass(registeredWindowClassCount() - 1).?,
    );
    macosAddFocusForwarderToWindowClass("AccessKitTestWindow");
    try testing.expectEqual(before + 1, registeredWindowClassCount());

    // The length form reads the same bytes and reaches the same registry, so
    // the two entry points are one function rather than two.
    const padded = "AccessKitTestPadded";
    macosAddFocusForwarderToWindowClassWithLength(padded.ptr, padded.len);
    try testing.expectEqual(before + 2, registeredWindowClassCount());
    macosAddFocusForwarderToWindowClassWithLength(padded.ptr, padded.len);
    try testing.expectEqual(before + 2, registeredWindowClassCount());
    try testing.expectEqualStrings(
        padded,
        registeredWindowClass(registeredWindowClassCount() - 1).?,
    );
}

test "a name read from the registry outlives the call that returned it" {
    // The registry is process-lifetime, so the name it hands out must still
    // read the same after the accessor has returned. An accessor that built
    // the view on its own frame handed out a pointer into that dead frame
    // instead: a Debug build read the stale bytes and passed, and an optimised
    // build faulted inside the assertion that read them. **The address is the
    // invariant**, and the read after the registry has moved on is what a
    // caller does.
    const index = registeredWindowClassCount();
    try testing.expect(index + 2 < window_class_capacity);
    macosAddFocusForwarderToWindowClass("AccessKitTestHeldName");
    const held = registeredWindowClass(index).?;
    const table = @intFromPtr(&window_class_names);
    const address = @intFromPtr(held.ptr);
    try testing.expect(address >= table);
    try testing.expect(address < table + @sizeOf(@TypeOf(window_class_names)));

    // A later registration writes a later slot, so the earlier view still
    // reads its own bytes and the count has grown past it.
    macosAddFocusForwarderToWindowClass("AccessKitTestLaterName");
    try testing.expectEqualStrings("AccessKitTestHeldName", held);
    try testing.expectEqualStrings(
        "AccessKitTestLaterName",
        registeredWindowClass(index + 1).?,
    );
    try testing.expectEqual(index + 2, registeredWindowClassCount());
    try testing.expect(registeredWindowClass(index + 2) == null);
}

test "the subclassing adapter forwards its four calls" {
    // It holds a `MacosAdapter` and adds the window it was built for.
    var recorder = RecordingHost.init(std.testing.allocator);
    defer recorder.deinit();
    var action = RecordingAction{};
    var window: u8 = 0;
    const adapter = newSubclassingAdapter(
        &window,
        &window,
        recordingAction,
        &action,
        recorder.host(),
    ).?;
    try testing.expect(adapter.window == @as(?*anyopaque, &window));
    try testing.expect(adapter.adapter.state == .inactive);

    // With no tree yet, the two update calls answer nothing.
    try testing.expect(
        macosSubclassingAdapterUpdateIfActive(adapter, oneShotFactory, null) == null,
    );
    try testing.expect(macosSubclassingAdapterUpdateViewFocusState(adapter, true) == null);
    macosSubclassingAdapterFree(adapter);
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
    _ = .{ raise, new, free, update, focus, children, held_focus, hit, debug };
}
