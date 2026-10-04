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
//! **What an update produces.** Three of the consumer half's four change slots
//! raise one `EVENT_WINDOW_CONTENT_CHANGED` with
//! `CONTENT_CHANGE_TYPE_SUBTREE`, and `focus_moved` raises the one focus event
//! for the new endpoint. That is the whole of Android's event vocabulary here:
//! `docs/42` section 4.4 records that `AK/android/src/adapter.rs:197` reads
//! `// TODO: other events?` and that this is it.
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
const consumer = @import("../../consumer/root.zig");
const java_call = @import("java_call.zig");
const jni = @import("jni_table.zig");
const node_mod = @import("node.zig");
const node_id_map = @import("node_id_map.zig");
const platform_action = @import("platform_action.zig");
const queued_events = @import("queued_events.zig");
const schema = @import("../../schema/root.zig");
const update_schema = @import("../../schema/update.zig");
const values = @import("values.zig");

const ActionHandler = boundary.ActionHandler;
const ActivationHandler = boundary.ActivationHandler;
const CActionRequest = boundary.CActionRequest;
const TreeUpdateFactory = boundary.TreeUpdateFactory;

const FullNodeId = consumer.tree_index.FullNodeId;
const JInt = values.JInt;
const JFloat = jni.JFloat;
const JniTable = jni.JniTable;
const JObject = jni.JObject;
const JValue = jni.JValue;
const NodeIdMap = node_id_map.NodeIdMap;
const NodeRef = consumer.node_id.NodeRef;
const PlatformAction = platform_action.PlatformAction;
const QueuedEvent = queued_events.QueuedEvent;
const QueuedEvents = queued_events.AndroidQueuedEvents;
const Tree = consumer.tree.Tree;
const TreeState = consumer.tree_state.TreeState;

const geometry = consumer.node_ref.geometry;
const hierarchy = consumer.node_ref.hierarchy;
const predicates = consumer.node_ref.predicates;
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
/// `FillError` is `node.zig`'s set, which already carries the query failures,
/// the narrowing failures, the two JNI failures and the id map's own. The four
/// tags this module adds are the ones only this layer can produce.
pub const Error = consumer.tree.UpdateError || node_mod.FillError ||
    update_schema.ActionDataToCError || error{
        /// The tree-update factory answered `null`. Upstream unwraps the same
        /// value at `AK/android/src/adapter.rs:554`, so a `null` here is a
        /// contract violation and **not** "no tree". `ActivationHandler`
        /// answering `null` is the other shape and is handled as data.
        NullTreeUpdate,

        /// The activation handler handed over a tree the consumer half rejected.
        /// It reaches here through `Tree.init` and carries one of the
        /// `UpdateError` tags, so it is listed rather than named separately.
        TreeRejected,

        /// A change slot could not append its event, so the queue the caller
        /// receives is missing one. The update still committed: the consumer
        /// half commits after the last slot returns and this module cannot
        /// un-commit it.
        TreeEventQueueFailed,
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
const node_info_obtain = java_call.Member{
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
    /// The allocator that grew the tree and both maps of the id map, and the
    /// only one any release goes through. It is `allocation.allocator()` in
    /// every case, because the C header releases the adapter and every block
    /// that leaves through a `CActionRequest` through the declared allocator.
    gpa: Allocator,

    /// The tree, or `null` while the adapter has not been activated.
    tree: ?Tree,

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
        return .{ .gpa = gpa, .tree = null, .id_map = try NodeIdMap.init(gpa, 0) };
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
    pub fn deinit(self: *AndroidAdapter) void {
        if (self.tree) |*tree| tree.deinit();
        self.tree = null;
        self.id_map.deinit(self.gpa);
        self.last_error = null;
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

        const produced = activation_handler(activation_handler_userdata) orelse return;
        // `Tree.init` takes the update by value and releases it on every path,
        // success or failure, so there is no release past this call.
        const built = Tree.init(self.gpa, produced.*, false) catch |err| switch (err) {
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
    pub fn updateIfActive(
        self: *AndroidAdapter,
        update_factory: TreeUpdateFactory,
        update_factory_userdata: ?*anyopaque,
    ) Error!?QueuedEvents {
        if (self.tree == null) return null;

        const produced = update_factory(update_factory_userdata) orelse
            return error.NullTreeUpdate;

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
        self.tree.?.updateAndProcessChanges(produced.*, &handler) catch |err| {
            // A slot that ran out of memory leaves the committed state as it
            // stands; the update is already consumed and cannot be replayed.
            if (context.out_of_memory) return error.OutOfMemory;
            return err;
        };
        if (context.out_of_memory) return error.TreeEventQueueFailed;
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
        return try self.fillNodeInfo(table, host, virtual_view_id, node);
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
        return try self.fillNodeInfo(table, host, virtual_id, node);
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
        if (self.tree == null) return null;

        var events = QueuedEvents.init(self.gpa, self);
        errdefer events.deinit();

        const state = self.tree.?.stateOf();
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
        if (self.tree == null) return null;

        var events = QueuedEvents.init(self.gpa, self);
        errdefer events.deinit();

        switch (action) {
            values.MOTION_ACTION_HOVER_ENTER, values.MOTION_ACTION_HOVER_MOVE => {
                const tree = self.tree.?;
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
        const target = schema.ActionRequest{
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
    /// The block comes from `allocation.create` and the payload from
    /// `schema.actionDataToC`, both through `self.gpa`, which is the C ABI's
    /// declared allocator — the same one `accesskit_action_request_free` uses.
    fn dispatch(
        self: *AndroidAdapter,
        request: schema.ActionRequest,
        action_handler: ActionHandler,
        action_handler_userdata: ?*anyopaque,
    ) Error!void {
        var payload: ?schema.CActionData = null;
        if (request.data) |data| payload = try schema.actionDataToC(self.gpa, data);

        const built = try allocation.create(CActionRequest);
        built.* = .{
            .action = request.action,
            .target_tree = request.target_tree,
            .target_node = request.target_node,
            .data = .{
                .has_value = payload != null,
                .value = payload orelse std.mem.zeroes(schema.CActionData),
            },
        };
        action_request.callActionHandler(action_handler, built, action_handler_userdata);
    }
};

/// The context the four change slots share.
///
/// The consumer half hands every slot the same `ptr`, so the queue and the
/// out-of-memory flag travel together. Neither is owned: the queue is a value on
/// `updateIfActive`'s stack and the flag is the same.
const ChangeContext = struct {
    /// Where the slots append.
    events: *QueuedEvents,
    /// Set when an append failed, which the caller turns into a tag.
    out_of_memory: bool = false,
};

/// One node the update added.
///
/// `docs/42` section 4.4 records that Android names no node in its events, so
/// the node is not read here; the slot exists because the consumer half offers
/// one and a `null` slot would be the port choosing to observe less than
/// upstream does.
fn nodeAddedSlot(ptr: *anyopaque, _: NodeRef) void {
    appendContentChanged(ptr);
}

/// One node the update rewrote.
fn nodeUpdatedSlot(ptr: *anyopaque, _: NodeRef, _: NodeRef) void {
    appendContentChanged(ptr);
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
    const node = new orelse return;
    const event = QueuedEvent.simple(values.EVENT_VIEW_ACCESSIBILITY_FOCUSED, node.id());
    context.events.append(event) catch {
        context.out_of_memory = true;
    };
}

/// Appends the one subtree content change every node slot shares.
fn appendContentChanged(ptr: *anyopaque) void {
    const context: *ChangeContext = @ptrCast(@alignCast(ptr));
    const event = QueuedEvent.contentChanged(null, values.CONTENT_CHANGE_TYPE_SUBTREE);
    context.events.append(event) catch {
        context.out_of_memory = true;
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
        return try moved;
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