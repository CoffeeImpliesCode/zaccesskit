//! The three application handler vtables, from `accesskit/src/lib.rs:3335-3385`.
//!
//! Upstream declares three traits. Rule Z7 turns each one into a struct of
//! function pointers whose first field is a `context` pointer, because a Zig
//! struct cannot hold a closure. The application owns the state behind
//! `context`, and it owns the two function pointers.
//!
//! A caller reaches a handler through the `call` method on its type. `call`
//! takes `?*const T`, and it owns the case of an absent vtable. Upstream has no
//! such case, because each handler sits in a `Box` that is always present
//! (`adapters/unix/src/context.rs:78`, `:79`).
//!
//! The thread that runs a handler is the adapter's choice, not this module's.
//! Upstream says so for all three (`accesskit/src/lib.rs:3356-3357`, `:3366-3367`,
//! `:3382-3383`), and the port keeps that answer.
//!
//! This module holds no state, allocates nothing, and performs no I/O, so no
//! declaration here takes `io` or an allocator.
//!
//! `TreeUpdate` and `ActionRequest` come from `update.zig`, which this module
//! does not declare.

const std = @import("std");

const update = @import("update.zig");
const action = @import("action.zig");
const ids = @import("ids.zig");

const ActionRequest = update.ActionRequest;
const TreeUpdate = update.TreeUpdate;
const Action = action.Action;
const tree_id_root = ids.tree_id_root;

const assert = std.debug.assert;
const testing = std.testing;

/// The application's answer to the adapter's request for a tree.
///
/// The adapter asks for a tree once per activation. A caller with no handler
/// holds a `null` pointer and reaches `ActivationHandler.call` with it.
pub const ActivationHandler = struct {
    /// The application state that `requestInitialTree` reads. The application
    /// owns it and keeps it alive until it unregisters this vtable. `null`
    /// reaches the callee as `null`.
    context: ?*anyopaque,

    /// Produces the full tree the adapter starts from, or answers later.
    ///
    /// The callee receives `context` unchanged and nothing else. `context`
    /// stays valid for the duration of the call, so a callee that keeps it
    /// must copy what it needs. A returned `TreeUpdate` belongs to the caller
    /// of `call`, which releases it.
    ///
    /// A `null` return means the application answers later, not now. It is
    /// neither a failure nor an empty tree. The adapter waits in its pending
    /// state (`adapters/unix/src/context.rs:104`), and the application sends
    /// the real tree to the adapter no later than the next display refresh
    /// (`accesskit/src/lib.rs:3339-3342`).
    ///
    /// A non-`null` return is a full tree, even when the application normally
    /// sends incremental updates (`accesskit/src/lib.rs:3352-3354`). The
    /// adapter may call this method again with no `DeactivationHandler.call`
    /// between the calls (`accesskit/src/lib.rs:3349-3351`), so every call
    /// produces a whole tree. The callee must not return a placeholder tree
    /// (`accesskit/src/lib.rs:3343-3345`).
    ///
    /// The adapter chooses the thread. The unix adapter holds its state lock
    /// across this call (`adapters/unix/src/context.rs:84`, `:91`), so a
    /// callee that reenters the adapter deadlocks.
    ///
    /// A `null` `context` means the application registered no state, so the
    /// callee has nothing to build a tree from and returns `null` to answer
    /// later.
    requestInitialTree: *const fn (context: ?*anyopaque) ?TreeUpdate,

    /// Calls `requestInitialTree` with the registered context.
    ///
    /// A `null` result means the application answers later, and it is also
    /// what a `null` receiver returns, because no application answered. The
    /// caller releases a returned update with `TreeUpdate.deinit`.
    pub fn call(self: ?*const ActivationHandler) ?TreeUpdate {
        const handler = self orelse return null;
        return handler.requestInitialTree(handler.context);
    }
};

/// The application's answer to an action request from an assistive technology.
///
/// The adapter forwards one request per platform method call. A caller with no
/// handler holds a `null` pointer and reaches `ActionHandler.call` with it.
pub const ActionHandler = struct {
    /// The application state that `doAction` reads. The application owns it
    /// and keeps it alive until it unregisters this vtable. `null` reaches
    /// the callee as `null`.
    context: ?*anyopaque,

    /// Performs the action named in `request`, or drops it.
    ///
    /// The callee receives `context` and `request` unchanged, and both stay
    /// valid for the duration of the call. `request` arrives by value, so the
    /// callee owns that copy and may keep it. A copy the callee keeps owns
    /// the buffer a `value` payload carries, and releases it with
    /// `ActionRequest.deinit`. A callee that stores the request after the
    /// call must copy it first. A request naming an action the application
    /// does not support is dropped, and the caller learns nothing
    /// (`accesskit/src/lib.rs:3363-3364`).
    ///
    /// The callee may act now or may queue the request and act later
    /// (`accesskit/src/lib.rs:3369-3371`). Queueing is preferred over
    /// blocking. The port supplies no queue, because the core crate has none.
    ///
    /// The adapter chooses the thread. The AT-SPI adapter forwards the
    /// request with no adapter lock held
    /// (`adapters/atspi-common/src/context.rs:76-78`), so the callee may
    /// reenter the adapter. It must not reenter itself, because the wrapper
    /// already holds the mutex around the handler
    /// (`adapters/atspi-common/src/context.rs:31`). It must not block, because
    /// the platform thread waits for the call.
    ///
    /// A `null` `context` means the application registered no state, so the
    /// callee has no application to act on and drops the request.
    doAction: *const fn (context: ?*anyopaque, request: ActionRequest) void,

    /// Calls `doAction` with the registered context and `request`.
    ///
    /// The call returns nothing, so the caller learns nothing about the
    /// outcome. A `null` receiver drops `request`, because the port has no
    /// acknowledgement channel on which to report the loss.
    pub fn call(self: ?*const ActionHandler, request: ActionRequest) void {
        const handler = self orelse return;
        handler.doAction(handler.context, request);
    }
};

/// The application's answer to the adapter's shutdown request.
///
/// The adapter calls this once per deactivation. A caller with no handler holds
/// a `null` pointer and reaches `DeactivationHandler.call` with it.
pub const DeactivationHandler = struct {
    /// The application state that `deactivateAccessibility` reads. The
    /// application owns it and keeps it alive until it unregisters this
    /// vtable. `null` reaches the callee as `null`.
    context: ?*anyopaque,

    /// Releases the accessibility data the application can rebuild later.
    ///
    /// The callee receives `context` unchanged and nothing else. `context`
    /// stays valid for the duration of the call, so a callee that keeps it
    /// must copy what it needs. The callee drops the data it holds and leaves
    /// this vtable registered (`accesskit/src/lib.rs:3377-3380`). The adapter
    /// asks for a tree again through `ActivationHandler.call` if one is needed
    /// later.
    ///
    /// The adapter chooses the thread. The unix adapter drops its state lock
    /// before it calls (`adapters/unix/src/context.rs:127`, `:128`), so the
    /// callee may reenter the adapter. It gets no tree when it does, because
    /// the adapter has already set the state to inactive
    /// (`adapters/unix/src/context.rs:122`, `:116`).
    ///
    /// A `null` `context` means the application registered no state, so the
    /// callee has nothing to release and returns without doing anything.
    deactivateAccessibility: *const fn (context: ?*anyopaque) void,

    /// Calls `deactivateAccessibility` with the registered context.
    ///
    /// A `null` receiver returns without doing anything, because there is no
    /// application data to release.
    pub fn call(self: ?*const DeactivationHandler) void {
        const handler = self orelse return;
        handler.deactivateAccessibility(handler.context);
    }
};

/// The state the test handlers reach through `context`.
const AppState = struct {
    /// How many handlers reached this state.
    calls: usize = 0,
    /// The node content the fake activation handler writes into its tree.
    focus_value: u64 = 0,
    /// The request the fake action handler stored, by value.
    last_request: ?ActionRequest = null,
    /// Whether the fake deactivation handler dropped its data.
    released: bool = false,
};

/// Answers now, with a full tree that names `focus_value`.
fn activationImmediate(context: ?*anyopaque) ?TreeUpdate {
    const state: *AppState = @ptrCast(@alignCast(context orelse return null));
    state.calls += 1;
    return .{ .focus = .{ .value = state.focus_value } };
}

/// Answers later, so the adapter stays pending.
fn activationDeferred(context: ?*anyopaque) ?TreeUpdate {
    const state: *AppState = @ptrCast(@alignCast(context orelse return null));
    state.calls += 1;
    return null;
}

/// Answers later when `context` is `null`, and produces a tree otherwise, so
/// a forwarded context that the application never set changes the answer.
fn activationWithoutState(context: ?*anyopaque) ?TreeUpdate {
    return if (context == null) null else .{ .focus = .{ .value = 1 } };
}

fn doActionRecorder(context: ?*anyopaque, request: ActionRequest) void {
    const state: *AppState = @ptrCast(@alignCast(context orelse return));
    state.calls += 1;
    state.last_request = request;
}

/// A `void` callback that holds no state can report only the context it was
/// given, so it checks it.
fn doActionWithoutState(context: ?*anyopaque, _: ActionRequest) void {
    assert(context == null);
}

fn deactivationRecorder(context: ?*anyopaque) void {
    const state: *AppState = @ptrCast(@alignCast(context orelse return));
    state.calls += 1;
    state.released = true;
}

/// A `void` callback that holds no state can report only the context it was
/// given, so it checks it.
fn deactivationWithoutState(context: ?*anyopaque) void {
    assert(context == null);
}

test "activation handler receives its context and answers now" {
    var state: AppState = .{ .focus_value = 7 };
    const vtable: ActivationHandler = .{
        .context = &state,
        .requestInitialTree = activationImmediate,
    };

    var answer = vtable.call() orelse return error.NoTreeReturned;
    defer answer.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 7), answer.focus.value);
    try testing.expectEqual(@as(usize, 1), state.calls);
}

test "activation handler may answer later" {
    var state: AppState = .{};
    const vtable: ActivationHandler = .{
        .context = &state,
        .requestInitialTree = activationDeferred,
    };

    try testing.expect(vtable.call() == null);
    try testing.expectEqual(@as(usize, 1), state.calls);
}

test "activation call with no handler answers later" {
    try testing.expect(ActivationHandler.call(null) == null);
}

test "activation handler with a null context answers later" {
    const vtable: ActivationHandler = .{
        .context = null,
        .requestInitialTree = activationWithoutState,
    };

    try testing.expect(vtable.call() == null);
}

test "action handler receives its context and the request by value" {
    var state: AppState = .{};
    const vtable: ActionHandler = .{
        .context = &state,
        .doAction = doActionRecorder,
    };

    const request: ActionRequest = .{
        .action = .click,
        .target_tree = tree_id_root,
        .target_node = .{ .value = 42 },
        .data = .{ .numeric_value = 2.5 },
    };

    vtable.call(request);

    try testing.expectEqual(@as(usize, 1), state.calls);
    const received = state.last_request orelse return error.NoRequestRecorded;
    try testing.expectEqual(Action.click, received.action);
    try testing.expectEqual(@as(u64, 42), received.target_node.value);
    const data = received.data orelse return error.NoActionData;
    switch (data) {
        .numeric_value => |value| try testing.expectEqual(@as(f64, 2.5), value),
        else => return error.UnexpectedActionData,
    }
}

test "action handler holds a copy, not the caller's request" {
    var state: AppState = .{};
    const vtable: ActionHandler = .{
        .context = &state,
        .doAction = doActionRecorder,
    };

    var request: ActionRequest = .{
        .action = .click,
        .target_tree = tree_id_root,
        .target_node = .{ .value = 1 },
        .data = null,
    };

    vtable.call(request);
    request.action = .focus;

    const received = state.last_request orelse return error.NoRequestRecorded;
    try testing.expectEqual(Action.click, received.action);
}

test "action call with no handler drops the request" {
    // The observable is that the call returns. A `call` that read through the
    // pointer instead of short circuiting traps on the null.
    ActionHandler.call(null, .{
        .action = .click,
        .target_tree = tree_id_root,
        .target_node = .{ .value = 1 },
        .data = null,
    });
}

test "action handler with a null context drops the request" {
    const vtable: ActionHandler = .{
        .context = null,
        .doAction = doActionWithoutState,
    };

    vtable.call(.{
        .action = .click,
        .target_tree = tree_id_root,
        .target_node = .{ .value = 1 },
        .data = null,
    });
}

test "deactivation handler receives its context" {
    var state: AppState = .{};
    const vtable: DeactivationHandler = .{
        .context = &state,
        .deactivateAccessibility = deactivationRecorder,
    };

    vtable.call();

    try testing.expectEqual(@as(usize, 1), state.calls);
    try testing.expect(state.released);
}

test "deactivation call with no handler does nothing" {
    // The observable is that the call returns. A `call` that read through the
    // pointer instead of short circuiting traps on the null.
    DeactivationHandler.call(null);
}

test "deactivation handler with a null context does nothing" {
    const vtable: DeactivationHandler = .{
        .context = null,
        .deactivateAccessibility = deactivationWithoutState,
    };

    vtable.call();
}
