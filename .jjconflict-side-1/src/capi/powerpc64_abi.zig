//! Private target authority and TreeId value lowering for the observed
//! PowerPC64 Linux musl ELFv2 C ABI. This is not a published Zig root or C type.
//! Canonical schema and header layouts remain the consumer contract.
const builtin = @import("builtin");
const std = @import("std");
const schema = @import("../schema/root.zig");

pub const needs_lowering = builtin.cpu.arch == .powerpc64 and
    builtin.os.tag == .linux and builtin.abi == .musl;

pub const TreeIdWords = extern struct {
    first: u64,
    second: u64,
};
pub const TreeIdValue = if (needs_lowering) TreeIdWords else schema.TreeId;

pub fn treeIdFromValue(value: TreeIdValue) schema.TreeId {
    if (!needs_lowering) return value;
    var tree: schema.TreeId = undefined;
    std.mem.writeInt(u64, tree.bytes[0..8], value.first, .big);
    std.mem.writeInt(u64, tree.bytes[8..16], value.second, .big);
    return tree;
}

pub fn treeIdToValue(value: schema.TreeId) TreeIdValue {
    if (!needs_lowering) return value;
    return .{
        .first = std.mem.readInt(u64, value.bytes[0..8], .big),
        .second = std.mem.readInt(u64, value.bytes[8..16], .big),
    };
}
