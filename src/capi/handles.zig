//! The opaque handle types the C ABI names but never defines.
//!
//! **What this file is.** Every `accesskit_*` handle in `include/zaccesskit.h` is
//! a forward declaration: the header says the type exists and never says what it
//! contains, so a C consumer can pass the pointer around and cannot read through
//! it. In Zig the equivalent is `opaque {}`, and this file is where all eleven of
//! them live.
//!
//! **Why it is a leaf.** These types are referenced by the module that creates the
//! handle, by the module that releases it, and by the root that gathers the whole
//! ABI. Declaring one in a domain module and re-exporting it upward means the root
//! and that domain module both import each other, which is a cycle. **A file with
//! no imports cannot be part of one**, so this file has none — not `std`, not
//! `schema`, not `consumer`. If you find yourself wanting to add an import here,
//! the handle belongs somewhere else.
//!
//! **One declaration per handle.** Every module in `src/capi/` imports its handles
//! from here. **A second declaration of any of these is a compile error at the union
//! gate and a duplicate-symbol error at the link**, so if you need one that is not
//! here, add it here and say so in your report.
//!
//! **On the guarded ones.** The header declares six of these behind a platform
//! guard: `accesskit_android_adapter`, `accesskit_ios_adapter`,
//! `accesskit_ios_queued_events`, `accesskit_macos_adapter`,
//! `accesskit_macos_queued_events`, `accesskit_unix_adapter` and
//! `accesskit_windows_adapter`. The guard is on the *functions* that use them, not
//! on the ability to name them, so declaring all eleven unconditionally is correct
//! and a platform build simply never exports the functions that take the handles it
//! does not support.

// --- the handles every platform shares -------------------------------------

/// One node. The header's `accesskit_node`, at line 984.
///
/// Created by `accesskit_node_new` and released by `accesskit_node_free`. Every
/// other `accesskit_node_*` function takes this pointer and neither reads nor
/// writes through it from Zig's side: the pointer **is** a `*schema.Node`, and the
/// conversions live in the module that casts.
pub const accesskit_node = opaque {};

/// The metadata describing one tree: its root node and its toolkit strings.
///
/// Created by `accesskit_tree_info_free`'s counterpart and released by
/// `accesskit_tree_info_free`. Its two strings are borrowed from the update that
/// carried them, so releasing the struct does not release them.
pub const accesskit_tree_info = opaque {};

/// One update to a tree: a set of nodes, an optional tree info, and a focus.
///
/// Released by `accesskit_tree_update_free`. Its node list is borrowed from the
/// caller, so the same rule holds.
pub const accesskit_tree_update = opaque {};

/// One custom action, with its identifier and its description.
///
/// Released by `accesskit_custom_action_free`, and a list of them by
/// `accesskit_custom_actions_free`. The description is owned by this handle; the
/// identifier is not.
pub const accesskit_custom_action = opaque {};

// --- the per-platform handles -----------------------------------------------
// The header names these and says they have no C layout. They are collected here
// rather than beside their exports so that one file owns the whole set, and so
// that a platform module does not have to declare the type its own functions take.

/// The Android adapter. Declared by the header behind `__ANDROID__`, line 883.
pub const accesskit_android_adapter = opaque {};

/// The Linux and BSD adapter. Behind the Linux/BSD family guard, line 1012.
pub const accesskit_unix_adapter = opaque {};

/// The Windows adapter. Behind `_WIN32`, line 1020.
pub const accesskit_windows_adapter = opaque {};

/// The macOS adapter. Behind `ACCESSKIT_MACOS`, line 955.
pub const accesskit_macos_adapter = opaque {};

/// The macOS queued-events handle. Behind `ACCESSKIT_MACOS`, line 963.
pub const accesskit_macos_queued_events = opaque {};

/// The iOS adapter. Behind the iOS, tvOS, visionOS and watchOS family guard,
/// line 928.
pub const accesskit_ios_adapter = opaque {};

/// The iOS queued-events handle. Behind the same family guard, line 937.
pub const accesskit_ios_queued_events = opaque {};

comptime {
    // The header declares eleven handles. If a twelfth appears and is not added
    // here, every module that needs it will declare its own, and the duplicate
    // will surface as a link error on somebody else's machine. The count is the
    // cheap alarm.
    const declared = [_]type{
        accesskit_node,
        accesskit_tree_info,
        accesskit_tree_update,
        accesskit_custom_action,
        accesskit_android_adapter,
        accesskit_unix_adapter,
        accesskit_windows_adapter,
        accesskit_macos_adapter,
        accesskit_macos_queued_events,
        accesskit_ios_adapter,
        accesskit_ios_queued_events,
    };
    if (declared.len != 11) @compileError("the header declares eleven handles");
    // Every handle must stay opaque: a handle with a known layout is a handle a
    // C consumer can read through, which is exactly what the header forbids by
    // declaring nothing about it. That is enforced by the declarations above
    // being `opaque {}` and not by a size check — `@sizeOf` on an `opaque`
    // type is itself a compile error, so a check written that way can only ever
    // fail the build rather than catch a regression.
}