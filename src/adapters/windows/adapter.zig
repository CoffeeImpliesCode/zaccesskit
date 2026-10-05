//! The Windows platform adapter: the three states, the tree, and the five
//! operations a window procedure and an application call.
//!
//! **What this file ports.** `Adapter` from
//! `adapters/windows/src/adapter.rs:376-594` in the pinned upstream tree: the
//! `State` enum, the five methods `new`, `update_if_active`,
//! `update_window_focus_state` and `handle_wm_getobject`, and the two helpers
//! `init_uia` and `normalize_objid` that the C ABI folds into it.
//! `platform.zig` is the C ABI half of the same design, and its ten Windows
//! declarations are written against this file.
//!
//! **What is compiled and tested on this host.** The whole state machine: which
//! of the three states a call finds, what each one answers, which `null` means
//! "no tree", and the `WM_GETOBJECT` decision. The UI Automation call at the
//! end of `handleWmGetobject` is the platform seam in `syscalls.zig`, and a
//! test drives it with a recording seam.
//!
//! **What needs the real platform.** Nothing in the state machine, and nothing
//! in the ten C entry points in `root.zig`; every platform call is one of the
//! six slots `syscalls.Platform` declares. A Windows host adds the COM node
//! layer that fills the provider slots.
//!
//! **What this file does not port, and why.** `NodeWrapper::enqueue_property_changes`
//! in `adapters/windows/src/node.rs` raises the per-node property changes and
//! builds a `VARIANT` for each one. It is not missing by oversight. Its input
//! is one node's state against the state that node held before the update, its
//! property domain is the 41 `UIA_*PropertyId` values `bindings.zig` lists, and
//! its output is the `com.VARIANT` `com.zig` writes. The first belongs to the
//! node layer, which this directory does not have, and the other two are in
//! files `build.zig.zon` keeps out of the Linux analysis graph because it
//! names only `zio`. `syscalls.PropertyId` therefore carries one member, for
//! the one property change `adapter.rs` itself raises beside each selection
//! event.
//!
//! **Loop bounds.** No loop outside a test. The walks that could run away —
//! the filter and the filtered children — are the consumer half's, and each
//! carries the bound its own module derives.

const std = @import("std");

const action_request = @import("../../capi/action_request.zig");
const allocation = @import("../../capi/allocation.zig");
const boundary = @import("../../capi/boundary.zig");
const change_handler = @import("change_handler.zig");
const consumer = @import("../../consumer/root.zig");
const elements = @import("elements.zig");
const queued_events = @import("queued_events.zig");
const schema = @import("../../schema/root.zig");
const syscalls = @import("syscalls.zig");

const ActionHandler = boundary.ActionHandler;
const ActivationHandler = boundary.ActivationHandler;
const COptLResult = boundary.COptLResult;
const CTreeUpdate = boundary.CTreeUpdate;
const Hwnd = boundary.Hwnd;
const LParam = boundary.LParam;
const LResult = syscalls.LResult;
const WParam = boundary.WParam;

const EventId = syscalls.EventId;
const Platform = syscalls.Platform;
const ProviderSlot = syscalls.ProviderSlot;
const RaiseReport = queued_events.RaiseReport;
const Tree = consumer.tree.Tree;
const UpdateError = consumer.tree.UpdateError;

/// Everything an adapter call can fail with.
///
/// The first four tags come from `consumer.tree.Tree` and reach this file
/// through `Tree.init` and `Tree.updateAndProcessChanges`. The last two are
/// this adapter's own: a tree update factory that returned `null` is a
/// contract violation rather than an ordinary answer, and a query over the tree
/// reported an error inside a change slot.
pub const Error = UpdateError || error{
    /// The factory installed by the caller answered `null`. Upstream unwraps
    /// the same value at `adapter.rs:554`, so a `null` here is a contract
    /// violation and not "no tree".
    NullTreeUpdate,

    /// A change slot recorded a `QueryError` while the update committed.
    TreeQueryFailed,
};

/// Which of the three states the adapter holds.
///
/// Upstream `State` at `adapter.rs:376-384`. The tree is held by value, so a
/// transition moves it rather than copying it, and the three arms hold no two
/// owners.
const State = union(enum) {
    /// No tree yet. The window, the focus flag and the action handler are on the
    /// adapter, not here, because they outlive the tree.
    inactive: void,
    /// A one-node placeholder tree, built when the activation handler answered
    /// `null`. Upstream `State::Placeholder`.
    placeholder: Tree,
    /// The real tree. Upstream `State::Active`.
    active: Tree,
};

/// The Windows platform adapter.
///
/// The caller owns the adapter and releases it with `free`. It owns one tree at
/// a time and one provider registry, and `deinit` releases both.
pub const WindowsAdapter = struct {
    /// The allocator that grew the tree and the registry.
    gpa: std.mem.Allocator,

    /// The seam every provider and UI Automation call goes through.
    platform: Platform,

    /// The window the adapter is bound to. `null` names no window, which is an
    /// ordinary value and not a failure.
    hwnd: Hwnd,

    /// The focus flag the window procedure last reported. It is read only while
    /// the state is `inactive`, because after that the tree owns the flag.
    is_window_focused: bool,

    /// The handler a platform action reaches. It stays valid until the adapter
    /// is released, which is what `platform.zig` promises the C caller.
    action_handler: ActionHandler,

    /// The pointer `action_handler` receives unchanged.
    action_handler_userdata: ?*anyopaque,

    /// Which of the three states the adapter holds.
    state: State = .inactive,

    /// The providers the adapter has published.
    registry: elements.Registry,

    /// What the last raise did, so `debug` can report a refusal that the C ABI
    /// has nowhere else to put.
    last_raise_report: RaiseReport = .{},

    /// The last failure, so `debug` can report one the C ABI cannot return.
    last_error: ?Error = null,

    /// Builds an adapter in the `inactive` state.
    ///
    /// **Errors.** `error.OutOfMemory` when the registry cannot be built; it
    /// allocates nothing, so only a later call can fail.
    ///
    /// This calls `Platform.init_uia` first, because upstream calls
    /// `init_uia()` inside `Adapter::new` at `adapter.rs:441` and
    /// `adapter.rs:596-604`: a `WM_GETOBJECT` that arrives before UI Automation
    /// has loaded brings a nested message, and assistive technologies then do
    /// not notice that the window implements UI Automation natively.
    pub fn create(
        gpa: std.mem.Allocator,
        platform: Platform,
        hwnd: Hwnd,
        is_window_focused: bool,
        action_handler: ActionHandler,
        action_handler_userdata: ?*anyopaque,
    ) std.mem.Allocator.Error!*WindowsAdapter {
        _ = platform.init_uia();
        const adapter = try gpa.create(WindowsAdapter);
        adapter.* = .{
            .gpa = gpa,
            .platform = platform,
            .hwnd = hwnd,
            .is_window_focused = is_window_focused,
            .action_handler = action_handler,
            .action_handler_userdata = action_handler_userdata,
            .registry = elements.Registry.init(gpa),
        };
        return adapter;
    }

    /// Releases the tree, the registry and the adapter.
    ///
    /// `error.OutOfMemory` never appears: nothing here allocates. A caller must
    /// call this exactly once, and a caller that calls it twice has a double
    /// free.
    pub fn deinit(self: *WindowsAdapter) void {
        const gpa = self.gpa;
        switch (self.state) {
            .inactive => {},
            .placeholder => |*held| held.deinit(),
            .active => |*held| held.deinit(),
        }
        self.state = .inactive;
        self.registry.deinit(self.platform);
        gpa.destroy(self);
    }

    /// Whether the adapter holds a tree.
    ///
    /// This is upstream's `!matches!(self.state, State::Inactive { .. })` at
    /// `adapter.rs:467-468`: `update_if_active` answers `null` in that one case
    /// and an answer in the other two.
    pub fn isActive(self: *const WindowsAdapter) bool {
        return self.state != .inactive;
    }

    /// Whether the adapter holds the placeholder tree.
    pub fn isPlaceholder(self: *const WindowsAdapter) bool {
        return self.state == .placeholder;
    }

    /// The tree the adapter holds, or `null` while it is inactive.
    pub fn tree(self: *WindowsAdapter) ?*Tree {
        return switch (self.state) {
            .inactive => null,
            .placeholder => |*held| held,
            .active => |*held| held,
        };
    }

    /// Asks `update_factory` for a tree and applies the answer.
    ///
    /// Upstream `update_if_active` at `adapter.rs:463-490`. The three arms are
    /// the three states: an inactive adapter answers `null`, a placeholder
    /// adapter builds the real tree and queues one focus event, and an active
    /// adapter applies the update and queues whatever it changed.
    ///
    /// **Errors.** `Error`. Every failure up to the point the new tree is
    /// installed leaves the adapter holding the tree it held before the call,
    /// so a caller may retry with a corrected update. A failure after that
    /// point leaves the adapter active on the new tree with the focus event
    /// lost, because the update has been consumed and cannot be replayed.
    /// `error.NullTreeUpdate` is a contract violation on the caller's side.
    pub fn updateIfActive(
        self: *WindowsAdapter,
        update_factory: boundary.TreeUpdateFactory,
        update_factory_userdata: ?*anyopaque,
    ) Error!?QueuedEventsHolder {
        switch (self.state) {
            .inactive => {
                self.last_error = null;
                return null;
            },
            .placeholder => {
                const update = WindowsAdapter.takeUpdate(
                    update_factory,
                    update_factory_userdata,
                ) catch |err| {
                    self.last_error = err;
                    return err;
                };
                const was_focused = self.tree().?.stateOf().isHostFocused();
                // The real tree is built before the placeholder is released, so
                // an allocation failure leaves the placeholder in the state
                // rather than leaving the adapter inactive.
                const real = Tree.init(self.gpa, update, was_focused) catch |err| {
                    self.last_error = err;
                    return err;
                };
                self.destroyCurrentTree();
                self.state = .{ .active = real };

                var queue = QueuedEventsHolder.init(self);
                const focused = self.tree().?.stateOf().focus();
                if (focused) |node| {
                    const slot = self.registry.slotFor(self.platform, node.id()) catch |err| {
                        self.last_error = err;
                        queue.deinit();
                        return err;
                    };
                    queue.append(.{
                        .simple = .{ .slot = slot, .event_id = .automation_focus_changed },
                    }) catch |err| {
                        self.last_error = err;
                        queue.deinit();
                        return err;
                    };
                }
                self.last_error = null;
                return queue;
            },
            .active => {
                const update = WindowsAdapter.takeUpdate(
                    update_factory,
                    update_factory_userdata,
                ) catch |err| {
                    self.last_error = err;
                    return err;
                };
                var queue = QueuedEventsHolder.init(self);
                errdefer queue.deinit();

                var handler = change_handler.Handler.init(
                    self.gpa,
                    self.platform,
                    &self.registry,
                    &queue.queue,
                );
                defer handler.deinit();

                const held = self.tree().?;
                held.updateAndProcessChanges(update, &handler.changeHandler()) catch |err| {
                    self.last_error = err;
                    return err;
                };
                // The detailed `QueryError` reaches the handler's own
                // `Failure`, and this arm reports the single tag the C ABI has.
                handler.enqueueSelectionChanges(held.stateOf()) catch {
                    self.last_error = error.TreeQueryFailed;
                    return error.TreeQueryFailed;
                };
                if (handler.takeFailure()) |failure| {
                    self.last_error = if (failure.out_of_memory)
                        error.OutOfMemory
                    else
                        error.TreeQueryFailed;
                    return self.last_error.?;
                }
                self.last_error = null;
                return queue;
            },
        }
    }

    /// Records the focus flag and applies it to the tree.
    ///
    /// Upstream `update_window_focus_state` at `adapter.rs:500-521`.
    ///
    /// **Errors.** `Error`. An inactive adapter answers `null` and only records
    /// the flag, because it has no tree to apply it to.
    pub fn updateWindowFocusState(
        self: *WindowsAdapter,
        is_focused: bool,
    ) Error!?QueuedEventsHolder {
        switch (self.state) {
            .inactive => {
                self.is_window_focused = is_focused;
                self.last_error = null;
                return null;
            },
            .placeholder, .active => {
                var queue = QueuedEventsHolder.init(self);
                errdefer queue.deinit();

                var handler = change_handler.Handler.init(
                    self.gpa,
                    self.platform,
                    &self.registry,
                    &queue.queue,
                );
                defer handler.deinit();

                const held = self.tree().?;
                held.updateHostFocusStateAndProcessChanges(
                    is_focused,
                    &handler.changeHandler(),
                ) catch |err| {
                    self.last_error = err;
                    return err;
                };
                // The detailed `QueryError` reaches the handler's own
                // `Failure`, and this arm reports the single tag the C ABI has.
                handler.enqueueSelectionChanges(held.stateOf()) catch {
                    self.last_error = error.TreeQueryFailed;
                    return error.TreeQueryFailed;
                };
                if (handler.takeFailure()) |failure| {
                    self.last_error = if (failure.out_of_memory)
                        error.OutOfMemory
                    else
                        error.TreeQueryFailed;
                    return self.last_error.?;
                }
                self.last_error = null;
                return queue;
            },
        }
    }

    /// Answers a `WM_GETOBJECT` message from a window procedure.
    ///
    /// Upstream `handle_wm_getobject` at `adapter.rs:534-593`.
    ///
    /// **The object identifier.** A sender may ask for something other than the
    /// provider root, and `DefWindowProc` answers those, so an identifier that
    /// is negative and is neither `UiaRootObjectId` nor `OBJID_CLIENT` answers
    /// `has_value = false` at `adapter.rs:544-547`.
    ///
    /// **The activation.** An inactive adapter asks `activation_handler` for a
    /// tree. A non-`null` answer builds the real tree; a `null` answer is an
    /// ordinary answer meaning "no tree", and the adapter builds the one-node
    /// placeholder tree of `adapter.rs:566-574`.
    ///
    /// **The lock.** Upstream returns a value that converts to the `LRESULT`
    /// later, so the caller can release its own lock before the nested
    /// `WM_GETOBJECT` arrives. The C ABI returns the `LRESULT` itself, so the
    /// platform call runs inside this call and the caller must hold no lock.
    ///
    /// This call cannot fail: an activation handler that throws is not a case
    /// this boundary has, and a tree that will not build leaves the adapter
    /// inactive and answers `has_value = false`.
    pub fn handleWmGetobject(
        self: *WindowsAdapter,
        wparam: WParam,
        lparam: LParam,
        activation_handler: ActivationHandler,
        activation_handler_userdata: ?*anyopaque,
    ) COptLResult {
        const objid = syscalls.normalizeObjId(lparam);
        if (objid < 0 and
            objid != syscalls.uia_root_object_id and
            objid != syscalls.objid_client)
        {
            return noLResult();
        }

        const slot: *const ProviderSlot = switch (self.state) {
            .inactive => self.activate(activation_handler, activation_handler_userdata) orelse
                return noLResult(),
            .placeholder => self.registry.placeholderSlot(),
            .active => blk: {
                const root_id = self.tree().?.stateOf().rootId();
                const built = self.registry.slotFor(self.platform, root_id) catch {
                    self.last_error = error.OutOfMemory;
                    return noLResult();
                };
                break :blk built;
            },
        };

        const value: LResult = self.platform.return_raw_element_provider(
            self.hwnd,
            wparam,
            lparam,
            slot,
        );
        return .{ .has_value = true, .value = value };
    }

    /// Hands one platform action to the installed handler.
    ///
    /// Upstream reaches this through `ActionHandlerWrapper` at `context.rs`, and
    /// the wrapper is the node layer's file. The C ABI half is here, because it
    /// is the half that owns the request: it builds the `CActionRequest`, hands
    /// the pointer over, and does **not** release it.
    ///
    /// **Ownership.** The callback owns the request from the moment it is called
    /// and must release it with `accesskit_action_request_free` before it
    /// returns, on every path out. A callback that stores the pointer has a
    /// use-after-free and one that releases it twice has a double free.
    ///
    /// **Errors.** `error.OutOfMemory` and `error.InteriorNul`, from
    /// `schema.actionDataToC`. Nothing is handed to the callback on either path,
    /// so the handler is not called and no request exists to free.
    pub fn dispatchAction(self: *WindowsAdapter, request: schema.ActionRequest) !void {
        const gpa = self.gpa;

        var payload: ?schema.CActionData = null;
        if (request.data) |data| payload = try schema.actionDataToC(gpa, data);

        const built = try allocation.create(schema.CActionRequest);
        built.* = .{
            .action = request.action,
            .target_tree = request.target_tree,
            .target_node = request.target_node,
            .data = .{
                .has_value = payload != null,
                .value = payload orelse std.mem.zeroes(schema.CActionData),
            },
        };
        // Ownership moves to the callback here. Nothing after this line releases
        // the request.
        action_request.callActionHandler(self.action_handler, built, self.action_handler_userdata);
    }

    /// Asks the activation handler for a tree and enters the active or the
    /// placeholder state, answering the provider to name.
    fn activate(
        self: *WindowsAdapter,
        activation_handler: ActivationHandler,
        activation_handler_userdata: ?*anyopaque,
    ) ?*const ProviderSlot {
        const produced = activation_handler(activation_handler_userdata);
        if (produced) |tree_update| {
            const update = takeOwnedUpdate(tree_update);
            const real = Tree.init(self.gpa, update, self.is_window_focused) catch {
                return null;
            };
            self.state = .{ .active = real };
            const root_id = self.tree().?.stateOf().rootId();
            const built = self.registry.slotFor(self.platform, root_id) catch {
                return null;
            };
            return built;
        }

        // A `null` answer means "no tree", not a failure. Upstream builds the
        // one-node placeholder at `adapter.rs:566-574`.
        const placeholder = self.placeholderUpdate() catch {
            return null;
        };
        const real = Tree.init(self.gpa, placeholder, self.is_window_focused) catch {
            return null;
        };
        self.state = .{ .placeholder = real };
        return self.registry.placeholderSlot();
    }

    /// The one-node placeholder update of `adapter.rs:566-571`.
    ///
    /// **Errors.** `error.OutOfMemory`. Nothing is handed on, so no caller
    /// holds a half-built update.
    fn placeholderUpdate(self: *WindowsAdapter) !schema.TreeUpdate {
        const gpa = self.gpa;
        var update: schema.TreeUpdate = .{};
        errdefer update.deinit(gpa);
        const placeholder_id: schema.NodeId = .{ .value = 0 };
        try update.pushNode(gpa, placeholder_id, schema.Node.init(gpa, .window));
        update.tree = schema.TreeInfo.init(placeholder_id);
        update.tree_id = schema.tree_id_root;
        update.focus = placeholder_id;
        return update;
    }

    /// Asks the factory for an update and takes ownership of the box.
    ///
    /// **Errors.** `error.NullTreeUpdate` and `error.OutOfMemory`. Nothing
    /// survives either path: a `null` factory answer has no box, and the box is
    /// released before this returns.
    fn takeUpdate(
        update_factory: boundary.TreeUpdateFactory,
        update_factory_userdata: ?*anyopaque,
    ) !schema.TreeUpdate {
        const produced = update_factory(update_factory_userdata) orelse
            return error.NullTreeUpdate;
        return takeOwnedUpdate(produced);
    }

    /// Releases the tree the state holds and answers an empty one.
    fn destroyCurrentTree(self: *WindowsAdapter) void {
        switch (self.state) {
            .inactive => {},
            .placeholder => |*held| held.deinit(),
            .active => |*held| held.deinit(),
        }
        self.state = .inactive;
        std.debug.assert(self.state == .inactive);
    }
};

/// Moves the tree out of the box the factory returned and releases the box.
///
/// The box holds the update by value, so moving the value out and releasing
/// the box is the whole of the ownership transfer. Nothing here allocates, so
/// this call cannot fail.
fn takeOwnedUpdate(box: *CTreeUpdate) schema.TreeUpdate {
    const owned = box;
    defer allocation.release(owned);
    return owned.*;
}

/// The `accesskit_opt_lresult` that tells the window procedure to pass the
/// message to `DefWindowProc`.
///
/// `value` is a zero the port writes, so a reader who ignores the flag reads a
/// defined zero rather than uninitialised storage.
fn noLResult() COptLResult {
    return .{ .has_value = false, .value = 0 };
}

/// The events one adapter call produced, boxed so a C handle can name them.
///
/// `platform.zig` returns `?*WindowsQueuedEvents`, so the queue is one
/// allocation with the queue inside it. `queued_events.QueuedEvents` itself is
/// the value; this is the box that owns it and that names the adapter the
/// events belong to, which is what lets `raise` report to that adapter.
pub const QueuedEventsHolder = struct {
    /// The adapter that produced these events. The pointer is borrowed and the
    /// box does not keep the adapter alive.
    ///
    /// A queued event already names a `syscalls.ProviderSlot` that the
    /// adapter's registry owns and releases, so raising after
    /// `WindowsAdapter.deinit` is a use-after-free whether or not this field
    /// exists. It is here so that `raise` runs on the seam which built those
    /// providers and so the refusal report lands on the adapter
    /// `windowsAdapterDebug` reads it from.
    adapter: *WindowsAdapter,

    /// The events, which the box owns and `raise` or `deinit` releases.
    queue: queued_events.QueuedEvents,

    /// An empty holder for `adapter`. Nothing is allocated, so this call cannot
    /// fail.
    pub fn init(adapter: *WindowsAdapter) QueuedEventsHolder {
        return .{ .adapter = adapter, .queue = queued_events.QueuedEvents.init(adapter.gpa) };
    }

    /// Adds one event at the end of the queue.
    ///
    /// **Errors.** `error.OutOfMemory` from the array growing. The queue is
    /// unchanged on that path, so the caller has lost exactly this event.
    pub fn append(
        self: *QueuedEventsHolder,
        event: queued_events.QueuedEvent,
    ) std.mem.Allocator.Error!void {
        try self.queue.append(event);
    }

    /// Releases the events without raising any of them.
    ///
    /// The providers the queue owns are released with the seam that built
    /// them, which is the one `adapter` holds. The box is left in its reset
    /// form, so a second call releases nothing. The adapter is not released.
    pub fn deinit(self: *QueuedEventsHolder) void {
        self.queue.deinit(self.adapter.platform);
    }

    /// Raises the events, releases the box, and answers what the raise did.
    ///
    /// The events go through the seam the adapter holds, and the report is
    /// recorded on that adapter as `last_raise_report`, which is where
    /// `windowsAdapterDebug` prints it. Nothing is allocated here.
    ///
    /// The value is taken by value because the caller has handed over the only
    /// handle to it. The allocator comes from the box itself, so a second call
    /// is a use-after-free and `include/zaccesskit.h` says so.
    pub fn raise(self: QueuedEventsHolder) RaiseReport {
        const report = self.queue.raise(self.adapter.platform);
        self.adapter.last_raise_report = report;
        return report;
    }

    /// How many events the box holds.
    pub fn len(self: *const QueuedEventsHolder) usize {
        return self.queue.len();
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

/// What a fixture callback needs.
///
/// The allocator is the one the adapter under test was built with, because
/// `Tree.init` releases the update a factory built and an update built with
/// any other allocator would be freed by the wrong one. The two counters are
/// how a test tells one call from two.
const Fixture = struct {
    /// The allocator the adapter under test was built with.
    gpa: std.mem.Allocator,

    /// How many times the activation handler ran.
    activation_calls: usize = 0,

    /// How many times the update factory ran.
    update_calls: usize = 0,
};

/// The fixture behind a callback, or `null` when the caller passed no context.
fn fixtureOf(context: ?*anyopaque) ?*Fixture {
    const any = context orelse return null;
    return @ptrCast(@alignCast(any));
}

/// One whole tree: a window that is its own root and holds the focus.
///
/// The nodes come from `gpa`, the allocator the adapter releases the tree
/// with, and the box comes from the declared allocator, which is the only one
/// `WindowsAdapter.takeOwnedUpdate` releases. Every failing path releases what
/// it built, so the allocation sweep below runs no leak.
fn buildWholeTree(gpa: std.mem.Allocator) ?*boundary.CTreeUpdate {
    var update: schema.TreeUpdate = .{};
    const node = schema.Node.init(gpa, .window);
    update.pushNode(gpa, .{ .value = 1 }, node) catch {
        update.deinit(gpa);
        return null;
    };
    update.tree = schema.TreeInfo.init(.{ .value = 1 });
    update.focus = .{ .value = 1 };
    const boxed = allocation.create(schema.TreeUpdate) catch {
        update.deinit(gpa);
        return null;
    };
    boxed.* = update;
    return boxed;
}

/// An activation handler that answers one whole tree.
fn activateWithTree(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    const fixture = fixtureOf(context) orelse return null;
    fixture.activation_calls += 1;
    return buildWholeTree(fixture.gpa);
}

/// An activation handler that answers no tree, which is an ordinary answer
/// upstream and means the adapter builds the placeholder.
fn activateWithNothing(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    const fixture = fixtureOf(context) orelse return null;
    fixture.activation_calls += 1;
    return null;
}

/// An update factory that answers one whole tree.
fn wholeTreeFactory(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    const fixture = fixtureOf(context) orelse return null;
    fixture.update_calls += 1;
    return buildWholeTree(fixture.gpa);
}

/// An update factory that answers `null`, which upstream unwraps and the port
/// reports as a contract violation.
fn nullFactory(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    _ = context;
    return null;
}

/// An action handler that releases the request it is handed, which is the duty
/// `dispatchAction` puts on every callback.
fn releaseAction(request: *boundary.CActionRequest, context: ?*anyopaque) callconv(.c) void {
    _ = context;
    schema.cActionRequestDeinit(allocation.allocator(), request);
    allocation.release(request);
}

/// Builds an adapter over `hwnd` from `gpa`, with the seam that refuses, so a
/// test drives the state machine and every block it makes is one the caller
/// named.
fn buildTestAdapter(
    gpa: std.mem.Allocator,
    fixture: *Fixture,
    hwnd: boundary.Hwnd,
    is_window_focused: bool,
) !*WindowsAdapter {
    return WindowsAdapter.create(
        gpa,
        syscalls.unavailablePlatform(),
        hwnd,
        is_window_focused,
        &releaseAction,
        fixture,
    ) catch return error.OutOfMemory;
}

/// Asserts the state an adapter must be in once it has answered a tree: active,
/// not the placeholder, and holding the tree it answered.
fn expectActivated(target: *WindowsAdapter) !void {
    try testing.expect(target.isActive());
    try testing.expect(!target.isPlaceholder());
    try testing.expect(target.tree() != null);
}

/// How many allocation failures the placeholder sweep tries before it gives
/// up.
///
/// The bound is this constant because the sweep is over an allocator counter
/// rather than over a domain of the adapter: the placeholder arm builds a tree
/// and one provider, and how many allocations that is depends on how the
/// consumer half grows its arrays. The sweep stops at the first attempt that
/// gets past the install, so the bound only has to sit above that count, and a
/// bound that did not would fail the test rather than pass it quietly.
const placeholder_failure_bound: usize = 16;

test "a new adapter is inactive and holds nothing" {
    var fixture: Fixture = .{ .gpa = testing.allocator };
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4000), false);
    defer target.deinit();

    try testing.expect(!target.isActive());
    try testing.expect(!target.isPlaceholder());
    try testing.expectEqual(@as(?*Tree, null), target.tree());
    try testing.expectEqual(@as(usize, 0), target.registry.nodeCount());
    try testing.expectEqual(@as(?Error, null), target.last_error);
    try testing.expectEqual(@as(usize, 0), target.last_raise_report.total());
}

test "an update on an inactive adapter answers null and never calls the factory" {
    var fixture: Fixture = .{ .gpa = testing.allocator };
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4100), false);
    defer target.deinit();

    // `adapter.rs:468` answers `None` in the inactive state, and a factory call
    // there would build a tree the adapter has nowhere to put.
    if (try target.updateIfActive(&wholeTreeFactory, &fixture) != null) {
        return error.EventsOnAnInactiveAdapter;
    }
    try testing.expectEqual(@as(usize, 0), fixture.update_calls);
    try testing.expect(!target.isActive());
}

test "the inactive focus arm records the flag and answers null" {
    var fixture: Fixture = .{ .gpa = testing.allocator };
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4200), false);
    defer target.deinit();

    if (try target.updateWindowFocusState(true) != null) return error.EventsOnAnInactiveAdapter;
    // The flag is the whole of what this arm records, at `adapter.rs:502-506`,
    // because an adapter with no tree has no tree to apply it to.
    try testing.expect(target.is_window_focused);
    try testing.expect(!target.isActive());
    try testing.expectEqual(@as(?*Tree, null), target.tree());
}

test "a WM_GETOBJECT for an identifier this adapter does not own stays inactive" {
    var fixture: Fixture = .{ .gpa = testing.allocator };
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4300), false);
    defer target.deinit();

    // `adapter.rs:544-547` passes every negative identifier that is neither
    // `UiaRootObjectId` nor `OBJID_CLIENT` to `DefWindowProc`, so the
    // activation handler is never reached.
    const answer = target.handleWmGetobject(
        0,
        @as(LParam, -5),
        &activateWithTree,
        &fixture,
    );
    try testing.expect(!answer.has_value);
    try testing.expectEqual(@as(isize, 0), answer.value);
    try testing.expectEqual(@as(usize, 0), fixture.activation_calls);
    try testing.expect(!target.isActive());
}

test "activation that answers no tree enters the placeholder state" {
    var fixture: Fixture = .{ .gpa = testing.allocator };
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4400), false);
    defer target.deinit();

    const answer = target.handleWmGetobject(
        0,
        @as(LParam, syscalls.uia_root_object_id),
        &activateWithNothing,
        &fixture,
    );
    try testing.expect(answer.has_value);
    try testing.expectEqual(@as(usize, 1), fixture.activation_calls);
    try testing.expect(target.isActive());
    try testing.expect(target.isPlaceholder());
    // The placeholder provider names no node, so it is not in the map and the
    // count stays at zero. `adapter.rs:575` builds it with
    // `PlatformNode::unspecified_root`.
    try testing.expectEqual(@as(usize, 0), target.registry.nodeCount());
}

test "activation that answers a tree enters the active state" {
    var fixture: Fixture = .{ .gpa = testing.allocator };
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4500), false);
    defer target.deinit();

    const answer = target.handleWmGetobject(
        0,
        @as(LParam, syscalls.objid_client),
        &activateWithTree,
        &fixture,
    );
    try testing.expect(answer.has_value);
    try testing.expectEqual(@as(usize, 1), fixture.activation_calls);
    try expectActivated(target);
    // The real tree has a root node, so the adapter publishes a provider for
    // it rather than naming the placeholder.
    try testing.expectEqual(@as(usize, 1), target.registry.nodeCount());
}

test "a second WM_GETOBJECT in the placeholder state answers the same provider" {
    var fixture: Fixture = .{ .gpa = testing.allocator };
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4600), false);
    defer target.deinit();

    const first = target.handleWmGetobject(
        0,
        @as(LParam, syscalls.objid_client),
        &activateWithNothing,
        &fixture,
    );
    const second = target.handleWmGetobject(
        0,
        @as(LParam, syscalls.objid_client),
        &activateWithNothing,
        &fixture,
    );
    try testing.expect(first.has_value);
    try testing.expect(second.has_value);
    // The activation handler ran once. A second run would build a second
    // placeholder over the first, and the three states have no edge between
    // them that would allow it.
    try testing.expectEqual(@as(usize, 1), fixture.activation_calls);
    try testing.expect(target.isPlaceholder());
}

test "the first update replaces the placeholder with the real tree" {
    var fixture: Fixture = .{ .gpa = testing.allocator };
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4700), true);
    defer target.deinit();

    _ = target.handleWmGetobject(
        0,
        @as(LParam, syscalls.uia_root_object_id),
        &activateWithNothing,
        &fixture,
    );
    try testing.expect(target.isPlaceholder());

    // The window holds focus and the tree declares one, so the placeholder arm
    // queues the single focus event of `adapter.rs:470-480`.
    const events = (try target.updateIfActive(&wholeTreeFactory, &fixture)) orelse
        return error.NoEvents;
    try expectActivated(target);
    try testing.expectEqual(@as(usize, 1), fixture.update_calls);
    try testing.expectEqual(@as(usize, 1), target.registry.nodeCount());
    try testing.expectEqual(@as(usize, 1), events.len());
    _ = events.raise();
}

test "a focus update on the placeholder keeps the placeholder state" {
    var fixture: Fixture = .{ .gpa = testing.allocator };
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4800), true);
    defer target.deinit();

    _ = target.handleWmGetobject(
        0,
        @as(LParam, syscalls.uia_root_object_id),
        &activateWithNothing,
        &fixture,
    );
    const events = (try target.updateWindowFocusState(false)) orelse return error.NoEvents;

    // The focus arm applies the flag to the tree the state holds, and the
    // placeholder tree is the tree the state holds.
    try testing.expect(target.isActive());
    try testing.expect(target.isPlaceholder());
    try testing.expectEqual(@as(usize, 0), fixture.update_calls);
    _ = events.raise();
}

test "no call takes an activated adapter back to inactive or to the placeholder" {
    var fixture: Fixture = .{ .gpa = testing.allocator };
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4900), true);
    defer target.deinit();

    _ = target.handleWmGetobject(
        0,
        @as(LParam, syscalls.objid_client),
        &activateWithTree,
        &fixture,
    );
    try expectActivated(target);

    // Each state has one direction. There is no `deactivate` in this module or
    // upstream, and the only place that releases a tree outside `deinit` is the
    // placeholder arm of `updateIfActive`, which installs the real tree where
    // the placeholder was. Every public operation is walked here, so an
    // operation added later is covered by the same assertion. The activation
    // handler here answers no tree, so an arm that reached it would leave the
    // adapter in the placeholder and fail the second assertion.
    const events = (try target.updateIfActive(&wholeTreeFactory, &fixture)) orelse
        return error.NoEvents;
    try expectActivated(target);
    try testing.expectEqual(@as(usize, 1), fixture.activation_calls);
    _ = events.raise();

    const focused = (try target.updateWindowFocusState(false)) orelse return error.NoEvents;
    try expectActivated(target);
    _ = focused.raise();

    const answered = target.handleWmGetobject(
        0,
        @as(LParam, syscalls.objid_client),
        &activateWithNothing,
        &fixture,
    );
    try testing.expect(answered.has_value);
    try expectActivated(target);
    try testing.expectEqual(@as(usize, 1), fixture.activation_calls);
}

test "a factory that answers null is refused and leaves the state untouched" {
    var fixture: Fixture = .{ .gpa = testing.allocator };
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4A00), true);
    defer target.deinit();

    _ = target.handleWmGetobject(
        0,
        @as(LParam, syscalls.objid_client),
        &activateWithTree,
        &fixture,
    );
    try testing.expectError(error.NullTreeUpdate, target.updateIfActive(&nullFactory, &fixture));
    try testing.expectEqual(error.NullTreeUpdate, target.last_error.?);
    try expectActivated(target);
}

/// Runs one placeholder-to-active update whose `index`-th allocation fails,
/// and asserts that the adapter still holds a tree afterwards.
///
/// Answers whether the call got past the install of the real tree, which is
/// what ends the sweep: an index above that one exercises the active arm and
/// the queue rather than the placeholder arm this test is about.
///
/// **Errors.** `error.OutOfMemory` from building the adapter, plus the tags the
/// body names.
fn placeholderUpdateFailingAt(gpa: std.mem.Allocator, index: usize) !bool {
    var fixture: Fixture = .{ .gpa = undefined };
    // The default configuration never fails, so the adapter and the
    // placeholder are built whole and `index` counts from the update's own
    // first allocation.
    var failing: std.testing.FailingAllocator = .init(gpa, .{});
    fixture.gpa = failing.allocator();
    const target = try WindowsAdapter.create(
        failing.allocator(),
        syscalls.unavailablePlatform(),
        @ptrFromInt(0x4B00),
        true,
        &releaseAction,
        &fixture,
    );
    defer target.deinit();

    _ = target.handleWmGetobject(
        0,
        @as(LParam, syscalls.uia_root_object_id),
        &activateWithNothing,
        &fixture,
    );
    try testing.expect(target.isPlaceholder());

    failing.fail_index = failing.alloc_index + index;
    const outcome = target.updateIfActive(&wholeTreeFactory, &fixture) catch |err| {
        // Two tags can come back. `error.OutOfMemory` is the failure the
        // contract is about, and `error.NullTreeUpdate` is the same failure
        // arriving inside the factory, which answers `null` rather than a tree
        // when it cannot build one. What is asserted is the state, not the tag.
        try testing.expect(err == error.OutOfMemory or err == error.NullTreeUpdate);
        try testing.expect(target.isActive());
        try testing.expect(target.tree() != null);
        return false;
    };
    try testing.expect(target.isActive());
    _ = (outcome orelse return error.NoEvents).raise();
    return true;
}

test "no allocation failure leaves the adapter without the tree it held" {
    // Every allocation the update makes is failed in turn, each on an adapter
    // of its own, and one property has to hold at every index: an adapter that
    // has a tree still has one. The alternative is an adapter left inactive,
    // which answers `null` to every later update and needs the application to
    // activate it a second time.
    //
    // The adapters run on `std.testing.allocator`, so every index is under the
    // per-test leak check and a block lost on any of them is a leak rather
    // than a silent success.
    var index: usize = 0;
    while (index <= placeholder_failure_bound) : (index += 1) {
        if (try placeholderUpdateFailingAt(testing.allocator, index)) return;
    }
    return error.SweepReachedItsBound;
}

test "the raise records its report on the adapter that produced the events" {
    var fixture: Fixture = .{ .gpa = testing.allocator };
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4C00), true);
    defer target.deinit();

    _ = target.handleWmGetobject(
        0,
        @as(LParam, syscalls.uia_root_object_id),
        &activateWithNothing,
        &fixture,
    );
    const events = (try target.updateIfActive(&wholeTreeFactory, &fixture)) orelse
        return error.NoEvents;
    try testing.expectEqual(@as(usize, 0), target.last_raise_report.total());

    // The seam for this target refuses every event, so the report counts one
    // event as unavailable rather than as raised, and it lands on the adapter
    // that `windowsAdapterDebug` reads.
    const report = events.raise();
    try testing.expectEqual(@as(usize, 1), report.total());
    try testing.expectEqual(@as(usize, 1), report.unavailable);
    try testing.expectEqual(@as(usize, 0), report.raised);
    try testing.expectEqual(@as(usize, 1), target.last_raise_report.total());
    try testing.expectEqual(@as(usize, 1), target.last_raise_report.unavailable);
}

test "deinit releases the tree, the providers and the adapter" {
    var fixture: Fixture = .{ .gpa = testing.allocator };
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4D00), true);

    _ = target.handleWmGetobject(
        0,
        @as(LParam, syscalls.objid_client),
        &activateWithTree,
        &fixture,
    );
    const events = (try target.updateIfActive(&wholeTreeFactory, &fixture)) orelse
        return error.NoEvents;
    try expectActivated(target);
    _ = events.raise();

    // Every block above comes from `testing.allocator`, so the per-test leak
    // check is the assertion: a tree, a provider or the adapter left behind is
    // reported as a leak instead of passing quietly. The events are raised
    // first because the adapter owns what they name.
    target.deinit();
}
