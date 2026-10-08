//! `AndroidAdapter`: the tree, the id map, and the ten calls that drive them.
//!
//! **What this adapter is.** Upstream is `AK/android/src/adapter.rs`, and it is
//! the plain one of the two Android adapters: it holds a tree and nothing that
//! touches Java. The host view arrives on each call, the activation handler
//! arrives on the call that needs it, and the action handler arrives on
//! `perform_action`. `injecting.zig` wraps this one with a host view and the two
//! handlers held instead of passed.
//!
//! **Why the host is a parameter and not a field.** `include/zaccesskit.h:5752-5757`
//! says this adapter takes no handler at construction, and the same reasoning
//! applies to the host: a C consumer may drive one adapter from several views, so
//! nothing about a view is held between calls. That is also what makes every call
//! here testable through `jni_table.inertTable` with no JVM.
//!
//! **Activation, and the two shapes of "no tree".** `ensureActive` asks the
//! activation handler once and remembers whether it answered. **A `null` answer
//! is ordinary and means "no tree"**, so the adapter stays inactive and every
//! later call answers `null` rather than calling the handler again. The other
//! shape is a `TreeUpdateFactory`: upstream unwraps it at `adapter.rs:554`, so a
//! `null` there is a contract violation. The two are the same Zig type and
//! different contracts, so they are different outcomes here:
//! `ensureActive` treats `null` as data and `updateIfActive` reports
//! `error.NullTreeUpdate`.
//!
//! **What an update produces.** Node changes preserve subtree content events.
//! An included node whose existing scroll offsets change also produces one
//! value-owned scroll payload; each changed axis keeps its current offset,
//! checked delta and optional maximum. Root scrolls name the host view, while
//! nonroot scrolls mint their virtual id before enqueue. Focus changes preserve
//! the focus event for the new endpoint. `AK/android/src/adapter.rs:143-197`.
//!
//! **The host focus flag.** `Tree.init` takes one and this adapter always passes
//! `false`. **Nothing in this C surface reports host focus**, and
//! `include/zaccesskit.h:5705-5713` names no entry point that would; a field no
//! call can set would be a claim the adapter cannot keep.
//!
//! **The `NoSuchMethodError` answer.** A method absent on an older device makes
//! `GetMethodID` answer `null` with an exception pending. `node.zig` reports that
//! as `error.JavaMemberMissing`, this adapter records it in `last_error` and
//! answers `null` — which is exactly what the header promises for a node that
//! does not exist and for an update that produced nothing. The exception is left
//! pending, because `docs/29` section 3.3 records upstream unwrapping rather than
//! clearing, and a thread with a pending exception must not keep calling.
//!
//! **The loop bound.** The walk in `onHoverEvent` is `geometry.hitTest`'s, which
//! carries its own bound. `simple_actions` has `simple_action_count` rows and is
//! walked once per simple action. Nothing here walks a domain of its own.

const std = @import("std");

const action_request = @import("../../capi/action_request.zig");
const allocation = @import("../../capi/allocation.zig");
const boundary = @import("../../capi/boundary.zig");
const c_tree_update = @import("../../capi/tree_update.zig");
const classes = @import("classes.zig");
const consumer = @import("../../consumer/root.zig");
const java_call = @import("java_call.zig");
const jni = @import("jni_table.zig");
const node_mod = @import("node.zig");
const node_id_map = @import("node_id_map.zig");
const platform_action = @import("platform_action.zig");
const queued_events = @import("queued_events.zig");
const schema = @import("../../schema/root.zig");
const values = @import("values.zig");

const ActionHandler = boundary.ActionHandler;
const ActivationHandler = boundary.ActivationHandler;
const CTreeUpdate = boundary.CTreeUpdate;
const TreeUpdateFactory = boundary.TreeUpdateFactory;

const JInt = values.JInt;
const JFloat = jni.JFloat;
const JniTable = jni.JniTable;
const JObject = jni.JObject;
const NodeIdMap = node_id_map.NodeIdMap;
const NodeRef = consumer.node_id.NodeRef;
const PlatformAction = platform_action.PlatformAction;
const QueuedEvent = queued_events.QueuedEvent;
const QueuedEvents = queued_events.AndroidQueuedEvents;
const Tree = consumer.tree.Tree;
const TreeState = consumer.tree_state.TreeState;

const geometry = consumer.node_ref.geometry;
const properties = consumer.node_ref.properties;
const set_state = consumer.node_ref.set_state;
const text_position = consumer.text.position;
const text_position_motion = consumer.text.position_motion;
const text_query = consumer.text.query;

const Allocator = std.mem.Allocator;
const testing = std.testing;

/// A position inside one node's text, as the text layer names it.
const Position = text_position.Position;

/// Everything an adapter call can fail with.
///
/// `FillError` carries JNI, query, narrowing and id-map failures. `SlotError`
/// preserves the exact change-slot cause after a consumed update commits.
pub const Error = consumer.tree.UpdateError || node_mod.FillError || SlotError ||
    schema.ActionDataToCError || error{
    /// The tree-update factory answered `null`. Upstream unwraps the same
    /// value at `AK/android/src/adapter.rs:554`, so a `null` here is a
    /// contract violation and **not** "no tree". `ActivationHandler`
    /// answering `null` is the other shape and is handled as data.
    NullTreeUpdate,

    /// The activation handler handed over a tree the consumer half rejected.
    /// It reaches here through `Tree.init` and carries one of the
    /// `UpdateError` tags, so it is listed rather than named separately.
    TreeRejected,
};

/// One simple action: the Android id and the AccessKit action it means.
///
/// The table is the whole mapping for an action that carries no payload. A row
/// that needed the node — the two scroll actions — is absent on purpose and is
/// resolved by `scrollActionFor`, because the same Android id means two different
/// things on a horizontal and a vertical scroller.
const SimpleAction = struct {
    /// One of the `ACTION_*` ids.
    android: JInt,
    /// The AccessKit action it becomes.
    accesskit: schema.Action,
};

/// How many rows `simple_actions` holds.
pub const simple_action_count = 5;

/// Every simple action the adapter answers, in the order the fill writes them.
pub const simple_actions = [simple_action_count]SimpleAction{
    .{ .android = values.ACTION_CLICK, .accesskit = .click },
    .{ .android = values.ACTION_FOCUS, .accesskit = .focus },
    .{ .android = values.ACTION_CLEAR_ACCESSIBILITY_FOCUS, .accesskit = .blur },
    // The two rows that do not depend on the node are the text and click ones
    // above; a scroll id is resolved by `scrollActionFor` instead.
    .{ .android = values.ACTION_SET_SELECTION, .accesskit = .set_text_selection },
    .{ .android = values.ACTION_SET_PROGRESS, .accesskit = .set_value },
};

/// `AccessibilityNodeInfo.obtain(View, int)`, `docs/29` row 34.
const node_info_obtain: java_call.Member = .{
    .class = .{
        .descriptor = "Landroid/view/accessibility/AccessibilityNodeInfo;",
        .internal_name = "android/view/accessibility/AccessibilityNodeInfo",
    },
    .name = "obtain",
    .signature = "(Landroid/view/View;I)Landroid/view/accessibility/AccessibilityNodeInfo;",
};

/// The filter the adapter applies to the tree before it fills or hits a node.
///
/// Upstream names one `filter` in `AK/android/src/node.rs` and it is
/// `common_filter`. The port has no closure, so this passes
/// `consumer.filter.commonFilter` through a `FilterFn` that carries no context.
const android_filter: consumer.filter.FilterFn = .{
    .context = null,
    .filter = androidFilterCall,
};

/// The filter call, which is the consumer half's own common filter.
fn androidFilterCall(
    _: ?*anyopaque,
    node: NodeRef,
) consumer.tree.QueryError!consumer.filter.FilterResult {
    return consumer.filter.commonFilter(node);
}

/// The tree one adapter holds, its id map, and its last failure.
///
/// The value owns the tree and both maps of the id map, and it owns neither a
/// Java object nor a handler: the host and both handlers arrive on the call that
/// needs them. `create` and `free` are the two halves a C handle uses, and
/// `init` and `deinit` are the same two halves for a value a caller owns.
pub const AndroidAdapter = struct {
    /// The allocator that grows the native tree and both maps of the id map.
    /// Callback handles and retained metadata use their own captured allocators.
    gpa: Allocator,

    /// The tree, or `null` while the adapter has not been activated.
    tree: ?Tree,
    /// Owns the toolkit strings borrowed by both native tree snapshots.
    metadata_owners: c_tree_update.LiveMetadataOwners = .{},

    /// Whether an activation handler has already been asked.
    ///
    /// **The handler is asked at most once**, which is upstream's rule: it calls
    /// `request_initial_tree` once per adapter at `AK/android/src/adapter.rs:218`.
    /// Without this, an application that has no tree yet would be asked again on
    /// every platform call, and `include/zaccesskit.h:5789` promises the handler
    /// belongs to the call that passed it rather than to the adapter.
    activation_asked: bool = false,

    /// The two-way map between a virtual view id and a node.
    id_map: NodeIdMap,

    /// The last failure any call reported, for a caller that wants to know why a
    /// `null` came back. It is cleared at the start of every entry point, so it
    /// answers the most recent call and never an older one.
    last_error: ?Error = null,

    /// An adapter with no tree, ready for an activation handler to fill.
    ///
    /// `error.OutOfMemory` leaves nothing allocated: the id map's own `init`
    /// releases its half-grown maps on the way out.
    pub fn init(gpa: Allocator) Allocator.Error!AndroidAdapter {
        return .{
            .gpa = gpa,
            .tree = null,
            .id_map = try NodeIdMap.init(gpa, 0),
        };
    }

    /// An adapter in a block the C header can hold, or `null`.
    ///
    /// This is what `accesskit_android_adapter_new` returns. The block comes
    /// from `allocation.create` because `accesskit_android_adapter_free` releases
    /// it through the declared allocator.
    pub fn create(gpa: Allocator) Error!?*AndroidAdapter {
        const block = allocation.create(AndroidAdapter) catch return error.OutOfMemory;
        const built = init(gpa) catch {
            allocation.release(@ptrCast(@alignCast(block)));
            return error.OutOfMemory;
        };
        block.* = built;
        return block;
    }

    /// Releases the tree and both maps of the id map, and the block itself.
    ///
    /// This is `accesskit_android_adapter_free`. It must run exactly once.
    pub fn free(self: *AndroidAdapter) void {
        self.deinit();
        allocation.release(@ptrCast(@alignCast(self)));
    }

    /// Releases the tree and both maps of the id map.
    ///
    /// A queued-events handle borrows this value, so the caller must have
    /// released every handle first. After the call a read of any field answers
    /// the empty adapter rather than an address that no longer holds one.
    ///
    /// The last line is the reset: `self.*` is one whole `AndroidAdapter` with
    /// `tree` at `null` and `activation_asked` and `last_error` back to the
    /// values `init` gives them. That is the Z030 shape, and the rule reads an
    /// assignment to `self.*` as a plain write rather than as a reset, so this
    /// comment says why the assignment is there. `free` depends on it: it reads
    /// `gpa` after this call to release the block, and `undefined` would make
    /// that a read of undefined memory.
    pub fn deinit(self: *AndroidAdapter) void {
        if (self.tree) |*tree| tree.deinit();
        self.metadata_owners.deinit();
        self.id_map.deinit(self.gpa);
        // SAFETY: every release this value owns has run above, so the reset is
        // the empty adapter a stale read sees. `gpa` keeps its value because the
        // allocator owns no memory, and `free` reads it after this call to
        // release the block.
        const gpa = self.gpa;
        self.* = .{ .gpa = gpa, .tree = null, .id_map = .{ .gpa = gpa } };
    }

    /// Whether an activation handler has answered with a tree.
    ///
    /// This is the answer `updateIfActive` and `performAction` check before
    /// they do anything, and it is what a `null` return to a C caller means.
    pub fn isActive(self: *const AndroidAdapter) bool {
        return self.tree != null;
    }

    /// The tree, or `null` while the adapter is inactive.
    pub fn treeOf(self: *const AndroidAdapter) ?*const Tree {
        if (self.tree) |*tree| return tree;
        return null;
    }

    /// The id map, so a fill can mint virtual ids and a queue can resolve them.
    ///
    /// The borrow ends when the adapter is released. Every call on the returned
    /// pointer is a call on the adapter's own map, and the two have to be the
    /// same map or a queued event could name a different node than the one it
    /// was queued for.
    pub fn idMap(self: *AndroidAdapter) *NodeIdMap {
        return &self.id_map;
    }

    /// Asks the activation handler for a tree, once.
    ///
    /// **A `null` answer is ordinary and means "no tree."** The adapter stays
    /// inactive and the caller answers `null`, and the handler is not called
    /// again until the adapter is released: upstream calls
    /// `request_initial_tree` once per adapter, at `adapter.rs:218`.
    fn ensureActive(
        self: *AndroidAdapter,
        activation_handler: ActivationHandler,
        activation_handler_userdata: ?*anyopaque,
    ) Error!void {
        if (self.tree != null) return;
        if (self.activation_asked) return;
        self.activation_asked = true;

        const produced = activation_handler(activation_handler_userdata) orelse return;
        defer self.metadata_owners.reap(self.treeOf());
        const update = try self.metadata_owners.consume(self.gpa, produced, self.treeOf());
        const built = Tree.init(self.gpa, update, false) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.TreeRejected,
        };
        self.tree = built;
    }

    /// Asks `update_factory` for a tree and hands it to the adapter.
    ///
    /// Answers `null` when the adapter is not active, and **builds nothing on
    /// that path**: `docs/42` section 4.2 records that this is why every adapter
    /// takes a factory rather than an update, so a deferred application does not
    /// build a tree the adapter would discard.
    ///
    /// `error.NullTreeUpdate` is the other shape. A factory that answers `null`
    /// is a contract violation upstream unwraps at `adapter.rs:554`, and it is
    /// **not** the same answer as an inactive adapter. A C caller sees `null` for
    /// both, because that is what the header promises for this function, so the
    /// distinction lives in `last_error` and in this signature rather than in
    /// the return value.
    ///
    /// A change-slot failure returns its first exact `SlotError` after the
    /// update commits and releases the incomplete event queue. The factory's
    /// update is consumed on every path and must not be replayed.
    pub fn updateIfActive(
        self: *AndroidAdapter,
        update_factory: TreeUpdateFactory,
        update_factory_userdata: ?*anyopaque,
    ) Error!?QueuedEvents {
        const active_tree = if (self.tree) |*tree| tree else return null;

        const produced = update_factory(update_factory_userdata) orelse
            return error.NullTreeUpdate;
        defer self.metadata_owners.reap(self.treeOf());
        const update = try self.metadata_owners.consume(self.gpa, produced, self.treeOf());

        var events = QueuedEvents.init(self.gpa, self);
        errdefer events.deinit();

        var context: ChangeContext = .{ .events = &events };
        const handler: consumer.tree.TreeChangeHandler = .{
            .ptr = &context,
            .node_added = nodeAddedSlot,
            .node_updated = nodeUpdatedSlot,
            .node_removed = nodeRemovedSlot,
            .focus_moved = focusMovedSlot,
        };
        active_tree.updateAndProcessChanges(update, &handler) catch |err| {
            // Preserve an earlier slot cause even if the subsequent commit
            // also fails. The consumed update cannot be replayed.
            if (context.append_error) |failure| return failure;
            return err;
        };
        if (context.append_error) |failure| return failure;
        return events;
    }

    /// The `AccessibilityNodeInfo` for `virtual_view_id`, or `null` when there
    /// is no such node.
    ///
    /// The answer is a JNI local reference that belongs to the caller's frame,
    /// which is what `include/zaccesskit.h:5789-5790` promises. On a failure the
    /// reference is released here instead, because the caller receives `null`
    /// and cannot release what it never received.
    pub fn createNodeInfo(
        self: *AndroidAdapter,
        activation_handler: ActivationHandler,
        activation_handler_userdata: ?*anyopaque,
        table: JniTable,
        host: JObject,
        virtual_view_id: JInt,
    ) Error!?JObject {
        try self.ensureActive(activation_handler, activation_handler_userdata);
        const tree = self.tree orelse return null;
        const node = self.nodeFor(tree.stateOf(), virtual_view_id) orelse return null;
        const answer = try self.fillNodeInfo(table, host, virtual_view_id, node);
        return answer;
    }

    /// The `AccessibilityNodeInfo` the focus belongs to, or `null` when the
    /// tree has no focus.
    ///
    /// `focus_type` is the input mode Android asked about. This port answers the
    /// tree's own focus for both values of it: the C surface offers no way to
    /// set a second focus, and `include/zaccesskit.h:5815-5816` names one focus.
    pub fn findFocus(
        self: *AndroidAdapter,
        activation_handler: ActivationHandler,
        activation_handler_userdata: ?*anyopaque,
        table: JniTable,
        host: JObject,
    ) Error!?JObject {
        try self.ensureActive(activation_handler, activation_handler_userdata);
        const tree = self.tree orelse return null;
        const node = tree.stateOf().focus() orelse return null;
        const virtual_id = try self.id_map.getOrCreateJavaId(node);
        const answer = try self.fillNodeInfo(table, host, virtual_id, node);
        return answer;
    }

    /// Obtains one node info for `node`, fills it and answers it.
    ///
    /// The id is minted for `node` if the fill has not named it yet, because
    /// Android's `obtain` takes the virtual id the platform will ask with.
    fn fillNodeInfo(
        self: *AndroidAdapter,
        table: JniTable,
        host: JObject,
        virtual_id: JInt,
        node: NodeRef,
    ) Error!?JObject {
        const info = try java_call.callStaticObjectChecked(
            table,
            node_info_obtain,
            &.{ .{ .l = host }, .{ .i = virtual_id } },
        );
        errdefer table.deleteLocalRef(info);
        try node_mod.populateNodeInfo(self.gpa, table, host, &self.id_map, node, info);
        return info;
    }

    /// Hands `action` to the application and answers the events it produced.
    ///
    /// Answers `null` only when the adapter is not active, which is what
    /// `include/zaccesskit.h:5819-5823` promises. **An active adapter always
    /// answers a queue**, even an empty one: every action's effect arrives as a
    /// tree update, which reaches `updateIfActive` and is where the events come
    /// from, so this call has nothing of its own to raise.
    ///
    /// A virtual view id the map does not name raises no request at all and
    /// answers an empty queue, because Android may hold an id for a node the
    /// application has already dropped.
    pub fn performAction(
        self: *AndroidAdapter,
        action_handler: ActionHandler,
        action_handler_userdata: ?*anyopaque,
        virtual_view_id: JInt,
        action: PlatformAction,
    ) Error!?QueuedEvents {
        const active_tree = if (self.tree) |*tree| tree else return null;

        var events = QueuedEvents.init(self.gpa, self);
        errdefer events.deinit();

        const state = active_tree.stateOf();
        const node = self.nodeFor(state, virtual_view_id) orelse return events;
        const request = try self.buildRequest(state, node, action) orelse return events;
        try self.dispatch(request, action_handler, action_handler_userdata);
        return events;
    }

    /// Delivers a hover at the logical pixel `(x, y)` and answers the events it
    /// produced.
    ///
    /// Answers `null` when the adapter is not active. `x` and `y` are in the host
    /// view's own coordinate space, which is the space the tree root's boxes are
    /// in, so the hit test needs no transform before it starts.
    ///
    /// A motion action the table does not name raises nothing and answers an
    /// empty queue rather than a failure: Android sends several and only three
    /// of them mean something here.
    pub fn onHoverEvent(
        self: *AndroidAdapter,
        activation_handler: ActivationHandler,
        activation_handler_userdata: ?*anyopaque,
        action: JInt,
        x: JFloat,
        y: JFloat,
    ) Error!?QueuedEvents {
        try self.ensureActive(activation_handler, activation_handler_userdata);
        const tree = if (self.tree) |*active| active else return null;

        var events = QueuedEvents.init(self.gpa, self);
        errdefer events.deinit();

        switch (action) {
            values.MOTION_ACTION_HOVER_ENTER, values.MOTION_ACTION_HOVER_MOVE => {
                const point = schema.pointInit(@floatCast(x), @floatCast(y));
                const root = tree.stateOf().root();
                const hit = try geometry.hitTest(
                    self.gpa,
                    root,
                    point,
                    android_filter,
                ) orelse return events;
                try events.append(.simple(values.EVENT_VIEW_HOVER_ENTER, hit.node.id()));
            },
            values.MOTION_ACTION_HOVER_EXIT => {
                try events.append(.simple(values.EVENT_VIEW_HOVER_EXIT, null));
            },
            else => {},
        }
        return events;
    }

    /// The node `virtual_view_id` names, or `null` when it names none.
    ///
    /// `values.HOST_VIEW_ID` names the tree root, because the host view is what
    /// the root hangs off and Android asks for it by that sentinel. Every other
    /// id goes through the map, and an id the map does not hold answers `null`,
    /// which the callers turn into the header's "no such node".
    fn nodeFor(
        self: *const AndroidAdapter,
        state: *const TreeState,
        virtual_view_id: JInt,
    ) ?NodeRef {
        if (virtual_view_id == values.HOST_VIEW_ID) return state.root();
        const id = self.id_map.getAccesskitId(virtual_view_id) orelse return null;
        return state.nodeById(id);
    }

    /// The request `action` becomes on `node`, or `null` when it becomes none.
    ///
    /// `null` is not a failure. It means the platform asked for something this
    /// tree does not offer: an action id the port does not map, a traversal on a
    /// node that holds no text, a collapse on a node with no selection. The
    /// application is told nothing in any of those cases, which is the contract
    /// at `include/zaccesskit.h:1016-1018`: a handler ignores an action it does
    /// not support, so raising nothing is better than raising a wrong one.
    fn buildRequest(
        self: *AndroidAdapter,
        state: *const TreeState,
        node: NodeRef,
        action: PlatformAction,
    ) Error!?schema.ActionRequest {
        const located = state.locateNode(node.id()) orelse return null;
        const target: schema.ActionRequest = .{
            .action = .click,
            .target_tree = located.tree_id,
            .target_node = located.local_id,
            .data = null,
        };
        switch (action) {
            .simple => |android| return try simpleRequest(target, node, android),
            .set_text_selection => |endpoints| {
                var request = target;
                request.action = .set_text_selection;
                request.data = .{ .set_text_selection = .{
                    .anchor = .{
                        .node_id = located.local_id,
                        .character_index = endIndex(endpoints.start),
                    },
                    .focus = .{
                        .node_id = located.local_id,
                        .character_index = endIndex(endpoints.end),
                    },
                } };
                return request;
            },
            .collapse_text_selection => {
                var request = target;
                request.action = .set_text_selection;
                request.data = .{ .set_text_selection = .{
                    .anchor = .{ .node_id = located.local_id, .character_index = 0 },
                    .focus = .{ .node_id = located.local_id, .character_index = 0 },
                } };
                return request;
            },
            .traverse_text => |traverse| return try self.traverseRequest(target, node, traverse),
            .set_progress => |progress| {
                var request = target;
                request.action = .set_value;
                request.data = .{ .numeric_value = @floatCast(progress) };
                return request;
            },
        }
    }

    /// The request a payload-free Android action becomes.
    fn simpleRequest(
        target: schema.ActionRequest,
        node: NodeRef,
        android: JInt,
    ) Error!?schema.ActionRequest {
        if (android == values.ACTION_SCROLL_FORWARD or android == values.ACTION_SCROLL_BACKWARD) {
            var request = target;
            request.action = scrollActionFor(node, android == values.ACTION_SCROLL_FORWARD);
            request.data = .{ .scroll_unit = .page };
            return request;
        }
        for (simple_actions) |row| {
            if (row.android != android) continue;
            var request = target;
            request.action = row.accesskit;
            return request;
        }
        return null;
    }

    /// The request a movement by one granularity becomes.
    ///
    /// AccessKit has no "move the text cursor" action: its 22 members at
    /// `src/schema/action.zig:23-87` name the result rather than the motion, so
    /// a traversal is a `set_text_selection` whose endpoints are the current
    /// selection moved by one step. `extend` keeps the anchor and moves the
    /// focus; without it both ends move, which is what a plain arrow key does.
    fn traverseRequest(
        self: *AndroidAdapter,
        target: schema.ActionRequest,
        node: NodeRef,
        traverse: platform_action.TraverseText,
    ) Error!?schema.ActionRequest {
        _ = self;
        if (!try set_state.hasValue(node)) return null;
        const current = text_query.textSelectionFocus(node) orelse return null;
        const moved = try moveByGranularity(current, traverse) orelse return null;
        const anchor = if (traverse.extend)
            text_query.textSelectionAnchor(node) orelse current
        else
            moved;

        var request = target;
        request.action = .set_text_selection;
        request.data = .{ .set_text_selection = .{
            .anchor = text_position.toRaw(anchor),
            .focus = text_position.toRaw(moved),
        } };
        return request;
    }

    /// Hands one request to the application by transfer.
    ///
    /// **The callback owns the request from this call and must release it with
    /// `accesskit_action_request_free` before it returns, on every path out.** A
    /// callback that stores the pointer has a use-after-free and one that
    /// releases it twice has a double free. Nothing after this call releases the
    /// request.
    ///
    /// The borrowed input remains owned by its caller. The boundary creates an
    /// independent request and payload through `allocation.allocator()`, matching
    /// `accesskit_action_request_free`. Failure calls no handler and leaks nothing.
    fn dispatch(
        self: *AndroidAdapter,
        request: schema.ActionRequest,
        action_handler: ActionHandler,
        action_handler_userdata: ?*anyopaque,
    ) Error!void {
        _ = self;
        const built = try boundary.createActionRequest(allocation.allocator(), request);
        action_request.callActionHandler(action_handler, built, action_handler_userdata);
    }
};

/// Failures a change slot can retain without an error return path.
pub const SlotError = Allocator.Error || schema.NarrowError ||
    node_id_map.Error || consumer.tree.QueryError;

/// The context the four change slots share.
///
/// The consumer half hands every slot the same `ptr`, so the queue and the
/// error an append raised travel together. Neither is owned: the queue is a
/// value on `updateIfActive`'s stack and the error is the same.
const ChangeContext = struct {
    /// Where the slots append.
    events: *QueuedEvents,
    /// First exact slot failure. Later slots do no queue work after it is set.
    append_error: ?SlotError = null,
};

/// A newly added node preserves the subtree event.
fn nodeAddedSlot(ptr: *anyopaque, _: NodeRef) void {
    appendContentChanged(ptr);
}

/// A changed included node reports its scroll payload before the subtree event.
fn nodeUpdatedSlot(ptr: *anyopaque, old: NodeRef, new: NodeRef) void {
    const context: *ChangeContext = @ptrCast(@alignCast(ptr));
    if (context.append_error != null) return;
    appendScrollChanged(context, old, new) catch |err| {
        context.append_error = err;
        return;
    };
    appendContentChanged(ptr);
}

/// Owns no node reference: only scalar ids and dimensions reach the queue.
fn appendScrollChanged(context: *ChangeContext, old: NodeRef, new: NodeRef) SlotError!void {
    if (try android_filter.call(old) != .include) return;
    if (try android_filter.call(new) != .include) return;

    const old_x = try node_mod.scrollX(old);
    const new_x = try node_mod.scrollX(new);
    const old_y = try node_mod.scrollY(old);
    const new_y = try node_mod.scrollY(new);
    var x: ?queued_events.ScrollDimension = null;
    var y: ?queued_events.ScrollDimension = null;
    if (old_x) |previous| {
        if (new_x) |current| {
            if (current != previous) x = .{
                .current = current,
                .delta = try scrollDelta(previous, current),
                .max = try node_mod.maxScrollX(new),
            };
        }
    }
    if (old_y) |previous| {
        if (new_y) |current| {
            if (current != previous) y = .{
                .current = current,
                .delta = try scrollDelta(previous, current),
                .max = try node_mod.maxScrollY(new),
            };
        }
    }
    if (x == null and y == null) return;
    const node = if (consumer.node_ref.hierarchy.isRoot(new)) null else new.id();
    if (node != null) _ = try context.events.adapter.idMap().getOrCreateJavaId(new);
    try context.events.append(.{ .scrolled = .{ .node = node, .x = x, .y = y } });
}

/// Two `JInt` offsets may have a delta outside `JInt`, but never outside `i64`.
fn scrollDelta(previous: JInt, current: JInt) schema.NarrowError!JInt {
    const delta = @as(i64, current) - @as(i64, previous);
    return std.math.cast(JInt, delta) orelse error.OutOfRange;
}

/// One node the update removed, which is the site `AK/android/src/adapter.rs:196`
/// emits from.
fn nodeRemovedSlot(ptr: *anyopaque, _: NodeRef) void {
    appendContentChanged(ptr);
}

/// The focus moved, and only the new endpoint matters.
///
/// `docs/42` section 4.5 records that all four adapters ignore the old endpoint,
/// because a focus loss has nothing to report. A `null` new endpoint therefore
/// queues nothing.
fn focusMovedSlot(ptr: *anyopaque, _: ?NodeRef, new: ?NodeRef) void {
    const context: *ChangeContext = @ptrCast(@alignCast(ptr));
    if (context.append_error != null) return;
    const node = new orelse return;
    const event = QueuedEvent.simple(values.EVENT_VIEW_ACCESSIBILITY_FOCUSED, node.id());
    context.events.append(event) catch |err| {
        context.append_error = err;
    };
}

/// Appends the one subtree content change every node slot shares.
fn appendContentChanged(ptr: *anyopaque) void {
    const context: *ChangeContext = @ptrCast(@alignCast(ptr));
    if (context.append_error != null) return;
    const event = QueuedEvent.contentChanged(null, values.CONTENT_CHANGE_TYPE_SUBTREE);
    context.events.append(event) catch |err| {
        context.append_error = err;
    };
}

/// The character index a Java endpoint names, as a `usize`.
///
/// A negative endpoint is not a position: Android clamps the selection to the
/// text it knows, and a negative one means the platform did not supply it. The
/// answer is `0`, which is the only index a document always has.
fn endIndex(value: JInt) usize {
    if (value < 0) return 0;
    return @intCast(value);
}

/// The AccessKit action a scroll id becomes on `node`.
///
/// Android's two scroll actions do not say which way to scroll; the node's own
/// scroll properties do. A node that scrolls horizontally and not vertically
/// scrolls sideways, and every other node scrolls down or up. **A node that
/// scrolls neither answers `.scroll_down`**, which is the direction a page
/// scrolls when nothing in the tree says otherwise.
fn scrollActionFor(node: NodeRef, forward: bool) schema.Action {
    const horizontal = properties.scrollX(node) != null;
    const vertical = properties.scrollY(node) != null;
    if (horizontal and !vertical) {
        return if (forward) .scroll_right else .scroll_left;
    }
    return if (forward) .scroll_down else .scroll_up;
}

/// The position `traverse` moves `current` to, or `null` when the node holds no
/// text to move through.
///
/// The four granularities are the four `MOVEMENT_GRANULARITY_*` values and each
/// has a forward and a backward call, so the table below is the whole movement
/// vocabulary. The walk is over `movement_steps`, whose length is
/// `movement_step_count`.
fn moveByGranularity(
    current: Position,
    traverse: platform_action.TraverseText,
) Error!?Position {
    for (movement_steps) |step| {
        if (step.granularity != traverse.granularity) continue;
        const forward = traverse.direction > 0;
        const moved = if (forward) step.forward(current) else step.backward(current);
        const answer = try moved;
        return answer;
    }
    return null;
}

/// How many granularity movements the table holds.
pub const movement_step_count = 4;

/// One granularity and the two calls that move by it.
const MovementStep = struct {
    /// The `MOVEMENT_GRANULARITY_*` value this row answers.
    granularity: JInt,
    /// The call that moves forward by one step.
    forward: *const fn (Position) consumer.tree.QueryError!Position,
    /// The call that moves backward by one step.
    backward: *const fn (Position) consumer.tree.QueryError!Position,
};

/// Every movement one traversal can ask for.
pub const movement_steps = [movement_step_count]MovementStep{
    .{
        .granularity = values.MOVEMENT_GRANULARITY_CHARACTER,
        .forward = text_position.forwardToCharacterEnd,
        .backward = text_position.backwardToCharacterStart,
    },
    .{
        .granularity = values.MOVEMENT_GRANULARITY_WORD,
        .forward = text_position_motion.forwardToWordEnd,
        .backward = text_position_motion.backwardToWordStart,
    },
    .{
        .granularity = values.MOVEMENT_GRANULARITY_LINE,
        .forward = text_position_motion.forwardToLineEnd,
        .backward = text_position_motion.backwardToLineStart,
    },
    .{
        .granularity = values.MOVEMENT_GRANULARITY_PARAGRAPH,
        .forward = text_position_motion.forwardToParagraphEnd,
        .backward = text_position_motion.backwardToParagraphStart,
    },
};

comptime {
    // Every simple row names an action the port maps, and every action the
    // Android ids name is in the table or is a scroll the node decides. A row
    // added for an id the decoder already handles differently would be two rules
    // for one input.
    for (simple_actions) |row| {
        if (row.accesskit == .scroll_up or row.accesskit == .scroll_down or
            row.accesskit == .scroll_left or row.accesskit == .scroll_right)
        {
            @compileError("a scroll action belongs to scrollActionFor, not the table");
        }
    }
    // The two scroll ids are resolved by node, so neither may appear in the
    // table as well.
    for (simple_actions) |row| {
        if (row.android == values.ACTION_SCROLL_FORWARD or
            row.android == values.ACTION_SCROLL_BACKWARD)
        {
            @compileError("a scroll id belongs to scrollActionFor, not the table");
        }
    }
    // The four granularities in `values.zig` are the four this table answers.
    if (movement_step_count != 4) @compileError("the map gives four movement granularities");
}

comptime {
    // `endIndex` narrows a non-negative `JInt` to a `usize`. That is safe on
    // every target the port claims for Android because the two are the same
    // width and the value has already been checked non-negative, and this
    // assertion is the record of that argument rather than a comment claiming
    // it.
    if (@bitSizeOf(JInt) > @bitSizeOf(usize)) {
        @compileError("endIndex assumes a JInt fits in a usize");
    }
}
// --- Tests --------------------------------------------------------------------

const CallbackRequestFixture = struct {
    store: [512]u8 align(8) = undefined,
    used: usize = 0,
    starts: [4]?*anyopaque = @splat(null),
    allocs: usize = 0,
    frees: usize = 0,
    calls: usize = 0,
    source: []u8,
    independent: bool = false,

    fn alloc(size: usize, context: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *CallbackRequestFixture = @ptrCast(@alignCast(context.?));
        if (self.allocs == self.starts.len) return null;
        const start = std.mem.alignForward(usize, self.used, 8);
        if (size > self.store.len -| start) return null;
        const ptr: *anyopaque = self.store[start..][0..size].ptr;
        self.used = start + size;
        self.starts[self.allocs] = ptr;
        self.allocs += 1;
        return ptr;
    }

    fn free(ptr: ?*anyopaque, context: ?*anyopaque) callconv(.c) void {
        const self: *CallbackRequestFixture = @ptrCast(@alignCast(context.?));
        for (&self.starts) |*start| {
            if (start.* == ptr and ptr != null) {
                start.* = null;
                self.frees += 1;
                return;
            }
        }
    }

    fn call(request: *boundary.CActionRequest, context: ?*anyopaque) callconv(.c) void {
        const self: *CallbackRequestFixture = @ptrCast(@alignCast(context.?));
        self.calls += 1;
        const text = request.data.value.payload.value.?;
        self.source[0] = 'X';
        self.independent = @intFromPtr(text) != @intFromPtr(self.source.ptr) and
            std.mem.eql(u8, std.mem.span(text), "value") and
            request.action == .set_value and request.target_node.value == 73;
        schema.cActionRequestDeinit(allocation.allocator(), request);
        allocation.allocator().destroy(request);
    }
};

test "Android producer callback owns an independent value in the configured C domain" {
    // Drive the actual producer; the pair observes raw-pointer teardown without
    // freeing invalid pointers, so the old header recipe fails an assertion.
    var adapter = try AndroidAdapter.init(allocation.allocator());
    defer adapter.deinit();
    var source: [5]u8 = "value".*;
    var fixture: CallbackRequestFixture = .{ .source = &source };
    allocation.installAllocator(CallbackRequestFixture.alloc, CallbackRequestFixture.free, &fixture);
    defer allocation.installAllocator(null, null, null);
    try adapter.dispatch(.{
        .action = .set_value,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 73 },
        .data = .{ .value = &source },
    }, CallbackRequestFixture.call, &fixture);
    try testing.expectEqual(@as(usize, 1), fixture.calls);
    try testing.expect(fixture.independent);
    try testing.expectEqual(fixture.allocs, fixture.frees);
    try testing.expectEqualSlices(u8, "Xalue", &source);
}

test "Android producer InteriorNul preserves borrowed bytes and leaves no live C allocation" {
    var adapter = try AndroidAdapter.init(allocation.allocator());
    defer adapter.deinit();
    var source: [5]u8 = "va\x00ue".*;
    var fixture: CallbackRequestFixture = .{ .source = &source };
    allocation.installAllocator(CallbackRequestFixture.alloc, CallbackRequestFixture.free, &fixture);
    defer allocation.installAllocator(null, null, null);
    try testing.expectError(error.InteriorNul, adapter.dispatch(.{
        .action = .set_value,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 73 },
        .data = .{ .value = &source },
    }, CallbackRequestFixture.call, &fixture));
    try testing.expectEqual(@as(usize, 0), fixture.calls);
    try testing.expectEqual(fixture.allocs, fixture.frees);
    try testing.expectEqualSlices(u8, "va\x00ue", &source);
}

/// What one dispatched request carried, reached through the handler's userdata.
///
/// `boundary.ActionHandler` takes one `?*anyopaque`, so a recorder travels
/// through it rather than being captured. The handler releases the request it is
/// handed, which is the rule the type states and the only release there is.
const ActionProbe = struct {
    /// How many requests arrived.
    calls: usize = 0,
    /// The action of the last request.
    action: schema.Action = .click,
    /// The target node of the last request.
    target: schema.NodeId = .{ .value = 0 },
    /// The tree of the last request.
    target_tree: schema.TreeId = schema.tree_id_root,
    /// Whether the last request carried a payload.
    has_payload: bool = false,
    /// The numeric payload of the last request, for the two actions that carry
    /// one as a plain number.
    numeric: f64 = 0,
    /// The scroll unit of the last request.
    scroll_unit: schema.ScrollUnit = .item,
    /// The selection of the last request.
    selection: schema.TextSelection = .{
        .anchor = .{ .node_id = .{ .value = 0 }, .character_index = 0 },
        .focus = .{ .node_id = .{ .value = 0 }, .character_index = 0 },
    },

    /// Reads one request, then releases its payload and raw outer allocation
    /// through the configured C allocator, including payload-free requests.
    fn take(self: *ActionProbe, request: *boundary.CActionRequest) void {
        defer allocation.allocator().destroy(request);
        defer schema.cActionRequestDeinit(allocation.allocator(), request);
        self.calls += 1;
        self.action = request.action;
        self.target = request.target_node;
        self.target_tree = request.target_tree;
        self.has_payload = request.data.has_value;
        if (!request.data.has_value) return;

        switch (@as(schema.ActionDataTag, @enumFromInt(request.data.value.tag))) {
            .numeric_value => {
                self.numeric = request.data.value.payload.numeric_value;
            },
            .scroll_unit => {
                self.scroll_unit = request.data.value.payload.scroll_unit;
            },
            .set_text_selection => {
                self.selection = request.data.value.payload.set_text_selection;
            },
            else => {},
        }
    }
};

/// A one-node tree update, which is the smallest `consumer.tree.Tree` accepts.
fn rootUpdate(gpa: Allocator) std.mem.Allocator.Error!schema.TreeUpdate {
    var update: schema.TreeUpdate = .{
        .nodes = .empty,
        .tree = schema.TreeInfo.init(.{ .value = 1 }),
        .tree_id = schema.tree_id_root,
        .focus = .{ .value = 1 },
    };
    try update.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .button));
    return update;
}

/// An adapter holding a one-node tree, released with `deinit`.
fn activeAdapter(gpa: Allocator) consumer.tree.UpdateError!AndroidAdapter {
    var adapter = try AndroidAdapter.init(gpa);
    errdefer adapter.deinit();
    adapter.tree = try Tree.init(gpa, try rootUpdate(gpa), false);
    return adapter;
}

/// The state of the tree `adapter` holds, which the fixture has already filled.
fn activeState(adapter: *AndroidAdapter) error{NoActiveTree}!*const TreeState {
    const tree = adapter.treeOf() orelse return error.NoActiveTree;
    return tree.stateOf();
}

/// The queue one call answered, which an active fixture always produces.
fn queueOrFail(maybe_events: ?QueuedEvents) error{NoQueueBuilt}!QueuedEvents {
    return maybe_events orelse error.NoQueueBuilt;
}

test "an adapter with no tree reports itself inactive" {
    const gpa = testing.allocator;
    var adapter = try AndroidAdapter.init(gpa);
    defer adapter.deinit();

    try testing.expect(!adapter.isActive());
    try testing.expect(adapter.treeOf() == null);
}

test "an adapter holding a tree reports itself active and answers it" {
    const gpa = testing.allocator;
    var adapter = try activeAdapter(gpa);
    defer adapter.deinit();

    try testing.expect(adapter.isActive());
    try testing.expect(adapter.treeOf() != null);
    const state = try activeState(&adapter);
    try testing.expectEqual(@as(u64, 1), state.rootId().local.value);
}

test "every simple action id becomes the AccessKit action the table names" {
    // The walk is over the five rows of `simple_actions`, so
    // `simple_action_count` is the bound, and reading the expectation out of the
    // same table would compare the code with itself, so it is a literal here.
    const expected = [_]schema.Action{
        .click,
        .focus,
        .blur,
        .set_text_selection,
        .set_value,
    };
    try testing.expectEqual(expected.len, simple_actions.len);

    const gpa = testing.allocator;
    var adapter = try activeAdapter(gpa);
    defer adapter.deinit();
    const state = try activeState(&adapter);
    const node = state.root();

    for (simple_actions, expected) |row, want| {
        const maybe_request = try adapter.buildRequest(
            state,
            node,
            .{ .simple = row.android },
        );
        const request = maybe_request orelse return error.NoRequestBuilt;
        try testing.expectEqual(want, request.action);
        try testing.expectEqual(@as(u64, 1), request.target_node.value);
        try testing.expectEqual(schema.tree_id_root, request.target_tree);
    }
}

test "an action id the port does not map becomes no request at all" {
    const gpa = testing.allocator;
    var adapter = try activeAdapter(gpa);
    defer adapter.deinit();
    const state = try activeState(&adapter);
    const node = state.root();

    // `null` is not a failure: the application is told nothing, which is the
    // contract at `include/zaccesskit.h:1016-1018`.
    try testing.expectEqual(
        @as(?schema.ActionRequest, null),
        try adapter.buildRequest(state, node, .{ .simple = 0x4242 }),
    );
}

test "a scroll action follows the node's own scroll properties" {
    const gpa = testing.allocator;
    var adapter = try activeAdapter(gpa);
    defer adapter.deinit();
    const state = try activeState(&adapter);
    const node = state.root();

    // A node that states no scroll property scrolls down, which is the direction
    // a page moves when nothing in the tree says otherwise.
    try testing.expectEqual(
        schema.Action.scroll_down,
        scrollActionFor(node, true),
    );
    try testing.expectEqual(
        schema.Action.scroll_up,
        scrollActionFor(node, false),
    );
}

test "a scroll action carries the page unit the platform means" {
    const gpa = testing.allocator;
    var adapter = try activeAdapter(gpa);
    defer adapter.deinit();
    var probe: ActionProbe = .{};
    const state = try activeState(&adapter);
    const node = state.root();
    _ = try adapter.idMap().getOrCreateJavaId(node);

    var events = try queueOrFail(try adapter.performAction(
        recordingActionHandler,
        &probe,
        values.HOST_VIEW_ID,
        .{ .simple = values.ACTION_SCROLL_FORWARD },
    ));
    defer events.deinit();

    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(schema.Action.scroll_down, probe.action);
    try testing.expect(probe.has_payload);
    try testing.expectEqual(schema.ScrollUnit.page, probe.scroll_unit);
}

test "a set-progress action becomes a numeric value on the target node" {
    const gpa = testing.allocator;
    var adapter = try activeAdapter(gpa);
    defer adapter.deinit();
    var probe: ActionProbe = .{};
    const state = try activeState(&adapter);
    const node = state.root();
    _ = try adapter.idMap().getOrCreateJavaId(node);

    var events = try queueOrFail(try adapter.performAction(
        recordingActionHandler,
        &probe,
        values.HOST_VIEW_ID,
        .{ .set_progress = 0.5 },
    ));
    defer events.deinit();

    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(schema.Action.set_value, probe.action);
    try testing.expectEqual(@as(f64, 0.5), probe.numeric);
}

test "a selection action carries the two endpoints the bundle named" {
    const gpa = testing.allocator;
    var adapter = try activeAdapter(gpa);
    defer adapter.deinit();
    var probe: ActionProbe = .{};
    const state = try activeState(&adapter);
    const node = state.root();
    _ = try adapter.idMap().getOrCreateJavaId(node);

    var events = try queueOrFail(try adapter.performAction(
        recordingActionHandler,
        &probe,
        values.HOST_VIEW_ID,
        .{ .set_text_selection = .{ .start = 3, .end = 7 } },
    ));
    defer events.deinit();

    try testing.expectEqual(schema.Action.set_text_selection, probe.action);
    try testing.expectEqual(@as(usize, 3), probe.selection.anchor.character_index);
    try testing.expectEqual(@as(usize, 7), probe.selection.focus.character_index);
}

test "a collapse becomes a caret at the start of the document" {
    const gpa = testing.allocator;
    var adapter = try activeAdapter(gpa);
    defer adapter.deinit();
    var probe: ActionProbe = .{};
    const state = try activeState(&adapter);
    const node = state.root();
    _ = try adapter.idMap().getOrCreateJavaId(node);

    var events = try queueOrFail(try adapter.performAction(
        recordingActionHandler,
        &probe,
        values.HOST_VIEW_ID,
        .collapse_text_selection,
    ));
    defer events.deinit();

    try testing.expectEqual(schema.Action.set_text_selection, probe.action);
    try testing.expectEqual(@as(usize, 0), probe.selection.anchor.character_index);
    try testing.expectEqual(@as(usize, 0), probe.selection.focus.character_index);
}

test "a negative selection endpoint becomes the start of the document" {
    // Android clamps a selection to the text it knows, and a negative endpoint is
    // the platform saying it did not supply one. `-1` as a `usize` would be the
    // largest index a document can hold, so the clamp is not cosmetic.
    try testing.expectEqual(@as(usize, 0), endIndex(-1));
    try testing.expectEqual(@as(usize, 0), endIndex(0));
    try testing.expectEqual(@as(usize, 12), endIndex(12));
}

test "a traversal on a node that states no value raises nothing" {
    // The fixture node declares no value, so there is no text to move through and
    // the request is not built. `null` is the honest answer rather than a caret
    // at an offset the node has no text for.
    const gpa = testing.allocator;
    var adapter = try activeAdapter(gpa);
    defer adapter.deinit();
    var probe: ActionProbe = .{};
    const state = try activeState(&adapter);
    const node = state.root();
    _ = try adapter.idMap().getOrCreateJavaId(node);

    var events = try queueOrFail(try adapter.performAction(
        recordingActionHandler,
        &probe,
        values.HOST_VIEW_ID,
        .{ .traverse_text = .{
            .granularity = values.MOVEMENT_GRANULARITY_WORD,
            .direction = 1,
            .extend = false,
        } },
    ));
    defer events.deinit();

    try testing.expectEqual(@as(usize, 0), probe.calls);
}

test "an action on a node the map never named raises nothing" {
    const gpa = testing.allocator;
    var adapter = try activeAdapter(gpa);
    defer adapter.deinit();
    var probe: ActionProbe = .{};

    var events = try queueOrFail(try adapter.performAction(
        recordingActionHandler,
        &probe,
        99,
        .{ .simple = values.ACTION_CLICK },
    ));
    defer events.deinit();

    try testing.expectEqual(@as(usize, 0), probe.calls);
    // The queue still exists: an active adapter with nothing to say is not an
    // inactive adapter, and the header tells the two apart.
    try testing.expectEqual(@as(usize, 0), events.len());
}

test "a hover that names no motion action raises nothing" {
    const gpa = testing.allocator;
    var adapter = try activeAdapter(gpa);
    defer adapter.deinit();

    var events = try queueOrFail(try adapter.onHoverEvent(
        unreachableActivation,
        null,
        0,
        0,
        0,
    ));
    defer events.deinit();
    try testing.expectEqual(@as(usize, 0), events.len());
}

test "a hover exit raises one event about the host view" {
    const gpa = testing.allocator;
    var adapter = try activeAdapter(gpa);
    defer adapter.deinit();

    var events = try queueOrFail(try adapter.onHoverEvent(
        unreachableActivation,
        null,
        values.MOTION_ACTION_HOVER_EXIT,
        0,
        0,
    ));
    defer events.deinit();

    try testing.expectEqual(@as(usize, 1), events.len());
    try testing.expectEqual(
        values.EVENT_VIEW_HOVER_EXIT,
        events.events.items[0].simple_event.event_type,
    );
    // The exit names the host view, because the platform is leaving the whole
    // view rather than one node of it.
    try testing.expect(events.events.items[0].simple_event.node == null);
}

test "an inactive adapter refuses an action and a hover without asking for a tree" {
    const gpa = testing.allocator;
    var adapter = try AndroidAdapter.init(gpa);
    defer adapter.deinit();

    try testing.expectEqual(
        @as(?queued_events.AndroidQueuedEvents, null),
        try adapter.performAction(unusedAction, null, 0, .{ .simple = values.ACTION_CLICK }),
    );
    try testing.expectEqual(
        @as(?queued_events.AndroidQueuedEvents, null),
        try adapter.onHoverEvent(
            unreachableActivation,
            null,
            values.MOTION_ACTION_HOVER_EXIT,
            0,
            0,
        ),
    );
}

test "every granularity the port answers has a movement row" {
    // The walk is over the four rows, so `movement_step_count` is the bound, and
    // the four values are the four `values.zig` declares.
    const expected = [_]JInt{
        values.MOVEMENT_GRANULARITY_CHARACTER,
        values.MOVEMENT_GRANULARITY_WORD,
        values.MOVEMENT_GRANULARITY_LINE,
        values.MOVEMENT_GRANULARITY_PARAGRAPH,
    };
    try testing.expectEqual(expected.len, movement_steps.len);
    for (movement_steps, expected) |step, want| {
        try testing.expectEqual(want, step.granularity);
    }
}

test "the node info obtain signature is the one methods.zig records" {
    try testing.expectEqualStrings("obtain", node_info_obtain.name);
    try testing.expectEqualStrings(
        "(Landroid/view/View;I)Landroid/view/accessibility/AccessibilityNodeInfo;",
        node_info_obtain.signature,
    );
    try testing.expect(classes.find(node_info_obtain.class.descriptor) != null);
}

/// The handler a probe test installs, which reads its probe from `userdata`.
///
/// `AGENTS.md` section 3 requires state to be a parameter rather than a capture,
/// and `boundary.ActionHandler` has nowhere to put a capture, so the probe
/// travels through the one pointer the callback already has.
fn recordingActionHandler(
    request: *boundary.CActionRequest,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const probe: *ActionProbe = @ptrCast(@alignCast(userdata orelse return));
    probe.take(request);
}

/// An activation handler that must never be reached, reached through a pointer
/// that is never dereferenced.
///
/// It returns `null` rather than trapping, because `AGENTS.md` section 3 bans a
/// bare `unreachable` and a test that fails this way reports nothing useful.
fn unreachableActivation(_: ?*anyopaque) callconv(.c) ?*CTreeUpdate {
    return null;
}

/// An action handler that must never be reached.
///
/// It does not release the request because it is never given one; see
/// `ActionProbe.handler` for the handler that does.
fn unusedAction(_: *boundary.CActionRequest, _: ?*anyopaque) callconv(.c) void {}

const ScrollSpec = struct {
    x: ?f64 = null,
    y: ?f64 = null,
    max_x: ?f64 = null,
    max_y: ?f64 = null,
    hidden: bool = false,
};

fn scrollNode(gpa: Allocator, spec: ScrollSpec) Allocator.Error!schema.Node {
    var node = schema.Node.init(gpa, .button);
    errdefer node.deinit();
    if (spec.x) |value| try schema.numbers.setScrollX(&node.properties, value);
    if (spec.y) |value| try schema.numbers.setScrollY(&node.properties, value);
    if (spec.max_x) |value| try schema.numbers.setScrollXMax(&node.properties, value);
    if (spec.max_y) |value| try schema.numbers.setScrollYMax(&node.properties, value);
    schema.flags.setHidden(&node.flags, spec.hidden);
    return node;
}

fn scrollTreeUpdate(gpa: Allocator, spec: ScrollSpec, child: bool) Allocator.Error!schema.TreeUpdate {
    var update: schema.TreeUpdate = .{
        .tree = schema.TreeInfo.init(.{ .value = 1 }),
        .focus = .{ .value = 1 },
    };
    errdefer update.deinit(gpa);
    if (child) {
        var root = schema.Node.init(gpa, .button);
        schema.ids_props.setChildren(&root.properties, &.{.{ .value = 2 }}) catch |err| {
            root.deinit();
            return err;
        };
        try update.pushNode(gpa, .{ .value = 1 }, root);
        try update.pushNode(gpa, .{ .value = 2 }, try scrollNode(gpa, spec));
    } else {
        try update.pushNode(gpa, .{ .value = 1 }, try scrollNode(gpa, spec));
    }
    return update;
}

const ScrollFactory = struct {
    handle: ?*c_tree_update.accesskit_tree_update,
    calls: usize = 0,

    fn init(gpa: Allocator, spec: ScrollSpec, child: bool) !ScrollFactory {
        const handle = try c_tree_update.treeUpdateWithFocus(gpa, 1);
        errdefer handle.deinit();
        handle.update = try scrollTreeUpdate(gpa, spec, child);
        return .{ .handle = handle };
    }

    fn deinit(self: *ScrollFactory) void {
        if (self.handle) |handle| handle.deinit();
        self.handle = null;
    }

    fn take(ptr: ?*anyopaque) callconv(.c) ?*CTreeUpdate {
        const self: *ScrollFactory = @ptrCast(@alignCast(ptr orelse return null));
        self.calls += 1;
        const handle = self.handle orelse return null;
        self.handle = null;
        return @ptrCast(handle);
    }
};

fn scrollingAdapter(gpa: Allocator, spec: ScrollSpec, child: bool) !AndroidAdapter {
    var adapter = try AndroidAdapter.init(gpa);
    errdefer adapter.deinit();
    adapter.tree = try Tree.init(gpa, try scrollTreeUpdate(gpa, spec, child), false);
    return adapter;
}

test "scroll updates preserve independent axes maxima absence and subtree events" {
    const Case = struct {
        old: ScrollSpec,
        new: ScrollSpec,
        x: ?queued_events.ScrollDimension,
        y: ?queued_events.ScrollDimension,
    };
    const cases = [_]Case{
        .{ .old = .{ .x = 10 }, .new = .{ .x = 17, .max_x = 90 }, .x = .{ .current = 17, .delta = 7, .max = 90 }, .y = null },
        .{ .old = .{ .y = 12 }, .new = .{ .y = 3 }, .x = null, .y = .{ .current = 3, .delta = -9, .max = null } },
        .{ .old = .{ .x = -2, .y = 4 }, .new = .{ .x = 0, .y = 9, .max_x = 0, .max_y = 30 }, .x = .{ .current = 0, .delta = 2, .max = 0 }, .y = .{ .current = 9, .delta = 5, .max = 30 } },
        .{ .old = .{ .x = 5, .y = 7 }, .new = .{ .x = 5, .y = 7, .max_y = 99 }, .x = null, .y = null },
        .{ .old = .{}, .new = .{ .x = 4, .y = 6 }, .x = null, .y = null },
        .{ .old = .{ .x = 4, .y = 6 }, .new = .{}, .x = null, .y = null },
        .{ .old = .{ .x = 1 }, .new = .{ .x = 2, .hidden = true }, .x = null, .y = null },
        .{ .old = .{ .x = 1, .hidden = true }, .new = .{ .x = 2 }, .x = null, .y = null },
    };
    for (cases) |case| {
        var adapter = try scrollingAdapter(testing.allocator, case.old, false);
        defer adapter.deinit();
        var factory = try ScrollFactory.init(testing.allocator, case.new, false);
        defer factory.deinit();
        var events = try queueOrFail(try adapter.updateIfActive(ScrollFactory.take, &factory));
        defer events.deinit();
        var scrolled: usize = 0;
        var subtree: usize = 0;
        for (events.events.items) |event| switch (event) {
            .scrolled => |payload| {
                scrolled += 1;
                try testing.expect(payload.node == null);
                try testing.expectEqualDeep(case.x, payload.x);
                try testing.expectEqualDeep(case.y, payload.y);
            },
            .content_changed => |payload| {
                subtree += 1;
                try testing.expect(payload.node == null);
                try testing.expectEqual(values.CONTENT_CHANGE_TYPE_SUBTREE, payload.content_change_types);
            },
            else => return error.UnexpectedEvent,
        };
        try testing.expectEqual(@as(usize, if (case.x != null or case.y != null) 1 else 0), scrolled);
        try testing.expectEqual(@as(usize, 1), subtree);
        try testing.expectEqual(@as(usize, 1), factory.calls);
        try testing.expectEqual(@as(usize, 0), adapter.idMap().count());
    }
}

test "nonroot scroll update mints its virtual id before any node info fill" {
    var adapter = try scrollingAdapter(testing.allocator, .{ .x = 2 }, true);
    defer adapter.deinit();
    var factory = try ScrollFactory.init(testing.allocator, .{ .x = 9 }, true);
    defer factory.deinit();
    var events = try queueOrFail(try adapter.updateIfActive(ScrollFactory.take, &factory));
    defer events.deinit();
    const state = try activeState(&adapter);
    const id = consumer.tree_index.FullNodeId.init(.{ .value = 2 }, .init(0));
    var saw_scroll = false;
    for (events.events.items) |event| switch (event) {
        .scrolled => |payload| {
            saw_scroll = true;
            try testing.expectEqualDeep(@as(?consumer.tree_index.FullNodeId, id), payload.node);
            try testing.expect(adapter.idMap().getJavaId(id) != null);
        },
        else => {},
    };
    try testing.expect(saw_scroll);
    try testing.expectEqual(@as(usize, 1), adapter.idMap().count());
    try testing.expectEqual(@as(?f64, 9), properties.scrollX(state.nodeById(id).?));
}

test "checked scroll delta and maxima failures return exact OutOfRange after commit" {
    const cases = [_][2]ScrollSpec{
        .{ .{ .x = -2147483648.0 }, .{ .x = 2147483647.0 } },
        .{ .{ .y = 2147483647.0 }, .{ .y = -2147483648.0 } },
        .{ .{ .x = 1 }, .{ .x = 2, .max_x = 2147483648.0 } },
        .{ .{ .y = 1 }, .{ .y = 2, .max_y = 2147483648.0 } },
    };
    for (cases) |case| {
        var adapter = try scrollingAdapter(testing.allocator, case[0], false);
        defer adapter.deinit();
        var factory = try ScrollFactory.init(testing.allocator, case[1], false);
        defer factory.deinit();
        try testing.expectError(error.OutOfRange, adapter.updateIfActive(ScrollFactory.take, &factory));
        const node = (try activeState(&adapter)).root();
        try testing.expectEqual(case[1].x, properties.scrollX(node));
        try testing.expectEqual(case[1].y, properties.scrollY(node));
        try testing.expectEqual(@as(usize, 1), factory.calls);
        try testing.expect(factory.handle == null);
    }
}

test "exhausted nonroot ids return exact VirtualIdsExhausted after committed scroll" {
    var adapter = try scrollingAdapter(testing.allocator, .{ .x = 1 }, true);
    defer adapter.deinit();
    adapter.idMap().next_virtual_id = @as(i64, node_id_map.largest_virtual_id) + 1;
    var factory = try ScrollFactory.init(testing.allocator, .{ .x = 3 }, true);
    defer factory.deinit();
    try testing.expectError(error.VirtualIdsExhausted, adapter.updateIfActive(ScrollFactory.take, &factory));
    const id = consumer.tree_index.FullNodeId.init(.{ .value = 2 }, .init(0));
    try testing.expectEqual(@as(?f64, 3), properties.scrollX((try activeState(&adapter)).nodeById(id).?));
    try testing.expectEqual(@as(usize, 0), adapter.idMap().count());
}

test "a filter cycle preserves exact TreeCycle after the update commits" {
    var adapter = try scrollingAdapter(testing.allocator, .{ .x = 1 }, false);
    defer adapter.deinit();
    // Corrupt only the previous snapshot: the working update remains valid.
    // The producer must filter the old node, retain TreeCycle, then return it
    // after the valid new snapshot has committed.
    if (adapter.tree) |*tree| {
        tree.state.nodes.getPtr(tree.state.root_id).?.parent_and_index = .{
            .parent_id = tree.state.root_id,
            .index = 0,
        };
    }
    var factory = try ScrollFactory.init(testing.allocator, .{ .x = 4 }, false);
    defer factory.deinit();
    try testing.expectError(error.TreeCycle, adapter.updateIfActive(ScrollFactory.take, &factory));
    try testing.expectEqual(@as(?f64, 4), properties.scrollX((try activeState(&adapter)).root()));
    try testing.expectEqual(@as(usize, 1), factory.calls);
}

test "queue allocation failure retains OutOfMemory after committed scroll update" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var adapter = try scrollingAdapter(testing.allocator, .{ .x = 1 }, false);
    defer adapter.deinit();
    var factory = try ScrollFactory.init(testing.allocator, .{ .x = 5 }, false);
    defer factory.deinit();
    adapter.gpa = gpa;
    // Unknown allocator domains require one node-array migration before the slots.
    // The tree keeps testing.allocator; fail the next allocation, the root event queue.
    failing.fail_index = failing.alloc_index + 1;
    try testing.expectError(error.OutOfMemory, adapter.updateIfActive(ScrollFactory.take, &factory));
    try testing.expectEqual(@as(?f64, 5), properties.scrollX((try activeState(&adapter)).root()));
    try testing.expectEqual(@as(usize, 1), factory.calls);
    try testing.expect(factory.handle == null);
}

test "the first slot failure stops later queue allocation and keeps its exact tag" {
    var old = try scrollingAdapter(testing.allocator, .{ .x = -2147483648.0 }, false);
    defer old.deinit();
    var new = try scrollingAdapter(testing.allocator, .{ .x = 2147483647.0 }, false);
    defer new.deinit();
    var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var events = QueuedEvents.init(failing.allocator(), &new);
    defer events.deinit();
    var context: ChangeContext = .{ .events = &events };
    const old_node = (try activeState(&old)).root();
    const new_node = (try activeState(&new)).root();

    nodeUpdatedSlot(&context, old_node, new_node);
    nodeAddedSlot(&context, new_node);
    nodeRemovedSlot(&context, old_node);
    focusMovedSlot(&context, old_node, new_node);
    try testing.expectEqual(error.OutOfRange, context.append_error.?);
    try testing.expectEqual(@as(usize, 0), events.len());
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "root scroll remains a host event when virtual ids are exhausted" {
    var adapter = try scrollingAdapter(testing.allocator, .{ .x = 1 }, false);
    defer adapter.deinit();
    adapter.idMap().next_virtual_id = @as(i64, node_id_map.largest_virtual_id) + 1;
    var factory = try ScrollFactory.init(testing.allocator, .{ .x = 7 }, false);
    defer factory.deinit();
    var events = try queueOrFail(try adapter.updateIfActive(ScrollFactory.take, &factory));
    defer events.deinit();
    var found = false;
    for (events.events.items) |event| switch (event) {
        .scrolled => |payload| {
            found = true;
            try testing.expect(payload.node == null);
        },
        else => {},
    };
    try testing.expect(found);
    try testing.expectEqual(@as(usize, 0), adapter.idMap().count());
}

test "an exact scroll failure disposes earlier subtree events after the full update commits" {
    var adapter = try scrollingAdapter(testing.allocator, .{ .x = -2147483648.0 }, true);
    defer adapter.deinit();
    var factory = try ScrollFactory.init(testing.allocator, .{ .x = 2147483647.0 }, true);
    defer factory.deinit();
    // The first updated node produces a subtree event before the child fails.
    // The testing allocator detects retaining that incomplete queue buffer.
    try schema.numbers.setNumericValue(
        &factory.handle.?.update.nodes.items[0].node.properties,
        42,
    );
    try testing.expectError(error.OutOfRange, adapter.updateIfActive(ScrollFactory.take, &factory));
    const state = try activeState(&adapter);
    try testing.expectEqual(@as(?f64, 42), properties.numericValue(state.root()));
    const id = consumer.tree_index.FullNodeId.init(.{ .value = 2 }, .init(0));
    try testing.expectEqual(@as(?f64, 2147483647.0), properties.scrollX(state.nodeById(id).?));
    try testing.expectEqual(@as(usize, 1), factory.calls);
}
