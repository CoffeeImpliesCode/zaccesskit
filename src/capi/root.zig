//! The C ABI: the seam a platform adapter links against.
//!
//! **What this namespace is.** `include/zaccesskit.h` is 6581 lines and declares
//! 498 functions; this namespace implements them in Zig so a platform adapter can
//! be written in any language that speaks C. The header is the contract, and it
//! is the only thing a C consumer compiles against — so every export here has to
//! match a declaration in it exactly, in name, in argument order, in return shape,
//! and in the ownership of everything it hands back.
//!
//! **The layers, and why the order is a constraint.**
//!
//! - `handles.zig` and `allocation.zig` sit at the bottom and have no dependencies
//!   on each other or on anything above. `handles.zig` declares the eleven opaque
//!   handle types the header forward-declares and nothing else; `allocation.zig`
//!   owns the allocator, the per-thread error slot, and the catalogue of the 17
//!   `*_free` functions.
//! - `marshal.zig` sits next and holds **every** conversion between the port's Zig
//!   types and the header's `extern struct` forms. No other module in this
//!   namespace defines a conversion. Two copies of one conversion is how they
//!   diverge.
//! - The domain files sit above it, one per group of declarations: `node.zig` for
//!   the node accessors, `geometry.zig` for the affine and rect surface,
//!   `tree_info.zig`, `action_request.zig`, `platform.zig`. Each converts through
//!   `marshal.zig` and reaches the consumer layer beneath.
//!
//! **The rule that catches everyone.** A C string stops at the first NUL. The
//! header states it for the two `_with_length` setters, and it holds for the whole
//! family because `string_free` releases with `std.mem.span`, which finds the end
//! at the first NUL — so an allocation holding a byte past one is freed at the
//! wrong length. `marshal.dupCString` truncates for that reason, and every
//! function that takes or returns text says so in its own doc comment.
//!
//! **Not here yet.** The tree-update, optional and property-value groups are still
//! being written, and this file grows as they land. A namespace root that listed a
//! module that does not exist would compile against nothing.

const std = @import("std");

/// The opaque handle types the header forward-declares. One declaration each, and
/// this is where a new one goes.
pub const handles = @import("handles.zig");

/// The allocator, the per-thread error slot, and the seventeen `*_free` functions.
pub const allocation = @import("allocation.zig");

/// Every conversion between the port's types and the header's `extern` forms.
pub const marshal = @import("marshal.zig");

/// The node accessors, and the property accessors that hang off them.
pub const node = @import("node.zig");

/// The affine transform, rect, point, vec2 and size surface.
pub const geometry = @import("geometry.zig");

/// The tree metadata and its release.
pub const tree_info = @import("tree_info.zig");

/// The action request, the custom actions, and the platform callback surface.
pub const action_request = @import("action_request.zig");

/// The platform entry points and the ten per-platform releases.
pub const platform = @import("platform.zig");

test "every module in this namespace is reachable and analysed" {
    // A `pub const` nothing references is a re-export the compiler may skip, so a
    // green run would report zero tests and prove nothing about the exports
    // underneath it. That has already happened twice in this package, once for
    // the schema layer and once for the consumer layer.
    std.testing.refAllDecls(handles);
    std.testing.refAllDecls(allocation);
    std.testing.refAllDecls(marshal);
    std.testing.refAllDecls(node);
    std.testing.refAllDecls(geometry);
    std.testing.refAllDecls(tree_info);
    std.testing.refAllDecls(action_request);
    std.testing.refAllDecls(platform);
}