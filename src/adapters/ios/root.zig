//! The adapter body of the iOS adapter: the three handle types and the
//! thirteen functions `src/capi/platform.zig` calls under the Apple-mobile
//! guard.
//!
//! Upstream is `accesskit_ios` 0.2.1. `adapter.rs` is 514 lines, `subclass.rs`
//! is 324 and `event.rs` is 270, and this module ports the state machine of
//! `adapter.rs:54-206`, the thirteen entry points of the C crate at
//! `accesskit-c/src/ios.rs`, the event generator of `event.rs:136-271` and the
//! class patching of `subclass.rs:214-262`. The other three files in the
//! directory hold the spellings this module sends: `uikit.zig` the 43
//! `UIAccessibility` identifiers, `selectors.zig` the 36 selector names,
//! `foundation.zig` the 3 UIKit classes and the 8 Foundation types, and
//! `objc.zig` the Objective-C surface the adapter calls through.
//!
//! **What is compiled and tested here.** The whole state machine: the three
//! states at `AK/ios/src/adapter.rs:54-64`, the activation gate at `:97-103`
//! and `:190-206`, the placeholder tree at `:169-186`, the deactivation at
//! `:208-237`, the update protocol at `:398-436`, the event generator at
//! `AK/ios/src/event.rs:136-271`, the point conversion at
//! `AK/ios/src/util.rs:33-40`, and the subclass name and restore logic at
//! `AK/ios/src/subclass.rs:214-262` and `:305-318`. Every one of those runs
//! against a fake platform in the tests below, so the activation gate, the
//! placeholder transition, the event coalescing, the announcements, the focus
//! tracking and the ownership rules are all exercised on this host. Those tests
//! run under `std.testing.allocator`, so a handle a test drops, an update a
//! factory never takes and a static buffer a caller would free are findings the
//! run reports rather than defects a reviewer has to notice.
//!
//! **What needs the real platform.** Every call that leaves this process. The
//! binding layer reaches UIKit and the Objective-C runtime through
//! `std.DynLib`, so nothing here links them: `zig build-exe -target
//! aarch64-ios` fails at `unable to find libSystem system library` because no
//! Apple SDK is installed on this host, which is level 1 of map section 3.4 and
//! no further. So the 43 identifier spellings, the 36 selector spellings, the
//! 13 Objective-C runtime entry points, the six type encodings and the two
//! image paths are all things a Linux compile cannot check. Each is pinned by a
//! test that asserts its exact bytes, and each says in its own doc comment that
//! no Apple SDK was read here.
//!
//! **What a missing weakly linked name means.** Three of the 43 identifiers
//! exist only as `dlsym` strings: `UIAccessibilityPriorityHigh`,
//! `UIAccessibilityPriorityLow` and
//! `UIAccessibilitySpeechAttributeAnnouncementPriority`, which are the three
//! `uikit.identifiers` rows of kind `.weak_link_only`. `objc.zig` resolves each
//! through the address of its storage, and **a null answer is a fallback, not a
//! failure**: an absent priority downgrades the announcement and an absent
//! attribute key posts the plain string, which is the shape
//! `AK/ios/src/util.rs:100-110` uses. So the adapter still asks the question on
//! an operating system that never exported the name, and answers with the older
//! shape. An answer that meant "cannot ask" would be the unsafe one here,
//! because UIKit would then receive no announcement at all.
//!
//! The fourth `runtime.weak_constants` row, `UIAccessibilityTraitToggleButton`,
//! carries the `.no_trait` fallback, and `objc.zig` reads it once through the
//! address its lookup answers, which is the route `AK/ios/src/util.rs:78-86`
//! takes. **Nothing reads the value yet**, because the only reader is the
//! `traits` method of `AK/ios/src/node.rs:124-165` and the node layer is not
//! ported. `objc.zig:2071-2089` is the test that pins the zero bit an absent name
//! answers.
//!
//! **What is blocked, and why.** `blocked` below is the machine-readable
//! record. Two functions and one half of a third are not complete, and none of
//! the three is complete because `AK/ios/src/node.rs`, 1076 lines that this
//! directory has never held, is what produces the objects they must return. The
//! node needs four `UIAccessibility` enumeration values no document under
//! `docs/` records, which is the same reason `uikit.zig:216-284` declares
//! `Notifications`, `Traits`, `ContainerType` and `ScrollDirection` as
//! non-exhaustive enums and no document records a case. `ExpandedStatus` is the
//! fifth and is not among them: `AK/ios/src/util.rs:24-26` writes its three
//! numbers, so `uikit.zig:243-278` holds all three. Every part of the three
//! blocked functions that does not need a platform node is written, is reached by
//! a test, and is named in the record, so the work left is one line in each.
//!
//! **The allocator.** Every allocation goes through `capi/allocation.zig`, the
//! declared allocator of the C ABI, read once when the adapter is created. The
//! thirteen functions have no allocator parameter because `include/zaccesskit.h`
//! gives them none, and the header's promise at `:6459` is that
//! `accesskit_set_allocator` runs before any other entry point, so the pair
//! cannot change under the adapter. A block the C ABI handed this module, which
//! is the `*CTreeUpdate` a tree-update factory returns, is released with
//! `allocation.release`, which is what `accesskit_tree_update_free` is.
//!
//! **The thread.** `include/zaccesskit.h:5901` says the library calls each
//! handler on the main thread, and this module adds no lock of its own. The
//! state is a plain union on one allocation, which is what the upstream
//! `RefCell<State>` protects on one thread only.
//!
//! **The loop bounds.** Four domains are walked: the 9 observed notification
//! names, the 43 `UIAccessibility` identifiers, the events of one update, and
//! the nodes of one subtree walk. Each bound is in the function that walks it:
//! `observed_notification_count` is `uikit.identifiers` filtered by kind, an
//! array length; the identifier scan is `uikit.identifier_count`, an array
//! length; the event list is whatever `ArrayList` grew, which the caller of
//! `append` checks; and the subtree walk is
//! `consumer.tree_state.treeWalkStepBound(node_count)`, the port's own bound
//! for a walk over a tree with a cycle, which the consumer derives and
//! `tree_state.zig:588-605` states.

const std = @import("std");

const boundary = @import("../../capi/boundary.zig");
const allocation = @import("../../capi/allocation.zig");
const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const affine = @import("../../schema/geometry/affine.zig");

const objc = @import("objc.zig");

/// The 3 UIKit classes and the 8 Foundation types the adapter names.
pub const foundation = @import("foundation.zig");
/// The Objective-C runtime surface: the 4 upstream entry points, the 4 weakly
/// linked names, the association policy and the notification centre.
pub const runtime = @import("runtime.zig");
/// The 36 selector spellings in the three groups.
pub const selectors = @import("selectors.zig");
/// The 43 `UIAccessibility` identifier spellings.
pub const uikit = @import("uikit.zig");
/// The node wrapper of `AK/ios/src/node.rs:61-122` and the iOS-only element
/// filter of `AK/ios/src/filters.rs:27-52`. The `PlatformNode` class is not
/// here, so this module holds the half of the node layer that reads no
/// Objective-C object. It is `node_layer` and not `node` because every function
/// below names its node parameter `node`.
pub const node_layer = @import("node.zig");

const testing = std.testing;

const Allocator = std.mem.Allocator;
const FullNodeId = consumer.tree_index.FullNodeId;
const NodeRef = consumer.node_id.NodeRef;
const Tree = consumer.tree.Tree;
const TreeChangeHandler = consumer.tree.TreeChangeHandler;
const FilterFn = consumer.filter.FilterFn;
const tree_walk_step_bound = consumer.tree_state.treeWalkStepBound;

/// One filter verdict, and what a walk that asks for one can report.
const FilterOutcome = consumer.tree.QueryError!consumer.filter.FilterResult;

/// `AK/ios/src/filters.rs:28` re-exports the common filter under the name
/// `filter`, and every walk in this module uses that one. The iOS-only
/// refinement, `filter_for_is_accessibility_element` at
/// `AK/ios/src/filters.rs:27-52`, decides whether one node is an element rather
/// than which nodes are visible, so it belongs to the node layer and not to this
/// module, and `node.zig` is where it is, reached as `node_layer`.
///
/// The port wraps it because `FilterFn.filter` takes the context first and the
/// consumer's takes only the node, and the wrapper asserts the context is
/// `null` rather than dropping it.
fn commonFilter(context: ?*anyopaque, node: NodeRef) FilterOutcome {
    std.debug.assert(context == null);
    return consumer.filter.commonFilter(node);
}

const common_filter: FilterFn = .{ .context = null, .filter = commonFilter };
comptime {
    // Map section 1.3.5 totals: 43 UIKit identifiers, 4 run-time string
    // literals, 19 node selectors, 5 view selectors, 4 Objective-C runtime
    // functions and 17 runtime, UIKit and Foundation items. The 17 are the 11
    // in `foundation` and the 6 in `runtime`.
    if (uikit.identifiers.len != 43) @compileError("the map gives 43 UIKit identifiers");
    if (runtime.weak_constants.len != 4) @compileError("the map gives 4 run-time strings");
    if (runtime.runtime_functions.len != 4) @compileError("the map gives 4 runtime functions");
    if (selectors.countOf(.node) != 19) @compileError("the map gives 19 node selectors");
    if (selectors.countOf(.host_view) != 5) @compileError("the map gives 5 view selectors");
    if (foundation.platform_names.len + 4 + 2 != 17) {
        @compileError("the map gives 17 runtime, UIKit and Foundation items");
    }
}

// --- the blocked record -------------------------------------------------------

/// One symbol of this module that is not complete, and what is missing.
///
/// The record is a table rather than a paragraph because a paragraph is easy to
/// lose: a caller reading `blocked` sees the same three names this module's
/// doc comment names and its tests check.
pub const Blocked = struct {
    /// The Zig symbol, exactly as `src/capi/platform.zig` calls it.
    symbol: [:0]const u8,
    /// What the function does today, in one sentence.
    today: [:0]const u8,
    /// The upstream file and lines that carry the missing half.
    unblocked_by: [:0]const u8,
};

/// How many rows `blocked` holds.
pub const blocked_count = 3;

/// The three symbols this module does not finish.
pub const blocked = [blocked_count]Blocked{
    .{
        .symbol = "iosAdapterAccessibilityElements",
        .today = "It walks the filtered tree and returns an empty NSArray.",
        .unblocked_by = "AK/ios/src/node.rs:393-394, the PlatformNode objects",
    },
    .{
        .symbol = "iosAdapterHitTest",
        .today = "It converts the point and finds the node at it, then returns null.",
        .unblocked_by = "AK/ios/src/node.rs:487-503, the PlatformNode object",
    },
    .{
        .symbol = "iosQueuedEventsRaise",
        .today = "It posts every notification, with a null argument where upstream " ++
            "would pass a node.",
        .unblocked_by = "AK/ios/src/event.rs:44-52, the PlatformNode argument",
    },
};

comptime {
    const Self = @This();
    for (blocked) |row| {
        if (!@hasDecl(Self, row.symbol)) {
            @compileError("a blocked symbol must still be declared");
        }
    }
}

// --- the names this module sends ----------------------------------------------

/// The 9 notifications `AK/ios/src/adapter.rs:105-119` registers.
///
/// The spellings come out of `uikit.identifiers`, which holds the 9 under
/// `.observed_notification` in the map's own order, so this module writes no
/// notification name of its own and cannot disagree with that table. The order
/// is not observable and `observedNotificationNames` says why.
pub const observed_notification_count: usize = uikit.countOfKind(.observed_notification);

const observed_notification_names = observedNotificationNames();

/// `PLACEHOLDER_ROOT_ID`, at `AK/ios/src/adapter.rs:52`.
const placeholder_root_id: schema.NodeId = .{ .value = 0 };

/// `AccessKitAccessibilityStatusObserver`, the class name at
/// `AK/ios/src/adapter.rs:249`.
///
/// The port never registers this class itself: it asks
/// `objc.class_with_name` first and registers only what is absent, because a
/// second adapter on the same process needs the class the first one made and
/// `objc_allocateClassPair` refuses a name twice.
const observer_class_name: [:0]const u8 = "AccessKitAccessibilityStatusObserver";

/// `NSObject`, the superclass of the observer at `AK/ios/src/adapter.rs:246`.
///
/// The spelling is the one `foundation.platform_names` records for the
/// Foundation root class, and the test below checks the two agree.
const observer_superclass_name: [:0]const u8 = "NSObject";

/// `AccessKitSubclassOf`, the prefix `AK/ios/src/subclass.rs:242` builds a
/// subclass name from.
const view_subclass_prefix: [:0]const u8 = "AccessKitSubclassOf";

// --- the handle types ---------------------------------------------------------

/// The events one tree update produced, and the platform that raises them.
///
/// The handle is what `accesskit_ios_queued_events_raise` frees, and that call
/// is the only way to free it (`include/zaccesskit.h:5886-5891`). A caller that
/// passes `null` terminates the process, which is why every entry point that
/// takes one says so.
///
/// **The adapter must outlive the handle.** `include/zaccesskit.h` does not say
/// so, and upstream's `Rc<Context>` at `AK/ios/src/event.rs:112-115` makes it
/// safe the other way round, because the context owns the nodes. This handle
/// holds a pointer to the platform table inside the adapter, and the adapter
/// releases the bindings that table reaches, so raising after
/// `accesskit_ios_adapter_free` is a use-after-free. A caller that needs the
/// upstream behaviour wants the header to promise it, and this is the sentence
/// that says the port does not.
pub const IosQueuedEvents = struct {
    /// The allocator every buffer under the handle came from.
    gpa: Allocator,
    /// The platform table of the adapter that produced the events. Borrowed for
    /// as long as the handle lives, which is the lifetime rule above.
    platform: *const objc.Platform,
    /// The events in the order they must be raised. Owned.
    events: []QueuedEvent,
};

/// What one queued event carries, and the two kinds upstream has at
/// `AK/ios/src/event.rs:25-33`.
///
/// `generic` names the notification by its tag and the node to hand
/// `UIAccessibilityPostNotification`, or `null` when the notification names no
/// node. `node_destroyed` drops the platform object the system caches for a
/// node, and `AK/ios/src/event.rs:176` is the function that does it.
pub const QueuedEvent = union(enum) {
    /// One `UIAccessibilityPostNotification` call.
    generic: struct {
        /// The `UIAccessibilityNotifications` tag, read out of the UIKit image
        /// and never written by this module.
        notification: u64,
        /// The node to name, or `null` when the notification names none.
        node_id: ?FullNodeId,
    },
    /// One node's platform object must leave the map before the system is told
    /// the layout changed.
    node_destroyed: FullNodeId,
    /// One live-region announcement.
    announcement: struct {
        /// The text, owned by the handle and released with it.
        text: []u8,
        /// `true` when the region is assertive, which is the high priority.
        assertive: bool,
    },
};

/// The three states of `AK/ios/src/adapter.rs:54-64`.
///
/// Upstream carries the view, the action handler and the thread marker in each
/// variant, because Rust moves them between variants. This module holds all
/// three in the fields of `IosAdapter`, so a variant carries only what the port
/// allocates, and the placeholder and active states both carry a tree.
pub const AdapterState = union(enum) {
    /// `AK/ios/src/adapter.rs:55-59`: no tree, and no assistive technology
    /// running.
    inactive,
    /// `AK/ios/src/adapter.rs:60-63`: the activation handler answered "no tree",
    /// so the port built the one-node placeholder tree and answers UIKit from
    /// it.
    placeholder: *Tree,
    /// `AK/ios/src/adapter.rs:64`: the application built a tree.
    active: *Tree,
};

/// An AccessKit adapter for an owned `UIView`.
///
/// Upstream `AK/ios/src/adapter.rs:319-325`. The caller owns the adapter and
/// releases it with `accesskit_ios_adapter_free`. **Every method must be called
/// on the main thread**, which is the condition `include/zaccesskit.h:5901`
/// states and which this module adds no lock to enforce.
///
/// The view and the three handler pointers must stay valid until the adapter is
/// released, which is the promise `include/zaccesskit.h:5900` makes on the
/// caller's side. The port therefore never retains the view itself.
pub const IosAdapter = struct {
    /// The allocator every buffer under the adapter came from, read once from
    /// the declared allocator when the adapter was created.
    gpa: Allocator,
    /// The platform calls this adapter makes.
    platform: objc.Platform,
    /// The host view, which the C caller owns and keeps alive.
    view: ?*runtime.AnyObject,
    /// `AK/ios/src/adapter.rs:322`: called once to build the first tree, and
    /// again after a deactivation. A `null` answer means "no tree", and it is
    /// not a failure.
    activation_handler: boundary.ActivationHandler,
    /// The `userdata` the activation handler reaches, passed through unchanged.
    activation_userdata: ?*anyopaque,
    /// `AK/ios/src/adapter.rs:322`: the action channel. **The callback owns
    /// every request it receives and releases it with
    /// `accesskit_action_request_free` before returning**, which
    /// `src/capi/boundary.zig:63-71` states. This module never calls it, because
    /// the actions arrive through `AK/ios/src/node.rs`, which is one of the
    /// blocked rows above; the pointer is stored so the tree is complete the
    /// moment the node layer lands.
    action_handler: boundary.ActionHandler,
    /// The `userdata` the action handler reaches.
    action_userdata: ?*anyopaque,
    /// `AK/ios/src/adapter.rs:322`: called when the last assistive technology
    /// stops.
    deactivation_handler: boundary.DeactivationHandler,
    /// The `userdata` the deactivation handler reaches.
    deactivation_userdata: ?*anyopaque,
    /// Which of the three states the adapter is in.
    state: AdapterState,
    /// The observer registered for the nine notifications at
    /// `AK/ios/src/adapter.rs:373`, and removed at `:511`.
    observer: ?*runtime.AnyObject,
    /// The node the system is on, at `AK/ios/src/event.rs:157-160`. A `null`
    /// here means the platform focus is not on a node of this tree, which is
    /// what a removal of the focused node sets.
    platform_focus: ?FullNodeId,

    /// The objects UIKit holds for the nodes of this tree, at
    /// `AK/ios/src/context.rs:56-92`. Nothing writes to it yet, which is the
    /// blocked row one of `blocked` names.
    platform_nodes: PlatformNodes,
};

/// An adapter that patches a copy of the host view's class at run time.
///
/// Upstream `AK/ios/src/subclass.rs:139-141`. The caller owns it and releases it
/// with `accesskit_ios_subclassing_adapter_free`, which restores the view's own
/// class and clears the association, so the view behaves exactly as it did
/// before the adapter existed.
pub const IosSubclassingAdapter = struct {
    /// The allocator every buffer under the adapter came from.
    gpa: Allocator,
    /// The platform calls this adapter makes.
    platform: objc.Platform,
    /// The view the port patched.
    view: *runtime.AnyObject,
    /// The class the view carried before the port installed its own, which is
    /// what the `superclass` override at `AK/ios/src/subclass.rs:80-83` answers
    /// from and what the drop restores.
    previous_class: ?*runtime.ObjClass,
    /// The adapter the installed implementations reach through the owner the
    /// binding layer associated with the view.
    adapter: *IosAdapter,
};

// --- the installed implementations call back into ----------------------------

/// The table the binding layer's installed implementations call, at
/// `AK/ios/src/adapter.rs:266-272` and `AK/ios/src/subclass.rs:80-135`.
///
/// Every entry takes the pointer `objc.claim_object` or `objc.observer_new`
/// received. The Objective-C ABI hands an implementation only `self` and
/// `_cmd`, so the implementation cannot find the adapter without the binding
/// layer's help: `root.zig` holds the logic and the binding layer holds the
/// bodies. The two meet here, once, at `platform()`.
const callbacks: objc.Callbacks = .{
    .view_superclass = callbackViewSuperclass,
    .view_is_accessibility_element = callbackViewIsAccessibilityElement,
    .view_accessibility_elements = callbackViewAccessibilityElements,
    .view_accessibility_hit_test = callbackViewAccessibilityHitTest,
    .view_previous_class = callbackViewPreviousClass,
    .view_did_move_to_window = callbackViewDidMoveToWindow,
    .accessibility_status_changed = callbackAccessibilityStatusChanged,
};

// --- the thirteen entry points ------------------------------------------------

/// Raises the queued events and releases the handle.
///
/// `accesskit_ios_queued_events_raise`, `include/zaccesskit.h:5893`, upstream
/// `AK/ios/src/event.rs:118-127`. **This call is the only way to release the
/// handle** (`include/zaccesskit.h:5888-5891`), the handle is unusable
/// afterwards, a second call on the same pointer is a use-after-free, and a
/// `null` handle terminates the process, which is what `terminate` below does.
///
/// One generic event posts `UIAccessibilityPostNotification` with the node the
/// system should move to, or with `null` when upstream's `and_then` at
/// `AK/ios/src/event.rs:47-52` found no platform object for the identifier.
/// **The port has no platform objects at all yet**, so every generic event takes
/// that branch, and a focus event does not move the focus. One `node_destroyed`
/// event drains the platform-object map, which does not exist yet either, so it
/// does nothing. An announcement posts its attributed string or its plain
/// string, which is whole, because it needs no platform object. The two halves
/// that need one are the third row of `blocked`.
///
/// Every event is raised in the order the handle holds them, and the handle's
/// buffers are released on every path out, including the ones that raise
/// nothing.
pub fn iosQueuedEventsRaise(events: *IosQueuedEvents) void {
    if (@intFromPtr(events) == 0) {
        terminate();
    }
    const gpa = events.gpa;
    const platform = events.platform;
    const ctx = platform.context;
    var index: usize = 0;
    while (index < events.events.len) : (index += 1) {
        const event = events.events[index];
        switch (event) {
            .generic => |generic| {
                platform.post_notification(ctx, generic.notification, null);
            },
            .node_destroyed => {},
            .announcement => |announcement| {
                platform.raise_announcement(ctx, announcement.text, announcement.assertive);
            },
        }
    }
    freeEvents(gpa, events);
}

/// Returns an adapter for `view`, or `null` when the allocation failed.
///
/// `accesskit_ios_adapter_new`, `include/zaccesskit.h:5904`, upstream
/// `AK/ios/src/adapter.rs:335-382`. **Must be called on the main thread**, and
/// every handler the adapter holds is called on the main thread
/// (`include/zaccesskit.h:5901`).
///
/// `view` and every handler pointer must stay valid until
/// `accesskit_ios_adapter_free` (`include/zaccesskit.h:5900`), so the adapter
/// stores them and retains none of them. The adapter starts
/// `AdapterState.inactive` and registers one observer for the nine
/// notifications at `AK/ios/src/adapter.rs:373`.
///
/// `null` means the allocation failed, which is what `include/zaccesskit.h:5898`
/// promises. It also covers the two cases that have no other channel: the UIKit
/// or the Objective-C image that would not open, and a view that is not an
/// object. `accesskit_last_error` stays at `none` on those two, because
/// `allocation.Tag` has one failure and it says allocation, so this module does
/// not write a tag that would be false. A caller that needs to tell them apart
/// needs a tag this header does not have.
pub fn iosAdapterNew(
    view: ?*anyopaque,
    activation_handler: boundary.ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: boundary.ActionHandler,
    action_handler_userdata: ?*anyopaque,
    deactivation_handler: boundary.DeactivationHandler,
    deactivation_handler_userdata: ?*anyopaque,
) ?*IosAdapter {
    const gpa = allocation.allocator();
    const platform = openPlatform(gpa) orelse return null;
    return adapterNew(
        gpa,
        platform,
        view,
        activation_handler,
        activation_handler_userdata,
        action_handler,
        action_handler_userdata,
        deactivation_handler,
        deactivation_handler_userdata,
    );
}

/// Releases the adapter and every tree it holds, exactly once.
///
/// `accesskit_ios_adapter_free`, `include/zaccesskit.h:5918`, upstream
/// `AK/ios/src/adapter.rs:506-514`. A `null` adapter terminates the process,
/// which `include/zaccesskit.h:5916` promises and `terminate` below does.
///
/// The teardown runs in the order `Drop` uses: the observer is removed from the
/// notification centre at `AK/ios/src/adapter.rs:511`, the tree is released,
/// the platform bindings are closed, and the adapter block goes back to the
/// declared allocator. A second call on the same pointer is a use-after-free.
pub fn iosAdapterFree(adapter: *IosAdapter) void {
    if (@intFromPtr(adapter) == 0) {
        terminate();
    }
    const gpa = adapter.gpa;
    if (adapter.observer) |observer| {
        adapter.platform.remove_status_observer(adapter.platform.context, observer);
    }
    releaseState(gpa, &adapter.state);
    adapter.platform.release(adapter.platform.context);
    gpa.destroy(adapter);
}

/// Asks `update_factory` for a tree and hands it to the adapter.
///
/// `accesskit_ios_adapter_update_if_active`, `include/zaccesskit.h:5929`,
/// upstream `AK/ios/src/adapter.rs:398-436`. Returns the events the answer
/// produced, or `null` when the adapter is not active, which is the case
/// `include/zaccesskit.h:5924` states and the only reason the factory is not
/// called. The caller owns a non-null result and must pass it to
/// `accesskit_ios_queued_events_raise`, which also releases it.
///
/// **The update arrives by transfer.** The factory built it and handed it over,
/// so this function owns the block: `takeTransferredUpdate` copies the value
/// out and returns the block to the declared allocator, which is what
/// `accesskit_tree_update_free` is, and then either a tree takes the value or
/// this function releases it. A `null` return from the factory is a contract
/// violation, not an answer, and `src/capi/boundary.zig:44-51` says it
/// terminates the process, which `terminate` below does. Nothing is built on
/// the `null` path out of this function.
///
/// A tree that cannot hold the update leaves the adapter in the state it was
/// in, sets `accesskit_last_error` to `out_of_memory`, and returns `null`.
pub fn iosAdapterUpdateIfActive(
    adapter: *IosAdapter,
    update_factory: boundary.TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) ?*IosQueuedEvents {
    if (@intFromPtr(adapter) == 0) {
        terminate();
    }
    switch (adapter.state) {
        .inactive => return null,
        .placeholder, .active => {},
    }
    const handed = update_factory(update_factory_userdata);
    const block = handed orelse {
        terminate();
    };
    const update = takeTransferredUpdate(block);
    switch (adapter.state) {
        .inactive => {
            // A re-entrant call deactivated the adapter while the factory ran.
            // Upstream drops the update at `AK/ios/src/adapter.rs:401`, and this
            // is that drop.
            var dropped = update;
            dropped.deinit(adapter.gpa);
            return null;
        },
        .placeholder => {
            // `Tree.init` reads the focus out of the update and builds the
            // tree in one step, so the focus is read before the transfer. The
            // value is the one the tree holds afterwards, because the first
            // update sets the focus at `AK/ios/src/adapter.rs:396`.
            const focus_id = treeUpdateFocusId(update);
            const next = buildTree(adapter.gpa, update) orelse {
                allocation.failWith(.out_of_memory);
                return null;
            };
            releaseState(adapter.gpa, &adapter.state);
            adapter.state = .{ .active = next };
            // Upstream returns no events when the tree has no focus, at
            // `AK/ios/src/adapter.rs:414-416`, and the state is active either
            // way.
            const focused = focus_id orelse return null;
            const event = genericEvent(
                adapter.platform.notification_tags.screen_changed,
                focused,
            );
            return queueEvents(adapter, &.{event});
        },
        .active => |tree| {
            var generator: EventGenerator = .{
                .adapter = adapter,
                .platform_focus = adapter.platform_focus,
            };
            defer generator.releaseEvents();
            var handler = generator.changeHandler();
            tree.updateAndProcessChanges(update, &handler) catch {
                allocation.failWith(.out_of_memory);
                return null;
            };
            return generator.intoEvents();
        },
    }
}

/// Tells the adapter that `view` appeared, and returns what it produced.
///
/// `accesskit_ios_adapter_view_did_appear`, `include/zaccesskit.h:5941`,
/// upstream `AK/ios/src/adapter.rs:452-456` through `try_activate` at
/// `:190-206`. Returns `null` when the adapter is not active, which is the
/// ordinary case on a device with no assistive technology running, and the
/// caller owns a non-null result.
///
/// The gate is upstream's and the order is upstream's: no assistive technology
/// means no call to the activation handler at all, an adapter that is already
/// active or placeholder means no second activation, and an activation handler
/// that answered "no tree" leaves the adapter in the placeholder state, which
/// produces no events.
pub fn iosAdapterViewDidAppear(adapter: *IosAdapter) ?*IosQueuedEvents {
    if (@intFromPtr(adapter) == 0) {
        terminate();
    }
    const ctx = adapter.platform.context;
    if (!adapter.platform.any_assistive_tech_running(ctx)) return null;
    switch (adapter.state) {
        .inactive => {},
        .placeholder, .active => return null,
    }
    const tree = getOrInitContext(adapter) orelse return null;
    switch (adapter.state) {
        .active => {},
        .inactive, .placeholder => return null,
    }
    const event = genericEvent(
        adapter.platform.notification_tags.layout_changed,
        treeFocusId(tree),
    );
    return queueEvents(adapter, &.{event});
}

/// Reports whether the adapter's view is an accessibility element itself.
///
/// `accesskit_ios_adapter_is_accessibility_element`,
/// `include/zaccesskit.h:5947`, upstream `AK/ios/src/adapter.rs:459-462`. It
/// builds the tree if the adapter has not built it yet, and it answers `false`
/// on every path, which is upstream's answer: the view is a container and UIKit
/// asks the container, so the view itself is not an element.
pub fn iosAdapterIsAccessibilityElement(adapter: *IosAdapter) bool {
    if (@intFromPtr(adapter) == 0) {
        terminate();
    }
    _ = getOrInitContext(adapter);
    return false;
}

/// Returns the platform object that names the view's accessibility elements.
///
/// `accesskit_ios_adapter_accessibility_elements`,
/// `include/zaccesskit.h:5961`, upstream `AK/ios/src/adapter.rs:464-482`.
/// Ownership does not transfer (`include/zaccesskit.h:5955`), so the caller
/// never releases what it gets, and a `null` answer means the call named no
/// object.
///
/// **Blocked, and this is row one of `blocked`.** The walk below is upstream's:
/// a root the filter includes answers with itself, and a root it excludes
/// answers with its filtered children. What the port cannot do is turn an
/// identifier into the `PlatformNode` object UIKit asks for, because
/// `AK/ios/src/node.rs` is not ported, so the answer is the empty array
/// `objc.empty_array` returns. An empty array is a legal UIKit answer for a
/// container and it is a false answer for a tree with children, which is why
/// this is recorded rather than left in a comment.
pub fn iosAdapterAccessibilityElements(adapter: *IosAdapter) ?*anyopaque {
    if (@intFromPtr(adapter) == 0) {
        terminate();
    }
    switch (adapter.state) {
        .inactive => return null,
        .placeholder, .active => {},
    }
    const ids = elementIdentifiers(adapter) catch |err| {
        reportQueryFailure(err);
        return null;
    };
    defer adapter.gpa.free(ids);
    return @ptrCast(adapter.platform.empty_array(adapter.platform.context));
}

/// Returns the platform object at the logical point `(x, y)`.
///
/// `accesskit_ios_adapter_hit_test`, `include/zaccesskit.h:5973`, upstream
/// `AK/ios/src/adapter.rs:486-503`. Ownership does not transfer
/// (`include/zaccesskit.h:5967`), so the caller never releases what it gets,
/// and `null` means the point names no object.
///
/// **Blocked, and this is row two of `blocked`.** The point conversion below is
/// upstream's `from_cg_point` at `AK/ios/src/util.rs:33-40`, and the walk is
/// the consumer's `nodeAtPoint`, so the identifier this function finds is the
/// right one. What the port cannot do is return the `PlatformNode` object for
/// it, because `AK/ios/src/node.rs` is not ported, so the answer is `null`,
/// which is upstream's answer for a point that names nothing.
pub fn iosAdapterHitTest(adapter: *IosAdapter, x: f64, y: f64) ?*anyopaque {
    if (@intFromPtr(adapter) == 0) {
        terminate();
    }
    const id = hitTestIdentifier(adapter, x, y) catch |failure| {
        reportQueryFailure(failure);
        return null;
    } orelse return null;
    return platformObjectFor(adapter, id);
}

/// Returns a text rendering of the adapter, or `null` when it cannot be built.
///
/// `accesskit_ios_adapter_debug`, `include/zaccesskit.h:5984`, upstream
/// `AK/ios/src/adapter.rs:327-333`. The caller releases the result with
/// `accesskit_string_free`, once, and the text borrows nothing from the
/// adapter, so the adapter may be released first
/// (`include/zaccesskit.h:5981`). The result comes from
/// `allocation.createCString`, which is the only allocation a `char *` a getter
/// returns may come from.
///
/// The three rows are upstream's three states. `root` and `focus` are the
/// `accesskit_node_id` values of the tree's root and its focus, and `none`
/// stands for the state that holds no tree.
pub fn iosAdapterDebug(adapter: *const IosAdapter) ?[*:0]u8 {
    if (@intFromPtr(adapter) == 0) {
        terminate();
    }
    const gpa = allocation.allocator();
    const text = debugText(gpa, adapter.state) orelse {
        allocation.failWith(.out_of_memory);
        return null;
    };
    defer gpa.free(text);
    return allocation.createCString(text) catch |err| switch (err) {
        error.OutOfMemory => {
            allocation.failWith(.out_of_memory);
            return null;
        },
    };
}

/// Returns a subclassing adapter for `view`, or `null` when the allocation
/// failed.
///
/// `accesskit_ios_subclassing_adapter_new`, `include/zaccesskit.h:5996`,
/// upstream `AK/ios/src/subclass.rs:150-190`. It must run before the view is
/// shown or focused for the first time, which is upstream's condition at
/// `AK/ios/src/subclass.rs:153-155`.
///
/// `null` means the allocation failed (`include/zaccesskit.h:5989`), and it
/// also covers a view that already carries a subclassing adapter, which
/// upstream treats as a programming error it panics on at
/// `AK/ios/src/subclass.rs:218-220`, and a view whose class the runtime does
/// not answer for.
pub fn iosSubclassingAdapterNew(
    view: ?*anyopaque,
    activation_handler: boundary.ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: boundary.ActionHandler,
    action_handler_userdata: ?*anyopaque,
    deactivation_handler: boundary.DeactivationHandler,
    deactivation_handler_userdata: ?*anyopaque,
) ?*IosSubclassingAdapter {
    const gpa = allocation.allocator();
    const host: *runtime.AnyObject = @ptrCast(view orelse return null);
    const platform = openPlatform(gpa) orelse return null;
    return subclassingAdapterNew(
        gpa,
        platform,
        host,
        activation_handler,
        activation_handler_userdata,
        action_handler,
        action_handler_userdata,
        deactivation_handler,
        deactivation_handler_userdata,
    );
}

/// Returns a subclassing adapter for the root view of `window`.
///
/// `accesskit_ios_subclassing_adapter_for_window`,
/// `include/zaccesskit.h:6011`, upstream `AK/ios/src/subclass.rs:262-290`. The
/// conditions are the ones `accesskit_ios_subclassing_adapter_new` states.
/// `null` also covers a window with no root view controller or with a root view
/// controller that has no view, which is the case upstream panics on at
/// `AK/ios/src/subclass.rs:271-276`.
pub fn iosSubclassingAdapterForWindow(
    window: ?*anyopaque,
    activation_handler: boundary.ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: boundary.ActionHandler,
    action_handler_userdata: ?*anyopaque,
    deactivation_handler: boundary.DeactivationHandler,
    deactivation_handler_userdata: ?*anyopaque,
) ?*IosSubclassingAdapter {
    const gpa = allocation.allocator();
    const host_window: *runtime.AnyObject = @ptrCast(window orelse return null);
    const platform = openPlatform(gpa) orelse return null;
    const root_view = platform.window_root_view(platform.context, host_window) orelse {
        platform.release(platform.context);
        return null;
    };
    return subclassingAdapterNew(
        gpa,
        platform,
        root_view,
        activation_handler,
        activation_handler_userdata,
        action_handler,
        action_handler_userdata,
        deactivation_handler,
        deactivation_handler_userdata,
    );
}

/// Releases the subclassing adapter and every tree it holds, exactly once.
///
/// `accesskit_ios_subclassing_adapter_free`, `include/zaccesskit.h:6025`,
/// upstream `AK/ios/src/subclass.rs:305-318`. A `null` adapter terminates the
/// process, which `include/zaccesskit.h:6023` promises.
///
/// The teardown restores the view's own class first, then clears the
/// association, then releases the adapter, which is upstream's order at
/// `AK/ios/src/subclass.rs:309-317` and the order that matters: a view with the
/// port's class but no owner answers as a view with no adapter.
pub fn iosSubclassingAdapterFree(adapter: *IosSubclassingAdapter) void {
    if (@intFromPtr(adapter) == 0) {
        terminate();
    }
    const gpa = adapter.gpa;
    if (adapter.previous_class) |previous| {
        adapter.platform.set_view_class(adapter.platform.context, adapter.view, previous);
    }
    adapter.platform.release_object(adapter.platform.context, adapter.view);
    const inner = adapter.adapter;
    gpa.destroy(adapter);
    iosAdapterFree(inner);
}

/// Asks `update_factory` for a tree and hands it to the subclassing adapter.
///
/// `accesskit_ios_subclassing_adapter_update_if_active`,
/// `include/zaccesskit.h:6038`, upstream `AK/ios/src/subclass.rs:292-303`. It
/// reaches the adapter at `AK/ios/src/subclass.rs:298-301` and answers exactly
/// what `accesskit_ios_adapter_update_if_active` would.
pub fn iosSubclassingAdapterUpdateIfActive(
    adapter: *IosSubclassingAdapter,
    update_factory: boundary.TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) ?*IosQueuedEvents {
    if (@intFromPtr(adapter) == 0) {
        terminate();
    }
    return iosAdapterUpdateIfActive(adapter.adapter, update_factory, update_factory_userdata);
}

// --- the platform-node map ---------------------------------------------------

/// The map from a node identifier to the object UIKit asks for, at
/// `AK/ios/src/context.rs:56-92`.
///
/// **Nothing writes to it yet.** Upstream fills it from `get_or_create_platform_node`
/// at `AK/ios/src/context.rs:88-92`, and that function calls
/// `AK/ios/src/node.rs`, which this directory has never held. So the map, the
/// lookup and the removal are real and the producer is the blocked row one of
/// `blocked` names. A lookup answers `null` for every identifier today, which is
/// why `accessibility_elements` returns an empty array and why a
/// `node_destroyed` event changes nothing.
const PlatformNodes = struct {
    /// What each identifier is called, by the object UIKit holds.
    objects: std.AutoHashMapUnmanaged(FullNodeId, ?*runtime.AnyObject) = .empty,
    /// The allocator the map grew with.
    gpa: Allocator,

    /// The object UIKit holds for `id`, or `null` when the map holds none.
    ///
    /// `null` is upstream's answer for an identifier no platform object was
    /// built for, at `AK/ios/src/event.rs:47-51`, so the branch it guards is
    /// upstream's own and not a port invention.
    fn lookup(self: *const PlatformNodes, id: FullNodeId) ?*runtime.AnyObject {
        return self.objects.get(id) orelse null;
    }

    /// Records the object UIKit holds for `id`.
    ///
    /// This is `AK/ios/src/context.rs:88-92` without the part that builds the
    /// object, so it exists for the tests and for the node layer. On
    /// `error.OutOfMemory` nothing is written.
    fn insert(
        self: *PlatformNodes,
        id: FullNodeId,
        object: *runtime.AnyObject,
    ) Allocator.Error!void {
        try self.objects.put(self.gpa, id, object);
    }

    /// Drops the object UIKit held for `id`, which is what
    /// `AK/ios/src/event.rs:176` does.
    ///
    /// The node must leave this map before the notification is posted, or the
    /// system caches an object for a node that no longer exists.
    fn remove(self: *PlatformNodes, id: FullNodeId) void {
        _ = self.objects.remove(id);
    }

    /// Releases the map. Nothing else survives.
    ///
    /// The last line is the reset: `self.*` is one whole `PlatformNodes` with
    /// every field at the value `init` gives it. That is the Z030 shape, and the
    /// rule does not read an assignment to `self.*` as a reset, so this comment
    /// says why the assignment is there.
    fn deinit(self: *PlatformNodes) void {
        self.objects.deinit(self.gpa);
        self.* = .{ .gpa = self.gpa };
    }
};

// --- the walks that build an answer -------------------------------------------

/// What the two walks that answer UIKit can report.
///
/// The members are the consumer's own: `QueryError` from `consumer/tree_state.zig:196-207`
/// for a walk that reached its bound or named a node the state does not hold,
/// `OutOfMemory` from an allocation, and the two this module adds for a view
/// that has no window and a screen with no coordinate space, which are the two
/// `AK/ios/src/util.rs:34-37` turns into `Option::None`.
pub const WalkError = consumer.tree.QueryError || error{
    /// The view is not in a window, or its window has no screen.
    NoWindow,
    /// The screen has no coordinate space.
    NoCoordinateSpace,
};

/// Records a walk failure where the C ABI records one.
///
/// `accesskit_last_error` has two tags and one of them is an allocation, so an
/// allocation failure is recorded and a walk that reached its bound is not: the
/// port would have to invent a tag to say more.
fn reportQueryFailure(failure: WalkError) void {
    switch (failure) {
        error.OutOfMemory => allocation.failWith(.out_of_memory),
        error.InvalidPosition,
        error.IndexOutOfRange,
        error.LineChainCycle,
        error.WrongPropertyKind,
        error.NoSuchNode,
        error.TreeCycle,
        error.NoWindow,
        error.NoCoordinateSpace,
        => {},
    }
}

/// The tree the adapter answers from, or `null` when it holds none.
fn activeTree(adapter: *const IosAdapter) ?*Tree {
    return switch (adapter.state) {
        .inactive => null,
        .placeholder => |tree| tree,
        .active => |tree| tree,
    };
}

/// The identifiers `accessibilityElements` answers with, in upstream's order.
///
/// Upstream at `AK/ios/src/adapter.rs:464-482`: a root the filter includes
/// answers with itself and no children, and a root it excludes answers with its
/// filtered children. `error.OutOfMemory` leaves nothing allocated, and every
/// other failure leaves the list empty, which the caller reads as "no
/// elements".
///
/// The result belongs to the caller and comes from `adapter.gpa`, including the
/// empty one, because the caller releases it with `adapter.gpa.free`.
fn elementIdentifiers(adapter: *const IosAdapter) WalkError![]FullNodeId {
    const gpa = adapter.gpa;
    // The empty answer is allocated too. The caller releases the slice with
    // `adapter.gpa.free`, and a static empty array is not a block that allocator
    // made.
    const tree = activeTree(adapter) orelse return gpa.dupe(FullNodeId, &.{});
    const root = tree.stateOf().root();
    const verdict = try consumer.filter.commonFilter(root);
    var ids: std.ArrayList(FullNodeId) = .empty;
    errdefer ids.deinit(gpa);
    if (verdict == .include) {
        try ids.append(gpa, root.id());
        return ids.toOwnedSlice(gpa);
    }
    var cursor = try consumer.node_ref.hierarchy.filteredChildren(root, common_filter);
    while (try cursor.next()) |child| {
        try ids.append(gpa, child.id());
    }
    return ids.toOwnedSlice(gpa);
}

/// The node at the logical point `(x, y)`, or `null` when the adapter holds no
/// tree.
///
/// Upstream at `AK/ios/src/adapter.rs:486-503` and `AK/ios/src/util.rs:33-40`.
/// A point that names no node answers with the root, which is upstream's
/// `unwrap_or(root)` at `AK/ios/src/adapter.rs:499`, so the only `null` here is
/// an adapter with no tree.
fn hitTestIdentifier(adapter: *const IosAdapter, x: f64, y: f64) WalkError!?FullNodeId {
    const tree = activeTree(adapter) orelse return null;
    const view = adapter.view orelse return null;
    const root = tree.stateOf().root();
    const point = try treePoint(adapter, view, root, .{ .x = x, .y = y });
    const found = try consumer.node_ref.geometry.nodeAtPoint(
        adapter.gpa,
        root,
        point,
        common_filter,
    );
    const node = found orelse root;
    return node.id();
}

/// The point in the tree's own coordinate space, at `AK/ios/src/util.rs:33-40`.
///
/// The steps are upstream's and the order is upstream's: the point arrives in
/// the screen's coordinate space, the view converts it into its own, the view's
/// content scale multiplies it, and the tree's inverse transform takes it into
/// the space the nodes store. Each step can fail with `error.NoWindow` or
/// `error.NoCoordinateSpace`, which is upstream's `Option::None` at each
/// `?`.
fn treePoint(
    adapter: *const IosAdapter,
    view: *runtime.AnyObject,
    root: NodeRef,
    point: foundation.CGPoint,
) WalkError!schema.Point {
    const ctx = adapter.platform.context;
    const window = adapter.platform.view_window(ctx, view) orelse return error.NoWindow;
    const screen = adapter.platform.view_screen(ctx, window) orelse return error.NoWindow;
    const space = adapter.platform.screen_coordinate_space(ctx, screen) orelse {
        return error.NoCoordinateSpace;
    };
    const local = adapter.platform.view_convert_point(ctx, view, point, space);
    const factor = adapter.platform.view_content_scale_factor(ctx, view);
    const scaled: schema.Point = .{ .x = local.x * factor, .y = local.y * factor };
    const transform = try consumer.node_ref.geometry.transform(root);
    return affine.mulPoint(affine.inverse(transform), scaled);
}

/// The screen rect `rect` names, at `AK/ios/src/util.rs:50-63`.
///
/// This is the reverse of `treePoint` above and the two are the two halves of
/// `AK/ios/src/util.rs`: the tree stores physical pixels and UIKit measures in
/// the view's own points, so each direction divides by the content scale. The
/// order is upstream's: read the factor, divide the origin and the size, then
/// hand the result to `to_screen_rect`, which is `AK/ios/src/util.rs:46-48` and
/// is the only caller of `UIAccessibilityConvertFrameToScreenCoordinates`.
///
/// **The factor is never zero for a view on a screen.** UIKit defines
/// `contentScaleFactor` as a positive scale, and upstream divides by it without
/// a test, so this divides without one too. A caller that hands in a view whose
/// scale is zero gets an infinite rect, which is what the same division gives
/// upstream, and the node layer that calls this never has such a view.
///
/// **Nothing calls this yet.** The one caller upstream is the
/// `accessibilityFrame` of `AK/ios/src/node.rs`, and that class is not ported.
fn toCgRect(
    adapter: *const IosAdapter,
    view: *runtime.AnyObject,
    rect: schema.Rect,
) foundation.CGRect {
    const ctx = adapter.platform.context;
    const factor = adapter.platform.view_content_scale_factor(ctx, view);
    const local: foundation.CGRect = .{
        .origin = .{ .x = rect.x0 / factor, .y = rect.y0 / factor },
        .size = .{ .width = rect.width() / factor, .height = rect.height() / factor },
    };
    return adapter.platform.to_screen_rect(ctx, view, local);
}

/// The object UIKit holds for `id`, or `null`.
///
/// **Blocked, and this is row one of `blocked` read from the other side.** The
/// lookup is a real lookup in a real map and it is the last line of the two
/// functions that need it. What the map has no entry for is any identifier,
/// because `AK/ios/src/context.rs:88-92` gets its entries by building a
/// `PlatformNode` and `AK/ios/src/node.rs` is not ported.
fn platformObjectFor(adapter: *const IosAdapter, id: FullNodeId) ?*anyopaque {
    const object = adapter.platform_nodes.lookup(id) orelse return null;
    return @ptrCast(object);
}

// --- the state machine -------------------------------------------------------

/// Makes the adapter active or placeholder, activating it if it is inactive.
///
/// Upstream `get_or_init_context` at `AK/ios/src/adapter.rs:128-188`. The three
/// steps are upstream's: an adapter that already holds a tree answers with it,
/// an activation handler that answered "no tree" produces the placeholder tree
/// and the placeholder state, and any other answer produces the tree and the
/// active state.
///
/// **A `null` answer from the activation handler is ordinary.** It means "no
/// tree", which is what `src/capi/boundary.zig:56-62` states and what the port
/// answers with a one-node window. A tree that cannot be built leaves the
/// adapter inactive, records `out_of_memory` and returns `null`.
fn getOrInitContext(adapter: *IosAdapter) ?*Tree {
    switch (adapter.state) {
        .inactive => {},
        .placeholder => |tree| return tree,
        .active => |tree| return tree,
    }
    if (adapter.activation_handler(adapter.activation_userdata)) |block| {
        const tree = buildTree(adapter.gpa, takeTransferredUpdate(block)) orelse {
            allocation.failWith(.out_of_memory);
            return null;
        };
        adapter.state = .{ .active = tree };
        return tree;
    }
    const placeholder = placeholderUpdate(adapter.gpa) catch {
        allocation.failWith(.out_of_memory);
        return null;
    };
    const tree = buildTree(adapter.gpa, placeholder) orelse {
        allocation.failWith(.out_of_memory);
        return null;
    };
    adapter.state = .{ .placeholder = tree };
    return tree;
}

/// Returns the adapter to the inactive state and tells the application.
///
/// Upstream `try_deactivate` at `AK/ios/src/adapter.rs:208-237`. An adapter
/// that is already inactive is left alone and the deactivation handler is not
/// called, which is upstream's early return at `:214`.
fn tryDeactivate(adapter: *IosAdapter) void {
    switch (adapter.state) {
        .inactive => return,
        .placeholder, .active => {},
    }
    releaseState(adapter.gpa, &adapter.state);
    adapter.deactivation_handler(adapter.deactivation_userdata);
}

/// Releases the tree the state holds and returns the state to inactive.
fn releaseState(gpa: Allocator, state: *AdapterState) void {
    switch (state.*) {
        .inactive => {},
        .placeholder => |tree| releaseTree(gpa, tree),
        .active => |tree| releaseTree(gpa, tree),
    }
    state.* = .inactive;
}

/// Releases one tree and its block.
fn releaseTree(gpa: Allocator, tree: *Tree) void {
    tree.deinit();
    gpa.destroy(tree);
}

/// Takes the update a factory handed over and returns its block.
///
/// The factory built the update and transferred it, which
/// `src/capi/boundary.zig:44-51` states, so the block is this module's to
/// release. The value is a copy of the struct and not of the storage, so the
/// nodes and the array survive the release and the caller still owns them.
/// Releasing the block is what `accesskit_tree_update_free` is, and it reads the
/// head the block carries, so it must be `allocation.release` and not
/// `gpa.free`.
fn takeTransferredUpdate(block: *boundary.CTreeUpdate) boundary.CTreeUpdate {
    const update = block.*;
    allocation.release(block);
    return update;
}

/// Builds a tree from `update`, which the call consumes on every path.
///
/// `Tree.init` takes the update by value and releases it whatever it answers,
/// which is the contract at `consumer/tree.zig:267-283`, so a caller must not
/// release it again. `null` means the tree could not be built and the update is
/// already gone.
fn buildTree(gpa: Allocator, update: boundary.CTreeUpdate) ?*Tree {
    const slot = gpa.create(Tree) catch {
        var owned = update;
        owned.deinit(gpa);
        return null;
    };
    slot.* = Tree.init(gpa, update, true) catch {
        gpa.destroy(slot);
        return null;
    };
    return slot;
}

/// The one-node tree the port builds when the activation handler says "no
/// tree", at `AK/ios/src/adapter.rs:170-180`.
///
/// It is a window with no children, focused on itself, and `error.OutOfMemory`
/// leaves nothing allocated.
fn placeholderUpdate(gpa: Allocator) Allocator.Error!boundary.CTreeUpdate {
    var update: boundary.CTreeUpdate = .{};
    errdefer update.deinit(gpa);
    var node = schema.Node.init(gpa, .window);
    errdefer node.deinit();
    try update.pushNode(gpa, placeholder_root_id, node);
    update.tree = schema.TreeInfo.init(placeholder_root_id);
    update.tree_id = schema.tree_id_root;
    update.focus = placeholder_root_id;
    return update;
}

/// The node the tree holds the focus on, or `null` when it holds none.
///
/// `null` is the ordinary answer when the host does not hold focus, which is
/// `TreeState.focusId` at `consumer/tree_state.zig:490-494`.
fn treeFocusId(tree: *const Tree) ?FullNodeId {
    const focus = tree.stateOf().focus() orelse return null;
    return focus.id();
}

/// The focus the first update of a tree names.
///
/// `null` when the update carries no tree data, because then the update is not
/// the first one of a tree and the tree it follows keeps the focus it had.
fn treeUpdateFocusId(update: boundary.CTreeUpdate) ?FullNodeId {
    if (update.tree == null) return null;
    return FullNodeId.init(update.focus, consumer.tree_index.TreeIndex.init(0));
}

// --- the events handle -------------------------------------------------------

/// One `UIAccessibilityPostNotification` call.
fn genericEvent(notification: u64, node_id: ?FullNodeId) QueuedEvent {
    return .{ .generic = .{ .notification = notification, .node_id = node_id } };
}

/// Builds a handle over a copy of `events`.
///
/// `null` on `error.OutOfMemory` and nothing survives. The handle borrows the
/// platform table of `adapter`, which is the lifetime rule on
/// `IosQueuedEvents`.
fn queueEvents(adapter: *IosAdapter, events: []const QueuedEvent) ?*IosQueuedEvents {
    const gpa = adapter.gpa;
    const slot = gpa.create(IosQueuedEvents) catch {
        allocation.failWith(.out_of_memory);
        return null;
    };
    const copy = gpa.dupe(QueuedEvent, events) catch {
        gpa.destroy(slot);
        allocation.failWith(.out_of_memory);
        return null;
    };
    slot.* = .{ .gpa = gpa, .platform = &adapter.platform, .events = copy };
    return slot;
}

/// Builds a handle over `events`, which the call consumes.
///
/// `null` on `error.OutOfMemory`, and then every buffer under `events` is
/// released, so the caller must not release them again.
fn queueOwnedEvents(
    adapter: *IosAdapter,
    events: *std.ArrayList(QueuedEvent),
) ?*IosQueuedEvents {
    const gpa = adapter.gpa;
    errdefer releaseEventList(gpa, events);
    const slot = gpa.create(IosQueuedEvents) catch {
        allocation.failWith(.out_of_memory);
        return null;
    };
    slot.* = .{ .gpa = gpa, .platform = &adapter.platform, .events = events.items };
    events.* = .empty;
    return slot;
}

/// Releases every buffer under the handle and the handle itself.
fn freeEvents(gpa: Allocator, events: *IosQueuedEvents) void {
    releaseEventSlice(gpa, events.events);
    gpa.destroy(events);
}

/// Releases every announcement text and the slice that holds the events.
fn releaseEventSlice(gpa: Allocator, events: []QueuedEvent) void {
    for (events) |event| {
        switch (event) {
            .generic, .node_destroyed => {},
            .announcement => |announcement| gpa.free(announcement.text),
        }
    }
    gpa.free(events);
}

/// Releases a list of events and leaves it empty.
fn releaseEventList(gpa: Allocator, events: *std.ArrayList(QueuedEvent)) void {
    releaseEventSlice(gpa, events.items);
    events.deinit(gpa);
    events.* = .empty;
}

// --- the subclassing adapter -------------------------------------------------

/// Builds a subclassing adapter for a view the caller owns.
///
/// Upstream `SubclassingAdapter::new_internal` at
/// `AK/ios/src/subclass.rs:197-262`, and the steps are upstream's in upstream's
/// order: refuse a view that already carries one, create the adapter, read the
/// view's own class, name the subclass after it, reuse the subclass when the
/// name is taken and register it when it is not, claim the view, point the view
/// at the subclass, and finally activate the adapter by hand because UIKit does
/// not replay `didMoveToWindow` for a view that is already attached.
///
/// Every `null` return releases everything the call had taken, and the
/// platform bindings with it.
fn subclassingAdapterNew(
    gpa: Allocator,
    platform: objc.Platform,
    view: *runtime.AnyObject,
    activation_handler: boundary.ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: boundary.ActionHandler,
    action_handler_userdata: ?*anyopaque,
    deactivation_handler: boundary.DeactivationHandler,
    deactivation_handler_userdata: ?*anyopaque,
) ?*IosSubclassingAdapter {
    const ctx = platform.context;
    const previous = platform.view_class(ctx, view) orelse {
        platform.release(platform.context);
        return null;
    };
    // Upstream panics on a second adapter for one view at
    // `AK/ios/src/subclass.rs:218-220`. The C ABI has no channel for a
    // programming error, so this reports it as the `null` the header already
    // reserves for a failed construction.
    if (platform.object_owner(ctx, view)) {
        platform.release(platform.context);
        return null;
    }
    const superclass = platform.class_superclass(ctx, previous) orelse {
        platform.release(platform.context);
        return null;
    };
    const name = subclassName(gpa, platform, previous) orelse {
        platform.release(platform.context);
        return null;
    };
    defer gpa.free(name);
    const subclass = platform.class_with_name(ctx, name) orelse blk: {
        const built = platform.build_view_subclass(ctx, name, superclass) orelse {
            platform.release(platform.context);
            return null;
        };
        break :blk built;
    };
    const adapter = adapterNew(
        gpa,
        platform,
        view,
        activation_handler,
        activation_handler_userdata,
        action_handler,
        action_handler_userdata,
        deactivation_handler,
        deactivation_handler_userdata,
    ) orelse return null;
    const slot = gpa.create(IosSubclassingAdapter) catch {
        iosAdapterFree(adapter);
        return null;
    };
    slot.* = .{
        .gpa = gpa,
        .platform = platform,
        .view = view,
        .previous_class = previous,
        .adapter = adapter,
    };
    platform.claim_object(ctx, view, slot);
    platform.set_view_class(ctx, view, subclass);
    // UIKit does not replay `didMoveToWindow` for a view that is already in a
    // window, so upstream catches up by hand at
    // `AK/ios/src/subclass.rs:281-285`.
    if (platform.view_window(ctx, view) != null) {
        if (iosAdapterViewDidAppear(adapter)) |events| iosQueuedEventsRaise(events);
    }
    return slot;
}

/// The name `AK/ios/src/subclass.rs:242` gives the subclass of `previous`:
/// `AccessKitSubclassOf` and the name of the class.
///
/// The name is unique for its superclass, which is what lets a second adapter on
/// a second view of the same class reuse the first one's subclass without a
/// map of them. `null` when the runtime has no name for the class or when the
/// allocation failed, and the port names no subclass without one.
fn subclassName(
    gpa: Allocator,
    platform: objc.Platform,
    previous: *runtime.ObjClass,
) ?[:0]u8 {
    const base = platform.class_name(platform.context, previous) orelse return null;
    const parts = [_][]const u8{ view_subclass_prefix, std.mem.span(base) };
    return std.mem.concatWithSentinel(gpa, u8, &parts, 0) catch null;
}

/// Builds an adapter over `platform`, which the call consumes on every path.
///
/// A `null` return has already released `platform`, so a caller that got one
/// must not release it again. The observer is the last thing built, because it
/// is the only step that can fail after the adapter exists, and a half-registered
/// observer would outlive the adapter.
fn adapterNew(
    gpa: Allocator,
    platform: objc.Platform,
    view: ?*anyopaque,
    activation_handler: boundary.ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: boundary.ActionHandler,
    action_handler_userdata: ?*anyopaque,
    deactivation_handler: boundary.DeactivationHandler,
    deactivation_handler_userdata: ?*anyopaque,
) ?*IosAdapter {
    const host: ?*runtime.AnyObject = @ptrCast(view);
    const ctx = platform.context;
    const superclass = platform.class_with_name(ctx, observer_superclass_name) orelse {
        platform.release(platform.context);
        return null;
    };
    const observer_class = platform.class_with_name(ctx, observer_class_name) orelse blk: {
        const built = platform.build_observer_class(ctx, observer_class_name, superclass) orelse {
            platform.release(platform.context);
            return null;
        };
        break :blk built;
    };
    const slot = gpa.create(IosAdapter) catch {
        platform.release(platform.context);
        allocation.failWith(.out_of_memory);
        return null;
    };
    slot.* = .{
        .gpa = gpa,
        .platform = platform,
        .view = host,
        .activation_handler = activation_handler,
        .activation_userdata = activation_handler_userdata,
        .action_handler = action_handler,
        .action_userdata = action_handler_userdata,
        .deactivation_handler = deactivation_handler,
        .deactivation_userdata = deactivation_handler_userdata,
        .state = .inactive,
        .observer = null,
        .platform_focus = null,
        .platform_nodes = .{ .gpa = gpa },
    };
    errdefer iosAdapterFree(slot);
    const observer = platform.observer_new(ctx, observer_class, slot) orelse return null;
    slot.observer = observer;
    var index: usize = 0;
    while (index < observed_notification_names.len) : (index += 1) {
        platform.add_status_observer(ctx, observer, observed_notification_names[index]);
    }
    return slot;
}

/// The 9 notification names `AK/ios/src/adapter.rs:105-119` registers.
///
/// **The order is the table's, not the array literal's.** The spellings come out
/// of `uikit.identifiers`, which holds the 9 under `.observed_notification` in
/// the map's alphabetical order, so this module writes no notification name of
/// its own and cannot disagree with that table. The order is not observable:
/// the adapter registers nine independent observers and no notification names
/// another, which is why the port takes the set rather than the sequence. The
/// walk is over the 43 rows and keeps the 9 whose kind matches, so the bound is
/// `uikit.identifier_count`.
fn observedNotificationNames() [observed_notification_count][:0]const u8 {
    var names: [observed_notification_count][:0]const u8 = undefined;
    var count: usize = 0;
    for (uikit.identifiers) |identifier| {
        if (identifier.kind != .observed_notification) continue;
        names[count] = identifier.name;
        count += 1;
    }
    std.debug.assert(count == names.len);
    return names;
}

/// The node identifier the debug text prints for the tree's root.
fn rootLocalId(tree: *const Tree) u64 {
    return tree.stateOf().root().id().local.value;
}

/// The node identifier the debug text prints for the tree's focus.
fn focusLocalId(tree: *const Tree) u64 {
    const focus = treeFocusId(tree) orelse return 0;
    return focus.local.value;
}

/// The debug text for `state`, as a buffer the declared allocator made.
///
/// `null` when the allocation failed, and the caller records
/// `Tag.out_of_memory`. **Every arm allocates**, because the caller releases
/// the buffer with `gpa.free` and a string literal is not a block the declared
/// allocator made. An arm that answered a literal left `iosAdapterDebug`
/// freeing a pointer into the read-only image, which is the
/// `free(): invalid pointer` glibc reports on the inactive state.
fn debugText(gpa: Allocator, state: AdapterState) ?[]u8 {
    return switch (state) {
        .inactive => gpa.dupe(
            u8,
            "IosAdapter { state: inactive, root: none, focus: none }",
        ) catch null,
        .placeholder => |tree| std.fmt.allocPrint(
            gpa,
            "IosAdapter {{ state: placeholder, root: {d}, focus: {d} }}",
            .{ rootLocalId(tree), focusLocalId(tree) },
        ) catch null,
        .active => |tree| std.fmt.allocPrint(
            gpa,
            "IosAdapter {{ state: active, root: {d}, focus: {d} }}",
            .{ rootLocalId(tree), focusLocalId(tree) },
        ) catch null,
    };
}

/// The name of one state, for the debug text and for the tests.
///
/// A test compares the name and not the union, because a union with a payload
/// cannot be written as a value, which is why the three assertions in the tests
/// below read `stateName` rather than `AdapterState.active`.
fn stateName(state: AdapterState) []const u8 {
    return switch (state) {
        .inactive => "inactive",
        .placeholder => "placeholder",
        .active => "active",
    };
}

/// Opens the two images the adapter needs and resolves every symbol in them.
///
/// `null` when an image did not open or when the UIKit image exports none of the
/// nine required symbols, and nothing survives: the binding layer closes what
/// it opened. The caller reports that as the `null` the header reserves for a
/// failed construction, because `accesskit_last_error` has one failure tag and
/// it says allocation.
fn openPlatform(gpa: Allocator) ?objc.Platform {
    return objc.platform(
        gpa,
        objc.default_objective_c_image_path,
        objc.default_uikit_image_path,
        callbacks,
    ) catch null;
}

/// Ends the process for a violation the header says ends it.
///
/// `src/capi/tree_info.zig` is the same call and the same reason: the C ABI
/// reports an unrecoverable contract violation by ending the process, because a
/// `null` return is an ordinary answer for most of its functions and would be
/// read as one. This call prints nothing, so which of the eleven call sites saw
/// the violation is not reported; the header sentence each one names is the
/// record of it.
fn terminate() noreturn {
    std.process.exit(1);
}

/// The label of `node` as a buffer the port owns, at
/// `consumer/node_ref/strings.zig:345-361`.
///
/// `null` when the node has no label, which is upstream's `None`. The only tag
/// the consumer adds is `error.WriteFailed`, because the collecting writer it
/// writes through is the only writer in the chain, and the port maps it to
/// `error.OutOfMemory`. `error.OutOfMemory` leaves nothing allocated.
fn labelOf(gpa: Allocator, node: NodeRef) WalkError!?[]u8 {
    const built = consumer.node_ref.strings.label(gpa, node) catch |failure| {
        // The collecting writer the consumer writes through is the only writer
        // in the chain, so its `error.WriteFailed` is `error.OutOfMemory`, at
        // `consumer/node_ref/strings.zig:356-361`.
        switch (failure) {
            error.WriteFailed => return error.OutOfMemory,
            else => |other| return other,
        }
    };
    var list = built orelse return null;
    const owned = try list.toOwnedSlice(gpa);
    return owned;
}

/// Whether two optional identifiers name the same node.
///
/// `FullNodeId` is a struct of a `NodeId` and a `TreeIndex`, and Zig 0.16.0
/// has no `==` for a struct, so the comparison is `std.meta.eql`. Two
/// `null`s are the same, which is what `AK/ios/src/event.rs:164` and `:178`
/// ask.
fn sameNode(a: ?FullNodeId, b: ?FullNodeId) bool {
    return std.meta.eql(a, b);
}

// --- the event generator -----------------------------------------------------

/// What one `UIAccessibilityLayoutChangedNotification` names, at
/// `AK/ios/src/event.rs:157` and `:170-174`.
///
/// Upstream holds an `Option<Option<FullNodeId>>`: no layout event at all, a
/// layout event with no argument, or a layout event with a node. A union with
/// an optional field is the same three states and the field says which one is
/// missing, so a reader does not have to count the `Option`s.
pub const EventFocus = union(enum) {
    /// The event names no node, which is upstream's `Some(None)`.
    none,
    /// The event names this node.
    node: FullNodeId,
};

/// The verdict, the live region and the label of one node, which is everything
/// the two update slots compare.
const NodeSummary = struct {
    /// What the common filter says about the node.
    verdict: consumer.filter.FilterResult,
    /// The nearest live region at or above the node.
    live: schema.Live,
    /// The label the port built, or `null` when the node has none. Owned.
    label: ?[]u8,

    /// Releases the label.
    fn release(self: NodeSummary, gpa: Allocator) void {
        if (self.label) |text| gpa.free(text);
    }
};

/// Builds the events one tree update produced, at
/// `AK/ios/src/event.rs:136-271`.
///
/// iOS is the only one of the four adapters that batches: one flag, one layout
/// event, one focused node per update, at `AK/ios/src/event.rs:170-174` and
/// `:198-204`. Every other event this module queues comes out of that walk.
const EventGenerator = struct {
    /// The adapter the events belong to. The update slots reach it through the
    /// `ptr` of the change handler, so the two are the same allocation and a
    /// slot never captures anything.
    adapter: *IosAdapter,
    /// What the update produced, in order.
    events: std.ArrayList(QueuedEvent) = .empty,
    /// The node the system was on when the update started, and the node it is
    /// on when the update ends.
    platform_focus: ?FullNodeId,
    /// Whether this update owes a layout event, and what it names. `null` owes
    /// none.
    layout_event_focus: ?EventFocus = null,
    /// The first failure a slot recorded, or `null` when every slot finished.
    ///
    /// `consumer.tree.TreeChangeHandler` slots return `void`, so a slot cannot
    /// report a `WalkError` to the update that called it. It records the tag here
    /// instead, and `intoEvents` reads it after the update returns. A generator
    /// with a failure recorded produced a partial event list, so the list is
    /// dropped rather than raised half-built.
    ///
    /// **The tag is kept and not reduced to a bit.** `WalkError` has nine
    /// members, and `error.OutOfMemory` is the only one the C ABI can report
    /// through `accesskit_last_error`. A field that could only say that
    /// something failed would read as the wrong one of the nine to every caller
    /// that inspects it, and the difference is exactly the difference between a
    /// walk that reached its bound and an allocator that ran out. This is the
    /// same shape `src/adapters/macos/events.zig:218` keeps.
    failure: ?WalkError = null,

    /// The handler `Tree.updateAndProcessChanges` reports to.
    fn changeHandler(self: *EventGenerator) TreeChangeHandler {
        return .{
            .ptr = self,
            .node_added = nodeAddedSlot,
            .node_updated = nodeUpdatedSlot,
            .focus_moved = focusMovedSlot,
            .node_removed = nodeRemovedSlot,
        };
    }

    /// Records `failure` and keeps the first failure a slot reported.
    ///
    /// A second failure never clears the first. `intoEvents` reads this once,
    /// after the commit, when the tree is consistent, and it wants the tag that
    /// stopped the walk rather than the last one to arrive.
    fn fail(self: *EventGenerator, failure: WalkError) void {
        if (self.failure == null) self.failure = failure;
        reportQueryFailure(failure);
    }

    /// Adds one event, or records the failure that stopped it.
    fn push(self: *EventGenerator, event: QueuedEvent) void {
        self.events.append(self.adapter.gpa, event) catch |failure| {
            switch (event) {
                .generic, .node_destroyed => {},
                .announcement => |announcement| self.adapter.gpa.free(announcement.text),
            }
            self.fail(failure);
        };
    }

    /// Adds the layout event the update owes, and adds it at most once.
    fn insertLayoutChangedEventIfNeeded(self: *EventGenerator) void {
        if (self.layout_event_focus == null) self.layout_event_focus = .{ .none = {} };
    }

    /// Points the layout event at `focus`, at `AK/ios/src/event.rs:164-166`.
    ///
    /// A focus that did not move adds nothing, and a focus that moved replaces a
    /// layout event that named no node, which is upstream's assignment rather
    /// than a choice between two events.
    fn insertFocusMovedEventIfNeeded(self: *EventGenerator, focus: FullNodeId) void {
        if (sameNode(self.platform_focus, focus)) return;
        self.layout_event_focus = .{ .node = focus };
    }

    /// Drops the object the system cached for `id`, at
    /// `AK/ios/src/event.rs:176-182`.
    fn removeNode(self: *EventGenerator, id: FullNodeId) void {
        self.insertLayoutChangedEventIfNeeded();
        if (sameNode(self.platform_focus, id)) {
            self.adapter.platform_focus = null;
            self.platform_focus = null;
        }
        self.push(.{ .node_destroyed = id });
    }

    /// Drops `node` and everything below it, at `AK/ios/src/event.rs:184-196`.
    ///
    /// **The bound.** The walk pops one node per step and pushes every child it
    /// finds. Each node is pushed once because it has one parent, so the queue
    /// holds at most `node_count` entries and the pops cannot exceed the pushes.
    /// The counter is twice `tree_walk_step_bound(node_count)`, the same
    /// `2 * treeWalkStepBound` the consumer's own hit-test walk uses at
    /// `consumer/node_ref/geometry.zig:299-301`, and reaching it means the tree
    /// has a parent cycle, which the port reports as `error.TreeCycle`.
    fn removeSubtree(self: *EventGenerator, node: NodeRef) void {
        const gpa = self.adapter.gpa;
        var queue: std.ArrayList(NodeRef) = .empty;
        defer queue.deinit(gpa);
        queue.append(gpa, node) catch |failure| {
            self.fail(failure);
            return;
        };
        const bound = 2 * tree_walk_step_bound(node.tree_state.nodes.count());
        var steps: usize = 0;
        var index: usize = 0;
        while (index < queue.items.len) : (index += 1) {
            steps += 1;
            if (steps > bound) {
                self.fail(error.TreeCycle);
                return;
            }
            const current = queue.items[index];
            var cursor = consumer.node_ref.hierarchy.filteredChildren(
                current,
                common_filter,
            ) catch |failure| {
                self.fail(failure);
                return;
            };
            while (cursor.next() catch |failure| {
                self.fail(failure);
                return;
            }) |child| {
                queue.append(gpa, child) catch |failure| {
                    self.fail(failure);
                    return;
                };
            }
            self.removeNode(current.id());
        }
    }

    /// The verdict, the live region and the label of `node`.
    fn summarize(self: *EventGenerator, node: NodeRef) WalkError!NodeSummary {
        const gpa = self.adapter.gpa;
        const verdict = try consumer.filter.commonFilter(node);
        const live = try consumer.node_ref.set_state.live(node);
        return .{ .verdict = verdict, .live = live, .label = try labelOf(gpa, node) };
    }

    /// `AK/ios/src/event.rs:205-213`: one added node owes a layout event, and a
    /// live region owes an announcement.
    fn nodeAdded(self: *EventGenerator, node: NodeRef) void {
        var summary = self.summarize(node) catch |failure| {
            self.fail(failure);
            return;
        };
        defer summary.release(self.adapter.gpa);
        if (summary.verdict != .include) return;
        self.insertLayoutChangedEventIfNeeded();
        if (summary.live == .off) return;
        const text = summary.label orelse return;
        self.push(.{ .announcement = .{ .text = text, .assertive = summary.live == .assertive } });
        // The event owns the text now, so the summary must not release it.
        summary.label = null;
    }

    /// `AK/ios/src/event.rs:215-247`: a node the filter now drops loses its
    /// object and its subtree, a node the filter now keeps owes a layout event,
    /// and a live region whose label or priority changed owes an announcement.
    fn nodeUpdated(self: *EventGenerator, old: NodeRef, new: NodeRef) void {
        const gpa = self.adapter.gpa;
        const old_summary = self.summarize(old) catch |failure| {
            self.fail(failure);
            return;
        };
        defer old_summary.release(gpa);
        var new_summary = self.summarize(new) catch |failure| {
            self.fail(failure);
            return;
        };
        defer new_summary.release(gpa);
        const old_included = old_summary.verdict == .include;
        const new_included = new_summary.verdict == .include;
        if (old_included and !new_included) {
            if (new_summary.verdict == .exclude_subtree) {
                self.removeSubtree(old);
            } else {
                self.removeNode(new.id());
            }
            return;
        }
        if (new_included) self.insertLayoutChangedEventIfNeeded();
        if (new_summary.live == .off) return;
        const text = new_summary.label orelse return;
        const was_filtered_out = old_summary.verdict != .include;
        const label_changed = blk: {
            const old_text = old_summary.label orelse break :blk true;
            break :blk !std.mem.eql(u8, text, old_text);
        };
        if (!label_changed and new_summary.live == old_summary.live and !was_filtered_out) return;
        self.push(.{ .announcement = .{
            .text = text,
            .assertive = new_summary.live == .assertive,
        } });
        new_summary.label = null;
    }

    /// `AK/ios/src/event.rs:249-256`: a focus that landed on a node the filter
    /// keeps points the layout event at it.
    fn focusMoved(self: *EventGenerator, new: ?NodeRef) void {
        const node = new orelse return;
        const verdict = consumer.filter.commonFilter(node) catch |failure| {
            self.fail(failure);
            return;
        };
        if (verdict != .include) return;
        self.insertFocusMovedEventIfNeeded(node.id());
    }

    /// `AK/ios/src/event.rs:258-264`: a removed node loses its object.
    fn nodeRemoved(self: *EventGenerator, node: NodeRef) void {
        const verdict = consumer.filter.commonFilter(node) catch |failure| {
            self.fail(failure);
            return;
        };
        if (verdict != .include) return;
        self.removeNode(node.id());
    }

    /// Finishes the batch: one layout event at the end when one is owed, the
    /// platform focus moved to where this generator left it, and a handle over
    /// the whole list. `AK/ios/src/event.rs:198-204`.
    fn intoEvents(self: *EventGenerator) ?*IosQueuedEvents {
        const adapter = self.adapter;
        if (self.failure != null) {
            releaseEventList(adapter.gpa, &self.events);
            return null;
        }
        if (self.layout_event_focus) |focus| {
            self.push(genericEvent(
                adapter.platform.notification_tags.layout_changed,
                switch (focus) {
                    .none => null,
                    .node => |id| id,
                },
            ));
            if (self.failure != null) {
                releaseEventList(adapter.gpa, &self.events);
                return null;
            }
        }
        adapter.platform_focus = self.platform_focus;
        return queueOwnedEvents(adapter, &self.events);
    }

    /// Releases every event the generator collected and nothing else.
    fn releaseEvents(self: *EventGenerator) void {
        releaseEventList(self.adapter.gpa, &self.events);
    }
};

/// The generator a slot reaches through the change handler's `ptr`.
fn generatorFrom(ptr: *anyopaque) *EventGenerator {
    return @ptrCast(@alignCast(ptr));
}

/// `AK/ios/src/event.rs:205`.
fn nodeAddedSlot(ptr: *anyopaque, node: NodeRef) void {
    generatorFrom(ptr).nodeAdded(node);
}

/// `AK/ios/src/event.rs:215`.
fn nodeUpdatedSlot(ptr: *anyopaque, old: NodeRef, new: NodeRef) void {
    generatorFrom(ptr).nodeUpdated(old, new);
}

/// `AK/ios/src/event.rs:249`.
fn focusMovedSlot(ptr: *anyopaque, _: ?NodeRef, new: ?NodeRef) void {
    generatorFrom(ptr).focusMoved(new);
}

/// `AK/ios/src/event.rs:258`.
fn nodeRemovedSlot(ptr: *anyopaque, node: NodeRef) void {
    generatorFrom(ptr).nodeRemoved(node);
}

// --- the installed implementations come back through these --------------------

/// The adapter the caller claimed, or `null` when there is none.
fn adapterFrom(claimed: ?*anyopaque) ?*IosAdapter {
    const pointer = claimed orelse return null;
    if (@intFromPtr(pointer) == 0) return null;
    return @ptrCast(@alignCast(pointer));
}

/// The subclassing adapter the caller claimed, or `null` when there is none.
fn subclassingAdapterFrom(claimed: ?*anyopaque) ?*IosSubclassingAdapter {
    const pointer = claimed orelse return null;
    if (@intFromPtr(pointer) == 0) return null;
    return @ptrCast(@alignCast(pointer));
}

/// `AK/ios/src/subclass.rs:80-83`: some view classes assume they are the lowest
/// subclass, so the port answers with the superclass of the class the view had
/// before it patched it.
fn callbackViewSuperclass(claimed: ?*anyopaque) ?*runtime.ObjClass {
    const self = subclassingAdapterFrom(claimed) orelse return null;
    const previous = self.previous_class orelse return null;
    return self.platform.class_superclass(self.platform.context, previous);
}

/// `AK/ios/src/subclass.rs:87-92`: UIKit asks the container, so the answer is
/// the adapter's.
fn callbackViewIsAccessibilityElement(claimed: ?*anyopaque) bool {
    const self = subclassingAdapterFrom(claimed) orelse return true;
    return iosAdapterIsAccessibilityElement(self.adapter);
}

/// `AK/ios/src/subclass.rs:95-100`.
fn callbackViewAccessibilityElements(claimed: ?*anyopaque) ?*runtime.AnyObject {
    const self = subclassingAdapterFrom(claimed) orelse return null;
    return @ptrCast(iosAdapterAccessibilityElements(self.adapter));
}

/// `AK/ios/src/subclass.rs:103-112`.
fn callbackViewAccessibilityHitTest(
    claimed: ?*anyopaque,
    point: foundation.CGPoint,
) ?*runtime.AnyObject {
    const self = subclassingAdapterFrom(claimed) orelse return null;
    return @ptrCast(iosAdapterHitTest(self.adapter, point.x, point.y));
}

/// `AK/ios/src/subclass.rs:118`: the class the view carried before the port
/// installed its own, which the forwarding implementation sends to.
fn callbackViewPreviousClass(claimed: ?*anyopaque) ?*runtime.ObjClass {
    const self = subclassingAdapterFrom(claimed) orelse return null;
    return self.previous_class;
}

/// `AK/ios/src/subclass.rs:130-135`: the view is in a window and the adapter is
/// not active yet, so activate it and raise what it produced.
fn callbackViewDidMoveToWindow(claimed: ?*anyopaque) void {
    const self = subclassingAdapterFrom(claimed) orelse return;
    if (iosAdapterViewDidAppear(self.adapter)) |events| iosQueuedEventsRaise(events);
}

/// `AK/ios/src/adapter.rs:266-272`: the last assistive technology either started
/// or stopped.
fn callbackAccessibilityStatusChanged(claimed: ?*anyopaque) void {
    const self = adapterFrom(claimed) orelse return;
    if (self.platform.any_assistive_tech_running(self.platform.context)) {
        _ = getOrInitContext(self);
        return;
    }
    tryDeactivate(self);
}

// --- the fixtures the tests run against ---------------------------------------

/// One announcement the fake platform recorded.
///
/// The text borrows the buffer the handle owns, so a test reads it before it
/// raises the handle and never keeps it.
const FakeAnnouncement = struct {
    /// The text, borrowed.
    text: []const u8,
    /// The priority the adapter asked for.
    assertive: bool,
};
/// A platform that answers every call without leaving this process, and records
/// what it was asked.
///
/// The thirteen entry points build their own platform through `objc.platform`,
/// which reaches UIKit through `std.DynLib` and therefore fails on this host, so
/// the tests drive the functions below `adapterNew` and hand them this. Every
/// one of them is the real code the C ABI calls, and the only thing replaced is
/// the platform.
const Fake = struct {
    /// The allocator the fixture releases its own records with.
    gpa: Allocator,
    /// What `any_assistive_tech_running` answers.
    assistive_tech_running: bool = false,
    /// What `view_window` answers, which is the gate on the activation.
    window: ?*runtime.AnyObject = null,
    /// What `view_screen` answers. `null` is the `AK/ios/src/util.rs:36` `None`.
    screen: ?*runtime.AnyObject = null,
    /// What `screen_coordinate_space` answers.
    space: ?*runtime.AnyObject = null,
    /// The point `view_convert_point` adds, so a test can see the conversion
    /// ran and in which direction.
    convert_offset: foundation.CGPoint = .{ .x = 0, .y = 0 },
    /// What `view_content_scale_factor` answers.
    content_scale: foundation.CGFloat = 1,
    /// The point `view_convert_point` was last asked about.
    last_point: foundation.CGPoint = .{ .x = 0, .y = 0 },
    /// How many times `view_convert_point` ran.
    conversions: usize = 0,
    /// The rect `to_screen_rect` was last asked about.
    screen_rect_input: foundation.CGRect = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 0, .height = 0 },
    },
    /// What `to_screen_rect` answers, which is the input plus this offset, so a
    /// test can see that the conversion ran.
    screen_rect_offset: foundation.CGPoint = .{ .x = 0, .y = 0 },
    /// How many times `to_screen_rect` ran.
    screen_rect_conversions: usize = 0,
    /// What `toggle_button_trait` answers, which is `0` unless a test sets it.
    toggle_trait: u64 = 0,
    /// What `class_name` answers, which is what the subclass name is built from.
    class_name_value: [:0]const u8 = "AKFakeView",
    /// What `class_superclass` answers.
    superclass_value: ?*runtime.ObjClass = null,
    /// What `class_with_name` answers, keyed by name. An empty map makes every
    /// lookup miss, which is what forces the adapter to build the class.
    known_classes: std.StringHashMapUnmanaged(*runtime.ObjClass) = .empty,
    /// How many classes the adapter asked to build.
    classes_built: usize = 0,
    /// Whether the runtime refuses to pair a class, which is upstream's
    /// `ClassBuilder::new(...).unwrap()` failing.
    class_pair_refused: bool = false,
    /// What `view_class` answers.
    view_class_value: ?*runtime.ObjClass = null,
    /// What `window_root_view` answers.
    window_root_view_value: ?*runtime.AnyObject = null,
    /// The class the view carries after `set_view_class`.
    set_view_class_calls: usize = 0,
    /// The owner the fake holds for the object the adapter claimed.
    claimed: ?*anyopaque = null,
    /// How many times `release_object` ran.
    releases: usize = 0,
    /// The instance `observer_new` handed out.
    observer: ?*runtime.AnyObject = null,
    /// How many times `observer_new` ran.
    observers_built: usize = 0,
    /// The notification names the adapter registered, in order. Each name is
    /// one of the nine table rows, so no copy is needed.
    observers: std.ArrayList([]const u8) = .empty,
    /// How many times `remove_status_observer` ran.
    observer_removals: usize = 0,
    /// The tags `notification_tags` carries. The values are the fake's own and
    /// no test reads them as UIKit values.
    tags: objc.NotificationTags = .{
        .screen_changed = 0x1001,
        .layout_changed = 0x1002,
        .announcement = 0x1003,
    },
    /// Every notification the adapter posted, in order.
    posted: std.ArrayList(u64) = .empty,
    /// Every announcement the adapter raised, in order.
    announcements: std.ArrayList(FakeAnnouncement) = .empty,
    /// How many times `empty_array` ran.
    empty_array_calls: usize = 0,
    /// The array `empty_array` hands out.
    array_value: ?*runtime.AnyObject = null,
    /// How many times the table's `release` ran, which is how many platform
    /// tables the adapter under test took.
    platform_releases: usize = 0,

    /// Releases every record the fixture holds. The observations themselves
    /// borrow table rows, so nothing else is freed.
    ///
    /// The last line is the reset: `self.*` is one whole `Fake` with every field
    /// at the value `init` gives it. That is the Z030 shape, and the rule does
    /// not read an assignment to `self.*` as a reset, so this comment says why
    /// the assignment is there.
    fn deinit(self: *Fake) void {
        self.known_classes.deinit(self.gpa);
        self.observers.deinit(self.gpa);
        self.posted.deinit(self.gpa);
        self.announcements.deinit(self.gpa);
        self.* = .{ .gpa = self.gpa };
    }
};

/// The fake a `Platform` entry point receives as its context, or `null` when the
/// caller supplies none.
///
/// Every entry point below answers its own absent form when this is `null`: the
/// false boolean, the null pointer, the zero scalar, the empty point. A handler
/// with no state behind it is not a crash, and this file's rule is that a
/// failure path is a value the caller can read.
fn fakeFrom(ctx: ?*anyopaque) ?*Fake {
    return @ptrCast(@alignCast(ctx));
}

/// The platform an object with no state answers from.
fn fakePointerFrom(backing: u32) *runtime.AnyObject {
    return @ptrFromInt(@as(usize, backing));
}

/// The platform an object with no state answers from, as a class.
fn fakeClassFrom(backing: u32) *runtime.ObjClass {
    return @ptrFromInt(@as(usize, backing));
}

fn fakeAnyAssistiveTechRunning(ctx: ?*anyopaque) bool {
    return (fakeFrom(ctx) orelse return false).assistive_tech_running;
}

fn fakeObserverNew(ctx: ?*anyopaque, _: *runtime.ObjClass, _: ?*anyopaque) ?*runtime.AnyObject {
    const self = fakeFrom(ctx) orelse return null;
    self.observers_built += 1;
    return self.observer orelse fakePointerFrom(0x1000);
}

fn fakeAddStatusObserver(
    ctx: ?*anyopaque,
    _: *runtime.AnyObject,
    notification_name: [:0]const u8,
) void {
    const self = fakeFrom(ctx) orelse return;
    self.observers.append(self.gpa, notification_name) catch return;
}

fn fakeRemoveStatusObserver(ctx: ?*anyopaque, _: *runtime.AnyObject) void {
    const self = fakeFrom(ctx) orelse return;
    self.observer_removals += 1;
}

fn fakeClaimObject(ctx: ?*anyopaque, _: *runtime.AnyObject, adapter: ?*anyopaque) void {
    (fakeFrom(ctx) orelse return).claimed = adapter;
}

fn fakeReleaseObject(ctx: ?*anyopaque, _: *runtime.AnyObject) void {
    const self = fakeFrom(ctx) orelse return;
    self.claimed = null;
    self.releases += 1;
}

fn fakeObjectOwner(ctx: ?*anyopaque, _: *runtime.AnyObject) bool {
    return (fakeFrom(ctx) orelse return false).claimed != null;
}

fn fakeViewWindow(ctx: ?*anyopaque, _: *runtime.AnyObject) ?*runtime.AnyObject {
    return (fakeFrom(ctx) orelse return null).window;
}

fn fakeViewScreen(ctx: ?*anyopaque, _: *runtime.AnyObject) ?*runtime.AnyObject {
    return (fakeFrom(ctx) orelse return null).screen;
}

fn fakeScreenCoordinateSpace(ctx: ?*anyopaque, _: *runtime.AnyObject) ?*runtime.AnyObject {
    return (fakeFrom(ctx) orelse return null).space;
}

fn fakeViewConvertPoint(
    ctx: ?*anyopaque,
    _: *runtime.AnyObject,
    point: foundation.CGPoint,
    _: *runtime.AnyObject,
) foundation.CGPoint {
    const self = fakeFrom(ctx) orelse return .{ .x = 0, .y = 0 };
    self.conversions += 1;
    self.last_point = point;
    return .{
        .x = point.x + self.convert_offset.x,
        .y = point.y + self.convert_offset.y,
    };
}

fn fakeViewContentScaleFactor(ctx: ?*anyopaque, _: *runtime.AnyObject) foundation.CGFloat {
    return (fakeFrom(ctx) orelse return 0).content_scale;
}

fn fakeWindowRootView(ctx: ?*anyopaque, _: *runtime.AnyObject) ?*runtime.AnyObject {
    return (fakeFrom(ctx) orelse return null).window_root_view_value;
}

fn fakeViewClass(ctx: ?*anyopaque, _: *runtime.AnyObject) ?*runtime.ObjClass {
    return (fakeFrom(ctx) orelse return null).view_class_value;
}

fn fakeClassName(ctx: ?*anyopaque, _: *runtime.ObjClass) ?[*:0]const u8 {
    const self = fakeFrom(ctx) orelse return null;
    return self.class_name_value.ptr;
}

fn fakeClassSuperclass(ctx: ?*anyopaque, _: *runtime.ObjClass) ?*runtime.ObjClass {
    return (fakeFrom(ctx) orelse return null).superclass_value;
}

fn fakeClassWithName(ctx: ?*anyopaque, name: [:0]const u8) ?*runtime.ObjClass {
    const self = fakeFrom(ctx) orelse return null;
    if (self.known_classes.get(name)) |known| return known;
    // The Foundation root class is registered on every real platform, so the
    // fixture answers it and nothing else. That makes the adapter build the
    // observer class, and a test that fills the map exercises the reuse path at
    // `AK/ios/src/subclass.rs:241-256`.
    if (std.mem.eql(u8, name, observer_superclass_name)) return fakeClassFrom(0x60);
    return null;
}

fn fakeBuildObserverClass(
    ctx: ?*anyopaque,
    _: [:0]const u8,
    _: *runtime.ObjClass,
) ?*runtime.ObjClass {
    const self = fakeFrom(ctx) orelse return null;
    if (self.class_pair_refused) return null;
    self.classes_built += 1;
    return fakeClassFrom(@intCast(0x2000 + self.classes_built));
}

fn fakeBuildViewSubclass(
    ctx: ?*anyopaque,
    _: [:0]const u8,
    _: *runtime.ObjClass,
) ?*runtime.ObjClass {
    const self = fakeFrom(ctx) orelse return null;
    if (self.class_pair_refused) return null;
    self.classes_built += 1;
    return fakeClassFrom(@intCast(0x2000 + self.classes_built));
}

fn fakeSetViewClass(
    ctx: ?*anyopaque,
    _: *runtime.AnyObject,
    class: *runtime.ObjClass,
) void {
    const self = fakeFrom(ctx) orelse return;
    self.view_class_value = class;
    self.set_view_class_calls += 1;
}

fn fakePostNotification(ctx: ?*anyopaque, notification: u64, _: ?*runtime.AnyObject) void {
    const self = fakeFrom(ctx) orelse return;
    self.posted.append(self.gpa, notification) catch return;
}

fn fakeRaiseAnnouncement(ctx: ?*anyopaque, text: []const u8, assertive: bool) void {
    const self = fakeFrom(ctx) orelse return;
    self.announcements.append(
        self.gpa,
        .{ .text = text, .assertive = assertive },
    ) catch return;
}

fn fakeEmptyArray(ctx: ?*anyopaque) ?*runtime.AnyObject {
    const self = fakeFrom(ctx) orelse return null;
    self.empty_array_calls += 1;
    return self.array_value orelse fakePointerFrom(0x3000);
}

fn fakeToScreenRect(
    ctx: ?*anyopaque,
    _: *runtime.AnyObject,
    rect: foundation.CGRect,
) foundation.CGRect {
    const self = fakeFrom(ctx) orelse return rect;
    self.screen_rect_input = rect;
    self.screen_rect_conversions += 1;
    return .{
        .origin = .{
            .x = rect.origin.x + self.screen_rect_offset.x,
            .y = rect.origin.y + self.screen_rect_offset.y,
        },
        .size = rect.size,
    };
}

fn fakeToggleButtonTrait(ctx: ?*anyopaque) u64 {
    return (fakeFrom(ctx) orelse return 0).toggle_trait;
}

/// The release a fake table carries, which closes nothing and counts once.
///
/// The fake owns no image and no bindings, so there is nothing to close. The
/// counter is the observation, so a path that must release the table it was
/// given says so in a test.
fn fakeReleasePlatform(ctx: ?*anyopaque) void {
    const self = fakeFrom(ctx) orelse return;
    self.platform_releases += 1;
}

/// The `Platform` the tests hand to `adapterNew`.
///
/// Every field is a fake entry point except `context`, which is the fixture,
/// and `notification_tags`, which carries the fixture's tags, so a test that
/// reaches a field this list leaves out reads the fixture's zero value rather
/// than an uninitialised pointer.
fn fakePlatform(state: *Fake) objc.Platform {
    return .{
        .context = state,
        .notification_tags = state.tags,
        .any_assistive_tech_running = fakeAnyAssistiveTechRunning,
        .observer_new = fakeObserverNew,
        .add_status_observer = fakeAddStatusObserver,
        .remove_status_observer = fakeRemoveStatusObserver,
        .claim_object = fakeClaimObject,
        .release_object = fakeReleaseObject,
        .object_owner = fakeObjectOwner,
        .view_window = fakeViewWindow,
        .view_screen = fakeViewScreen,
        .screen_coordinate_space = fakeScreenCoordinateSpace,
        .view_convert_point = fakeViewConvertPoint,
        .view_content_scale_factor = fakeViewContentScaleFactor,
        .window_root_view = fakeWindowRootView,
        .view_class = fakeViewClass,
        .class_name = fakeClassName,
        .class_superclass = fakeClassSuperclass,
        .class_with_name = fakeClassWithName,
        .build_observer_class = fakeBuildObserverClass,
        .build_view_subclass = fakeBuildViewSubclass,
        .set_view_class = fakeSetViewClass,
        .post_notification = fakePostNotification,
        .raise_announcement = fakeRaiseAnnouncement,
        .empty_array = fakeEmptyArray,
        .to_screen_rect = fakeToScreenRect,
        .toggle_button_trait = fakeToggleButtonTrait,
        .release = fakeReleasePlatform,
    };
}

/// What the fixture activation handler answers and what it was asked for.
const ActivationFixture = struct {
    /// The allocator the answer is built with, which is the declared allocator
    /// a C caller would use.
    gpa: Allocator,
    /// The update the next call hands over, or `null` for the ordinary "no tree".
    answer: ?boundary.CTreeUpdate = null,
    /// How many times the handler ran.
    calls: usize = 0,
};

/// The activation handler a test installs.
fn activationHandler() boundary.ActivationHandler {
    return struct {
        fn call(userdata: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
            const fixture: *ActivationFixture = @ptrCast(@alignCast(userdata orelse
                return null));
            fixture.calls += 1;
            const built = fixture.answer orelse return null;
            // A fixture that cannot allocate answers "no tree", and the test
            // then fails on the state it expected rather than on the fixture.
            const block = allocation.create(boundary.CTreeUpdate) catch return null;
            block.* = built;
            fixture.answer = null;
            return block;
        }
    }.call;
}

/// What the fixture deactivation handler recorded.
const DeactivationFixture = struct {
    /// How many times the handler ran.
    calls: usize = 0,
};

/// The deactivation handler a test installs.
fn deactivationHandler() boundary.DeactivationHandler {
    return struct {
        fn call(userdata: ?*anyopaque) callconv(.c) void {
            const fixture: *DeactivationFixture = @ptrCast(@alignCast(userdata orelse
                return));
            fixture.calls += 1;
        }
    }.call;
}

/// The action handler a test installs.
///
/// **This slice never calls it.** The iOS actions arrive through the installed
/// node selectors at `AK/ios/src/node.rs:340-391`, and that layer is the blocked
/// row the module doc names, so the pointer is stored and nothing reaches it. A
/// test asserts the count stays at zero rather than asserting the handler works.
fn actionHandler() boundary.ActionHandler {
    return struct {
        fn call(_: *boundary.CActionRequest, _: ?*anyopaque) callconv(.c) void {}
    }.call;
}

/// What the fixture tree-update factory answers and what it was asked for.
const FactoryFixture = struct {
    /// The allocator the answer is built with.
    gpa: Allocator,
    /// The update the next call hands over, or `null` when the fixture holds
    /// none. The field goes to `null` when a call takes the update, because the
    /// update arrives by transfer and the fixture cannot hand the same one over
    /// twice.
    answer: ?boundary.CTreeUpdate = null,
    /// How many times the factory ran.
    calls: usize = 0,

    /// Releases an answer no call took, which is every answer in a test where
    /// the factory never ran. A call that took the answer leaves nothing here.
    ///
    /// The reset to `self.*` is the Z030 shape, and the rule does not read an
    /// assignment to `self.*` as a reset. It sits above the release on purpose:
    /// the answer is read into a local first, so the value is already reset
    /// before anything below this line can return, and a second call finds
    /// `answer` null rather than an answer it has released.
    fn deinit(self: *FactoryFixture) void {
        const gpa = self.gpa;
        const built = self.answer;
        // SAFETY: the lines below released the only buffer this value owned, and
        // the reset is what a stale read sees. The allocator owns no memory and
        // the counter is a scalar, so neither has anything to invalidate.
        self.* = .{ .gpa = gpa };
        const answer = built orelse return;
        var owned = answer;
        owned.deinit(gpa);
    }
};

/// The tree-update factory a test installs.
fn updateFactory() boundary.TreeUpdateFactory {
    return struct {
        fn call(userdata: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
            const fixture: *FactoryFixture = @ptrCast(@alignCast(userdata orelse
                return null));
            fixture.calls += 1;
            const built = fixture.answer orelse return null;
            const block = allocation.create(boundary.CTreeUpdate) catch return null;
            block.* = built;
            fixture.answer = null;
            return block;
        }
    }.call;
}

/// The first update of a tree with a `root_role` root, `children` buttons and
/// the focus on `focus`.
///
/// `label` and `live` dress one child, so a test can drive the live-region
/// announcement at `AK/ios/src/event.rs:205-213`. `root_role` is the only way
/// a test reaches the `common_filter` role branch at
/// `consumer/filter.zig:171-172`, because a window root is included and a
/// `generic_container` root is not. `error.OutOfMemory` leaves nothing
/// allocated.
fn fixtureUpdate(
    gpa: Allocator,
    root_role: schema.Role,
    children: []const schema.NodeId,
    focus: schema.NodeId,
    dress_first: bool,
) Allocator.Error!boundary.CTreeUpdate {
    var update: boundary.CTreeUpdate = .{};
    errdefer update.deinit(gpa);
    const root = schema.Node.init(gpa, root_role);
    try update.pushNode(gpa, .{ .value = 0 }, root);
    try schema.ids_props.setChildren(&update.nodes.items[0].node.properties, children);
    for (children) |child| {
        const node = schema.Node.init(gpa, .button);
        try update.pushNode(gpa, child, node);
    }
    if (dress_first and children.len > 0) {
        const dressed = &update.nodes.items[1].node;
        try schema.strings.setLabel(&dressed.properties, "OK");
        try schema.enums.setLive(&dressed.properties, .assertive);
    }
    update.tree = schema.TreeInfo.init(.{ .value = 0 });
    update.tree_id = schema.tree_id_root;
    update.focus = focus;
    return update;
}

/// Releases everything `iosAdapterFree` releases.
///
/// The order is the order `iosAdapterFree` uses, so a test that leaves the
/// observer registered or a tree alive fails on the leak checker rather than on
/// a crash. The platform goes back through its own table entry, so the fake
/// counts the release and a real table closes its images.
fn teardown(adapter: *IosAdapter) void {
    const gpa = adapter.gpa;
    if (adapter.observer) |observer| {
        adapter.platform.remove_status_observer(adapter.platform.context, observer);
    }
    releaseState(gpa, &adapter.state);
    adapter.platform_nodes.deinit();
    adapter.platform.release(adapter.platform.context);
    gpa.destroy(adapter);
}

/// Raises and releases `events`, and does nothing for a `null` handle.
///
/// `accesskit_ios_queued_events_raise` is the only release the header declares
/// (`include/zaccesskit.h:5888-5891`), so a test that drops the handle a call
/// returned leaks both the handle and its events. The helper is that release,
/// named so that a test which does not read the events still says that it
/// raised them.
fn raiseEvents(events: ?*IosQueuedEvents) void {
    if (events) |handle| iosQueuedEventsRaise(handle);
}

/// An adapter over `state` with the three fixtures a test drives.
///
/// `null` when the adapter could not be built, which is the only answer
/// `adapterNew` has and which a test that expected one treats as a failure.
fn adapterFor(
    state: *Fake,
    gpa: Allocator,
    activation: *ActivationFixture,
    deactivation: *DeactivationFixture,
) ?*IosAdapter {
    return adapterNew(
        gpa,
        fakePlatform(state),
        fakePointerFrom(0x10),
        activationHandler(),
        activation,
        actionHandler(),
        null,
        deactivationHandler(),
        deactivation,
    );
}

// --- Tests -------------------------------------------------------------------

test "a slot records the tag it failed with, and keeps the first one" {
    // A `TreeChangeHandler` slot returns `void`, so a failure has nowhere to
    // go but this field. `WalkError` carries nine tags and only `OutOfMemory`
    // reaches `accesskit_last_error`, so a field that could only say that
    // something failed would read as an exhausted allocator for every other
    // one of them. A second failure must not overwrite the first either:
    // `intoEvents` reads the field once, after the commit, and the tag that
    // stopped the walk is the one it wants.
    const gpa = testing.allocator;
    var state: Fake = .{ .gpa = gpa };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    var generator: EventGenerator = .{
        .adapter = adapter,
        .platform_focus = adapter.platform_focus,
    };
    defer generator.releaseEvents();
    try testing.expectEqual(@as(?WalkError, null), generator.failure);

    generator.fail(error.TreeCycle);
    try testing.expectEqual(@as(?WalkError, error.TreeCycle), generator.failure);

    generator.fail(error.OutOfMemory);
    try testing.expectEqual(@as(?WalkError, error.TreeCycle), generator.failure);
}

test "the five binding modules and the node layer are reachable and analysed" {
    testing.refAllDecls(foundation);
    testing.refAllDecls(runtime);
    testing.refAllDecls(selectors);
    testing.refAllDecls(uikit);
    testing.refAllDecls(objc);
    testing.refAllDecls(node_layer);
}

test "the census holds the figures the map measured" {
    try testing.expectEqual(@as(usize, 43), uikit.identifier_count);
    try testing.expectEqual(@as(usize, 4), runtime.weak_constant_count);
    try testing.expectEqual(@as(usize, 19), selectors.countOf(.node));
    try testing.expectEqual(@as(usize, 5), selectors.countOf(.host_view));
    try testing.expectEqual(@as(usize, 11), foundation.platform_name_count);
}

test "the blocked record names three symbols and each one is declared" {
    const Self = @This();
    try testing.expectEqual(@as(usize, 3), blocked_count);
    try testing.expectEqualStrings("iosAdapterAccessibilityElements", blocked[0].symbol);
    try testing.expectEqualStrings("iosAdapterHitTest", blocked[1].symbol);
    try testing.expectEqualStrings("iosQueuedEventsRaise", blocked[2].symbol);
    inline for (blocked) |row| {
        // `@hasDecl` needs a comptime name and the table rows are comptime, so
        // a symbol that stops being declared is a compile error rather than a
        // test that stops checking.
        try testing.expect(@hasDecl(Self, row.symbol));
        try testing.expect(row.today.len > 0);
        try testing.expect(row.unblocked_by.len > 0);
    }
}

test "the nine observed notifications are the ones upstream registers" {
    try testing.expectEqual(@as(usize, 9), observed_notification_count);
    try testing.expectEqual(observed_notification_count, observed_notification_names.len);
    // The set is upstream's, at `AK/ios/src/adapter.rs:105-119`. The order is
    // the table's rather than the array literal's, because the adapter
    // registers nine independent observers and no observer's order is
    // observable, while the spellings all come out of `uikit.identifiers` so
    // that this module writes no notification name of its own.
    const expected = [_][]const u8{
        "UIAccessibilityVoiceOverStatusDidChangeNotification",
        "UIAccessibilitySwitchControlStatusDidChangeNotification",
        "UIAccessibilitySpeakScreenStatusDidChangeNotification",
        "UIAccessibilityInvertColorsStatusDidChangeNotification",
        "UIAccessibilityReduceMotionStatusDidChangeNotification",
        "UIAccessibilityBoldTextStatusDidChangeNotification",
        "UIAccessibilityDarkerSystemColorsStatusDidChangeNotification",
        "UIAccessibilityOnOffSwitchLabelsDidChangeNotification",
        "UIAccessibilityVideoAutoplayStatusDidChangeNotification",
    };
    for (expected) |name| {
        var found = false;
        for (observed_notification_names) |observed| {
            if (std.mem.eql(u8, name, observed)) found = true;
        }
        try testing.expect(found);
    }
}

test "the observer class and the subclass prefix are spelled as upstream spells them" {
    try testing.expectEqualStrings("AccessKitAccessibilityStatusObserver", observer_class_name);
    try testing.expectEqualStrings("AccessKitSubclassOf", view_subclass_prefix);
    // The observer's superclass is the Foundation root class, and the spelling
    // has to agree with the table in `foundation`.
    try testing.expectEqualStrings("NSObject", observer_superclass_name);
    try testing.expect(foundation.find(observer_superclass_name) != null);
    try testing.expectEqual(@as(u64, 0), placeholder_root_id.value);
}

test "the thirteen entry points have the signatures the C ABI calls" {
    // Each row is the whole signature `src/capi/platform.zig` calls, so a
    // parameter that drifts, a return that drifts and a calling convention that
    // drifts all fail here rather than in the platform's own code. None of the
    // thirteen carries `callconv(.c)`, because the convention belongs to the
    // `@export`ed wrapper and `src/capi/boundary.zig:126-129` warns about a
    // callback whose convention is wrong.
    const Activation = boundary.ActivationHandler;
    const Action = boundary.ActionHandler;
    const Deactivation = boundary.DeactivationHandler;
    const Factory = boundary.TreeUpdateFactory;
    const Userdata = ?*anyopaque;
    const NewSignature = fn (
        Userdata,
        Activation,
        Userdata,
        Action,
        Userdata,
        Deactivation,
        Userdata,
    ) ?*IosAdapter;
    const SubclassingSignature = fn (
        Userdata,
        Activation,
        Userdata,
        Action,
        Userdata,
        Deactivation,
        Userdata,
    ) ?*IosSubclassingAdapter;

    try testing.expectEqual(fn (*IosQueuedEvents) void, @TypeOf(iosQueuedEventsRaise));
    try testing.expectEqual(NewSignature, @TypeOf(iosAdapterNew));
    try testing.expectEqual(fn (*IosAdapter) void, @TypeOf(iosAdapterFree));
    try testing.expectEqual(
        fn (*IosAdapter, Factory, Userdata) ?*IosQueuedEvents,
        @TypeOf(iosAdapterUpdateIfActive),
    );
    try testing.expectEqual(fn (*IosAdapter) ?*IosQueuedEvents, @TypeOf(iosAdapterViewDidAppear));
    try testing.expectEqual(fn (*IosAdapter) bool, @TypeOf(iosAdapterIsAccessibilityElement));
    try testing.expectEqual(
        fn (*IosAdapter) ?*anyopaque,
        @TypeOf(iosAdapterAccessibilityElements),
    );
    try testing.expectEqual(
        fn (*IosAdapter, f64, f64) ?*anyopaque,
        @TypeOf(iosAdapterHitTest),
    );
    try testing.expectEqual(fn (*const IosAdapter) ?[*:0]u8, @TypeOf(iosAdapterDebug));
    try testing.expectEqual(SubclassingSignature, @TypeOf(iosSubclassingAdapterNew));
    try testing.expectEqual(SubclassingSignature, @TypeOf(iosSubclassingAdapterForWindow));
    try testing.expectEqual(
        fn (*IosSubclassingAdapter) void,
        @TypeOf(iosSubclassingAdapterFree),
    );
    try testing.expectEqual(
        fn (*IosSubclassingAdapter, Factory, Userdata) ?*IosQueuedEvents,
        @TypeOf(iosSubclassingAdapterUpdateIfActive),
    );
}

test "a new adapter is inactive, holds the handlers, and registers the nine notifications" {
    const gpa = testing.allocator;
    var state: Fake = .{ .gpa = gpa };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    try testing.expectEqualStrings("inactive", stateName(adapter.state));
    try testing.expectEqual(observed_notification_count, state.observers.items.len);
    try testing.expectEqual(@as(usize, 1), state.observers_built);
    try testing.expectEqual(@as(usize, 0), activation.calls);
    try testing.expectEqual(@as(usize, 0), deactivation.calls);
    // The action handler is stored and never called, which is the blocked row
    // the module doc names.
    try testing.expect(@intFromPtr(adapter.action_handler) != 0);
    // The observer class was built once, and `NSObject` was looked up first.
    try testing.expectEqual(@as(usize, 1), state.classes_built);
}

test "view did appear does nothing while no assistive technology runs" {
    const gpa = testing.allocator;
    var state: Fake = .{ .gpa = gpa, .assistive_tech_running = false };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    try testing.expectEqual(@as(?*IosQueuedEvents, null), iosAdapterViewDidAppear(adapter));
    try testing.expectEqual(@as(usize, 0), activation.calls);
    try testing.expectEqualStrings("inactive", stateName(adapter.state));
}

test "view did appear activates the adapter and queues one layout event on the focus" {
    const gpa = testing.allocator;
    var state: Fake = .{ .gpa = gpa, .assistive_tech_running = true };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    const answer = try fixtureUpdate(gpa, .window, &.{.{ .value = 1 }}, .{ .value = 1 }, false);
    activation.answer = answer;
    const events = iosAdapterViewDidAppear(adapter) orelse return error.NoEvents;
    try testing.expectEqualStrings("active", stateName(adapter.state));
    try testing.expectEqual(@as(usize, 1), events.events.len);
    const event = events.events[0];
    try testing.expectEqual(state.tags.layout_changed, event.generic.notification);
    try testing.expectEqual(
        FullNodeId.init(.{ .value = 1 }, consumer.tree_index.TreeIndex.init(0)),
        event.generic.node_id orelse return error.NoFocus,
    );
    iosQueuedEventsRaise(events);
    try testing.expectEqual(@as(usize, 1), state.posted.items.len);
    try testing.expectEqual(state.tags.layout_changed, state.posted.items[0]);
}

test "an activation handler that answers no tree leaves the placeholder state and no events" {
    const gpa = testing.allocator;
    var state: Fake = .{ .gpa = gpa, .assistive_tech_running = true };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    // The fixture answers `null`, which is the ordinary "no tree".
    try testing.expectEqual(@as(?*IosQueuedEvents, null), iosAdapterViewDidAppear(adapter));
    try testing.expectEqual(@as(usize, 1), activation.calls);
    const tree = switch (adapter.state) {
        .placeholder => |held| held,
        else => return error.NotPlaceholder,
    };
    // The placeholder is the one-node window at `AK/ios/src/adapter.rs:170-180`.
    try testing.expectEqual(@as(u64, 0), tree.stateOf().root().id().local.value);
    try testing.expectEqual(schema.Role.window, tree.stateOf().root().data().role);
}

test "an inactive adapter never calls the update factory" {
    const gpa = testing.allocator;
    var state: Fake = .{ .gpa = gpa };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    var factory: FactoryFixture = .{
        .gpa = gpa,
        .answer = try fixtureUpdate(gpa, .window, &.{}, .{ .value = 0 }, false),
    };
    // The factory never runs, so nothing takes this answer, and the fixture
    // releases it.
    defer factory.deinit();
    try testing.expectEqual(
        @as(?*IosQueuedEvents, null),
        iosAdapterUpdateIfActive(adapter, updateFactory(), &factory),
    );
    try testing.expectEqual(@as(usize, 0), factory.calls);
}

test "an update out of the placeholder state becomes active and queues a screen changed event" {
    const gpa = testing.allocator;
    var state: Fake = .{ .gpa = gpa, .assistive_tech_running = true };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    raiseEvents(iosAdapterViewDidAppear(adapter));
    try testing.expectEqualStrings("placeholder", stateName(adapter.state));
    var factory: FactoryFixture = .{
        .gpa = gpa,
        .answer = try fixtureUpdate(gpa, .window, &.{.{ .value = 1 }}, .{ .value = 1 }, false),
    };
    defer factory.deinit();
    const events = iosAdapterUpdateIfActive(
        adapter,
        updateFactory(),
        &factory,
    ) orelse return error.NoEvents;
    try testing.expectEqualStrings("active", stateName(adapter.state));
    try testing.expectEqual(@as(usize, 1), factory.calls);
    try testing.expectEqual(@as(usize, 1), events.events.len);
    try testing.expectEqual(state.tags.screen_changed, events.events[0].generic.notification);
    iosQueuedEventsRaise(events);
    try testing.expectEqual(@as(usize, 1), state.posted.items.len);
}

test "the last assistive technology stopping deactivates the adapter exactly once" {
    const gpa = testing.allocator;
    var state: Fake = .{ .gpa = gpa, .assistive_tech_running = true };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    activation.answer = try fixtureUpdate(gpa, .window, &.{}, .{ .value = 0 }, false);
    raiseEvents(iosAdapterViewDidAppear(adapter));
    try testing.expectEqualStrings("active", stateName(adapter.state));
    state.assistive_tech_running = false;
    callbacks.accessibility_status_changed(adapter);
    try testing.expectEqualStrings("inactive", stateName(adapter.state));
    try testing.expectEqual(@as(usize, 1), deactivation.calls);
    callbacks.accessibility_status_changed(adapter);
    try testing.expectEqual(@as(usize, 1), deactivation.calls);
    // A stopped adapter asks the application for a tree again when the
    // technology starts, which is the other arm of
    // `AK/ios/src/adapter.rs:258-275`. The first update arrived by transfer and
    // the fixture cannot hand the same one over twice, so a second answer has to
    // be built. Without one the handler would answer "no tree", which is the
    // placeholder state and not the active one.
    activation.answer = try fixtureUpdate(gpa, .window, &.{}, .{ .value = 0 }, false);
    state.assistive_tech_running = true;
    callbacks.accessibility_status_changed(adapter);
    try testing.expectEqual(@as(usize, 2), activation.calls);
    try testing.expectEqualStrings("active", stateName(adapter.state));
}

test "the debug text names the state, the root and the focus, and the adapter may go first" {
    const gpa = testing.allocator;
    var state: Fake = .{ .gpa = gpa, .assistive_tech_running = true };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    const inactive = iosAdapterDebug(adapter) orelse return error.NoText;
    defer allocation.release(inactive);
    try testing.expectEqualStrings(
        "IosAdapter { state: inactive, root: none, focus: none }",
        std.mem.span(inactive),
    );

    activation.answer = try fixtureUpdate(
        gpa,
        .window,
        &.{.{ .value = 2 }},
        .{ .value = 2 },
        false,
    );
    raiseEvents(iosAdapterViewDidAppear(adapter));
    const active = iosAdapterDebug(adapter) orelse return error.NoText;
    defer allocation.release(active);
    try testing.expectEqualStrings(
        "IosAdapter { state: active, root: 0, focus: 2 }",
        std.mem.span(active),
    );
}

test "the debug text names the placeholder state and the one-node tree under it" {
    const gpa = testing.allocator;
    var state: Fake = .{ .gpa = gpa, .assistive_tech_running = true };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    // The activation handler answers "no tree", so the port builds the
    // one-node placeholder tree at `AK/ios/src/adapter.rs:170-180` and the text
    // names it rather than the literal the inactive state uses.
    raiseEvents(iosAdapterViewDidAppear(adapter));
    try testing.expectEqualStrings("placeholder", stateName(adapter.state));
    const text = iosAdapterDebug(adapter) orelse return error.NoText;
    defer allocation.release(text);
    try testing.expectEqualStrings(
        "IosAdapter { state: placeholder, root: 0, focus: 0 }",
        std.mem.span(text),
    );
}

test "the element walk answers with the root or with the filtered children" {
    const gpa = testing.allocator;
    var state: Fake = .{ .gpa = gpa, .assistive_tech_running = true };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    // A window root is not one of the three roles `common_filter` drops, so the
    // walk answers with the root itself and with nothing below it. That is the
    // first arm of `AK/ios/src/adapter.rs:459-480`, which
    // `docs/29-apple-android-apis.md:158-161` records in these words.
    activation.answer = try fixtureUpdate(
        gpa,
        .window,
        &.{ .{ .value = 1 }, .{ .value = 2 } },
        .{ .value = 0 },
        false,
    );
    raiseEvents(iosAdapterViewDidAppear(adapter));
    const with_root = try elementIdentifiers(adapter);
    defer gpa.free(with_root);
    try testing.expectEqual(@as(usize, 1), with_root.len);
    try testing.expectEqual(@as(u64, 0), with_root[0].local.value);
    // The answer is the empty array until the node layer writes to the map.
    try testing.expect(iosAdapterAccessibilityElements(adapter) != null);
    try testing.expectEqual(@as(usize, 1), state.empty_array_calls);

    // A generic container root is the other branch of the same rule, so the
    // walk answers with the filtered children. The focus sits on a child,
    // because `common_filter_base` includes a focused node before it reaches
    // the role branch at `consumer/filter.zig:165`.
    state.assistive_tech_running = false;
    callbacks.accessibility_status_changed(adapter);
    activation.answer = try fixtureUpdate(
        gpa,
        .generic_container,
        &.{ .{ .value = 1 }, .{ .value = 2 } },
        .{ .value = 1 },
        false,
    );
    state.assistive_tech_running = true;
    callbacks.accessibility_status_changed(adapter);
    const with_children = try elementIdentifiers(adapter);
    defer gpa.free(with_children);
    try testing.expectEqual(@as(usize, 2), with_children.len);
    try testing.expectEqual(@as(u64, 1), with_children[0].local.value);
    try testing.expectEqual(@as(u64, 2), with_children[1].local.value);
}

test "the platform node map answers for the identifiers the node layer wrote" {
    const gpa = testing.allocator;
    var state: Fake = .{
        .gpa = gpa,
        .assistive_tech_running = true,
        .window = fakePointerFrom(0x11),
        .screen = fakePointerFrom(0x12),
        .space = fakePointerFrom(0x13),
    };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    activation.answer = try fixtureUpdate(
        gpa,
        .window,
        &.{.{ .value = 1 }},
        .{ .value = 1 },
        false,
    );
    raiseEvents(iosAdapterViewDidAppear(adapter));
    // The fixture gives no node a box, so the hit test finds nothing and falls
    // back to the root, which is upstream's `unwrap_or(root)` at
    // `AK/ios/src/adapter.rs:499`. The map entry therefore belongs to the root.
    const id = FullNodeId.init(.{ .value = 0 }, consumer.tree_index.TreeIndex.init(0));
    // Nothing has written to the map, which is the blocked row, so the hit test
    // answers null after it has done the conversion.
    try testing.expectEqual(@as(?*anyopaque, null), iosAdapterHitTest(adapter, 3, 4));
    try testing.expectEqual(@as(usize, 1), state.conversions);
    try testing.expectEqual(@as(foundation.CGFloat, 3), state.last_point.x);
    // A written entry answers the object, and a removal takes it away again.
    try adapter.platform_nodes.insert(id, fakePointerFrom(0x4000));
    try testing.expectEqual(
        @as(?*anyopaque, @ptrCast(fakePointerFrom(0x4000))),
        iosAdapterHitTest(adapter, 3, 4),
    );
    adapter.platform_nodes.remove(id);
    try testing.expectEqual(@as(?*anyopaque, null), iosAdapterHitTest(adapter, 3, 4));
}

test "the point conversion scales by the content scale and inverts the tree transform" {
    const gpa = testing.allocator;
    var state: Fake = .{
        .gpa = gpa,
        .assistive_tech_running = true,
        .window = fakePointerFrom(0x11),
        .screen = fakePointerFrom(0x12),
        .space = fakePointerFrom(0x13),
        .convert_offset = .{ .x = 2, .y = -1 },
        .content_scale = 2,
    };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    activation.answer = try fixtureUpdate(gpa, .window, &.{}, .{ .value = 0 }, false);
    raiseEvents(iosAdapterViewDidAppear(adapter));
    const tree = switch (adapter.state) {
        .active => |held| held,
        else => return error.NotActive,
    };
    const point = try treePoint(
        adapter,
        fakePointerFrom(0x10),
        tree.stateOf().root(),
        .{ .x = 1, .y = 1 },
    );
    // `(1, 1)` becomes `(3, 0)` in the view's own space, the scale makes it
    // `(6, 0)`, and the tree's transform is the identity for a root with none.
    try testing.expectEqual(@as(f64, 6), point.x);
    try testing.expectEqual(@as(f64, 0), point.y);
}

test "the rect conversion divides by the content scale and converts to the screen" {
    // The reverse of the test above, at `AK/ios/src/util.rs:50-63`. The fake
    // adds `screen_rect_offset` to the rect it is given, so the test can see
    // that the division ran before the conversion and that the conversion ran
    // at all.
    const gpa = testing.allocator;
    var state: Fake = .{
        .gpa = gpa,
        .assistive_tech_running = true,
        .content_scale = 2,
        .screen_rect_offset = .{ .x = 100, .y = 200 },
    };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    const rect: schema.Rect = .{ .x0 = 4, .y0 = 6, .x1 = 12, .y1 = 18 };
    const screen = toCgRect(adapter, fakePointerFrom(0x10), rect);

    // The tree's `(4, 6)` with a width of `8` and a height of `12` divide by the
    // scale of `2`, and the conversion moves the origin by the offset.
    try testing.expectEqual(@as(foundation.CGFloat, 2), state.screen_rect_input.origin.x);
    try testing.expectEqual(@as(foundation.CGFloat, 3), state.screen_rect_input.origin.y);
    try testing.expectEqual(@as(foundation.CGFloat, 4), state.screen_rect_input.size.width);
    try testing.expectEqual(@as(foundation.CGFloat, 6), state.screen_rect_input.size.height);
    try testing.expectEqual(@as(usize, 1), state.screen_rect_conversions);
    try testing.expectEqual(@as(foundation.CGFloat, 102), screen.origin.x);
    try testing.expectEqual(@as(foundation.CGFloat, 203), screen.origin.y);
    try testing.expectEqual(@as(foundation.CGFloat, 4), screen.size.width);
    try testing.expectEqual(@as(foundation.CGFloat, 6), screen.size.height);
}

test "a view with no window answers the hit test with no window" {
    const gpa = testing.allocator;
    var state: Fake = .{ .gpa = gpa, .assistive_tech_running = true, .window = null };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    activation.answer = try fixtureUpdate(gpa, .window, &.{}, .{ .value = 0 }, false);
    raiseEvents(iosAdapterViewDidAppear(adapter));
    const active = activeTree(adapter) orelse return error.NoActiveTree;
    try testing.expectError(error.NoWindow, treePoint(
        adapter,
        fakePointerFrom(0x10),
        active.stateOf().root(),
        .{ .x = 0, .y = 0 },
    ));
    try testing.expectEqual(@as(usize, 0), state.conversions);
}

test "the subclassing adapter names the subclass after the view class and restores it" {
    const gpa = testing.allocator;
    var state: Fake = .{
        .gpa = gpa,
        .assistive_tech_running = false,
        .view_class_value = fakeClassFrom(0x51),
        .superclass_value = fakeClassFrom(0x52),
        .class_name_value = "AKFakeView",
    };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = subclassingAdapterNew(
        gpa,
        fakePlatform(&state),
        fakePointerFrom(0x50),
        activationHandler(),
        &activation,
        actionHandler(),
        null,
        deactivationHandler(),
        &deactivation,
    ) orelse return error.NoAdapter;
    defer {
        adapter.platform.release_object(adapter.platform.context, adapter.view);
        teardown(adapter.adapter);
        gpa.destroy(adapter);
    }
    // One class for the observer and one for the view, and the name is the
    // prefix and the class name at `AK/ios/src/subclass.rs:242`.
    try testing.expectEqual(@as(usize, 2), state.classes_built);
    const name = try std.mem.concatWithSentinel(
        gpa,
        u8,
        &.{ view_subclass_prefix, state.class_name_value },
        0,
    );
    defer gpa.free(name);
    try testing.expectEqualStrings("AccessKitSubclassOfAKFakeView", name);
    try testing.expect(state.claimed != null);
    try testing.expectEqual(@as(usize, 1), state.set_view_class_calls);
    const assigned = state.view_class_value orelse return error.NoAssignedClass;
    try testing.expect(assigned != fakeClassFrom(0x51));
}

test "a second subclassing adapter on the same view is refused and changes nothing" {
    const gpa = testing.allocator;
    var state: Fake = .{
        .gpa = gpa,
        .view_class_value = fakeClassFrom(0x51),
        .superclass_value = fakeClassFrom(0x52),
        .claimed = @ptrFromInt(@as(usize, 0x99)),
    };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const refused = subclassingAdapterNew(
        gpa,
        fakePlatform(&state),
        fakePointerFrom(0x50),
        activationHandler(),
        &activation,
        actionHandler(),
        null,
        deactivationHandler(),
        &deactivation,
    );
    try testing.expectEqual(@as(?*IosSubclassingAdapter, null), refused);
    try testing.expectEqual(@as(usize, 0), state.classes_built);
    try testing.expectEqual(@as(usize, 0), state.set_view_class_calls);
    // The refusal returns the table it was given, so nothing is left open.
    try testing.expectEqual(@as(usize, 1), state.platform_releases);
}

test "the transferred update survives the release of the block the factory handed over" {
    const gpa = testing.allocator;
    const built = try fixtureUpdate(gpa, .window, &.{.{ .value = 1 }}, .{ .value = 1 }, true);
    const block = try allocation.create(boundary.CTreeUpdate);
    block.* = built;
    const taken = takeTransferredUpdate(block);
    // The nodes are still there after the block went back to the declared
    // allocator, which is what `accesskit_tree_update_free` does.
    try testing.expectEqual(@as(usize, 2), taken.nodes.items.len);
    try testing.expectEqual(@as(u64, 1), taken.focus.value);
    try testing.expect(taken.tree != null);
    var owned = taken;
    owned.deinit(gpa);
}

test "the queued events handle is released by raising it" {
    const gpa = testing.allocator;
    var state: Fake = .{ .gpa = gpa, .assistive_tech_running = true };
    defer state.deinit();
    var activation: ActivationFixture = .{ .gpa = gpa };
    var deactivation: DeactivationFixture = .{};
    const adapter = adapterFor(&state, gpa, &activation, &deactivation) orelse
        return error.NoAdapter;
    defer teardown(adapter);

    activation.answer = try fixtureUpdate(gpa, .window, &.{}, .{ .value = 0 }, false);
    const events = iosAdapterViewDidAppear(adapter) orelse return error.NoEvents;
    try testing.expectEqual(@as(usize, 1), events.events.len);
    iosQueuedEventsRaise(events);
    // A second call is a use-after-free the header forbids, so the test proves
    // the release instead by letting the leak checker run.
    try testing.expectEqual(@as(usize, 1), state.posted.items.len);
}

test "every platform entry point answers its absent form with no context" {
    // A `Platform` whose `context` is `null` is the table a caller that hands
    // over no fixture gets. Each entry point below must answer its own absent
    // form rather than dereference the null. The assertion is per entry point:
    // the absent form is the false boolean, the null pointer, the zero scalar
    // or the empty point, and a caller can read each one.
    const table: objc.Platform = .{
        .context = null,
        .notification_tags = .{
            .screen_changed = 0,
            .layout_changed = 0,
            .announcement = 0,
        },
        .any_assistive_tech_running = fakeAnyAssistiveTechRunning,
        .observer_new = fakeObserverNew,
        .add_status_observer = fakeAddStatusObserver,
        .remove_status_observer = fakeRemoveStatusObserver,
        .claim_object = fakeClaimObject,
        .release_object = fakeReleaseObject,
        .object_owner = fakeObjectOwner,
        .view_window = fakeViewWindow,
        .view_screen = fakeViewScreen,
        .screen_coordinate_space = fakeScreenCoordinateSpace,
        .view_convert_point = fakeViewConvertPoint,
        .view_content_scale_factor = fakeViewContentScaleFactor,
        .window_root_view = fakeWindowRootView,
        .view_class = fakeViewClass,
        .class_name = fakeClassName,
        .class_superclass = fakeClassSuperclass,
        .class_with_name = fakeClassWithName,
        .build_observer_class = fakeBuildObserverClass,
        .build_view_subclass = fakeBuildViewSubclass,
        .set_view_class = fakeSetViewClass,
        .post_notification = fakePostNotification,
        .raise_announcement = fakeRaiseAnnouncement,
        .empty_array = fakeEmptyArray,
        .to_screen_rect = fakeToScreenRect,
        .toggle_button_trait = fakeToggleButtonTrait,
        .release = fakeReleasePlatform,
    };
    const ctx = table.context;

    // The false boolean. An assistive technology running is a claim about the
    // fixture, and a fixture that is not there has made no claim.
    try testing.expectEqual(false, table.any_assistive_tech_running(ctx));
    // The false boolean again, for the owner check.
    try testing.expectEqual(false, table.object_owner(ctx, fakePointerFrom(0x10)));
    // The null pointer. An observer with no fixture behind it is not allocated,
    // and a class pair with no fixture is not registered.
    try testing.expectEqual(
        @as(?*runtime.AnyObject, null),
        table.observer_new(ctx, fakeClassFrom(0x60), null),
    );
    try testing.expectEqual(
        @as(?*runtime.ObjClass, null),
        table.class_with_name(ctx, observer_class_name),
    );
    try testing.expectEqual(
        @as(?*runtime.ObjClass, null),
        table.build_observer_class(ctx, observer_class_name, fakeClassFrom(0x60)),
    );
    try testing.expectEqual(
        @as(?*runtime.ObjClass, null),
        table.build_view_subclass(ctx, observer_class_name, fakeClassFrom(0x60)),
    );
    try testing.expectEqual(@as(?*runtime.AnyObject, null), table.empty_array(ctx));
    // The remaining null pointers, which are the getters.
    try testing.expectEqual(
        @as(?*runtime.AnyObject, null),
        table.view_window(ctx, fakePointerFrom(1)),
    );
    try testing.expectEqual(
        @as(?*runtime.AnyObject, null),
        table.view_screen(ctx, fakePointerFrom(1)),
    );
    try testing.expectEqual(
        @as(?*runtime.AnyObject, null),
        table.screen_coordinate_space(ctx, fakePointerFrom(1)),
    );
    try testing.expectEqual(
        @as(?*runtime.AnyObject, null),
        table.window_root_view(ctx, fakePointerFrom(1)),
    );
    try testing.expectEqual(
        @as(?*runtime.ObjClass, null),
        table.view_class(ctx, fakePointerFrom(1)),
    );
    try testing.expectEqual(
        @as(?*runtime.ObjClass, null),
        table.class_superclass(ctx, fakeClassFrom(1)),
    );
    try testing.expectEqual(
        @as(?[*:0]const u8, null),
        table.class_name(ctx, fakeClassFrom(1)),
    );
    // The zero scalar, which is the content scale factor.
    try testing.expectEqual(
        @as(foundation.CGFloat, 0),
        table.view_content_scale_factor(ctx, fakePointerFrom(1)),
    );
    // The empty point, which is the conversion of a view that has no fixture.
    const converted = table.view_convert_point(
        ctx,
        fakePointerFrom(1),
        .{ .x = 7, .y = 9 },
        fakePointerFrom(2),
    );
    try testing.expectEqual(@as(foundation.CGFloat, 0), converted.x);
    try testing.expectEqual(@as(foundation.CGFloat, 0), converted.y);
    // The void entry points. Each one writes to the fixture or appends to one
    // of its lists, so with no fixture each returns without touching memory.
    // The test cannot observe the absence of a write, so what it proves is that
    // none of them dereferences the null, which is a crash in Debug.
    table.add_status_observer(ctx, fakePointerFrom(1), observer_class_name);
    table.remove_status_observer(ctx, fakePointerFrom(1));
    table.claim_object(ctx, fakePointerFrom(1), null);
    table.release_object(ctx, fakePointerFrom(1));
    table.set_view_class(ctx, fakePointerFrom(1), fakeClassFrom(1));
    table.post_notification(ctx, 0x1001, null);
    table.raise_announcement(ctx, "absent", true);
    table.release(ctx);
}
