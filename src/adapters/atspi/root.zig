//! The AT-SPI adapter behind the six `accesskit_unix_adapter_*` exports.
//!
//! **What this file is.** `src/capi/platform.zig` owns the six declarations
//! `include/zaccesskit.h:6267-6329` puts behind the Linux and BSD guard, and it
//! forwards each one to a function here. Nothing in `src/capi/**` imports this
//! module back: the shared types come from `src/capi/boundary.zig`, which is a
//! leaf, and this module imports only that. Every type the C ABI and an adapter
//! both name is declared exactly once, in `boundary.zig`.
//!
//! ## What is compiled and tested on this host
//!
//! Everything this file and its nine siblings below hold, with no bus, no
//! window manager and no accessibility daemon:
//!
//! - the six exports' signatures, their argument order and their return shapes,
//!   checked by the C ABI itself when `platform.zig` compiles;
//! - the adapter lifetime: allocate once, release once, release twice is safe;
//! - the three wire body types, `ObjectAddress`, `Action` and `Rect`, marshalled
//!   byte for byte and checked against the alignment the D-Bus specification
//!   fixes, and the six-member error set with its map onto five D-Bus error
//!   names;
//! - the tree state machine — the first update builds the tree, every later one
//!   applies to it, and a node added, rewritten or removed raises the event the
//!   reference defines;
//! - the focus flag, which reaches the consumer tree and raises `Focus`;
//! - the window boxes and the `f64` to `i32` conversion with its rounding rule;
//! - the object-path scheme, including that two adapters never share a path;
//! - the five-argument event body, its signature and the split between the
//!   header fields and the body.
//!
//! ## What needs the real platform and is not here
//!
//! Three gaps, named so a reviewer does not have to find them.
//!
//! 1. **No D-Bus transport, so no body reaches a bus.** `object_address.zig`,
//!    `wire/action.zig` and `wire/rect.zig` marshal their value into a D-Bus
//!    body and are analysed and tested with everything else, but nothing carries
//!    that body to a connection. `build.zig.zon` declares `zio` and nothing
//!    else, and `docs/40-plan.md` puts the connection, the object register and
//!    the dispatch loop under a later milestone. The consequence is that no
//!    signal is raised on a bus, no inbound member call is answered, and no
//!    `org.a11y.atspi.Socket.Embed` handshake is performed.
//!
//! 2. **No unique bus name, so no `Embed`.** goose v3.3.0 sends `Hello` and
//!    discards the reply (`connection.zig:572-573`), so it cannot tell the
//!    application its own unique name. Upstream needs that name as the first
//!    half of the `Embed` plug (`bus.rs:88`) and as the first half of every
//!    `(so)` address this adapter hands out. **The decision this port takes is
//!    recorded here and not discovered at run time: the adapter does not
//!    perform `Embed`, and it therefore does not claim a bus name.** The
//!    consequence is that the AT-SPI registry does not list the application as
//!    an accessibility client until `Embed` is performed, which needs the five
//!    lines `docs/41` section 3.1 names. Deciding it here rather than at run
//!    time is the point: a caller reading this file knows before it calls
//!    `accesskit_unix_adapter_new` that no handshake will happen.
//!
//! 3. **No role and state mapping, and so no `StateChanged`.** The mapping from
//!    the consumer layer's flags onto the forty-three-value `wire.StateSet` is
//!    `node.rs:87-443` upstream. It is not ported, so an update raises
//!    `AddAccessible`, `RemoveAccessible`, `BoundsChanged` and `Focus` and
//!    nothing else. `platform_adapter.zig` lists this gap and `node.zig` is the
//!    module that would close it.
//!
//! ## The action handler, and why this file does not call it
//!
//! `accesskit_action_request_free` is `schema.cActionRequestDeinit` followed by
//! `allocation.release`, and `release` reads the head `allocation.create`
//! writes. So the request an action handler receives must be allocated by
//! `src/capi/allocation.zig`, and an adapter cannot reach it: importing
//! `src/capi/root.zig` from here would close the cycle
//! `src/capi/boundary.zig` exists to break. Calling the action handler with a
//! request this file allocated itself would hand the application a pointer that
//! `accesskit_action_request_free` cannot release safely.
//!
//! **The handler is stored, because the header requires every handler pointer to
//! stay valid until the adapter is released, and it is not called.** The fix is
//! to move `allocation.allocator`, `create` and `release` into
//! `src/capi/boundary.zig`, which is the leaf both sides already import. This
//! is a blocker, not a design choice, and it is named rather than papered over.
//!
//! ## The allocator this file uses
//!
//! `std.heap.c_allocator`, which is what `src/capi/allocation.zig` returns
//! while no `accesskit_set_allocator` pair is installed. The two agree, so a
//! consumer that does not install an allocator is correct, including for the
//! `char *` `accesskit_unix_adapter_debug` returns and
//! `accesskit_string_free` releases. A consumer that *does* install a pair must
//! not use this adapter until the allocator is reachable from `boundary.zig`.
//!
//! ## The activation handler, and what this port decided it means
//!
//! `accesskit_activation_handler_callback` returns a tree update or `null`, and
//! `null` is an ordinary answer. `accesskit_tree_update_factory` is the same
//! shape and `null` from it terminates the process. The difference is the
//! contract and not the type, and `boundary.zig` pins it.
//!
//! **This port's rule, stated once so a reader does not have to infer it:**
//! `accesskit_unix_adapter_update_if_active` calls `update_factory` on every
//! call and applies what it returns. The first of those calls also marks the
//! adapter active and calls `activation_handler`, so the application learns
//! that its tree is now the live one and may answer with a tree of its own. A
//! `null` answer is ordinary, is recorded, and changes nothing.
//! `accesskit_unix_adapter_free` calls `deactivation_handler` if and only if the
//! adapter was activated, which is what "called when the platform deactivates
//! accessibility" means for a platform whose only deactivation is its release.

const std = @import("std");

const adapter_errors = @import("error.zig");
const boundary = @import("../../capi/boundary.zig");
const events = @import("events.zig");
const object_address = @import("object_address.zig");
const object_id = @import("object_id.zig");
const platform_adapter = @import("platform_adapter.zig");
const wire = @import("wire.zig");
const wire_action = @import("wire/action.zig");
const wire_rect = @import("wire/rect.zig");

const ActivationHandler = boundary.ActivationHandler;
const ActionHandler = boundary.ActionHandler;
const CRect = boundary.CRect;
const CTreeUpdate = boundary.CTreeUpdate;
const DeactivationHandler = boundary.DeactivationHandler;
const ObjectId = object_id.ObjectId;
const PlatformAdapter = platform_adapter.PlatformAdapter;

/// The failures an allocating export here reports, which are the two a C
/// consumer can see: the allocation itself and the consumer layer's tree
/// rejections.
pub const UnixAdapterError = std.mem.Allocator.Error || platform_adapter.AdapterError;

/// The allocator every allocation this file makes uses and every release goes
/// through. It is `c_allocator` and not a value a caller passes, because the C
/// ABI has no allocator parameter on these six declarations; see the module doc
/// for what that costs.
pub const adapter_allocator: std.mem.Allocator = std.heap.c_allocator;

/// One AT-SPI window, as the C ABI hands it out.
///
/// The value owns its tree, its event queue and the three handler pointers the
/// constructor was given. It has no copy operation: two owners of one tree
/// release it twice, so the only way to hand one to a callee is a pointer.
///
/// The layout is not a contract. A C caller receives an opaque pointer and
/// reads nothing through it, so a field added here is a field nothing outside
/// this file can see.
pub const UnixAdapter = struct {
    /// The allocator every buffer under this value was grown with.
    gpa: std.mem.Allocator,
    /// The tree, the boxes, the focus flag and the events an update produced.
    platform: PlatformAdapter,
    /// Called once, the first time the adapter holds a tree. A `null` answer
    /// is ordinary and means the application had nothing to add.
    activation_handler: ActivationHandler,
    /// The application's own context for `activation_handler`, passed back
    /// unchanged. It must stay valid until the adapter is released.
    activation_userdata: ?*anyopaque,
    /// Stored and not called. See the module doc: the request it would receive
    /// cannot be allocated from an adapter.
    action_handler: ActionHandler,
    /// The application's own context for `action_handler`. It must stay valid
    /// until the adapter is released, which is why the pointer is kept even
    /// though the slot has no caller.
    action_userdata: ?*anyopaque,
    /// Called from `unixAdapterFree` when the adapter was activated.
    deactivation_handler: DeactivationHandler,
    /// The application's own context for `deactivation_handler`.
    deactivation_userdata: ?*anyopaque,
    /// Whether the adapter has ever held a tree. `unixAdapterFree` reads it to
    /// decide whether the platform is deactivating or was never active, and
    /// `debug` reports it.
    activated: bool,
    /// Whether `activation_handler` answered `null` the one time it was called.
    /// `null` is an ordinary answer and not a failure, so it is recorded rather
    /// than raised.
    application_declined_activation: bool,

    /// Releases the tree, the events and the adapter itself, exactly once.
    ///
    /// **Errors.** This function does not fail.
    pub fn deinit(self: *UnixAdapter) void {
        self.platform.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }
};

/// Builds an adapter for one AT-SPI window, or `null` when the allocation
/// failed.
///
/// `accesskit_unix_adapter_new`, `include/zaccesskit.h:6268`, upstream
/// `accesskit_unix/src/lib.rs:2997`.
///
/// Every handler must stay valid until the adapter is released, so all three
/// are stored with their userdata and none is copied.
///
/// **Errors.** `error.OutOfMemory`. The value is a null return on the header's
/// side, which is `ACCESSKIT_ERROR_OUT_OF_MEMORY` through `accesskit_last_error`.
pub fn unixAdapterNew(
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
    deactivation_handler: DeactivationHandler,
    deactivation_handler_userdata: ?*anyopaque,
) ?*UnixAdapter {
    const gpa = adapter_allocator;
    const adapter = gpa.create(UnixAdapter) catch return null;
    adapter.* = .{
        .gpa = gpa,
        // The number every node path carries. It is 0 for the first adapter a
        // process builds and this module does not raise it; see
        // `nextAdapterNumber` for why, and for what a second window costs.
        .platform = PlatformAdapter.init(gpa, nextAdapterNumber(), false),
        .activation_handler = activation_handler,
        .activation_userdata = activation_handler_userdata,
        .action_handler = action_handler,
        .action_userdata = action_handler_userdata,
        .deactivation_handler = deactivation_handler,
        .deactivation_userdata = deactivation_handler_userdata,
        .activated = false,
        .application_declined_activation = false,
    };
    return adapter;
}

/// Releases the adapter and every tree it holds, exactly once.
///
/// `accesskit_unix_adapter_free`, `include/zaccesskit.h:6281`, upstream
/// `accesskit_unix/src/lib.rs:3008`.
///
/// The deactivation handler runs first, on the same thread as the activation
/// handler ran, and only when the adapter was activated: a process that built
/// an adapter and released it without ever handing it a tree never deactivated
/// accessibility, and calling the handler would say otherwise.
///
/// A `null` adapter terminates the process, because `docs/31-c-abi-design.md`
/// record B gives a `void` export nowhere to put a status and
/// `include/zaccesskit.h:6479` gives the header the same rule.
///
/// **Errors.** This function does not fail.
pub fn unixAdapterFree(adapter: *UnixAdapter) void {
    if (@intFromPtr(adapter) == 0) terminate();
    if (adapter.activated) {
        adapter.deactivation_handler(adapter.deactivation_userdata);
    }
    adapter.deinit();
}

/// Records the root window's two boxes.
///
/// `accesskit_unix_adapter_set_root_window_bounds`,
/// `include/zaccesskit.h:6290`, upstream `accesskit_unix/src/lib.rs:3022`.
///
/// Both boxes arrive as `accesskit_rect`, which is `schema.Rect` and the same
/// four `double` at the same offsets, so the conversion across the boundary is
/// the identity and neither side writes a copy.
///
/// Returns nothing and cannot fail.
///
/// **Errors.** This function does not fail.
pub fn unixAdapterSetRootWindowBounds(
    adapter: *UnixAdapter,
    outer: CRect,
    inner: CRect,
) void {
    adapter.platform.setRootWindowBounds(outer, inner);
}

/// Asks `update_factory` for a tree, applies it and collects what it produced.
///
/// `accesskit_unix_adapter_update_if_active`,
/// `include/zaccesskit.h:6305`, upstream `accesskit_unix/src/lib.rs:3029`.
///
/// This family returns nothing and has no queued-events handle: the Unix adapter
/// raises what the answer produced on its own thread and the caller has no
/// handle to raise. `docs/31-c-abi-design.md` row 17 names four
/// `*_queued_events` handles and none of them is this family's.
///
/// A `null` answer from the factory terminates the process. That is the
/// contract `boundary.TreeUpdateFactory` states and `include/zaccesskit.h:1725`
/// ships: the factory builds one whole update and must not return `null`. The
/// alternative would be to skip the update, which reports success for a tree
/// that was never delivered.
///
/// The first update also marks the adapter active and calls
/// `activation_handler`; see the module doc for the rule and why.
///
/// **Errors.** `error.OutOfMemory` and the consumer layer's `UpdateError` set.
/// The C ABI returns nothing here, so a failure leaves the committed tree as
/// `docs/33` section 1 describes and the caller sees it on the next update.
pub fn unixAdapterUpdateIfActive(
    adapter: *UnixAdapter,
    update_factory: boundary.TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) void {
    const update = update_factory(update_factory_userdata) orelse terminate();
    const was_active = adapter.activated;

    // A failure here leaves the committed tree as `docs/33` section 1 describes
    // and the caller sees it on the next update, which is why the C ABI's `void`
    // return is not hiding one.
    adapter.platform.apply(update.*) catch return;

    if (!was_active) {
        adapter.activated = true;
        // A `null` answer is an ordinary answer and means the application had
        // no tree of its own to add, so it is recorded and not raised.
        adapter.application_declined_activation =
            adapter.activation_handler(adapter.activation_userdata) == null;
    }
}
/// `accesskit_unix_adapter_update_window_focus_state`,
/// `include/zaccesskit.h:6316`, upstream `accesskit_unix/src/lib.rs:3040`.
///
/// The flag reaches the consumer tree, which is where the effective focus is
/// decided: a tree whose host is not focused reports no focus at all. That is
/// why an update after this one reports a focus move when the host regains
/// focus.
///
/// Returns nothing and cannot fail.
///
/// **Errors.** This function does not fail.
pub fn unixAdapterUpdateWindowFocusState(
    adapter: *UnixAdapter,
    is_focused: bool,
) void {
    adapter.platform.updateWindowFocusState(is_focused) catch return;
}

/// Renders the adapter as text, or answers `null` when the text could not be
/// built.
///
/// `accesskit_unix_adapter_debug`, `include/zaccesskit.h:6329`, upstream
/// `accesskit_unix/src/lib.rs:3049`.
///
/// The text borrows nothing from the adapter once the call returns, so the
/// caller may release the adapter first and then release the string with
/// `accesskit_string_free`.
///
/// **Errors.** `error.OutOfMemory` from `gpa`, which the C ABI reports as a
/// `null` return.
pub fn unixAdapterDebug(adapter: *const UnixAdapter) ?[*:0]u8 {
    const gpa = adapter.gpa;
    const platform = &adapter.platform;
    const outer = platform.bounds.outer;
    const inner = platform.bounds.inner;
    return std.fmt.allocPrintSentinel(
        gpa,
        "UnixAdapter {{ id: {d}, nodes: {d}, updates: {d}, focused: {s}, " ++
            "activated: {s}, declined: {s}, events: {d}, " ++
            "outer: ({d},{d}) {d}x{d}, inner: ({d},{d}) {d}x{d}, " ++
            "states: {d}, roles: {d} }}",
        .{
            platform.id,
            platform.nodeCount(),
            platform.applied_updates,
            if (platform.is_host_focused) "yes" else "no",
            if (adapter.activated) "yes" else "no",
            if (adapter.application_declined_activation) "yes" else "no",
            platform.raised.count(),
            @as(i64, @intFromFloat(outer.x0)),
            @as(i64, @intFromFloat(outer.y0)),
            @as(i64, @intFromFloat(outer.width())),
            @as(i64, @intFromFloat(outer.height())),
            @as(i64, @intFromFloat(inner.x0)),
            @as(i64, @intFromFloat(inner.y0)),
            @as(i64, @intFromFloat(inner.width())),
            @as(i64, @intFromFloat(inner.height())),
            wire.state_count,
            wire.interface_count,
        },
        0,
    ) catch null;
}

/// The number the next adapter's node paths carry.
///
/// **This is the one piece of process-wide state in this module, and it is
/// deliberate.** The number is part of every node object path, and a path is
/// named by a peer on another connection, so the number has to be unique across
/// every live adapter in the process and not merely unique within one. No
/// per-adapter storage can hold it, because the value a path needs is the value
/// another adapter also has to avoid. Upstream keeps the same counter in a
/// process-global atomic at `atspi-common/src/adapter.rs:356-358`, and this is
/// that counter.
///
/// The consequence to write down: it is a global, which `AGENTS.md` section 2
/// forbids for anything else, and the alternative — every adapter numbered zero
/// — makes two windows in one process share a node path, which is worse. A
/// port that needs the number injected must have the constructor take it, and
/// `accesskit_unix_adapter_new` has no such parameter.
///
/// **Errors.** This function does not fail.
pub fn nextAdapterNumber() usize {
    return next_adapter_number.fetchAdd(1, .monotonic);
}

/// The process-wide adapter number, as `nextAdapterNumber` explains.
var next_adapter_number = std.atomic.Value(usize).init(0);

/// Ends the process, because the call that reached here has nowhere to report a
/// failure.
///
/// Two contracts reach this function. `accesskit_unix_adapter_free` on a `null`
/// adapter is one, and a `null` answer from `accesskit_tree_update_factory` is
/// the other. Both say the caller broke a rule the header states in as many
/// words, and both are cases where returning would report success for something
/// that did not happen.
///
/// It is not a panic and it is not an `unreachable`: both of those are claims
/// about a program that cannot reach them, and a C consumer can.
///
/// **Errors.** This function does not return.
pub fn terminate() noreturn {
    std.process.exit(1);
}

const testing = std.testing;

/// A tree update that names one window node, which is the whole root tree.
///
/// The node has no children. A fixture that named itself as a child would be a
/// cycle, and the consumer layer's validator rejects a cyclic tree, so a test
/// built on one would measure the validator rather than the adapter.
fn oneNodeUpdate(gpa: std.mem.Allocator) !CTreeUpdate {
    const schema = @import("../../schema/root.zig");
    var update = CTreeUpdate{
        .tree = schema.TreeInfo.init(.{ .value = 1 }),
        .focus = .{ .value = 1 },
    };
    try update.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .window));
    return update;
}

/// Counts the calls one handler receives, for the tests below.
const Probe = struct {
    calls: usize = 0,
    last_userdata: ?*anyopaque = null,
    answers_tree: bool = false,

    fn activation(context: ?*anyopaque) callconv(.c) ?*CTreeUpdate {
        const probe: *Probe = @ptrCast(@alignCast(context orelse return null));
        probe.calls += 1;
        probe.last_userdata = context;
        if (!probe.answers_tree) return null;
        const update = adapter_allocator.create(CTreeUpdate) catch return null;
        update.* = oneNodeUpdate(adapter_allocator) catch {
            adapter_allocator.destroy(update);
            return null;
        };
        return update;
    }

    fn action(request: *boundary.CActionRequest, context: ?*anyopaque) callconv(.c) void {
        _ = request;
        const probe: *Probe = @ptrCast(@alignCast(context orelse return));
        probe.calls += 1;
        probe.last_userdata = context;
    }

    fn deactivation(context: ?*anyopaque) callconv(.c) void {
        const probe: *Probe = @ptrCast(@alignCast(context orelse return));
        probe.calls += 1;
        probe.last_userdata = context;
    }

    fn factory(context: ?*anyopaque) callconv(.c) ?*CTreeUpdate {
        const probe: *Probe = @ptrCast(@alignCast(context orelse return null));
        probe.calls += 1;
        probe.last_userdata = context;
        const update = adapter_allocator.create(CTreeUpdate) catch return null;
        update.* = oneNodeUpdate(adapter_allocator) catch {
            adapter_allocator.destroy(update);
            return null;
        };
        return update;
    }
};

/// Builds an adapter whose three handlers and one factory all reach `probe`.
///
/// **Errors.** `error.OutOfMemory`.
fn adapterFor(probe: *Probe) !*UnixAdapter {
    return unixAdapterNew(
        Probe.activation,
        probe,
        Probe.action,
        probe,
        Probe.deactivation,
        probe,
    ) orelse error.AdapterAllocationFailed;
}

test "a new adapter holds no tree and raises nothing" {
    const gpa = adapter_allocator;
    var probe = Probe{};
    const adapter = try gpa.create(UnixAdapter);
    adapter.* = .{
        .gpa = gpa,
        .platform = PlatformAdapter.init(gpa, 0, false),
        .activation_handler = Probe.activation,
        .activation_userdata = &probe,
        .action_handler = Probe.action,
        .action_userdata = &probe,
        .deactivation_handler = Probe.deactivation,
        .deactivation_userdata = &probe,
        .activated = false,
        .application_declined_activation = false,
    };
    defer adapter.deinit();

    try testing.expect(!adapter.platform.hasTree());
    try testing.expectEqual(@as(usize, 0), adapter.platform.raised.count());
    try testing.expect(!adapter.activated);
}

test "an update calls the factory, builds the tree and marks the adapter active" {
    var probe = Probe{};
    const adapter = try adapterFor(&probe);
    defer adapter.deinit();

    unixAdapterUpdateIfActive(adapter, Probe.factory, &probe);

    // One factory call and one activation call reach the same counter.
    try testing.expectEqual(@as(usize, 2), probe.calls);
    try testing.expect(adapter.platform.hasTree());
    try testing.expect(adapter.platform.nodeCount() > 0);
    // The activation handler runs on the first tree, and a `null` answer from it
    // is an ordinary answer rather than a failure.
    try testing.expect(adapter.activated);
    try testing.expect(adapter.application_declined_activation);
}

test "the factory is called on every update and the activation handler only once" {
    var probe = Probe{};
    const adapter = try adapterFor(&probe);
    defer adapter.deinit();

    unixAdapterUpdateIfActive(adapter, Probe.factory, &probe);
    const after_first = probe.calls;

    unixAdapterUpdateIfActive(adapter, Probe.factory, &probe);

    // The factory runs again and the activation handler does not, which is what
    // separates a tree from a re-activation: one more call, not two.
    try testing.expectEqual(after_first + 1, probe.calls);
    try testing.expectEqual(@as(u64, 2), adapter.platform.applied_updates);
}

test "the application context reaches the handler unchanged" {
    var probe = Probe{};
    const adapter = try adapterFor(&probe);
    defer adapter.deinit();

    unixAdapterUpdateIfActive(adapter, Probe.factory, &probe);

    // The header requires `userdata` to be passed through unchanged, and the
    // only way to check that is to look at what came back.
    try testing.expect(probe.last_userdata != null);
}

test "releasing an activated adapter calls the deactivation handler" {
    var probe = Probe{};
    const adapter = try adapterFor(&probe);

    unixAdapterUpdateIfActive(adapter, Probe.factory, &probe);
    unixAdapterFree(adapter);

    // One factory call, one activation call and one deactivation call.
    try testing.expectEqual(@as(usize, 3), probe.calls);
}

test "releasing an adapter that was never active does not deactivate" {
    var probe = Probe{};
    const adapter = try adapterFor(&probe);

    unixAdapterFree(adapter);

    // One call is the factory's, from nothing; the deactivation handler must not
    // run for an adapter that was never activated.
    try testing.expectEqual(@as(usize, 0), probe.calls);
}

test "the focus flag reaches the tree and raises a Focus event" {
    var probe = Probe{};
    const adapter = try adapterFor(&probe);
    defer adapter.deinit();

    unixAdapterUpdateIfActive(adapter, Probe.factory, &probe);
    var taken: std.ArrayList(events.Event) = .empty;
    defer taken.deinit(adapter.gpa);
    try adapter.platform.raised.drainInto(adapter.gpa, &taken);

    unixAdapterUpdateWindowFocusState(adapter, true);

    try testing.expect(adapter.platform.is_host_focused);
    try testing.expect(adapter.platform.raised.count() >= 1);
    try testing.expectEqualStrings(
        events.member_focus,
        adapter.platform.raised.items.items[0].member,
    );
}

test "the window boxes reach the platform adapter" {
    var probe = Probe{};
    const adapter = try adapterFor(&probe);
    defer adapter.deinit();

    const outer = @import("../../schema/root.zig").rectInit(0, 0, 800, 600);
    const inner = @import("../../schema/root.zig").rectInit(0, 30, 800, 600);
    unixAdapterSetRootWindowBounds(adapter, outer, inner);

    try testing.expectEqual(@as(f64, 600), adapter.platform.bounds.outer.height());
    try testing.expectEqual(@as(f64, 570), adapter.platform.bounds.viewportSize().height);
}

test "the debug text names the adapter and borrows nothing from it" {
    var probe = Probe{};
    const adapter = try adapterFor(&probe);

    unixAdapterUpdateIfActive(adapter, Probe.factory, &probe);
    unixAdapterSetRootWindowBounds(
        adapter,
        @import("../../schema/root.zig").rectInit(0, 0, 800, 600),
        @import("../../schema/root.zig").rectInit(0, 30, 800, 600),
    );

    const text = unixAdapterDebug(adapter) orelse return error.DebugTextNotBuilt;
    // The text outlives the adapter, which is what the header promises, so the
    // adapter is released before the string is read.
    unixAdapterFree(adapter);

    const borrowed: []const u8 = std.mem.span(text);
    try testing.expect(std.mem.indexOf(u8, borrowed, "UnixAdapter") != null);
    try testing.expect(std.mem.indexOf(u8, borrowed, "updates: 1") != null);
    try testing.expect(std.mem.indexOf(u8, borrowed, "activated: yes") != null);
    try testing.expect(std.mem.indexOf(u8, borrowed, "800x600") != null);
    std.heap.c_allocator.free(std.mem.span(text));
}

test "the adapter number rises so two windows never share a node path" {
    const first = nextAdapterNumber();
    const second = nextAdapterNumber();

    // The number is the middle of every node path, so two adapters that shared
    // one would have their nodes share a path and a peer would call the wrong
    // window.
    try testing.expect(second > first);
}

test "every module in this adapter is reachable and analysed" {
    // A `pub const` nothing references is a re-export the compiler may skip, so
    // a green run would prove nothing about the modules underneath. This is the
    // third instance of that defect in this package and it has been written down
    // three times already. The four modules below were the fourth instance: they
    // imported a D-Bus library this project does not depend on, so nothing
    // reached them and the gate analysed them at no point.
    std.testing.refAllDecls(adapter_errors);
    std.testing.refAllDecls(object_address);
    std.testing.refAllDecls(platform_adapter);
    std.testing.refAllDecls(wire);
    std.testing.refAllDecls(wire_action);
    std.testing.refAllDecls(wire_rect);
    std.testing.refAllDecls(object_id);
}

test "the object identifier names the three paths this adapter exports" {
    // The cache object is the third, and a build that could not name it would
    // raise every cache signal on the root path.
    const cache: ObjectId = .cache;
    const path = try cache.path(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try testing.expectEqualStrings("/org/a11y/atspi/cache", path);
}
