//! Single-owner accessibility dispatch lane with bounded, lossless task queues.
//! The caller keeps its allocator, I/O backend and zio runtime alive through close.
//! Source mapping: AccessKit 466e24e252103f4d82bd6fbab98141b551e46e0c,
//! adapters/unix/src/context.rs:48-79 (explicit owner replacing get_or_init_messages),
//! :169-219 (session status and serialized adapter-message loop), and
//! adapters/unix/src/adapter.rs Callback/send_message/Message (completed owner work).
//! zio 2662fdc45997611b962b560c513c16963475a01b src/runtime.zig:1816,260 supplies
//! explicit task ownership; src/sync/channel.zig:619-709 supplies bounded backpressure.
const std = @import("std");
const zio = @import("zio");
const dbus = @import("dbus.zig");
const bus = @import("bus.zig");

/// Failure before acceptance; an accepted operation is always settled before submit returns.
pub const SubmitError = error{ Closed, Canceled, Reentrant };
pub const SpawnError = error{
    OutOfMemory,
    RuntimeShutdown,
    InvalidPlacement,
    ContextTooLarge,
    ResultTooLarge,
    Closed,
};
pub const Error = bus.Error || SubmitError || SpawnError || error{AlreadyStarted};
pub const Options = bus.Options;
pub const RejectReason = enum { closed, canceled };

/// Caller-owned operation data remains live until submit returns. Both callbacks run only
/// on the owner lane; execute records the native typed result, reject records no commit.
pub const Work = struct {
    context: *anyopaque,
    execute: *const fn (*anyopaque, *bus.Bus) void,
    reject: *const fn (*anyopaque, RejectReason) void,
};

/// All callbacks execute on the owned pump task. Message strings borrow its frame only
/// during request; replies transfer ownership. Callbacks may not submit or close this pump.
/// A request may emit ordered signals before returning its owned reply; failures preserve
/// the full bus.Error so a failed signal write cannot become a successful method reply.
pub const Hooks = struct {
    context: *anyopaque,
    activate: *const fn (*anyopaque, *bus.Bus) bus.Error!void,
    attached: *const fn (*anyopaque, *bus.Bus) void,
    deactivate: *const fn (*anyopaque, ?bus.Error) void,
    request: *const fn (*anyopaque, *bus.Bus, dbus.Message) bus.Error!dbus.OwnedReply,
    /// Optional failure observer, including failures while inactive; null still retains
    /// the cause in lastFailure. Runs on the owner lane, never a reader or after close.
    failure: ?*const fn (*anyopaque, bus.Error) void = null,
};

const Lane = enum { session, accessibility };
const State = enum(u8) { created, starting, running, closing, stopped };
const Receipt = struct {
    work: Work,
    done: zio.Event = .init,
    failure: ?SubmitError = null,

    fn reject(self: *Receipt, reason: RejectReason) void {
        std.debug.assert(!self.done.isSet());
        self.work.reject(self.work.context, reason);
        self.failure = switch (reason) {
            .closed => error.Closed,
            .canceled => error.Canceled,
        };
        self.done.set();
    }
};
const WriteReceipt = struct {
    done: zio.Event = .init,
    failure: ?bus.Error = null,

    fn finish(self: *WriteReceipt, failure: ?bus.Error) void {
        std.debug.assert(!self.done.isSet());
        self.failure = failure;
        self.done.set();
    }
};
const Event = union(enum) {
    work: *Receipt,
    frame: struct { lane: Lane, generation: u64, owned: dbus.OwnedFrame },
    failure: struct { lane: Lane, generation: u64, cause: bus.Error },
    terminal_failure: bus.Error,
};
const Outgoing = struct {
    connection: *bus.Connection,
    bytes: []u8,
    receipt: *WriteReceipt,
};

/// Owns bounded inbound/writer queues and every spawned task. The stable heap address
/// is its task-local lane key. Options' environment and strings borrow the caller through
/// close. Only one caller starts/closes/destroys; concurrent submit callers are supported,
/// but all callers must stop retaining this pointer before destroy.
/// gpa must support concurrent allocation/free by readers, owner and writer. std.Io is
/// explicit owner context; Unix readiness/socket I/O is driven by the supplied zio runtime,
/// not inferred from an std.Io vtable or a port-global runtime.
pub const Pump = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    runtime: *zio.Runtime,
    options: Options,
    hooks: Hooks,
    state: std.atomic.Value(State) = .init(.created),
    lane_key: zio.TaskLocal(bool) = .{},
    startup: zio.Event = .init,
    startup_error: ?Error = null,
    diagnostic: bus.Diagnostic = .empty,
    failure_code: std.atomic.Value(u16) = .init(0),
    writer_failure_code: std.atomic.Value(u16) = .init(0),
    owner: ?zio.JoinHandle(void) = null,
    session_reader: ?zio.JoinHandle(void) = null,
    accessibility_reader: ?zio.JoinHandle(void) = null,
    writer: ?zio.JoinHandle(void) = null,
    inbound_storage: [64]Event = undefined,
    outbound_storage: [32]Outgoing = undefined,
    inbound: zio.Channel(Event),
    outbound: zio.Channel(Outgoing),
    native_bus: ?bus.Bus = null,
    generation: u64 = 1,
    refresh_serial: ?u32 = null,
    address_serial: ?u32 = null,
    send_failure: ?bus.Error = null,
    activated: bool = false,

    /// Allocates a stable owner. No I/O or callback runs before start.
    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        runtime: *zio.Runtime,
        options: Options,
        hooks: Hooks,
    ) Error!*Pump {
        const self = try gpa.create(Pump);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .runtime = runtime,
            .options = options,
            .hooks = hooks,
            .inbound = undefined,
            .outbound = undefined,
        };
        self.inbound = zio.Channel(Event).init(&self.inbound_storage);
        self.outbound = zio.Channel(Outgoing).init(&self.outbound_storage);
        return self;
    }

    /// Starts the owner on the supplied runtime and waits until native startup completes.
    /// A runtime without a driven executor cannot service this blocking call.
    pub fn start(self: *Pump) Error!void {
        if (self.state.cmpxchgStrong(.created, .starting, .acq_rel, .acquire) != null) {
            return error.AlreadyStarted;
        }
        self.owner = self.runtime.spawn(run, .{self}) catch |err| {
            self.state.store(.stopped, .release);
            return mapSpawnError(err);
        };
        waitSettled(&self.startup);
        if (self.startup_error) |err| {
            self.owner.?.join();
            self.owner = null;
            return err;
        }
    }

    /// True only from this pump's callback/operation lane, including startup and teardown.
    pub fn onLane(self: *Pump) bool {
        return self.lane_key.get() orelse false;
    }

    /// Borrows the exact last remote error name until destroy or the next remote error.
    /// Read only on the owner lane or after failed start/successful close, not concurrently
    /// with active dispatch. A supplied failure_diagnostic owns its transferred name instead.
    pub fn lastRemoteErrorName(self: *const Pump) ?[]const u8 {
        if (self.diagnostic.name) |name| return name;
        if (self.options.failure_diagnostic) |diagnostic| {
            if (diagnostic.name) |name| return name;
        }
        if (self.native_bus) |*native| return native.remoteErrorName();
        return null;
    }

    /// Thread-safe last transport failure, including failures before activation.
    /// Success does not erase history; the scalar remains readable until destroy.
    pub fn lastFailure(self: *const Pump) ?bus.Error {
        const code = self.failure_code.load(.acquire);
        return if (code == 0) null else @errorCast(@errorFromInt(code));
    }

    fn recordFailure(self: *Pump, cause: bus.Error) void {
        self.failure_code.store(@intFromError(cause), .release);
        if (self.hooks.failure) |callback| callback(self.hooks.context, cause);
    }

    /// Blocks until execution or explicit rejection. Queue capacity backpressures callers;
    /// no accepted update disappears on close/cancellation. Native execution errors remain
    /// in the caller's operation data. Inactive work still executes to retain focus/bounds.
    pub fn submit(self: *Pump, work: Work) SubmitError!void {
        if (self.onLane()) return error.Reentrant;
        if (self.state.load(.acquire) != .running) return error.Closed;
        try zio.checkCancel();
        var receipt: Receipt = .{ .work = work };
        self.inbound.send(.{ .work = &receipt }) catch |err| return switch (err) {
            error.Closed => error.Closed,
            error.Canceled => error.Canceled,
            else => unreachable, // Channel.send's public contract has only these failures.
        };
        waitSettled(&receipt.done);
        if (receipt.failure) |err| return err;
    }

    /// Stops admission, settles queued work, cancels/joins every task and waits all callbacks.
    /// Reentrant close does nothing and returns Reentrant. The borrowed runtime remains live.
    pub fn close(self: *Pump) error{Reentrant}!void {
        if (self.onLane()) return error.Reentrant;
        self.state.store(.closing, .release);
        self.inbound.close(.graceful);
        if (self.owner) |*handle| {
            handle.cancel();
            self.owner = null;
        } else {
            drainRejected(&self.inbound);
            self.state.store(.stopped, .release);
        }
    }

    /// Frees an already closed or never started owner. Copies are not additional owners.
    pub fn destroy(self: *Pump) void {
        std.debug.assert(self.owner == null);
        std.debug.assert(self.state.load(.acquire) != .running);
        self.diagnostic.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn run(self: *Pump) void {
        var binding: zio.TaskLocal(bool).Node = .unset;
        self.lane_key.set(&binding, true);
        defer self.lane_key.clear(&binding);
        defer self.cleanup();
        self.initialize() catch |err| {
            self.startup_error = err;
            self.recordFailure(err);
            self.startup.set();
            return;
        };
        self.state.store(.running, .release);
        self.startup.set();
        // The lifetime bound is independent of queue capacity and preserves long-lived owners.
        const owner_steps_limit = self.options.pump_steps_limit;
        var owner_steps: u64 = 0;
        while (owner_steps < owner_steps_limit) : (owner_steps += 1) {
            if (self.state.load(.acquire) != .running) break;
            const event = self.inbound.receive() catch |err| switch (err) {
                error.Closed, error.Canceled => break,
                else => unreachable, // Channel.receive exposes only Closed and Canceled.
            };
            if (self.state.load(.acquire) != .running) {
                disposeRejected(event);
                break;
            }
            self.process(event);
        }
        if (owner_steps == owner_steps_limit) {
            self.recordFailure(error.PumpLimit);
            self.writer_failure_code.store(@intFromError(error.PumpLimit), .release);
            self.outbound.close(.graceful);
        }
    }

    fn initialize(self: *Pump) bus.Error!void {
        var options = self.options;
        options.failure_diagnostic = &self.diagnostic;
        self.native_bus = try bus.Bus.init(self.gpa, self.io, self.runtime, options, .{
            .context = self,
            .dispatch = startupDispatch,
        });
        self.writer = self.runtime.spawn(writeLoop, .{self}) catch |err| {
            return mapSpawnError(err);
        };
        const native = &self.native_bus.?;
        const needs_snapshot = native.startup_owner_changed and !native.force_enabled;
        if (!needs_snapshot and native.enabled) try self.attach();
        if (self.native_bus.?.session) |connection| {
            self.session_reader = self.runtime.spawn(readLoop, .{
                self, connection, Lane.session, @as(u64, 0),
            }) catch |err| return mapSpawnError(err);
        }
        if (needs_snapshot) try self.requestFreshState();
    }

    fn attach(self: *Pump) bus.Error!void {
        const native = &self.native_bus.?;
        try native.attach();
        errdefer native.detach();
        self.activated = true;
        self.hooks.activate(self.hooks.context, native) catch |err| {
            self.hooks.deactivate(self.hooks.context, err);
            self.activated = false;
            return err;
        };
        native.embed(self.options.root_path) catch |err| {
            self.hooks.deactivate(self.hooks.context, err);
            self.activated = false;
            return err;
        };
        native.installWriter(.{ .context = self, .write = sendOwned });
        self.accessibility_reader = self.runtime.spawn(readLoop, .{
            self, native.accessibility.?, Lane.accessibility, self.generation,
        }) catch |err| {
            const failure = mapSpawnError(err);
            self.hooks.deactivate(self.hooks.context, failure);
            self.activated = false;
            return failure;
        };
        self.hooks.attached(self.hooks.context, native);
    }

    fn detach(self: *Pump, cause: ?bus.Error) void {
        self.send_failure = null;
        if (cause) |failure| self.recordFailure(failure);
        if (self.accessibility_reader) |*handle| {
            handle.cancel();
            self.accessibility_reader = null;
        }
        if (self.activated) {
            self.hooks.deactivate(self.hooks.context, cause);
            self.activated = false;
        }
        self.native_bus.?.detach();
        self.generation +%= 1;
        // A generation is never reused in the lifetime of an owner.
        if (self.generation == 0) self.state.store(.closing, .release);
    }

    fn process(self: *Pump, event: Event) void {
        switch (event) {
            .work => |receipt| {
                receipt.work.execute(receipt.work.context, &self.native_bus.?);
                if (self.send_failure) |cause| {
                    self.send_failure = null;
                    self.detach(cause);
                }
                receipt.done.set();
            },
            .failure => |failure| {
                if (failure.cause == error.PumpLimit) {
                    self.recordFailure(failure.cause);
                    self.state.store(.closing, .release);
                    return;
                }
                if (failure.lane == .session) {
                    if (self.session_reader) |*handle| {
                        handle.cancel();
                        self.session_reader = null;
                    }
                    if (self.native_bus.?.session) |connection| {
                        connection.destroy();
                        self.native_bus.?.session = null;
                    }
                    self.refresh_serial = null;
                    self.address_serial = null;
                    if (self.native_bus.?.force_enabled) {
                        self.recordFailure(failure.cause);
                    } else {
                        self.detach(failure.cause);
                    }
                } else if (failure.generation == self.generation) {
                    self.detach(failure.cause);
                }
            },
            .terminal_failure => |cause| {
                self.recordFailure(cause);
                self.state.store(.closing, .release);
            },
            .frame => |incoming| {
                var owned = incoming.owned;
                defer owned.deinit();
                if (incoming.lane == .session) {
                    self.processSession(owned.message) catch |err| self.detach(err);
                } else if (incoming.generation == self.generation) {
                    if (self.native_bus.?.accessibility != null) {
                        self.dispatch(owned.message) catch |err| self.detach(err);
                    }
                }
            },
        }
    }

    fn processSession(self: *Pump, message: dbus.Message) bus.Error!void {
        const native = &self.native_bus.?;
        if (native.session == null) return;
        if (native.force_enabled) return;
        if (try native.refreshStatusOwner(message)) {
            self.detach(null);
            self.refresh_serial = null;
            self.address_serial = null;
            try self.requestFreshState();
            return;
        }
        if (!native.isStatusSender(message)) return;
        if (self.address_serial) |serial| {
            if (message.reply_serial == serial) {
                self.address_serial = null;
                try native.updateAddress(message);
                var request = bus.statusRequest();
                request.serial = try native.session.?.nextSerial();
                self.refresh_serial = request.serial;
                try self.sendMessage(native.session.?, request);
                return;
            }
        }
        if (self.refresh_serial) |serial| {
            if (message.reply_serial == serial) {
                self.refresh_serial = null;
                try native.checkReplyError(message);
                native.startup_owner_changed = false;
                try self.changeEnabled(try bus.statusEnabled(message));
                return;
            }
        }
        if (try bus.statusChange(message)) |enabled| {
            // A direct property notification supersedes an older in-flight Get snapshot.
            self.refresh_serial = null;
            if (self.address_serial != null) {
                native.enabled = enabled;
                return;
            }
            native.startup_owner_changed = false;
            try self.changeEnabled(enabled);
        } else if (try bus.statusInvalidated(message)) {
            if (self.address_serial != null) return;
            if (self.refresh_serial != null) return;
            var request = bus.statusRequest();
            request.serial = try native.session.?.nextSerial();
            self.refresh_serial = request.serial;
            try self.sendMessage(native.session.?, request);
        }
    }

    fn requestFreshState(self: *Pump) bus.Error!void {
        const native = &self.native_bus.?;
        if (native.status_owner == null) return;
        const connection = native.session orelse return error.Disconnected;
        var request = if (native.address_overridden) bus.statusRequest() else bus.getAddressRequest();
        request.serial = try connection.nextSerial();
        if (native.address_overridden) {
            self.refresh_serial = request.serial;
        } else {
            self.address_serial = request.serial;
        }
        try self.sendMessage(connection, request);
    }

    fn changeEnabled(self: *Pump, enabled: bool) bus.Error!void {
        const native = &self.native_bus.?;
        native.enabled = enabled;
        if (enabled) {
            if (native.accessibility == null) try self.attach();
        } else if (native.accessibility != null) {
            self.detach(null);
        }
    }

    fn dispatch(self: *Pump, message: dbus.Message) bus.Error!void {
        if (message.kind != .method_call) return;
        var reply = try self.hooks.request(self.hooks.context, &self.native_bus.?, message);
        defer reply.deinit();
        if ((message.flags & 1) != 0) return;
        var outgoing: dbus.Message = .{
            .kind = if (reply.error_name != null) .error_reply else .method_return,
            .reply_serial = message.serial,
            .destination = message.sender,
            .error_name = reply.error_name,
        };
        outgoing.signature = reply.body.signature;
        outgoing.body = reply.body.values;
        try self.sendMessage(self.native_bus.?.accessibility.?, outgoing);
    }

    fn startupDispatch(
        context: *anyopaque,
        native: *bus.Bus,
        connection: *bus.Connection,
        message: dbus.Message,
    ) bus.Error!void {
        const self: *Pump = @ptrCast(@alignCast(context));
        if (message.kind != .method_call) return;
        var reply = try self.hooks.request(self.hooks.context, native, message);
        defer reply.deinit();
        if ((message.flags & 1) != 0) return;
        try connection.writeMessage(.{
            .kind = if (reply.error_name != null) .error_reply else .method_return,
            .reply_serial = message.serial,
            .destination = message.sender,
            .error_name = reply.error_name,
            .signature = reply.body.signature,
            .body = reply.body.values,
        });
    }

    fn sendOwned(
        context: *anyopaque,
        message: dbus.Message,
        body: *const dbus.OwnedBody,
    ) bus.Error!void {
        const self: *Pump = @ptrCast(@alignCast(context));
        std.debug.assert(self.onLane());
        var outgoing = message;
        outgoing.signature = body.signature;
        outgoing.body = body.values;
        const connection = self.native_bus.?.accessibility orelse return error.Disconnected;
        try self.sendMessage(connection, outgoing);
    }

    fn sendMessage(self: *Pump, connection: *bus.Connection, message: dbus.Message) bus.Error!void {
        if (self.writer == null) return error.Disconnected;
        var outgoing = message;
        if (outgoing.serial == 0) outgoing.serial = try connection.nextSerial();
        const bytes = try dbus.encode(self.gpa, outgoing, .little, self.options.limits);
        var receipt: WriteReceipt = .{};
        self.outbound.send(.{
            .connection = connection,
            .bytes = bytes,
            .receipt = &receipt,
        }) catch |err| {
            self.gpa.free(bytes);
            return switch (err) {
                error.Closed => blk: {
                    const code = self.writer_failure_code.load(.acquire);
                    const cause: bus.Error = if (code == 0)
                        error.Disconnected
                    else
                        @errorCast(@errorFromInt(code));
                    self.send_failure = cause;
                    break :blk cause;
                },
                error.Canceled => error.Canceled,
                else => unreachable, // Channel.send exposes only Closed and Canceled.
            };
        };
        // Cancellation joins the writer before this stack-owned receipt can disappear.
        receipt.done.wait() catch |err| switch (err) {
            error.Canceled => {
                if (self.writer) |*handle| {
                    handle.cancel();
                    self.writer = null;
                }
                waitSettled(&receipt.done);
                return error.Canceled;
            },
        };
        if (receipt.failure) |err| {
            self.send_failure = err;
            return err;
        }
    }

    fn readLoop(self: *Pump, connection: *bus.Connection, lane: Lane, generation: u64) void {
        // Readers only frame and enqueue; no application callback can block socket reception.
        const reader_steps_limit = self.options.pump_steps_limit;
        var reader_steps: u64 = 0;
        while (reader_steps < reader_steps_limit) : (reader_steps += 1) {
            var owned = connection.readOwned() catch |err| {
                if (err != error.Canceled) {
                    self.inbound.send(.{ .failure = .{
                        .lane = lane,
                        .generation = generation,
                        .cause = err,
                    } }) catch |send_error| switch (send_error) {
                        error.Closed, error.Canceled => {},
                        else => unreachable, // Channel.send exposes only Closed and Canceled.
                    };
                }
                return;
            };
            self.inbound.send(.{ .frame = .{
                .lane = lane,
                .generation = generation,
                .owned = owned,
            } }) catch |err| {
                owned.deinit();
                switch (err) {
                    error.Closed, error.Canceled => return,
                    else => unreachable, // Channel.send exposes only Closed and Canceled.
                }
            };
        }
        self.publishTerminalFailure(error.PumpLimit);
    }

    fn writeLoop(self: *Pump) void {
        const writer_steps_limit = self.options.pump_steps_limit;
        var writer_steps: u64 = 0;
        var terminal_failure: bus.Error = error.Disconnected;
        var publish_failure = false;
        while (writer_steps < writer_steps_limit) : (writer_steps += 1) {
            const outgoing = self.outbound.receive() catch |err| switch (err) {
                error.Closed, error.Canceled => break,
                else => unreachable, // Channel.receive exposes only Closed and Canceled.
            };
            const terminal_code = self.writer_failure_code.load(.acquire);
            if (terminal_code != 0) {
                self.gpa.free(outgoing.bytes);
                outgoing.receipt.finish(@errorCast(@errorFromInt(terminal_code)));
                break;
            }
            const failure: ?bus.Error = blk: {
                outgoing.connection.writeBytes(outgoing.bytes) catch |err| break :blk err;
                break :blk null;
            };
            self.gpa.free(outgoing.bytes);
            outgoing.receipt.finish(failure);
            if (failure) |cause| {
                if (cause == error.Canceled) break;
            }
        }
        if (writer_steps == writer_steps_limit) {
            terminal_failure = error.PumpLimit;
            publish_failure = self.writer_failure_code.cmpxchgStrong(
                0,
                @intFromError(terminal_failure),
                .acq_rel,
                .acquire,
            ) == null;
        }
        const terminal_code = self.writer_failure_code.load(.acquire);
        if (terminal_code != 0) terminal_failure = @errorCast(@errorFromInt(terminal_code));
        // Close before draining so concurrent senders cannot retain unsettled receipts.
        self.outbound.close(.graceful);
        const writer_drain_steps_limit = self.outbound_storage.len;
        for (0..writer_drain_steps_limit) |_| {
            const outgoing = self.outbound.tryReceive() catch |err| switch (err) {
                error.Closed, error.WouldBlock => break,
                else => unreachable, // Channel.tryReceive exposes only Closed and WouldBlock.
            };
            self.gpa.free(outgoing.bytes);
            outgoing.receipt.finish(terminal_failure);
        }
        if (publish_failure) self.publishTerminalFailure(terminal_failure);
    }

    fn publishTerminalFailure(self: *Pump, cause: bus.Error) void {
        self.writer_failure_code.store(@intFromError(cause), .release);
        self.outbound.close(.graceful);
        self.inbound.send(.{ .terminal_failure = cause }) catch |err| switch (err) {
            // Closed/canceled admission means cleanup already owns the remaining resources.
            error.Closed, error.Canceled => return,
            else => unreachable, // Channel.send exposes only Closed and Canceled.
        };
    }

    fn cleanup(self: *Pump) void {
        self.state.store(.closing, .release);
        self.inbound.close(.graceful);
        if (self.session_reader) |*handle| {
            handle.cancel();
            self.session_reader = null;
        }
        if (self.accessibility_reader) |*handle| {
            handle.cancel();
            self.accessibility_reader = null;
        }
        self.outbound.close(.graceful);
        if (self.writer) |*handle| {
            handle.cancel();
            self.writer = null;
        }
        drainRejected(&self.inbound);
        if (self.activated) {
            self.hooks.deactivate(self.hooks.context, null);
            self.activated = false;
        }
        if (self.native_bus) |*native| {
            const diagnostic = native.takeDiagnostic();
            if (diagnostic.name != null) {
                self.diagnostic.deinit(self.gpa);
                self.diagnostic = diagnostic;
            }
            native.deinit();
            self.native_bus = null;
        }
        if (self.startup_error != null) {
            if (self.options.failure_diagnostic) |target| {
                std.debug.assert(target.name == null);
                target.* = self.diagnostic;
                self.diagnostic = .empty;
            }
        }
        self.state.store(.stopped, .release);
    }
};

fn mapSpawnError(err: anytype) SpawnError {
    return err;
}

fn waitSettled(event: *zio.Event) void {
    // Cancellation cannot release caller-owned storage still retained by an accepted queue item.
    zio.beginShield();
    defer zio.endShield();
    while (!event.isSet()) {
        event.wait() catch |err| switch (err) {
            error.Canceled => {},
        };
    }
}

fn disposeRejected(event: Event) void {
    switch (event) {
        .work => |receipt| receipt.reject(.closed),
        .frame => |incoming| {
            var owned = incoming.owned;
            owned.deinit();
        },
        .failure, .terminal_failure => {},
    }
}

fn drainRejected(queue: *zio.Channel(Event)) void {
    while (queue.tryReceive()) |event| {
        disposeRejected(event);
    } else |err| switch (err) {
        error.Closed, error.WouldBlock => {},
        else => unreachable, // Channel.tryReceive exposes only Closed and WouldBlock.
    }
}

// Closing a bounded queue must settle every accepted caller-owned receipt before returning.
test "closed owner queue rejects accepted work and records completion exactly once" {
    const ClosedWorkState = struct {
        const Self = @This();

        rejected: u32 = 0,
        fn execute(_: *anyopaque, _: *bus.Bus) void {
            @panic("closed queue executed work");
        }
        fn reject(context: *anyopaque, reason: RejectReason) void {
            const state: *Self = @ptrCast(@alignCast(context));
            std.debug.assert(reason == .closed);
            state.rejected += 1;
        }
    };
    var state: ClosedWorkState = .{};
    var first: Receipt = .{ .work = .{
        .context = &state,
        .execute = ClosedWorkState.execute,
        .reject = ClosedWorkState.reject,
    } };
    var second: Receipt = .{ .work = first.work };
    var storage: [2]Event = undefined;
    var queue = zio.Channel(Event).init(&storage);
    try queue.trySend(.{ .work = &first });
    try queue.trySend(.{ .work = &second });
    queue.close(.graceful);
    drainRejected(&queue);
    try std.testing.expectEqual(@as(u32, 2), state.rejected);
    try std.testing.expect(first.done.isSet());
    try std.testing.expect(second.done.isSet());
    try std.testing.expectEqual(error.Closed, first.failure.?);
    drainRejected(&queue);
    try std.testing.expectEqual(@as(u32, 2), state.rejected);
}

// Writer ownership ends only after the complete write outcome has been published.
test "writer receipt retains exact failure after completion barrier" {
    var receipt: WriteReceipt = .{};
    receipt.finish(error.Disconnected);
    try receipt.done.wait();
    try std.testing.expectEqual(error.Disconnected, receipt.failure.?);
}

// Queued decoded frames must release their owned backing bytes on the same close drain.
test "owner close drain releases received frames without dispatching them" {
    const gpa = std.testing.allocator;
    const bytes = try dbus.encode(gpa, .{
        .kind = .signal,
        .serial = 1,
        .path = "/fixture",
        .interface = "org.example.Fixture",
        .member = "Changed",
        .signature = "s",
        .body = &.{.{ .string = "owned queued frame" }},
    }, .little, .{});
    defer gpa.free(bytes);
    const owned = try dbus.decode(gpa, bytes, .{});
    var storage: [1]Event = undefined;
    var queue = zio.Channel(Event).init(&storage);
    try queue.trySend(.{ .frame = .{
        .lane = .accessibility,
        .generation = 1,
        .owned = owned,
    } });
    queue.close(.graceful);
    drainRejected(&queue);
    try std.testing.expectError(error.Closed, queue.tryReceive());
}

fn createFailureCase(
    gpa: std.mem.Allocator,
    runtime: *zio.Runtime,
    environ: *const std.process.Environ.Map,
) !void {
    const Unexpected = struct {
        fn activate(_: *anyopaque, _: *bus.Bus) bus.Error!void {
            @panic("create invoked activation");
        }
        fn attached(_: *anyopaque, _: *bus.Bus) void {
            @panic("create invoked attachment");
        }
        fn deactivate(_: *anyopaque, _: ?bus.Error) void {
            @panic("create invoked deactivation");
        }
        fn request(_: *anyopaque, _: *bus.Bus, _: dbus.Message) bus.Error!dbus.OwnedReply {
            @panic("create invoked request");
        }
        fn failure(context: *anyopaque, cause: bus.Error) void {
            const observed: *u8 = @ptrCast(@alignCast(context));
            std.debug.assert(cause == error.Disconnected);
            observed.* += 1;
        }
    };
    var context: u8 = 0;
    const owner = try Pump.create(gpa, std.Io.failing, runtime, .{
        .uid = 0,
        .environ = environ,
    }, .{
        .context = &context,
        .activate = Unexpected.activate,
        .attached = Unexpected.attached,
        .deactivate = Unexpected.deactivate,
        .request = Unexpected.request,
        .failure = Unexpected.failure,
    });
    defer owner.destroy();
    try std.testing.expect(!owner.onLane());
    try std.testing.expectError(error.Closed, owner.submit(.{
        .context = &context,
        .execute = struct {
            fn execute(_: *anyopaque, _: *bus.Bus) void {
                @panic("unstarted execute");
            }
        }.execute,
        .reject = struct {
            fn reject(_: *anyopaque, _: RejectReason) void {
                @panic("unaccepted reject");
            }
        }.reject,
    }));
    const Probe = struct {
        fn run(pump: *Pump) !void {
            var node: zio.TaskLocal(bool).Node = .unset;
            pump.lane_key.set(&node, true);
            defer pump.lane_key.clear(&node);
            try std.testing.expect(pump.lastFailure() == null);
            pump.recordFailure(error.Disconnected);
            try std.testing.expectEqual(error.Disconnected, pump.lastFailure().?);
            try std.testing.expect(pump.onLane());
            try std.testing.expectError(error.Reentrant, pump.close());
            var value: u8 = 0;
            try std.testing.expectError(error.Reentrant, pump.submit(.{
                .context = &value,
                .execute = struct {
                    fn execute(_: *anyopaque, _: *bus.Bus) void {
                        @panic("reentrant execute");
                    }
                }.execute,
                .reject = struct {
                    fn reject(_: *anyopaque, _: RejectReason) void {
                        @panic("reentrant reject");
                    }
                }.reject,
            }));
        }
    };
    var probe = try runtime.spawn(Probe.run, .{owner});
    try probe.join();
    try std.testing.expectEqual(@as(u8, 1), context);
    // On one executor, the coordinator cannot run after entered until the sender
    // yields at the full channel. This proves cancellation before actual acceptance.
    owner.state.store(.running, .release);
    for (0..owner.inbound_storage.len) |_| {
        try owner.inbound.trySend(.{ .failure = .{
            .lane = .session,
            .generation = 0,
            .cause = error.Disconnected,
        } });
    }
    const Admission = struct {
        const Self = @This();

        pump: *Pump,
        entered: zio.Event = .init,
        fn send(self: *Self) SubmitError!void {
            self.entered.set();
            return self.pump.submit(.{
                .context = self,
                .execute = struct {
                    fn execute(_: *anyopaque, _: *bus.Bus) void {
                        @panic("canceled unaccepted execute");
                    }
                }.execute,
                .reject = struct {
                    fn reject(_: *anyopaque, _: RejectReason) void {
                        @panic("canceled unaccepted reject");
                    }
                }.reject,
            });
        }
        fn cancel(self: *Self, sender: *zio.JoinHandle(SubmitError!void)) !void {
            try self.entered.wait();
            sender.cancel();
        }
    };
    var admission: Admission = .{ .pump = owner };
    var sender = try runtime.spawn(Admission.send, .{&admission});
    errdefer {
        owner.inbound.close(.graceful);
        sender.cancel();
    }
    var canceler = try runtime.spawn(Admission.cancel, .{ &admission, &sender });
    try canceler.join();
    try std.testing.expectError(error.Canceled, sender.join());
    try owner.close();
    try owner.close();
}

// Allocation failure cannot acquire a native socket, invoke a callback or leak the stable owner.
test "unstarted pump is failure atomic and close is repeatable" {
    const runtime = try zio.Runtime.init(std.testing.allocator, .{
        .executors = .exact(1),
        .enable_main_executor = false,
    });
    defer runtime.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, createFailureCase, .{
        runtime, &environ,
    });
}

test "request transport failure propagates before normal or startup reply write" {
    const Fixture = struct {
        const Self = @This();

        calls: u8 = 0,
        cause: bus.Error = error.Disconnected,
        expected_bus: *bus.Bus = undefined,
        fn request(context: *anyopaque, native: *bus.Bus, _: dbus.Message) bus.Error!dbus.OwnedReply {
            const self: *Self = @ptrCast(@alignCast(context));
            std.debug.assert(native == self.expected_bus);
            self.calls += 1;
            return self.cause;
        }
        fn activate(_: *anyopaque, _: *bus.Bus) bus.Error!void {
            unreachable;
        }
        fn attached(_: *anyopaque, _: *bus.Bus) void {
            unreachable;
        }
        fn deactivate(_: *anyopaque, _: ?bus.Error) void {
            unreachable;
        }
    };
    var fixture: Fixture = .{};
    // Only the request hook is accessible on these failure paths. Any attempted
    // reply write would access uninitialized connection state instead of passing.
    var owner: Pump = undefined;
    owner.native_bus = @as(bus.Bus, undefined);
    fixture.expected_bus = &owner.native_bus.?;
    owner.hooks = .{
        .context = &fixture,
        .activate = Fixture.activate,
        .attached = Fixture.attached,
        .deactivate = Fixture.deactivate,
        .request = Fixture.request,
    };
    const message: dbus.Message = .{
        .kind = .method_call,
        .serial = 17,
        .path = "/org/a11y/atspi/accessible/root",
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Set",
    };
    try std.testing.expectError(error.Disconnected, owner.dispatch(message));
    var connection: bus.Connection = undefined;
    var constructor_bus: bus.Bus = undefined;
    owner.native_bus = null;
    fixture.expected_bus = &constructor_bus;
    try std.testing.expectError(
        error.Disconnected,
        Pump.startupDispatch(&owner, &constructor_bus, &connection, message),
    );
    fixture.cause = error.OutOfMemory;
    owner.native_bus = @as(bus.Bus, undefined);
    fixture.expected_bus = &owner.native_bus.?;
    try std.testing.expectError(error.OutOfMemory, owner.dispatch(message));
    owner.native_bus = null;
    fixture.expected_bus = &constructor_bus;
    try std.testing.expectError(
        error.OutOfMemory,
        Pump.startupDispatch(&owner, &constructor_bus, &connection, message),
    );
    try std.testing.expectEqual(@as(u8, 4), fixture.calls);
}

// Zero injected steps exercises the real writer's exhaustion and owned queue cleanup.
test "pump step exhaustion settles every accepted writer with exact PumpLimit" {
    var owner: Pump = undefined;
    owner.gpa = std.testing.allocator;
    owner.options.pump_steps_limit = 0;
    owner.writer_failure_code = .init(0);
    owner.outbound = zio.Channel(Outgoing).init(&owner.outbound_storage);
    owner.inbound = zio.Channel(Event).init(&owner.inbound_storage);
    var first: WriteReceipt = .{};
    var second: WriteReceipt = .{};
    var connection: bus.Connection = undefined;
    try owner.outbound.trySend(.{
        .connection = &connection,
        .bytes = try owner.gpa.dupe(u8, "first"),
        .receipt = &first,
    });
    try owner.outbound.trySend(.{
        .connection = &connection,
        .bytes = try owner.gpa.dupe(u8, "second"),
        .receipt = &second,
    });
    owner.writeLoop();
    try std.testing.expect(first.done.isSet());
    try std.testing.expect(second.done.isSet());
    try std.testing.expectEqual(error.PumpLimit, first.failure.?);
    try std.testing.expectEqual(error.PumpLimit, second.failure.?);
    try std.testing.expectError(error.Closed, owner.outbound.tryReceive());
    const event = try owner.inbound.tryReceive();
    try std.testing.expectEqual(error.PumpLimit, event.terminal_failure);
    try std.testing.expectError(error.WouldBlock, owner.inbound.tryReceive());
}

// Exhaustion must not touch a connection or dispatch callbacks from a reader.
test "zero reader step bound publishes terminal PumpLimit without reading" {
    var owner: Pump = undefined;
    owner.options.pump_steps_limit = 0;
    owner.writer_failure_code = .init(0);
    owner.outbound = zio.Channel(Outgoing).init(&owner.outbound_storage);
    owner.inbound = zio.Channel(Event).init(&owner.inbound_storage);
    var connection: bus.Connection = undefined;
    owner.readLoop(&connection, .accessibility, 1);
    const event = try owner.inbound.tryReceive();
    try std.testing.expectEqual(error.PumpLimit, event.terminal_failure);
    try std.testing.expectError(error.WouldBlock, owner.inbound.tryReceive());
}

// Reader exhaustion closes writer admission before owner callbacks or teardown can run.
test "reader exhaustion rejects queued writer bytes without accessing the connection" {
    var owner: Pump = undefined;
    owner.gpa = std.testing.allocator;
    owner.options.pump_steps_limit = 0;
    owner.writer_failure_code = .init(0);
    owner.outbound = zio.Channel(Outgoing).init(&owner.outbound_storage);
    owner.inbound = zio.Channel(Event).init(&owner.inbound_storage);
    var receipt: WriteReceipt = .{};
    var connection: bus.Connection = undefined;
    try owner.outbound.trySend(.{
        .connection = &connection,
        .bytes = try owner.gpa.dupe(u8, "queued"),
        .receipt = &receipt,
    });
    owner.readLoop(&connection, .accessibility, 1);
    owner.writeLoop();
    try std.testing.expect(receipt.done.isSet());
    try std.testing.expectEqual(error.PumpLimit, receipt.failure.?);
    try std.testing.expectError(error.Closed, owner.outbound.tryReceive());
    owner.failure_code = .init(0);
    owner.state = .init(.running);
    owner.hooks.failure = null;
    owner.process(try owner.inbound.tryReceive());
    try std.testing.expectEqual(error.PumpLimit, owner.lastFailure().?);
    try std.testing.expectEqual(State.closing, owner.state.load(.acquire));
}
