//! zaccesskit — a pure Zig 0.16 port of the Rust `accesskit` toolkit, built
//! around the `zio` async runtime.
//!
//! **What this package is.** `accesskit` defines a platform-neutral
//! accessibility tree, a `Tree` update protocol, an `ActionRequest` channel
//! from the platform back to the application, and a C ABI that platform
//! adapters implement. This package re-implements all of that in Zig and
//! links the platform half as C.
//!
//! **What this file is.** The module root. Everything a consumer reaches must
//! be re-exported here. Apart from the two values below it carries no
//! declarations, because the port has not started: the module layout, the
//! naming of each shard, and the order in which they land are fixed by
//! `docs/30-port-design.md`, and the milestones that add them are in
//! `docs/40-plan.md`.
//!
//! **Read first.** `docs/10-accesskit-core.md` is the upstream surface being
//! ported. `docs/20-zio-and-zig-io.md` is the runtime the port is built on and
//! the Zig 0.16 `Io` interfaces it has to bridge. `docs/31-c-abi-design.md` is
//! the C seam. `AGENTS.md` holds the house rules this code is written under.

const std = @import("std");
const builtin = @import("builtin");

/// The platform-neutral value types: roles, actions, identifiers, geometry, the
/// property model and the tree update. A consumer names these in a signature,
/// so they sit one namespace below the package root rather than being
/// flattened into it; `docs/30-port-design.md` record R2 gives the reasoning.
///
/// Nothing in this layer reaches for a runtime. It holds no clock, no
/// environment and no socket, and every entry point that can block takes
/// `io: std.Io`.
pub const schema = @import("schema/root.zig");

/// The consumer half: a materialized tree, the queries over it, and the update
/// protocol that keeps it current.
///
/// It sits one namespace below the package root beside `schema`, for the same
/// reason and with the same reasoning: a consumer names these types in a
/// signature next to the schema types, so neither belongs flattened into the
/// root.
///
/// Nothing in this layer reaches for a runtime either, and for the same
/// reason: the consumer half is synchronous. What an application does with a
/// node, and what it does with a platform event, is above this layer.
pub const consumer = @import("consumer/root.zig");

/// The C ABI: the seam a platform adapter links against.
///
/// `include/zaccesskit.h` is the contract and this namespace implements it. It
/// sits one level below the package root with `schema` and `consumer` because a
/// C consumer never sees a Zig name: the seam is the 498 declarations in the
/// header, and the modules behind them are an implementation detail of it.
pub const capi = @import("capi/root.zig");

/// Package version, mirrored from `.version` in `build.zig.zon` through the
/// `build_options` module.
///
/// Zig's build API exposes no manifest reader, so `build.zig` holds a second
/// copy. A release bumps both.
///
/// The C ABI needs it at milestone M4, for the shared library's version symbol
/// and the version macro in the header. `docs/31-c-abi-design.md` section 4
/// owns that.
pub const version = @import("build_options").version;

/// Compiler floor the package declares, mirrored from
/// `.minimum_zig_version` in `build.zig.zon`. It is a floor, so building with a
/// later compiler is allowed; building with an earlier one is not, and would
/// ship a package whose documented compiler does not build it.
pub const minimum_zig_version = @import("build_options").minimum_zig_version;

test "the running compiler is at least the declared floor" {
    // A floor raised above the compiler the gate runs would leave the gate
    // green and every consumer on the documented floor unable to build. That
    // is the defect this guards.
    const running = builtin.zig_version;

    var parts = std.mem.splitScalar(u8, minimum_zig_version, '.');
    const want: std.SemanticVersion = .{
        .major = try std.fmt.parseInt(usize, parts.next() orelse return error.BadFloor, 10),
        .minor = try std.fmt.parseInt(usize, parts.next() orelse return error.BadFloor, 10),
        .patch = try std.fmt.parseInt(usize, parts.next() orelse return error.BadFloor, 10),
    };
    if (parts.next() != null) return error.BadFloor;

    try std.testing.expect(running.order(want) != .lt);
}

test "the published version is three numeric components" {
    // `version` becomes a C header macro and a shared library version symbol at
    // M4, both of which take `major.minor.patch`. A malformed bump would
    // produce a header that does not compile for a C consumer.
    var parts = std.mem.splitScalar(u8, version, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        _ = try std.fmt.parseInt(u32, part, 10);
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "the schema namespace is reachable and analysed" {
    // Without this, `pub const schema = @import(...)` compiles to a re-export
    // that nothing references, so `zig build test` would report green while
    // analysing no module under `src/schema/`. That is exactly what happened
    // before this test existed, and a green gate that checked two constants
    // was worth nothing.
    std.testing.refAllDecls(schema);
}

test "the consumer namespace is reachable and analysed" {
    // Same defect this file already guards against for `schema`, one namespace
    // over: a re-export nothing references analyses no module, so a green run
    // would say nothing about the twenty-seven files underneath it.
    std.testing.refAllDecls(consumer);
}

test "the C ABI namespace is reachable and analysed" {
    // The third instance of the same defect. A re-export nothing references
    // analyses no module, and this namespace is the one where an unanalysed
    // export is a missing C symbol rather than a missing query.
    std.testing.refAllDecls(capi);
}
