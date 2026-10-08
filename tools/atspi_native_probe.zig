//! Hand-authored consumer fixture. Native proof requires an independent real-bus client.
const std = @import("std");
const package = @import("zaccesskit");
const schema = package.schema;
const native = package.adapters.atspi;
const fixture = @import("atspi_probe_fixture.zig");
const host_module = @import("atspi_probe_host.zig");
const Host = host_module.Host;
const Factory = host_module.Factory;
const FaultAllocator = host_module.FaultAllocator;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 8) return error.TooManyArguments;
    var session: ?[]const u8 = null;
    var accessibility: ?[]const u8 = null;
    var c_metadata = false;
    var defer_activation = false;
    var positioned_edits = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--c-metadata")) {
            c_metadata = true;
        } else if (std.mem.eql(u8, args[index], "--defer-activation")) {
            defer_activation = true;
        } else if (std.mem.eql(u8, args[index], "--positioned-edits")) {
            positioned_edits = true;
        } else if (std.mem.eql(u8, args[index], "--session")) {
            index += 1;
            if (index == args.len) return error.MissingArgument;
            session = args[index];
        } else if (std.mem.eql(u8, args[index], "--a11y")) {
            index += 1;
            if (index == args.len) return error.MissingArgument;
            accessibility = args[index];
        } else return error.UnknownArgument;
    }
    if (c_metadata and defer_activation) return error.ConflictingActivationOptions;
    var faults: FaultAllocator = .{ .backing = init.gpa };
    const gpa = faults.allocator();
    const runtime = try package.Runtime.init(init.gpa, .{
        .executors = .exact(1),
        .enable_main_executor = false,
        .thread_pool = .{ .min_threads = 0, .max_threads = 0 },
        .dns = .{ .custom_resolver = false },
    });
    defer runtime.deinit();
    var output_buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    var host: Host = .{
        .gpa = gpa,
        .io = init.io,
        .output = &output.interface,
        .faults = &faults,
        .full = try fixture.buildFull(gpa, .{}, null),
    };
    host.defer_activation = defer_activation;
    defer host.deinit();
    if (c_metadata) {
        host.metadata_name = "probe-c-owner";
        host.metadata_version = "1.0";
        host.full.tree = host.info(1);
        host.c_activation = try host.makeC(1);
    }
    const callbacks: native.Callbacks = .{
        .context = &host,
        .activation = Host.activation,
        .activation_completed = Host.activationCompleted,
        .action = Host.action,
        .deactivation = Host.deactivation,
        .editable_text = if (positioned_edits) Host.positionedEdit else null,
    };
    const adapter = try native.NativeAdapter.create(gpa, init.io, runtime, .{
        .adapter_id = 1,
        .app_name = "Zaccesskit native probe",
        .is_host_focused = true,
        .bus = .{ .environ = init.environ_map, .uid = std.c.getuid(), .session_address = session, .accessibility_address = accessibility },
    }, callbacks);
    defer adapter.destroy();
    // Close returns only Reentrant on the pump lane. This defer runs in main, outside that lane.
    defer adapter.close() catch unreachable;
    adapter.start() catch |err| {
        try host.output.print("START_REJECTED {s} remote={s}\n", .{
            @errorName(err), adapter.startupErrorName() orelse "none",
        });
        try host.output.flush();
        return err;
    };
    try host.line("READY adapter=1 root=/org/a11y/atspi/accessible/root " ++
        "cache=/org/a11y/atspi/cache nodes=/org/a11y/atspi/accessible/1/ID\n");
    try host.line(if (positioned_edits)
        "EDIT_MODE positioned=true queue=8 replacement_bytes=256 live_bytes=1024\n"
    else
        "EDIT_MODE positioned=false insert_delete=NotSupported\n");
    var input_buffer: [1024]u8 = undefined;
    var input = std.Io.File.stdin().reader(init.io, &input_buffer);
    var exhausted = true;
    for (0..command_limit) |_| {
        const line = try input.interface.takeDelimiter('\n') orelse {
            exhausted = false;
            break;
        };
        if (line.len > 1023) return error.CommandTooLong;
        var words = std.mem.tokenizeAny(u8, line, " \r\t");
        const command = words.next() orelse continue;
        const argument = words.next();
        if (words.next() != null) return error.TooManyArguments;
        if (std.mem.eql(u8, command, "close")) {
            if (argument != null) return error.UnexpectedArgument;
            exhausted = false;
            break;
        }
        if (std.mem.eql(u8, command, "readstats") or
            std.mem.eql(u8, command, "reattach-status"))
        {
            if (argument != null) return error.UnexpectedArgument;
            try host.stats(adapter);
            continue;
        }
        if (std.mem.eql(u8, command, "drain") or
            std.mem.eql(u8, command, "editcommit"))
        {
            if (argument != null) return error.UnexpectedArgument;
            if (!positioned_edits) return error.PositionedEditsDisabled;
            try host.drainEdits();
            if (std.mem.eql(u8, command, "drain")) continue;
        }
        if (std.mem.eql(u8, command, "focus")) {
            const value = argument orelse return error.MissingArgument;
            if (!std.mem.eql(u8, value, "0") and !std.mem.eql(u8, value, "1"))
                return error.InvalidFocus;
            host.recordModel(adapter.updateWindowFocusState(std.mem.eql(u8, value, "1")), false, null, "", "");
            continue;
        }
        var forced_full = false;
        var invalid_root = false;
        var missing_full_child = false;
        var prepared_only = false;
        var fail_next = false;
        var next_model = host.model;
        var next_name = host.metadata_name;
        var next_version = host.metadata_version;
        if (std.mem.eql(u8, command, "update") or std.mem.eql(u8, command, "prepare")) {
            next_model.revision ^= 1;
            next_model.bad_geometry = false;
            prepared_only = std.mem.eql(u8, command, "prepare");
        } else if (std.mem.eql(u8, command, "reorder")) {
            next_model.reordered = !next_model.reordered;
        } else if (std.mem.eql(u8, command, "remove")) {
            next_model.removed = true;
            if (next_model.focus == 2) next_model.focus = 1;
        } else if (std.mem.eql(u8, command, "metadata-delta")) {
            // Metadata is deliberately omitted, not reset to fixture defaults.
        } else if (std.mem.eql(u8, command, "publish") or
            std.mem.eql(u8, command, "editcommit"))
        {
            // Publish the actual cached schema without rebuilding its prepared nodes.
        } else if (std.mem.eql(u8, command, "borrowed-missing")) {
            missing_full_child = true;
            next_model.revision ^= 1;
        } else if (std.mem.eql(u8, command, "full-missing")) {
            forced_full = true;
            missing_full_child = true;
            next_model.revision ^= 1;
        } else if (std.mem.eql(u8, command, "metadata-invalid")) {
            forced_full = true;
            invalid_root = true;
        } else if (std.mem.eql(u8, command, "metadata-corrected")) {
            next_name = "probe-corrected";
            next_version = "2.0";
            forced_full = true;
        } else if (std.mem.eql(u8, command, "tree-oom")) {
            fail_next = true;
            next_model.revision ^= 1;
        } else if (std.mem.eql(u8, command, "notification-error")) {
            next_model.revision ^= 1;
            next_model.bad_geometry = true;
        } else return error.UnknownCommand;
        if (argument != null) return error.UnexpectedArgument;
        const reused_cache = std.mem.eql(u8, command, "publish") or
            std.mem.eql(u8, command, "editcommit") or
            std.mem.eql(u8, command, "metadata-delta") or
            std.mem.eql(u8, command, "metadata-invalid");
        if (!reused_cache) {
            const full = try fixture.buildFull(gpa, next_model, .{
                .root = fixture.nodeId(1),
                .toolkit_name = next_name,
                .toolkit_version = next_version,
            });
            host.cache_mutex.lockUncancelable(host.io);
            host.full.deinit(gpa);
            host.full = full;
            host.model = next_model;
            host.rebindTextModel();
            host.metadata_name = next_name;
            host.metadata_version = next_version;
            if (host.c_activation) |old| {
                package.capi.tree_update.treeUpdateFree(old);
                _ = host.c_frees.fetchAdd(1, .monotonic);
                host.c_activation = null;
                host.c_activation = host.makeC(1) catch |err| {
                    host.cache_mutex.unlock(host.io);
                    return err;
                };
            }
            host.cache_mutex.unlock(host.io);
        }
        if (prepared_only) {
            host.output_mutex.lockUncancelable(host.io);
            defer host.output_mutex.unlock(host.io);
            try host.output.print("PREPARED attachment={d} revision={d} delta=1,2,3,4,7,8\n", .{ adapter.updateTicket().attachment, host.model.revision });
            try host.output.flush();
            continue;
        }
        var factory: Factory = .{ .host = &host, .forced_full = forced_full, .fail_next = fail_next, .missing_full_child = missing_full_child };
        defer if (factory.c_owner) |owner| package.capi.tree_update.treeUpdateFree(owner);
        if (forced_full) {
            factory.c_owner = try host.makeC(if (invalid_root) 999 else 1);
            if (invalid_root) {
                try package.capi.tree_info.treeInfoSetToolkitName(factory.c_owner.?.info.?, "rejected-toolkit");
                try package.capi.tree_info.treeInfoSetToolkitVersion(factory.c_owner.?.info.?, "9.9");
                factory.c_owner.?.update.tree = factory.c_owner.?.info.?.tree;
            }
        }
        var outcome: native.UpdateOutcome = undefined;
        if (forced_full or fail_next) {
            outcome = adapter.updateIfActive(Factory.get, &factory);
        } else {
            // The views share preflighted cache storage and never own its node properties.
            var delta_entries: [fixture.node_count]schema.NodeEntry = undefined;
            var full_entries: [fixture.node_count]schema.NodeEntry = undefined;
            var delta: schema.TreeUpdate = .{
                .nodes = .initBuffer(&delta_entries),
                .focus = host.full.focus,
            };
            var candidate_full = host.full;
            candidate_full.nodes = .initBuffer(&full_entries);
            for (host.full.nodes.items) |entry| {
                const id = entry.node_id.value;
                if (id == 1 or id == 2 or id == 3 or id == 4 or id == 7 or id == 8)
                    delta.nodes.appendAssumeCapacity(entry);
                if (!missing_full_child or id != 5)
                    candidate_full.nodes.appendAssumeCapacity(entry);
            }
            outcome = adapter.updateIfActiveBorrowedChecked(.{
                .delta = &delta,
                .current_full = &candidate_full,
            });
        }
        faults.disarm();
        if (factory.c_owner) |owner| {
            package.capi.tree_update.treeUpdateFree(owner);
            factory.c_owner = null;
            _ = host.c_frees.fetchAdd(1, .monotonic);
        }
        host.record(outcome, factory.included_metadata);
    }
    if (exhausted) try host.line("BOUND commands=256 closing=true\n");
    try adapter.close();
    host.closed.store(true, .release);
    try host.stats(adapter);
    try host.line("CLOSED tasks_joined=true userdata_live=true\n");
    if (host.output_failed.load(.acquire)) return error.WriteFailed;
}

const command_limit = 256;
