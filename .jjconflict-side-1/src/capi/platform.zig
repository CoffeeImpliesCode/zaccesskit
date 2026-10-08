//! The platform half of the C ABI: the 58 declarations `include/zaccesskit.h`
//! puts behind its five preprocessor guards, and nothing else.
//!
//! **What this file is.** `docs/40-capi-build-map.md` section 2 splits the 498
//! header declarations into 440 portable ones and 58 platform ones. The 440
//! belong to `src/capi/root.zig` and the schema and consumer layers they read.
//! The 58 belong here, because they are the whole of the answer to "how does a
//! platform link in": a constructor, a release, an activation handoff, and a
//! handful of calls that take a platform object address.
//!
//! **Upstream range.** `AccessKit/accesskit-c` at
//! `8b6ed37c20ed4c59390e253407983333053662ba`, `src/lib.rs:2539-3148`: the five
//! `platform_android`, `platform_ios`, `platform_macos`, `platform_unix` and
//! `platform_windows` cfg blocks, which hold 13, 13, 16, 6 and 10 functions
//! respectively. `docs/11-accesskit-c-abi.md` section 2.13 gives each upstream
//! line and `ExportRecord.upstream_line` below carries it.
//!
//! **What a platform adapter must do at startup.** It must call its platform's
//! `accesskit_<platform>_adapter_new` exactly once, passing the handlers the
//! header lists for that platform, and it must keep every handler pointer and
//! every userdata pointer valid until it calls the matching
//! `accesskit_<platform>_adapter_free`, because that pair is the whole of how a
//! platform registers itself with this library and unregisters again.
//!
//! **The guard is the contract.** A declaration behind `_WIN32` must not appear
//! in a Linux shared library, and a portable one must appear on every target.
//! Nothing on this host can see a Windows symbol in a Linux build, so the split
//! is pinned two ways. `Guard.declaresOn` is a pure function of a `Platform`,
//! which is an operating-system tag paired with a C ABI, and is therefore
//! testable for `x86_64-linux` *and* for an Android target from any host; and
//! every `@export` below sits inside a `comptime` branch that is dead when its
//! guard does not apply, so a symbol no target claims is never emitted. What
//! that dead branch does **not** do is remove the Zig declaration, which is why
//! `@hasDecl` answers "does this module declare it" for all 58 rows on every
//! target, and why the test that reads it says so rather than tying it to the
//! guard.
//! `docs/40-capi-build-map.md` section 1.1 measured the consequence: a Linux
//! build exports 446 of the 498, and the 6 this file contributes to that number
//! are the six `accesskit_unix_*` declarations.
//!
//! **Why the guard takes two fields and not one.** The header keeps
//! `__ANDROID__` and `__linux__` apart, and Zig cannot: `std/Target.zig:762`
//! puts `android` and `androideabi` in `std.Target.Abi`, so an Android target is
//! `.linux` with the `.android` C ABI. A predicate reading only the OS tag
//! therefore has no answer for Android at all, and the two available were to
//! fold Android into the unix guard or to read `builtin.abi` inside the
//! predicate. Folding puts the 13 `accesskit_android_*` symbols in a Linux
//! shared library whose header does not declare them; reading `builtin.abi`
//! inside makes the Android answer the one question no other host can test. So
//! the ABI is a parameter beside the tag.
//! `docs/17-rust-dependency-surface.md:369` records the predicate upstream
//! writes for its Android adapter, `cfg(target_os = "android")`, which is not
//! `cfg(target_os = "linux")` — the same separation, in the vocabulary each
//! language has for it.
//!
//! **The bound every loop here walks.** Three, and each is derived here.
//! `export_records.len` is 58, and every loop over the declarations is an
//! `inline for` or a `for` over it; 58 is 13 Android plus 13 Apple-mobile plus
//! 16 macOS plus 6 unix plus 10 Windows, counted from
//! `docs/40-capi-build-map.md` section 2 and cross-checked against
//! `docs/11-accesskit-c-abi.md` section 2.13, which counts the same 58 at the
//! pinned revision. `all_guards.len` is 5, which is the number of `#if` blocks
//! the platform region of the header carries. `sample_targets.len` is 15,
//! derived in that constant's own doc comment. Nothing else in the file loops.
//!
//! **Where the bodies go.** Each export owns its C symbol, convention and guard.
//! It clears the shared error slot and forwards to the owning adapter, which
//! preserves typed failures without treating ordinary absence as allocation
//! failure. Windows construction selects real native authority and transfers
//! its owned I/O runtime to the adapter's final weak-control release.
//!
//! **The header lines below are the current ones.** `docs/40-capi-build-map.md`
//! section 2 records the line of each declaration in
//! `include/zaccesskit.h` as it stood when that document was written; the
//! header has since grown by 9 lines above line 5700, so every `header_line`
//! here is 9 higher than the table's `hdr` column. The upstream lines are
//! unaffected.

const std = @import("std");
const builtin = @import("builtin");

const boundary = @import("boundary.zig");
const allocation = @import("allocation.zig");

/// The Android adapter, which is the adapter behind the `accesskit_unix_*`
/// family. `docs/40-capi-build-map.md` section 2.13.4 names `src/adapters/unix`
/// as its Zig target and `docs/30-port-design.md` section 3.3 names `atspi`,
/// `windows`, `macos`, `ios` and `android` as the five adapter directories;
/// this module takes the second name, which is the directory, and the first
/// name, which is the family, and they name the same adapter.
const atspi = @import("../adapters/atspi/root.zig");
const windows = @import("../adapters/windows/root.zig");
const macos = @import("../adapters/macos/root.zig");
const ios = @import("../adapters/ios/root.zig");
const android = @import("../adapters/android/root.zig");

/// The shared boundary types live in `src/capi/boundary.zig`, which imports
/// nothing but `schema`. They are re-exported here so every existing reference
/// in this file and in its tests keeps working, and every adapter imports the
/// leaf directly.
///
/// **Why the split.** This file imports all five adapters, because it owns the 58
/// declarations the header puts behind its platform guards. An adapter needs the
/// four callback types to *hold* a handler it was given, so it would have to
/// import this file back — and the two would import each other. A file that
/// imports nothing but `schema` cannot be part of that cycle.
pub const CRect = boundary.CRect;
pub const CTreeUpdate = boundary.CTreeUpdate;
pub const CActionRequest = boundary.CActionRequest;

/// `accesskit_tree_update_factory`, `include/zaccesskit.h:1707`, upstream
/// `src/lib.rs:1698`.
///
/// Builds one whole tree update and transfers it to the library, which releases
/// it after delivery. It runs on a thread of the library's own, so it assumes
/// nothing about the thread that installed it. **A `null` return is a contract
/// violation and terminates the process.**
pub const TreeUpdateFactory = boundary.TreeUpdateFactory;

/// `accesskit_activation_handler_callback`, `include/zaccesskit.h:1720`,
/// upstream `src/lib.rs:1711`.
///
/// Textually identical to `TreeUpdateFactory` and the header keeps both names
/// because upstream does. The difference is the contract and it is the one an
/// adapter gets wrong: **a `null` return here is an ordinary answer meaning "no
/// tree", not a failure**, and the library keeps nothing.
pub const ActivationHandler = boundary.ActivationHandler;

/// `accesskit_action_handler_callback`, `include/zaccesskit.h:1737`, upstream
/// `src/lib.rs:1728`.
///
/// The request arrives by transfer: **the callback owns it and releases it with
/// `accesskit_action_request_free` before returning, on every path out.** For a
/// `value` payload that release also frees the string inside it.
pub const ActionHandler = boundary.ActionHandler;

/// `accesskit_deactivation_handler_callback`, `include/zaccesskit.h:1748`,
/// upstream `src/lib.rs:1739`.
///
/// Runs on the same thread as the activation handler for the same adapter, and
/// `userdata` reaches it unchanged.
pub const DeactivationHandler = boundary.DeactivationHandler;

/// `HWND`, from `<windows.h>`, which the header includes under `_WIN32`. Spelled
/// as an opaque pointer because `windows.h` is not available on this target and
/// the header's contract is the pointer, not the struct.
pub const Hwnd = boundary.Hwnd;

/// `WPARAM`, the unsigned pointer-sized message field of a Win32 message.
pub const WParam = boundary.WParam;

/// `LPARAM`, the signed pointer-sized message field of a Win32 message.
pub const LParam = boundary.LParam;

/// `accesskit_opt_lresult`, at `include/zaccesskit.h:1573`, the one struct this
/// boundary declares that exists only under `_WIN32`.
///
/// `docs/40-capi-build-map.md` section 3.2 measured it: 16 bytes at alignment 8
/// with `value` at offset 8. `has_value` false means this adapter does not own
/// the window and the window procedure returns `false` from `DefWindowProc`;
/// `value` is then a zero the port writes so a reader who ignores the flag
/// reads a defined zero rather than uninitialised storage.
pub const COptLResult = boundary.COptLResult;

comptime {
    std.debug.assert(@sizeOf(COptLResult) == 16);
    std.debug.assert(@alignOf(COptLResult) == 8);
    std.debug.assert(@offsetOf(COptLResult, "value") == 8);
    std.debug.assert(@sizeOf(CRect) == 32);
    std.debug.assert(@alignOf(CRect) == 8);
}

/// `JNIEnv *`, from `<jni.h>`, which the header includes under `__ANDROID__`.
/// Declared once, by the adapter that owns the JNI boundary; see the note there
/// for why it is `?*anyopaque` and not the `?*const anyopaque` `jni.h` implies.
pub const JniEnv = android.JniEnv;

/// `jobject`, a local reference to a Java object.
pub const JObject = ?*anyopaque;

/// `jint`, the 32-bit signed integer of the JNI.
pub const JInt = c_int;

/// `jfloat`, the 32-bit IEEE float of the JNI.
pub const JFloat = f32;

/// The two facts about a build target that the header's preprocessor guards
/// read.
///
/// One field decides four of the five guards and cannot decide the fifth. The
/// header gates the thirteen `accesskit_android_*` declarations on
/// `__ANDROID__` and the six `accesskit_unix_*` on `__linux__`, and Zig carries
/// no `.android` in `std.Target.Os.Tag`: `std/Target.zig:762` holds `android`
/// and `androideabi` in `std.Target.Abi`, so an Android target is `.linux` with
/// the `.android` C ABI. **Both fields are therefore load-bearing**, and it is
/// the pair that keeps the android and unix guards disjoint rather than
/// overlapping on every Linux build.
pub const Platform = struct {
    /// The operating-system tag, exactly as `builtin.os.tag` reports it.
    os_tag: std.Target.Os.Tag,
    /// The C ABI, exactly as `builtin.abi` reports it. `.android` and
    /// `.androideabi` are the two that mean "this is Android", and
    /// `std.Target.Abi.isAndroid` is the one predicate that says so for both.
    abi: std.Target.Abi,

    /// The platform with OS tag `os_tag` and the `.none` C ABI.
    ///
    /// `.none` is the ABI every Apple target and every BSD but the ARM ones
    /// carries — `std.Target.Abi.default` answers `.none` for all of them — and
    /// only the android and unix guards read the ABI at all, so neither of them
    /// can be changed by this constructor. It exists so a census row can name
    /// the one fact it is about.
    pub fn abiNone(os_tag: std.Target.Os.Tag) Platform {
        return .{ .os_tag = os_tag, .abi = .none };
    }
};

/// The target being compiled for, in the two fields the guards read.
///
/// Every guard below asks about this rather than reading `builtin` inside the
/// predicate, so there is one place that reads the build target and every
/// predicate stays pure. A test can then ask about a target that is not this
/// one, which is the whole reason the guards are functions and not `if` chains.
pub const this_platform: Platform = .{
    .os_tag = builtin.os.tag,
    .abi = builtin.abi,
};

/// A Linux build target: `.linux` with a C ABI that is not Android's. Glibc and
/// musl both answer this way, and both are claimed by the unix guard.
pub const linux_target: Platform = .{ .os_tag = .linux, .abi = .gnu };

/// An Android build target: `.linux` with the `.android` C ABI. The header
/// gates its thirteen declarations on `__ANDROID__` and Zig spells Android
/// this way, which is the disagreement `Platform` exists to resolve.
pub const android_target: Platform = .{ .os_tag = .linux, .abi = .android };

/// A Windows build target: `.windows` with the `.gnu` C ABI, which is what
/// `std.Target.Abi.default` answers for Windows.
pub const windows_target: Platform = .{ .os_tag = .windows, .abi = .gnu };

/// Every target the census in the tests below walks, each with the C ABI that
/// target really has. The bound on every loop over this domain is its length,
/// 15: six rows the unix guard claims, four Apple-mobile rows, one macOS row,
/// one Windows row and one wasi row that no guard claims — 6 + 4 + 1 + 1 + 1 is
/// 13, and the two Android rows are the other two.
///
/// **The four `.linux` rows are the point of the list.** Glibc Linux, musl
/// Linux, Android and 32-bit ARM Android are all `.linux` to Zig and are told
/// apart only by their C ABI. It is that ABI which keeps the Android pair out
/// of the unix guard's count, so it is here that folding Android into that
/// guard would change the census.
pub const sample_targets = [_]Platform{
    .{ .os_tag = .linux, .abi = .gnu },
    .{ .os_tag = .linux, .abi = .musl },
    .{ .os_tag = .linux, .abi = .android },
    .{ .os_tag = .linux, .abi = .androideabi },
    .{ .os_tag = .dragonfly, .abi = .none },
    .{ .os_tag = .freebsd, .abi = .none },
    .{ .os_tag = .netbsd, .abi = .none },
    .{ .os_tag = .openbsd, .abi = .none },
    .{ .os_tag = .macos, .abi = .none },
    .{ .os_tag = .ios, .abi = .none },
    .{ .os_tag = .tvos, .abi = .none },
    .{ .os_tag = .visionos, .abi = .none },
    .{ .os_tag = .watchos, .abi = .none },
    .{ .os_tag = .windows, .abi = .gnu },
    .{ .os_tag = .wasi, .abi = .musl },
};

/// The preprocessor guard a declaration sits behind in
/// `include/zaccesskit.h`, and the question "does `platform` see it?".
///
/// The five members are the five guards the header uses. There is no portable
/// member, because nothing behind a guard is portable: this file holds no
/// portable declaration, and a portable one in `src/capi/root.zig` is what
/// makes the 440.
pub const Guard = enum {
    /// `__linux__`, `__DragonFly__`, `__FreeBSD__`, `__NetBSD__` or
    /// `__OpenBSD__`. Six functions. **Not Android**, and the exclusion is on
    /// the ABI rather than on the OS tag, which is what `Platform`'s doc
    /// comment is about.
    unix,
    /// `ACCESSKIT_MACOS`. Sixteen functions.
    macos,
    /// `ACCESSKIT_IOS`, `ACCESSKIT_TVOS`, `ACCESSKIT_VISIONOS` or
    /// `ACCESSKIT_WATCHOS`. Thirteen functions.
    apple_mobile,
    /// `__ANDROID__`. Thirteen functions.
    android,
    /// `_WIN32`. Ten functions.
    windows,

    /// Whether a declaration behind this guard is declared on `platform`.
    ///
    /// It is a pure function of the two fields of `Platform` and reads nothing
    /// else, so the Linux answer and the Android answer are both testable from
    /// a macOS or Windows host — which is the only way to pin a split that
    /// cannot be observed at run time. `.android` and `.androideabi` are the
    /// two ABIs that mean Android, so both answer true for `.android` and both
    /// make `.unix` answer false, and that is the disjointness the header's two
    /// `#if` blocks and upstream's two `cfg` blocks have between them.
    pub fn declaresOn(self: Guard, platform: Platform) bool {
        return switch (self) {
            .unix => switch (platform.os_tag) {
                .linux, .dragonfly, .freebsd, .netbsd, .openbsd => !platform.abi.isAndroid(),
                else => false,
            },
            .macos => platform.os_tag == .macos,
            .apple_mobile => switch (platform.os_tag) {
                .ios, .tvos, .visionos, .watchos => true,
                else => false,
            },
            .android => platform.os_tag == .linux and platform.abi.isAndroid(),
            .windows => platform.os_tag == .windows,
        };
    }
};

/// The five guards in header order: the `#if` blocks at
/// `include/zaccesskit.h:5709`, `:5883`, `:6046`, `:6256` and `:6333`.
///
/// The bound on every loop over this domain is its length, 5, which is the
/// count of `#if` blocks the platform region of the header carries. A sixth
/// member added to `Guard` without a row here is what the test "the five
/// guards" reports.
pub const all_guards = [_]Guard{ .unix, .macos, .apple_mobile, .android, .windows };

/// One declaration this module owns: the C symbol, the line it sits on in
/// `include/zaccesskit.h`, the line it sits on in upstream `src/lib.rs`, and
/// the guard it is behind.
pub const ExportRecord = struct {
    /// The C symbol, which is also the Zig `export fn` name.
    symbol: []const u8,
    /// The line of the function name in `include/zaccesskit.h`, measured on
    /// 2026-10-05 against the header as it stands.
    header_line: u16,
    /// The line of the function name in `accesskit-c/src/lib.rs` at
    /// `8b6ed37c20ed4c59390e253407983333053662ba`, from
    /// `docs/11-accesskit-c-abi.md` section 2.13.
    upstream_line: u16,
    /// The guard the declaration is behind.
    guard: Guard,
};

/// Every declaration this module owns, in header order: Android, the
/// Apple-mobile family, macOS, the Linux and BSD family, then Windows.
///
/// The bound on every loop over this domain is its length, 58, derived in this
/// module's doc comment. A row here with no `export fn` behind it, or an
/// `export fn` with no row, is a defect a test in this file reports.
pub const export_records = [_]ExportRecord{
    // --- Android, 13, guard `__ANDROID__` at include/zaccesskit.h:5701 ------
    .{
        .symbol = "accesskit_android_platform_action_from_java",
        .header_line = 5711,
        .upstream_line = 2539,
        .guard = .android,
    },
    .{
        .symbol = "accesskit_android_platform_action_free",
        .header_line = 5720,
        .upstream_line = 2544,
        .guard = .android,
    },
    .{
        .symbol = "accesskit_android_queued_events_raise",
        .header_line = 5732,
        .upstream_line = 2552,
        .guard = .android,
    },
    .{
        .symbol = "accesskit_android_adapter_new",
        .header_line = 5744,
        .upstream_line = 2557,
        .guard = .android,
    },
    .{
        .symbol = "accesskit_android_adapter_free",
        .header_line = 5753,
        .upstream_line = 2561,
        .guard = .android,
    },
    .{
        .symbol = "accesskit_android_adapter_update_if_active",
        .header_line = 5765,
        .upstream_line = 2570,
        .guard = .android,
    },
    .{
        .symbol = "accesskit_android_adapter_create_accessibility_node_info",
        .header_line = 5778,
        .upstream_line = 2577,
        .guard = .android,
    },
    .{
        .symbol = "accesskit_android_adapter_find_focus",
        .header_line = 5794,
        .upstream_line = 2585,
        .guard = .android,
    },
    .{
        .symbol = "accesskit_android_adapter_perform_action",
        .header_line = 5811,
        .upstream_line = 2598,
        .guard = .android,
    },
    .{
        .symbol = "accesskit_android_adapter_on_hover_event",
        .header_line = 5826,
        .upstream_line = 2611,
        .guard = .android,
    },
    .{
        .symbol = "accesskit_android_injecting_adapter_new",
        .header_line = 5843,
        .upstream_line = 2619,
        .guard = .android,
    },
    .{
        .symbol = "accesskit_android_injecting_adapter_free",
        .header_line = 5855,
        .upstream_line = 2628,
        .guard = .android,
    },
    .{
        .symbol = "accesskit_android_injecting_adapter_update_if_active",
        .header_line = 5868,
        .upstream_line = 2633,
        .guard = .android,
    },

    // --- Apple-mobile, 13, guard ACCESSKIT_IOS/TVOS/VISIONOS/WATCHOS at :5875 -
    .{
        .symbol = "accesskit_ios_queued_events_raise",
        .header_line = 5886,
        .upstream_line = 2644,
        .guard = .apple_mobile,
    },
    .{
        .symbol = "accesskit_ios_adapter_new",
        .header_line = 5897,
        .upstream_line = 2658,
        .guard = .apple_mobile,
    },
    .{
        .symbol = "accesskit_ios_adapter_free",
        .header_line = 5910,
        .upstream_line = 2669,
        .guard = .apple_mobile,
    },
    .{
        .symbol = "accesskit_ios_adapter_update_if_active",
        .header_line = 5922,
        .upstream_line = 2678,
        .guard = .apple_mobile,
    },
    .{
        .symbol = "accesskit_ios_adapter_view_did_appear",
        .header_line = 5934,
        .upstream_line = 2694,
        .guard = .apple_mobile,
    },
    .{
        .symbol = "accesskit_ios_adapter_is_accessibility_element",
        .header_line = 5940,
        .upstream_line = 2704,
        .guard = .apple_mobile,
    },
    .{
        .symbol = "accesskit_ios_adapter_accessibility_elements",
        .header_line = 5953,
        .upstream_line = 2715,
        .guard = .apple_mobile,
    },
    .{
        .symbol = "accesskit_ios_adapter_hit_test",
        .header_line = 5965,
        .upstream_line = 2726,
        .guard = .apple_mobile,
    },
    .{
        .symbol = "accesskit_ios_adapter_debug",
        .header_line = 5977,
        .upstream_line = 2735,
        .guard = .apple_mobile,
    },
    .{
        .symbol = "accesskit_ios_subclassing_adapter_new",
        .header_line = 5989,
        .upstream_line = 2747,
        .guard = .apple_mobile,
    },
    .{
        .symbol = "accesskit_ios_subclassing_adapter_for_window",
        .header_line = 6004,
        .upstream_line = 2771,
        .guard = .apple_mobile,
    },
    .{
        .symbol = "accesskit_ios_subclassing_adapter_free",
        .header_line = 6018,
        .upstream_line = 2782,
        .guard = .apple_mobile,
    },
    .{
        .symbol = "accesskit_ios_subclassing_adapter_update_if_active",
        .header_line = 6031,
        .upstream_line = 2793,
        .guard = .apple_mobile,
    },

    // --- macOS, 16, guard ACCESSKIT_MACOS at include/zaccesskit.h:6038 -------
    .{
        .symbol = "accesskit_macos_queued_events_raise",
        .header_line = 6048,
        .upstream_line = 2803,
        .guard = .macos,
    },
    .{
        .symbol = "accesskit_macos_adapter_new",
        .header_line = 6059,
        .upstream_line = 2813,
        .guard = .macos,
    },
    .{
        .symbol = "accesskit_macos_adapter_free",
        .header_line = 6068,
        .upstream_line = 2820,
        .guard = .macos,
    },
    .{
        .symbol = "accesskit_macos_adapter_update_if_active",
        .header_line = 6080,
        .upstream_line = 2828,
        .guard = .macos,
    },
    .{
        .symbol = "accesskit_macos_adapter_update_view_focus_state",
        .header_line = 6093,
        .upstream_line = 2842,
        .guard = .macos,
    },
    .{
        .symbol = "accesskit_macos_adapter_view_children",
        .header_line = 6107,
        .upstream_line = 2851,
        .guard = .macos,
    },
    .{
        .symbol = "accesskit_macos_adapter_focus",
        .header_line = 6121,
        .upstream_line = 2862,
        .guard = .macos,
    },
    .{
        .symbol = "accesskit_macos_adapter_hit_test",
        .header_line = 6135,
        .upstream_line = 2873,
        .guard = .macos,
    },
    .{
        .symbol = "accesskit_macos_adapter_debug",
        .header_line = 6149,
        .upstream_line = 2883,
        .guard = .macos,
    },
    .{
        .symbol = "accesskit_macos_subclassing_adapter_new",
        .header_line = 6160,
        .upstream_line = 2894,
        .guard = .macos,
    },
    .{
        .symbol = "accesskit_macos_subclassing_adapter_for_window",
        .header_line = 6174,
        .upstream_line = 2913,
        .guard = .macos,
    },
    .{
        .symbol = "accesskit_macos_subclassing_adapter_free",
        .header_line = 6186,
        .upstream_line = 2921,
        .guard = .macos,
    },
    .{
        .symbol = "accesskit_macos_subclassing_adapter_update_if_active",
        .header_line = 6199,
        .upstream_line = 2931,
        .guard = .macos,
    },
    .{
        .symbol = "accesskit_macos_subclassing_adapter_update_view_focus_state",
        .header_line = 6212,
        .upstream_line = 2945,
        .guard = .macos,
    },
    .{
        .symbol = "accesskit_macos_add_focus_forwarder_to_window_class",
        .header_line = 6228,
        .upstream_line = 2966,
        .guard = .macos,
    },
    .{
        .symbol = "accesskit_macos_add_focus_forwarder_to_window_class_with_length",
        .header_line = 6242,
        .upstream_line = 2988,
        .guard = .macos,
    },

    // --- Linux and BSD, 6, guard __linux__/DragonFly/FreeBSD/NetBSD/OpenBSD at
    //     include/zaccesskit.h:6248. These six are what a Linux build exports
    //     from this file.
    .{
        .symbol = "accesskit_unix_adapter_new",
        .header_line = 6260,
        .upstream_line = 2997,
        .guard = .unix,
    },
    .{
        .symbol = "accesskit_unix_adapter_free",
        .header_line = 6273,
        .upstream_line = 3008,
        .guard = .unix,
    },
    .{
        .symbol = "accesskit_unix_adapter_set_root_window_bounds",
        .header_line = 6282,
        .upstream_line = 3022,
        .guard = .unix,
    },
    .{
        .symbol = "accesskit_unix_adapter_update_if_active",
        .header_line = 6297,
        .upstream_line = 3029,
        .guard = .unix,
    },
    .{
        .symbol = "accesskit_unix_adapter_update_window_focus_state",
        .header_line = 6308,
        .upstream_line = 3040,
        .guard = .unix,
    },
    .{
        .symbol = "accesskit_unix_adapter_debug",
        .header_line = 6321,
        .upstream_line = 3049,
        .guard = .unix,
    },

    // --- Windows, 10, guard _WIN32 at include/zaccesskit.h:6325 --------------
    .{
        .symbol = "accesskit_windows_queued_events_raise",
        .header_line = 6335,
        .upstream_line = 3057,
        .guard = .windows,
    },
    .{
        .symbol = "accesskit_windows_adapter_new",
        .header_line = 6346,
        .upstream_line = 3062,
        .guard = .windows,
    },
    .{
        .symbol = "accesskit_windows_adapter_free",
        .header_line = 6356,
        .upstream_line = 3069,
        .guard = .windows,
    },
    .{
        .symbol = "accesskit_windows_adapter_update_if_active",
        .header_line = 6368,
        .upstream_line = 3078,
        .guard = .windows,
    },
    .{
        .symbol = "accesskit_windows_adapter_update_window_focus_state",
        .header_line = 6381,
        .upstream_line = 3092,
        .guard = .windows,
    },
    .{
        .symbol = "accesskit_windows_adapter_handle_wm_getobject",
        .header_line = 6396,
        .upstream_line = 3097,
        .guard = .windows,
    },
    .{
        .symbol = "accesskit_windows_adapter_debug",
        .header_line = 6412,
        .upstream_line = 3107,
        .guard = .windows,
    },
    .{
        .symbol = "accesskit_windows_subclassing_adapter_new",
        .header_line = 6424,
        .upstream_line = 3126,
        .guard = .windows,
    },
    .{
        .symbol = "accesskit_windows_subclassing_adapter_free",
        .header_line = 6436,
        .upstream_line = 3134,
        .guard = .windows,
    },
    .{
        .symbol = "accesskit_windows_subclassing_adapter_update_if_active",
        .header_line = 6449,
        .upstream_line = 3144,
        .guard = .windows,
    },
};

/// How many declarations this module owns: 58, derived in this module's doc
/// comment from the five guard counts.
pub const export_record_count: usize = export_records.len;

/// How many of this module's declarations `platform` exports.
///
/// The loop walks `export_records`, whose bound is 58, derived in this module's
/// doc comment.
pub fn declaredCount(platform: Platform) usize {
    // `std.Target.Os.Tag` has about sixty members, and this loop walks 58
    // records, so a `comptime` call — and `linux_declared_count` is one —
    // evaluates more than a thousand branches. The default quota is a thousand.
    @setEvalBranchQuota(20_000);
    var count: usize = 0;
    for (export_records) |record| {
        if (record.guard.declaresOn(platform)) count += 1;
    }
    return count;
}

/// How many of this module's declarations `platform` exports with `guard`.
pub fn declaredCountFor(platform: Platform, guard: Guard) usize {
    // The same reasoning as `declaredCount`: 58 records, each re-walking the
    // OS-tag switch inside `declaresOn`.
    @setEvalBranchQuota(20_000);
    var count: usize = 0;
    for (export_records) |record| {
        if (record.guard == guard and record.guard.declaresOn(platform)) count += 1;
    }
    return count;
}

/// Whether `platform` declares the export named `symbol`.
///
/// A `symbol` this module does not own answers `false`, so a caller can ask
/// about any C symbol without first checking membership.
pub fn declaresSymbol(platform: Platform, symbol: []const u8) bool {
    for (export_records) |record| {
        if (std.mem.eql(u8, record.symbol, symbol)) {
            return record.guard.declaresOn(platform);
        }
    }
    return false;
}

/// How many of this module's declarations a Linux build target exports: six,
/// the `accesskit_unix_*` family.
///
/// `docs/40-capi-build-map.md` section 1.1 measured the whole library at 446 on
/// this target, and this module is the 6 of it that are platform functions; the
/// other 440 are portable and belong to `src/capi/root.zig`.
pub const linux_declared_count: usize = declaredCount(linux_target);

comptime {
    // The 58 this module's doc comment derives. A row added to one guard
    // without adjusting this is a census that no longer matches the header.
    std.debug.assert(export_record_count == 58);
    std.debug.assert(declaredCountFor(linux_target, .unix) == 6);
    std.debug.assert(declaredCountFor(Platform.abiNone(.macos), .macos) == 16);
    std.debug.assert(declaredCountFor(Platform.abiNone(.ios), .apple_mobile) == 13);
    std.debug.assert(declaredCountFor(Platform.abiNone(.tvos), .apple_mobile) == 13);
    std.debug.assert(declaredCountFor(Platform.abiNone(.visionos), .apple_mobile) == 13);
    std.debug.assert(declaredCountFor(Platform.abiNone(.watchos), .apple_mobile) == 13);
    std.debug.assert(declaredCountFor(android_target, .android) == 13);
    std.debug.assert(declaredCountFor(windows_target, .windows) == 10);
    // A Linux target sees the six Unix declarations and no other, and no other
    // target's set overlaps it. The Android exclusion in the unix guard is on
    // the ABI, so glibc and musl Linux answer true and Android answers false,
    // and the two guards stay disjoint here as well as at compile time.
    std.debug.assert(linux_declared_count == 6);
    std.debug.assert(declaredCountFor(linux_target, .macos) == 0);
    std.debug.assert(declaredCountFor(linux_target, .apple_mobile) == 0);
    std.debug.assert(declaredCountFor(linux_target, .android) == 0);
    std.debug.assert(declaredCountFor(linux_target, .windows) == 0);
    std.debug.assert(declaredCount(android_target) == 13);
    std.debug.assert(declaredCount(windows_target) == 10);
    std.debug.assert(declaredCount(Platform.abiNone(.macos)) == 16);
}

// =============================================================================
// Android, 13 declarations, guard `__ANDROID__`.
// =============================================================================

/// Builds a platform action from the Java object an Android action
/// callback supplied.
//
// `accesskit_android_platform_action_from_java`,
// `include/zaccesskit.h:5711`, upstream `src/lib.rs:2539`.
//
// Returns `null` when the allocation failed. The caller owns a
// non-null result and releases it with
// `accesskit_android_platform_action_free`. The `arguments` object
// belongs to the Java call and is not retained.
fn accesskit_android_platform_action_from_java(
    env: JniEnv,
    action: JInt,
    arguments: JObject,
) callconv(.c) ?*android.AndroidPlatformAction {
    allocation.clearError();
    return android.androidPlatformActionFromJava(env, action, arguments);
}

// Releases a platform action and everything it owns, exactly once.
//
// `accesskit_android_platform_action_free`,
// `include/zaccesskit.h:5720`, upstream `src/lib.rs:2544`.
//
// The node the action names is not released. The header says passing
// `null` terminates the process, and upstream dereferences the pointer
// without a check, so this module forwards it unchanged rather than
// adding a guard upstream does not have.
fn accesskit_android_platform_action_free(
    platform_action: *android.AndroidPlatformAction,
) callconv(.c) void {
    allocation.clearError();
    android.androidPlatformActionFree(platform_action);
}

// Raises the queued events on the platform and releases the handle.
//
// `accesskit_android_queued_events_raise`,
// `include/zaccesskit.h:5732`, upstream `src/lib.rs:2552`.
//
// This call is the only way to release the handle. A second call on
// the same pointer is a use-after-free, and passing `null` terminates
// the process.
fn accesskit_android_queued_events_raise(
    events: *android.AndroidQueuedEvents,
    env: JniEnv,
    host: JObject,
) callconv(.c) void {
    allocation.clearError();
    android.androidQueuedEventsRaise(events, env, host);
}

// Returns an Android adapter, or `null` when the allocation failed.
//
// `accesskit_android_adapter_new`, `include/zaccesskit.h:5744`,
// upstream `src/lib.rs:2557`.
//
// This adapter takes no handler at construction: the activation and
// action handlers arrive on the calls that need them. The caller owns
// a non-null result and releases it with
// `accesskit_android_adapter_free`, and calls `accesskit_last_error`
// after a `null` return.
fn accesskit_android_adapter_new() callconv(.c) ?*android.AndroidAdapter {
    allocation.clearError();
    return android.androidAdapterNew();
}

// Releases the adapter and every tree it holds, exactly once.
//
// `accesskit_android_adapter_free`, `include/zaccesskit.h:5753`,
// upstream `src/lib.rs:2561`.
//
// A tree update already handed to the adapter was released by the
// library. Passing `null` terminates the process.
fn accesskit_android_adapter_free(
    adapter: *android.AndroidAdapter,
) callconv(.c) void {
    allocation.clearError();
    android.androidAdapterFree(adapter);
}

// Asks `update_factory` for a tree and hands it to the adapter.
//
// `accesskit_android_adapter_update_if_active`,
// `include/zaccesskit.h:5765`, upstream `src/lib.rs:2570`.
//
// Returns the events the answer produced, or `null` when the adapter
// is not active. The caller owns a non-null result and must pass it to
// `accesskit_android_queued_events_raise`, which also releases it.
fn accesskit_android_adapter_update_if_active(
    adapter: *android.AndroidAdapter,
    update_factory: TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) callconv(.c) ?*android.AndroidQueuedEvents {
    allocation.clearError();
    return android.androidAdapterUpdateIfActive(
        adapter,
        update_factory,
        update_factory_userdata,
    );
}

// Returns the `AccessibilityNodeInfo` for `virtual_view_id`, or `null`
// when there is no such node.
//
// `accesskit_android_adapter_create_accessibility_node_info`,
// `include/zaccesskit.h:5778`, upstream `src/lib.rs:2577`.
//
// Ownership of the JNI local reference does not transfer; it belongs to
// the call this was made from. `activation_handler` is supplied on
// this call and the library drops it when the call returns.
fn accesskit_android_adapter_create_accessibility_node_info(
    adapter: *android.AndroidAdapter,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    env: JniEnv,
    host: JObject,
    virtual_view_id: JInt,
) callconv(.c) JObject {
    allocation.clearError();
    return android.androidAdapterCreateAccessibilityNodeInfo(
        adapter,
        activation_handler,
        activation_handler_userdata,
        env,
        host,
        virtual_view_id,
    );
}

// Returns the `AccessibilityNodeInfo` the focus belongs to, or `null`
// when the tree has no focus.
//
// `accesskit_android_adapter_find_focus`,
// `include/zaccesskit.h:5794`, upstream `src/lib.rs:2585`.
//
// Ownership of the JNI local reference does not transfer. The
// activation handler is supplied on this call and dropped when it
// returns.
fn accesskit_android_adapter_find_focus(
    adapter: *android.AndroidAdapter,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    env: JniEnv,
    host: JObject,
    focus_type: JInt,
) callconv(.c) JObject {
    allocation.clearError();
    return android.androidAdapterFindFocus(
        adapter,
        activation_handler,
        activation_handler_userdata,
        env,
        host,
        focus_type,
    );
}

// Hands `action` to the application and returns the events the answer
// produced.
//
// `accesskit_android_adapter_perform_action`,
// `include/zaccesskit.h:5811`, upstream `src/lib.rs:2598`.
//
// Returns `null` when the adapter is not active. The caller owns a
// non-null result and must pass it to
// `accesskit_android_queued_events_raise`.
fn accesskit_android_adapter_perform_action(
    adapter: *android.AndroidAdapter,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
    virtual_view_id: JInt,
    action: *const android.AndroidPlatformAction,
) callconv(.c) ?*android.AndroidQueuedEvents {
    allocation.clearError();
    return android.androidAdapterPerformAction(
        adapter,
        action_handler,
        action_handler_userdata,
        virtual_view_id,
        action,
    );
}

// Delivers a hover at the logical pixel `(x, y)` to the application.
//
// `accesskit_android_adapter_on_hover_event`,
// `include/zaccesskit.h:5826`, upstream `src/lib.rs:2611`.
//
// Returns the events the answer produced, or `null` when the adapter
// is not active. The caller owns a non-null result.
fn accesskit_android_adapter_on_hover_event(
    adapter: *android.AndroidAdapter,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action: JInt,
    x: JFloat,
    y: JFloat,
) callconv(.c) ?*android.AndroidQueuedEvents {
    allocation.clearError();
    return android.androidAdapterOnHoverEvent(
        adapter,
        activation_handler,
        activation_handler_userdata,
        action,
        x,
        y,
    );
}

// Returns an injecting Android adapter bound to `host`, or `null` when
// the allocation failed.
//
// `accesskit_android_injecting_adapter_new`,
// `include/zaccesskit.h:5843`, upstream `src/lib.rs:2619`.
//
// `host` and both handler userdata pointers must stay valid until the
// adapter is released. The caller owns the adapter and releases it
// with `accesskit_android_injecting_adapter_free`.
fn accesskit_android_injecting_adapter_new(
    env: JniEnv,
    host: JObject,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
) callconv(.c) ?*android.AndroidInjectingAdapter {
    allocation.clearError();
    return android.androidInjectingAdapterNew(
        env,
        host,
        activation_handler,
        activation_handler_userdata,
        action_handler,
        action_handler_userdata,
    );
}

// Releases the adapter and every tree it holds, exactly once.
//
// `accesskit_android_injecting_adapter_free`,
// `include/zaccesskit.h:5855`, upstream `src/lib.rs:2628`.
//
// Passing `null` terminates the process.
fn accesskit_android_injecting_adapter_free(
    adapter: *android.AndroidInjectingAdapter,
) callconv(.c) void {
    allocation.clearError();
    android.androidInjectingAdapterFree(adapter);
}

// Asks `update_factory` for a tree and hands it to the adapter.
//
// `accesskit_android_injecting_adapter_update_if_active`,
// `include/zaccesskit.h:5868`, upstream `src/lib.rs:2633`.
//
// This adapter returns nothing, so there are no queued events to
// raise: the injecting adapter delivers the tree to its own host.
fn accesskit_android_injecting_adapter_update_if_active(
    adapter: *android.AndroidInjectingAdapter,
    update_factory: TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) callconv(.c) void {
    allocation.clearError();
    android.androidInjectingAdapterUpdateIfActive(
        adapter,
        update_factory,
        update_factory_userdata,
    );
}

// Tests emit Android wrappers to exercise the public C error boundary.
comptime {
    if (Guard.android.declaresOn(this_platform) or builtin.is_test) {
        @export(
            &accesskit_android_platform_action_from_java,
            .{ .name = "accesskit_android_platform_action_from_java", .linkage = .strong },
        );
        @export(
            &accesskit_android_platform_action_free,
            .{ .name = "accesskit_android_platform_action_free", .linkage = .strong },
        );
        @export(
            &accesskit_android_queued_events_raise,
            .{ .name = "accesskit_android_queued_events_raise", .linkage = .strong },
        );
        @export(
            &accesskit_android_adapter_new,
            .{ .name = "accesskit_android_adapter_new", .linkage = .strong },
        );
        @export(
            &accesskit_android_adapter_free,
            .{ .name = "accesskit_android_adapter_free", .linkage = .strong },
        );
        @export(
            &accesskit_android_adapter_update_if_active,
            .{ .name = "accesskit_android_adapter_update_if_active", .linkage = .strong },
        );
        @export(
            &accesskit_android_adapter_create_accessibility_node_info,
            .{
                .name = "accesskit_android_adapter_create_accessibility_node_info",
                .linkage = .strong,
            },
        );
        @export(
            &accesskit_android_adapter_find_focus,
            .{ .name = "accesskit_android_adapter_find_focus", .linkage = .strong },
        );
        @export(
            &accesskit_android_adapter_perform_action,
            .{ .name = "accesskit_android_adapter_perform_action", .linkage = .strong },
        );
        @export(
            &accesskit_android_adapter_on_hover_event,
            .{ .name = "accesskit_android_adapter_on_hover_event", .linkage = .strong },
        );
        @export(
            &accesskit_android_injecting_adapter_new,
            .{ .name = "accesskit_android_injecting_adapter_new", .linkage = .strong },
        );
        @export(
            &accesskit_android_injecting_adapter_free,
            .{ .name = "accesskit_android_injecting_adapter_free", .linkage = .strong },
        );
        @export(
            &accesskit_android_injecting_adapter_update_if_active,
            .{ .name = "accesskit_android_injecting_adapter_update_if_active", .linkage = .strong },
        );
    }
}

// =============================================================================
// The Apple-mobile family, 13 declarations, guard ACCESSKIT_IOS, ACCESSKIT_TVOS,
// ACCESSKIT_VISIONOS or ACCESSKIT_WATCHOS.
// =============================================================================

// Raises the queued events on the platform and releases the handle.
//
// `accesskit_ios_queued_events_raise`, `include/zaccesskit.h:5886`,
// upstream `src/lib.rs:2644`.
//
// This call is the only way to release the handle. A second call is a
// use-after-free, and passing `null` terminates the process.
fn accesskit_ios_queued_events_raise(
    events: *ios.IosQueuedEvents,
) callconv(.c) void {
    allocation.clearError();
    ios.iosQueuedEventsRaise(events);
}

// Returns an iOS-family adapter for `view`, or `null` when the
// allocation failed.
//
// `accesskit_ios_adapter_new`, `include/zaccesskit.h:5897`,
// upstream `src/lib.rs:2658`.
//
// `view` and every handler pointer must stay valid until the adapter
// is released. The library calls each handler on the main thread. The
// caller owns the adapter and releases it with
// `accesskit_ios_adapter_free`.
fn accesskit_ios_adapter_new(
    view: ?*anyopaque,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
    deactivation_handler: DeactivationHandler,
    deactivation_handler_userdata: ?*anyopaque,
) callconv(.c) ?*ios.IosAdapter {
    allocation.clearError();
    return ios.iosAdapterNew(
        view,
        activation_handler,
        activation_handler_userdata,
        action_handler,
        action_handler_userdata,
        deactivation_handler,
        deactivation_handler_userdata,
    );
}

// Releases the adapter and every tree it holds, exactly once.
//
// `accesskit_ios_adapter_free`, `include/zaccesskit.h:5910`,
// upstream `src/lib.rs:2669`.
//
// Passing `null` terminates the process.
fn accesskit_ios_adapter_free(adapter: *ios.IosAdapter) callconv(.c) void {
    allocation.clearError();
    ios.iosAdapterFree(adapter);
}

// Asks `update_factory` for a tree and hands it to the adapter.
//
// `accesskit_ios_adapter_update_if_active`,
// `include/zaccesskit.h:5922`, upstream `src/lib.rs:2678`.
//
// Returns the events the answer produced, or `null` when the adapter
// is not active. The caller owns a non-null result and must pass it to
// `accesskit_ios_queued_events_raise`, which also releases it.
fn accesskit_ios_adapter_update_if_active(
    adapter: *ios.IosAdapter,
    update_factory: TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) callconv(.c) ?*ios.IosQueuedEvents {
    allocation.clearError();
    return ios.iosAdapterUpdateIfActive(
        adapter,
        update_factory,
        update_factory_userdata,
    );
}

// Tells the adapter that `view` appeared and returns the events the
// answer produced.
//
// `accesskit_ios_adapter_view_did_appear`,
// `include/zaccesskit.h:5934`, upstream `src/lib.rs:2694`.
//
// Returns `null` when the adapter is not active. The caller owns a
// non-null result and must raise it.
fn accesskit_ios_adapter_view_did_appear(
    adapter: *ios.IosAdapter,
) callconv(.c) ?*ios.IosQueuedEvents {
    allocation.clearError();
    return ios.iosAdapterViewDidAppear(adapter);
}

// Reports whether the adapter's view is an accessibility element
// itself.
//
// `accesskit_ios_adapter_is_accessibility_element`,
// `include/zaccesskit.h:5940`, upstream `src/lib.rs:2704`.
fn accesskit_ios_adapter_is_accessibility_element(
    adapter: *ios.IosAdapter,
) callconv(.c) bool {
    allocation.clearError();
    return ios.iosAdapterIsAccessibilityElement(adapter);
}

// Returns the platform object that names the view's accessibility
// elements, or `null` when there is none.
//
// `accesskit_ios_adapter_accessibility_elements`,
// `include/zaccesskit.h:5953`, upstream `src/lib.rs:2715`.
//
// Ownership of the pointer does not transfer. The object belongs to
// the platform view and its lifetime is the platform's own.
fn accesskit_ios_adapter_accessibility_elements(
    adapter: *ios.IosAdapter,
) callconv(.c) ?*anyopaque {
    allocation.clearError();
    return ios.iosAdapterAccessibilityElements(adapter);
}

// Returns the platform object at the logical point `(x, y)`, or `null`
// when nothing is there.
//
// `accesskit_ios_adapter_hit_test`, `include/zaccesskit.h:5965`,
// upstream `src/lib.rs:2726`.
//
// Ownership of the pointer does not transfer.
fn accesskit_ios_adapter_hit_test(
    adapter: *ios.IosAdapter,
    x: f64,
    y: f64,
) callconv(.c) ?*anyopaque {
    allocation.clearError();
    return ios.iosAdapterHitTest(adapter, x, y);
}

// Returns a text rendering of the adapter, or `null` when the text
// could not be built.
//
// `accesskit_ios_adapter_debug`, `include/zaccesskit.h:5977`,
// upstream `src/lib.rs:2735`.
//
// Release the result with `accesskit_string_free`, once. The text
// borrows nothing from the adapter once the call returns, so the
// adapter may be released first.
fn accesskit_ios_adapter_debug(
    adapter: *const ios.IosAdapter,
) callconv(.c) ?[*:0]u8 {
    allocation.clearError();
    return ios.iosAdapterDebug(adapter);
}

// Returns an iOS-family subclassing adapter for `view`, or `null` when
// the allocation failed.
//
// `accesskit_ios_subclassing_adapter_new`,
// `include/zaccesskit.h:5989`, upstream `src/lib.rs:2747`.
//
// `view` and every handler pointer must stay valid until the adapter
// is released. The caller owns the adapter and releases it with
// `accesskit_ios_subclassing_adapter_free`.
fn accesskit_ios_subclassing_adapter_new(
    view: ?*anyopaque,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
    deactivation_handler: DeactivationHandler,
    deactivation_handler_userdata: ?*anyopaque,
) callconv(.c) ?*ios.IosSubclassingAdapter {
    allocation.clearError();
    return ios.iosSubclassingAdapterNew(
        view,
        activation_handler,
        activation_handler_userdata,
        action_handler,
        action_handler_userdata,
        deactivation_handler,
        deactivation_handler_userdata,
    );
}

// Returns a subclassing adapter for `window`, or `null` when the
// allocation failed.
//
// `accesskit_ios_subclassing_adapter_for_window`,
// `include/zaccesskit.h:6004`, upstream `src/lib.rs:2771`.
//
// The conditions are the ones
// `accesskit_ios_subclassing_adapter_new` states.
fn accesskit_ios_subclassing_adapter_for_window(
    window: ?*anyopaque,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
    deactivation_handler: DeactivationHandler,
    deactivation_handler_userdata: ?*anyopaque,
) callconv(.c) ?*ios.IosSubclassingAdapter {
    allocation.clearError();
    return ios.iosSubclassingAdapterForWindow(
        window,
        activation_handler,
        activation_handler_userdata,
        action_handler,
        action_handler_userdata,
        deactivation_handler,
        deactivation_handler_userdata,
    );
}

// Releases the adapter and every tree it holds, exactly once.
//
// `accesskit_ios_subclassing_adapter_free`,
// `include/zaccesskit.h:6018`, upstream `src/lib.rs:2782`.
//
// Passing `null` terminates the process.
fn accesskit_ios_subclassing_adapter_free(
    adapter: *ios.IosSubclassingAdapter,
) callconv(.c) void {
    allocation.clearError();
    ios.iosSubclassingAdapterFree(adapter);
}

// Asks `update_factory` for a tree and hands it to the adapter.
//
// `accesskit_ios_subclassing_adapter_update_if_active`,
// `include/zaccesskit.h:6031`, upstream `src/lib.rs:2793`.
//
// Returns the events the answer produced, or `null` when the adapter
// is not active. The caller owns a non-null result and must pass it to
// `accesskit_ios_queued_events_raise`.
fn accesskit_ios_subclassing_adapter_update_if_active(
    adapter: *ios.IosSubclassingAdapter,
    update_factory: TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) callconv(.c) ?*ios.IosQueuedEvents {
    allocation.clearError();
    return ios.iosSubclassingAdapterUpdateIfActive(
        adapter,
        update_factory,
        update_factory_userdata,
    );
}

// The apple_mobile exports. A declaration above is emitted as a symbol only
// where its guard is true; this block is the whole of that decision.
comptime {
    if (Guard.apple_mobile.declaresOn(this_platform)) {
        @export(
            &accesskit_ios_queued_events_raise,
            .{ .name = "accesskit_ios_queued_events_raise", .linkage = .strong },
        );
        @export(
            &accesskit_ios_adapter_new,
            .{ .name = "accesskit_ios_adapter_new", .linkage = .strong },
        );
        @export(
            &accesskit_ios_adapter_free,
            .{ .name = "accesskit_ios_adapter_free", .linkage = .strong },
        );
        @export(
            &accesskit_ios_adapter_update_if_active,
            .{ .name = "accesskit_ios_adapter_update_if_active", .linkage = .strong },
        );
        @export(
            &accesskit_ios_adapter_view_did_appear,
            .{ .name = "accesskit_ios_adapter_view_did_appear", .linkage = .strong },
        );
        @export(
            &accesskit_ios_adapter_is_accessibility_element,
            .{ .name = "accesskit_ios_adapter_is_accessibility_element", .linkage = .strong },
        );
        @export(
            &accesskit_ios_adapter_accessibility_elements,
            .{ .name = "accesskit_ios_adapter_accessibility_elements", .linkage = .strong },
        );
        @export(
            &accesskit_ios_adapter_hit_test,
            .{ .name = "accesskit_ios_adapter_hit_test", .linkage = .strong },
        );
        @export(
            &accesskit_ios_adapter_debug,
            .{ .name = "accesskit_ios_adapter_debug", .linkage = .strong },
        );
        @export(
            &accesskit_ios_subclassing_adapter_new,
            .{ .name = "accesskit_ios_subclassing_adapter_new", .linkage = .strong },
        );
        @export(
            &accesskit_ios_subclassing_adapter_for_window,
            .{ .name = "accesskit_ios_subclassing_adapter_for_window", .linkage = .strong },
        );
        @export(
            &accesskit_ios_subclassing_adapter_free,
            .{ .name = "accesskit_ios_subclassing_adapter_free", .linkage = .strong },
        );
        @export(
            &accesskit_ios_subclassing_adapter_update_if_active,
            .{ .name = "accesskit_ios_subclassing_adapter_update_if_active", .linkage = .strong },
        );
    }
}

// =============================================================================
// macOS, 16 declarations, guard ACCESSKIT_MACOS.
// =============================================================================

// Raises the queued events on the platform and releases the handle.
//
// `accesskit_macos_queued_events_raise`,
// `include/zaccesskit.h:6048`, upstream `src/lib.rs:2803`.
//
// This call is the only way to release the handle. A second call is a
// use-after-free, and passing `null` terminates the process.
fn accesskit_macos_queued_events_raise(
    events: *macos.MacosQueuedEvents,
) callconv(.c) void {
    allocation.clearError();
    macos.macosQueuedEventsRaise(events);
}

// Returns a macOS adapter for `view`, or `null` when the allocation
// failed.
//
// `accesskit_macos_adapter_new`, `include/zaccesskit.h:6059`,
// upstream `src/lib.rs:2813`.
//
// `view` and `action_handler_userdata` must stay valid until the
// adapter is released. This adapter takes no activation or
// deactivation handler: AppKit asks for the tree itself. The caller
// owns the adapter and releases it with
// `accesskit_macos_adapter_free`.
fn accesskit_macos_adapter_new(
    view: ?*anyopaque,
    is_view_focused: bool,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
) callconv(.c) ?*macos.MacosAdapter {
    allocation.clearError();
    return macos.macosAdapterNew(view, is_view_focused, action_handler, action_handler_userdata);
}

// Releases the adapter and every tree it holds, exactly once.
//
// `accesskit_macos_adapter_free`, `include/zaccesskit.h:6068`,
// upstream `src/lib.rs:2820`.
//
// Passing `null` terminates the process.
fn accesskit_macos_adapter_free(adapter: *macos.MacosAdapter) callconv(.c) void {
    allocation.clearError();
    macos.macosAdapterFree(adapter);
}

// Asks `update_factory` for a tree and hands it to the adapter.
//
// `accesskit_macos_adapter_update_if_active`,
// `include/zaccesskit.h:6080`, upstream `src/lib.rs:2828`.
//
// Returns the events the answer produced, or `null` when the adapter
// is not active. The caller owns a non-null result and must pass it to
// `accesskit_macos_queued_events_raise`.
fn accesskit_macos_adapter_update_if_active(
    adapter: *macos.MacosAdapter,
    update_factory: TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) callconv(.c) ?*macos.MacosQueuedEvents {
    allocation.clearError();
    return macos.macosAdapterUpdateIfActive(
        adapter,
        update_factory,
        update_factory_userdata,
    );
}

// Tells the adapter whether `view` holds focus, and returns the events
// the answer produced.
//
// `accesskit_macos_adapter_update_view_focus_state`,
// `include/zaccesskit.h:6093`, upstream `src/lib.rs:2842`.
//
// Returns `null` when the adapter is not active. The caller owns a
// non-null result and must raise it.
fn accesskit_macos_adapter_update_view_focus_state(
    adapter: *macos.MacosAdapter,
    is_focused: bool,
) callconv(.c) ?*macos.MacosQueuedEvents {
    allocation.clearError();
    return macos.macosAdapterUpdateViewFocusState(adapter, is_focused);
}

// Returns the platform object that names the view's children, or
// `null` when there is none.
//
// `accesskit_macos_adapter_view_children`,
// `include/zaccesskit.h:6107`, upstream `src/lib.rs:2851`.
//
// Ownership of the pointer does not transfer. The activation handler
// is supplied on this call and dropped when it returns.
fn accesskit_macos_adapter_view_children(
    adapter: *macos.MacosAdapter,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
) callconv(.c) ?*anyopaque {
    allocation.clearError();
    return macos.macosAdapterViewChildren(
        adapter,
        activation_handler,
        activation_handler_userdata,
    );
}

// Returns the platform object that holds focus, or `null` when
// nothing holds it.
//
// `accesskit_macos_adapter_focus`, `include/zaccesskit.h:6121`,
// upstream `src/lib.rs:2862`.
//
// Ownership of the pointer does not transfer. The activation handler
// is supplied on this call and dropped when it returns.
fn accesskit_macos_adapter_focus(
    adapter: *macos.MacosAdapter,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
) callconv(.c) ?*anyopaque {
    allocation.clearError();
    return macos.macosAdapterFocus(adapter, activation_handler, activation_handler_userdata);
}

// Returns the platform object at the logical point `(x, y)`, or `null`
// when nothing is there.
//
// `accesskit_macos_adapter_hit_test`, `include/zaccesskit.h:6135`,
// upstream `src/lib.rs:2873`.
//
// Ownership of the pointer does not transfer. The activation handler
// is supplied on this call and dropped when it returns.
fn accesskit_macos_adapter_hit_test(
    adapter: *macos.MacosAdapter,
    x: f64,
    y: f64,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
) callconv(.c) ?*anyopaque {
    allocation.clearError();
    return macos.macosAdapterHitTest(
        adapter,
        x,
        y,
        activation_handler,
        activation_handler_userdata,
    );
}

// Returns a text rendering of the adapter, or `null` when the text
// could not be built.
//
// `accesskit_macos_adapter_debug`, `include/zaccesskit.h:6149`,
// upstream `src/lib.rs:2883`.
//
// Release the result with `accesskit_string_free`, once. The text
// borrows nothing from the adapter once the call returns.
fn accesskit_macos_adapter_debug(
    adapter: *const macos.MacosAdapter,
) callconv(.c) ?[*:0]u8 {
    allocation.clearError();
    return macos.macosAdapterDebug(adapter);
}

// Returns a macOS subclassing adapter for `view`, or `null` when the
// allocation failed.
//
// `accesskit_macos_subclassing_adapter_new`,
// `include/zaccesskit.h:6160`, upstream `src/lib.rs:2894`.
//
// `view` and every handler pointer must stay valid until the adapter
// is released. The caller owns the adapter and releases it with
// `accesskit_macos_subclassing_adapter_free`.
fn accesskit_macos_subclassing_adapter_new(
    view: ?*anyopaque,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
) callconv(.c) ?*macos.MacosSubclassingAdapter {
    allocation.clearError();
    return macos.macosSubclassingAdapterNew(
        view,
        activation_handler,
        activation_handler_userdata,
        action_handler,
        action_handler_userdata,
    );
}

// Returns a subclassing adapter for `window`, or `null` when the
// allocation failed.
//
// `accesskit_macos_subclassing_adapter_for_window`,
// `include/zaccesskit.h:6174`, upstream `src/lib.rs:2913`.
//
// The conditions are the ones `accesskit_macos_subclassing_adapter_new`
// states.
fn accesskit_macos_subclassing_adapter_for_window(
    window: ?*anyopaque,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
) callconv(.c) ?*macos.MacosSubclassingAdapter {
    allocation.clearError();
    return macos.macosSubclassingAdapterForWindow(
        window,
        activation_handler,
        activation_handler_userdata,
        action_handler,
        action_handler_userdata,
    );
}

// Releases the adapter and every tree it holds, exactly once.
//
// `accesskit_macos_subclassing_adapter_free`,
// `include/zaccesskit.h:6186`, upstream `src/lib.rs:2921`.
//
// Passing `null` terminates the process.
fn accesskit_macos_subclassing_adapter_free(
    adapter: *macos.MacosSubclassingAdapter,
) callconv(.c) void {
    allocation.clearError();
    macos.macosSubclassingAdapterFree(adapter);
}

// Asks `update_factory` for a tree and hands it to the adapter.
//
// `accesskit_macos_subclassing_adapter_update_if_active`,
// `include/zaccesskit.h:6199`, upstream `src/lib.rs:2931`.
//
// Returns the events the answer produced, or `null` when the adapter
// is not active. The caller owns a non-null result.
fn accesskit_macos_subclassing_adapter_update_if_active(
    adapter: *macos.MacosSubclassingAdapter,
    update_factory: TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) callconv(.c) ?*macos.MacosQueuedEvents {
    allocation.clearError();
    return macos.macosSubclassingAdapterUpdateIfActive(
        adapter,
        update_factory,
        update_factory_userdata,
    );
}

// Tells the adapter whether `view` holds focus, and returns the events
// the answer produced.
//
// `accesskit_macos_subclassing_adapter_update_view_focus_state`,
// `include/zaccesskit.h:6212`, upstream `src/lib.rs:2945`.
//
// Returns `null` when the adapter is not active. The caller owns a
// non-null result and must raise it.
fn accesskit_macos_subclassing_adapter_update_view_focus_state(
    adapter: *macos.MacosSubclassingAdapter,
    is_focused: bool,
) callconv(.c) ?*macos.MacosQueuedEvents {
    allocation.clearError();
    return macos.macosSubclassingAdapterUpdateViewFocusState(adapter, is_focused);
}

// Adds a focus forwarder to the `NSWindow` subclass named by the
// NUL-terminated `class_name`.
//
// `accesskit_macos_add_focus_forwarder_to_window_class`,
// `include/zaccesskit.h:6228`, upstream `src/lib.rs:2966`.
//
// The function reads `class_name` and keeps its own copy, so the
// caller keeps ownership of the buffer and must not release it after
// this call. Calling this twice for one class name has no additional
// effect. The change cannot be undone, so the library must stay loaded
// for the life of the process: link it statically into the main
// executable.
fn accesskit_macos_add_focus_forwarder_to_window_class(
    class_name: [*:0]const u8,
) callconv(.c) void {
    allocation.clearError();
    macos.macosAddFocusForwarderToWindowClass(class_name);
}

// Adds a focus forwarder to the `NSWindow` subclass named by
// `class_name`, which is `length` bytes and is not NUL-terminated.
//
// `accesskit_macos_add_focus_forwarder_to_window_class_with_length`,
// `include/zaccesskit.h:6242`, upstream `src/lib.rs:2988`.
//
// The buffer need not be NUL-terminated, so the pointer carries no
// sentinel and the length is the only bound. The rest of the contract
// is the one
// `accesskit_macos_add_focus_forwarder_to_window_class` states.
fn accesskit_macos_add_focus_forwarder_to_window_class_with_length(
    class_name: [*]const u8,
    length: usize,
) callconv(.c) void {
    allocation.clearError();
    macos.macosAddFocusForwarderToWindowClassWithLength(class_name, length);
}

// The macos exports. A declaration above is emitted as a symbol only
// where its guard is true; this block is the whole of that decision.
comptime {
    if (Guard.macos.declaresOn(this_platform)) {
        @export(
            &accesskit_macos_queued_events_raise,
            .{ .name = "accesskit_macos_queued_events_raise", .linkage = .strong },
        );
        @export(
            &accesskit_macos_adapter_new,
            .{ .name = "accesskit_macos_adapter_new", .linkage = .strong },
        );
        @export(
            &accesskit_macos_adapter_free,
            .{ .name = "accesskit_macos_adapter_free", .linkage = .strong },
        );
        @export(
            &accesskit_macos_adapter_update_if_active,
            .{ .name = "accesskit_macos_adapter_update_if_active", .linkage = .strong },
        );
        @export(
            &accesskit_macos_adapter_update_view_focus_state,
            .{ .name = "accesskit_macos_adapter_update_view_focus_state", .linkage = .strong },
        );
        @export(
            &accesskit_macos_adapter_view_children,
            .{ .name = "accesskit_macos_adapter_view_children", .linkage = .strong },
        );
        @export(
            &accesskit_macos_adapter_focus,
            .{ .name = "accesskit_macos_adapter_focus", .linkage = .strong },
        );
        @export(
            &accesskit_macos_adapter_hit_test,
            .{ .name = "accesskit_macos_adapter_hit_test", .linkage = .strong },
        );
        @export(
            &accesskit_macos_adapter_debug,
            .{ .name = "accesskit_macos_adapter_debug", .linkage = .strong },
        );
        @export(
            &accesskit_macos_subclassing_adapter_new,
            .{ .name = "accesskit_macos_subclassing_adapter_new", .linkage = .strong },
        );
        @export(
            &accesskit_macos_subclassing_adapter_for_window,
            .{ .name = "accesskit_macos_subclassing_adapter_for_window", .linkage = .strong },
        );
        @export(
            &accesskit_macos_subclassing_adapter_free,
            .{ .name = "accesskit_macos_subclassing_adapter_free", .linkage = .strong },
        );
        @export(
            &accesskit_macos_subclassing_adapter_update_if_active,
            .{ .name = "accesskit_macos_subclassing_adapter_update_if_active", .linkage = .strong },
        );
        @export(
            &accesskit_macos_subclassing_adapter_update_view_focus_state,
            .{
                .name = "accesskit_macos_subclassing_adapter_update_view_focus_state",
                .linkage = .strong,
            },
        );
        @export(
            &accesskit_macos_add_focus_forwarder_to_window_class,
            .{ .name = "accesskit_macos_add_focus_forwarder_to_window_class", .linkage = .strong },
        );
        @export(
            &accesskit_macos_add_focus_forwarder_to_window_class_with_length,
            .{
                .name = "accesskit_macos_add_focus_forwarder_to_window_class_with_length",
                .linkage = .strong,
            },
        );
    }
}

// =============================================================================
// Linux and the BSD family, 6 declarations, guard `__linux__`, `__DragonFly__`,
// `__FreeBSD__`, `__NetBSD__` or `__OpenBSD__`. These are the six a Linux build
// exports from this file.
// =============================================================================

// Returns a Unix adapter, or `null` when the allocation failed.
//
// `accesskit_unix_adapter_new`, `include/zaccesskit.h:6260`,
// upstream `src/lib.rs:2997`.
//
// Every handler runs on a thread of the library's own, never on the
// thread that calls this, and every handler pointer must stay valid
// until the adapter is released. The caller owns the adapter and
// releases it with `accesskit_unix_adapter_free`.
fn accesskit_unix_adapter_new(
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
    deactivation_handler: DeactivationHandler,
    deactivation_handler_userdata: ?*anyopaque,
) callconv(.c) ?*atspi.UnixAdapter {
    allocation.clearError();
    return atspi.unixAdapterNewChecked(.{
        .activation_handler = activation_handler,
        .activation_handler_userdata = activation_handler_userdata,
        .action_handler = action_handler,
        .action_handler_userdata = action_handler_userdata,
        .deactivation_handler = deactivation_handler,
        .deactivation_handler_userdata = deactivation_handler_userdata,
    }) catch |err| {
        allocation.failWithError(err);
        return null;
    };
}

// Releases the adapter and every tree it holds, exactly once.
//
// `accesskit_unix_adapter_free`, `include/zaccesskit.h:6273`,
// upstream `src/lib.rs:3008`.
//
// Passing `null` terminates the process.
fn accesskit_unix_adapter_free(adapter: *atspi.UnixAdapter) callconv(.c) void {
    allocation.clearError();
    atspi.unixAdapterFree(adapter);
}

// Sets the outer bounds of the root window to `outer` and its inner
// bounds to `inner`, in logical pixels relative to the screen origin.
//
// `accesskit_unix_adapter_set_root_window_bounds`,
// `include/zaccesskit.h:6282`, upstream `src/lib.rs:3022`.
//
// Both boxes are `accesskit_rect` by value, and both are already the
// `extern struct` the header describes, so the conversion is the
// identity. Typed operational failures remain in the shared C error slot.
fn accesskit_unix_adapter_set_root_window_bounds(
    adapter: *atspi.UnixAdapter,
    outer: CRect,
    inner: CRect,
) callconv(.c) void {
    allocation.clearError();
    atspi.unixAdapterSetRootWindowBounds(adapter, outer, inner);
}

// Asks `update_factory` for a tree and hands it to the adapter.
//
// `accesskit_unix_adapter_update_if_active`,
// `include/zaccesskit.h:6297`, upstream `src/lib.rs:3029`.
//
// This family returns nothing and has no queued-events type: the Unix
// adapter raises what the answer produced on its own thread and the
// caller has no handle to raise. `docs/31-c-abi-design.md` section 3
// row 17 names four `*_queued_events` handles and none of them is
// this family's.
fn accesskit_unix_adapter_update_if_active(
    adapter: *atspi.UnixAdapter,
    update_factory: TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) callconv(.c) void {
    allocation.clearError();
    atspi.unixAdapterUpdateIfActive(adapter, update_factory, update_factory_userdata);
}

// Tells the adapter whether the window holds focus.
//
// `accesskit_unix_adapter_update_window_focus_state`,
// `include/zaccesskit.h:6308`, upstream `src/lib.rs:3040`.
//
// Typed operational failures remain in the shared C error slot.
fn accesskit_unix_adapter_update_window_focus_state(
    adapter: *atspi.UnixAdapter,
    is_focused: bool,
) callconv(.c) void {
    allocation.clearError();
    atspi.unixAdapterUpdateWindowFocusState(adapter, is_focused);
}

// Returns a text rendering of the adapter, or `null` when the text
// could not be built.
//
// `accesskit_unix_adapter_debug`, `include/zaccesskit.h:6321`,
// upstream `src/lib.rs:3049`.
//
// Release the result with `accesskit_string_free`, once. The text
// borrows nothing from the adapter once the call returns, so the
// adapter may be released first.
fn accesskit_unix_adapter_debug(
    adapter: *const atspi.UnixAdapter,
) callconv(.c) ?[*:0]u8 {
    allocation.clearError();
    return atspi.unixAdapterDebug(adapter);
}

// The unix exports. A declaration above is emitted as a symbol only
// where its guard is true; this block is the whole of that decision.
comptime {
    if (Guard.unix.declaresOn(this_platform)) {
        @export(
            &accesskit_unix_adapter_new,
            .{ .name = "accesskit_unix_adapter_new", .linkage = .strong },
        );
        @export(
            &accesskit_unix_adapter_free,
            .{ .name = "accesskit_unix_adapter_free", .linkage = .strong },
        );
        @export(
            &accesskit_unix_adapter_set_root_window_bounds,
            .{ .name = "accesskit_unix_adapter_set_root_window_bounds", .linkage = .strong },
        );
        @export(
            &accesskit_unix_adapter_update_if_active,
            .{ .name = "accesskit_unix_adapter_update_if_active", .linkage = .strong },
        );
        @export(
            &accesskit_unix_adapter_update_window_focus_state,
            .{ .name = "accesskit_unix_adapter_update_window_focus_state", .linkage = .strong },
        );
        @export(
            &accesskit_unix_adapter_debug,
            .{ .name = "accesskit_unix_adapter_debug", .linkage = .strong },
        );
    }
}

// =============================================================================
// Windows, 10 declarations, guard `_WIN32`.
// =============================================================================

const WindowsRuntime = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,

    fn release(userdata: ?*anyopaque) void {
        const self: *WindowsRuntime = @ptrCast(@alignCast(userdata.?));
        const gpa = self.gpa;
        self.threaded.deinit();
        gpa.destroy(self);
    }
};

/// The caller owns this authority until a constructor succeeds. Retained providers
/// and queued events then keep it alive through final weak-control release.
/// The configured allocator itself must outlive every retained COM object.
fn foundationOptions(
    hwnd: Hwnd,
    focused: bool,
    action_handler: ActionHandler,
    action_userdata: ?*anyopaque,
) error{ OutOfMemory, NotImplemented }!windows.WindowsAdapter.Options {
    const automation = windows.syscalls.nativeAutomationApi() orelse return error.NotImplemented;
    const gpa = allocation.allocator();
    const runtime = try gpa.create(WindowsRuntime);
    runtime.* = .{ .gpa = gpa, .threaded = std.Io.Threaded.init(gpa, .{}) };
    return .{
        .io = runtime.threaded.io(),
        .platform = windows.syscalls.platformForCurrentTarget(),
        .factory = windows.nativeFactory(),
        .automation = automation,
        .hwnd = hwnd,
        .is_window_focused = focused,
        .action_sink = .{ .c = .{ .callback = action_handler, .userdata = action_userdata } },
        .runtime_release = .{ .userdata = runtime, .release = WindowsRuntime.release },
    };
}

// Raises the queued events on the platform and releases the handle.
//
// `accesskit_windows_queued_events_raise`,
// `include/zaccesskit.h:6335`, upstream `src/lib.rs:3057`.
//
// Successful cleanup releases the handle. Failed cleanup reports its exact
// error and retains the handle for retry without redelivering events.
// Passing null terminates the process.
fn accesskit_windows_queued_events_raise(
    events: *windows.WindowsQueuedEvents,
) callconv(.c) void {
    allocation.clearError();
    const report = windows.windowsQueuedEventsRaise(events);
    if (report.cleanup.first_error) |err| allocation.failWithError(err);
}

// Returns a real Windows adapter, or null with its exact constructor failure.
//
// `accesskit_windows_adapter_new`, `include/zaccesskit.h:6346`,
// upstream `src/lib.rs:3062`.
//
// `action_handler_userdata` must stay valid until the adapter is
// released. This adapter takes no activation or deactivation handler:
// the `WM_GETOBJECT` reply asks for the tree. The caller owns the
// adapter and releases it with `accesskit_windows_adapter_free`.
fn accesskit_windows_adapter_new(
    hwnd: Hwnd,
    is_window_focused: bool,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
) callconv(.c) ?*windows.WindowsAdapter {
    allocation.clearError();
    const options = foundationOptions(
        hwnd,
        is_window_focused,
        action_handler,
        action_handler_userdata,
    ) catch |err| {
        allocation.failWithError(err);
        return null;
    };
    // Failed construction retains the authority here, not in a partial context.
    return windows.WindowsAdapter.create(allocation.allocator(), options) catch |err| {
        const authority = options.runtime_release.?;
        authority.release(authority.userdata);
        allocation.failWithError(err);
        return null;
    };
}

// Releases the adapter and every tree it holds, exactly once.
//
// `accesskit_windows_adapter_free`, `include/zaccesskit.h:6356`,
// upstream `src/lib.rs:3069`.
//
// Passing `null` terminates the process.
fn accesskit_windows_adapter_free(
    adapter: *windows.WindowsAdapter,
) callconv(.c) void {
    allocation.clearError();
    windows.windowsAdapterFree(adapter);
}

// Asks `update_factory` for a tree and hands it to the adapter.
//
// `accesskit_windows_adapter_update_if_active`,
// `include/zaccesskit.h:6368`, upstream `src/lib.rs:3078`.
//
// Returns the events the answer produced, or `null` when the adapter
// is not active. The caller owns a non-null result and must pass it to
// `accesskit_windows_queued_events_raise`.
fn accesskit_windows_adapter_update_if_active(
    adapter: *windows.WindowsAdapter,
    update_factory: TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) callconv(.c) ?*windows.WindowsQueuedEvents {
    allocation.clearError();
    return windows.windowsAdapterUpdateIfActive(
        adapter,
        update_factory,
        update_factory_userdata,
    );
}

// Tells the adapter whether `hwnd` holds focus, and returns the events
// the answer produced.
//
// `accesskit_windows_adapter_update_window_focus_state`,
// `include/zaccesskit.h:6381`, upstream `src/lib.rs:3092`.
//
// Returns `null` when the adapter is not active. The caller owns a
// non-null result and must raise it.
fn accesskit_windows_adapter_update_window_focus_state(
    adapter: *windows.WindowsAdapter,
    is_focused: bool,
) callconv(.c) ?*windows.WindowsQueuedEvents {
    allocation.clearError();
    return windows.windowsAdapterUpdateWindowFocusState(adapter, is_focused);
}

// Answers a `WM_GETOBJECT` message from a window procedure.
//
// `accesskit_windows_adapter_handle_wm_getobject`,
// `include/zaccesskit.h:6396`, upstream `src/lib.rs:3097`.
//
// The window procedure passes `wparam` and `lparam` unchanged.
// `has_value` is false when this adapter is not the one that owns the
// window, and the window procedure then returns `false` from
// `DefWindowProc`. When it is true, `value` is the `LRESULT` to
// return. The library calls `activation_handler` on its own thread and
// releases any tree update it returns.
fn accesskit_windows_adapter_handle_wm_getobject(
    adapter: *windows.WindowsAdapter,
    wparam: WParam,
    lparam: LParam,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
) callconv(.c) COptLResult {
    allocation.clearError();
    return adapter.handleWmGetobject(wparam, lparam, .{ .c = .{
        .callback = activation_handler,
        .userdata = activation_handler_userdata,
    } }) catch |err| {
        allocation.failWithError(err);
        return std.mem.zeroes(COptLResult);
    };
}

// Returns a text rendering of the adapter, or `null` when the text
// could not be built.
//
// `accesskit_windows_adapter_debug`, `include/zaccesskit.h:6412`,
// upstream `src/lib.rs:3107`.
//
// Release the result with `accesskit_string_free`, once. The text
// borrows nothing from the adapter once the call returns.
fn accesskit_windows_adapter_debug(
    adapter: *const windows.WindowsAdapter,
) callconv(.c) ?[*:0]u8 {
    allocation.clearError();
    return windows.windowsAdapterDebug(adapter);
}

/// Returns a native subclassing adapter, or null on refusal or typed failure.
///
/// `accesskit_windows_subclassing_adapter_new`,
/// `include/zaccesskit.h:6424`, upstream `src/lib.rs:3126`.
///
/// Every handler pointer must stay valid until the adapter is released.
/// The caller owns the adapter and releases it with
/// `accesskit_windows_subclassing_adapter_free`.
/// Install on the owning window thread before showing the window.
fn accesskit_windows_subclassing_adapter_new(
    hwnd: Hwnd,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
) callconv(.c) ?*windows.WindowsSubclassingAdapter {
    allocation.clearError();
    const options = foundationOptions(
        hwnd,
        false,
        action_handler,
        action_handler_userdata,
    ) catch |err| {
        allocation.failWithError(err);
        return null;
    };
    const created = windows.WindowsSubclassingAdapter.create(
        allocation.allocator(),
        options,
        windows.syscalls.windowApiForCurrentTarget(),
        .{ .c = .{ .callback = activation_handler, .userdata = activation_handler_userdata } },
    ) catch |err| {
        const authority = options.runtime_release.?;
        authority.release(authority.userdata);
        allocation.failWithError(err);
        return null;
    };
    if (created == null) {
        const authority = options.runtime_release.?;
        authority.release(authority.userdata);
    }
    return created;
}

/// Releases the adapter and every tree it holds, exactly once.
///
/// `accesskit_windows_subclassing_adapter_free`,
/// `include/zaccesskit.h:6436`, upstream `src/lib.rs:3134`.
///
/// Passing `null` terminates the process.
/// Free on the owning window thread, serialized with its procedure.
/// Do not free from a callback or while holding a context lease.
fn accesskit_windows_subclassing_adapter_free(
    adapter: *windows.WindowsSubclassingAdapter,
) callconv(.c) void {
    allocation.clearError();
    windows.windowsSubclassingAdapterFree(adapter);
}

/// Asks `update_factory` for a tree and hands it to the adapter.
///
/// `accesskit_windows_subclassing_adapter_update_if_active`,
/// `include/zaccesskit.h:6449`, upstream `src/lib.rs:3144`.
///
/// Returns the events the answer produced, or `null` when the adapter
/// is not active. The caller owns a non-null result and must pass it to
/// `accesskit_windows_queued_events_raise`.
fn accesskit_windows_subclassing_adapter_update_if_active(
    adapter: *windows.WindowsSubclassingAdapter,
    update_factory: TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) callconv(.c) ?*windows.WindowsQueuedEvents {
    allocation.clearError();
    return windows.windowsSubclassingAdapterUpdateIfActive(
        adapter,
        update_factory,
        update_factory_userdata,
    );
}

// The windows exports. A declaration above is emitted as a symbol only
// where its guard is true; this block is the whole of that decision.
comptime {
    if (Guard.windows.declaresOn(this_platform)) {
        @export(
            &accesskit_windows_queued_events_raise,
            .{ .name = "accesskit_windows_queued_events_raise", .linkage = .strong },
        );
        @export(
            &accesskit_windows_adapter_new,
            .{ .name = "accesskit_windows_adapter_new", .linkage = .strong },
        );
        @export(
            &accesskit_windows_adapter_free,
            .{ .name = "accesskit_windows_adapter_free", .linkage = .strong },
        );
        @export(
            &accesskit_windows_adapter_update_if_active,
            .{ .name = "accesskit_windows_adapter_update_if_active", .linkage = .strong },
        );
        @export(
            &accesskit_windows_adapter_update_window_focus_state,
            .{ .name = "accesskit_windows_adapter_update_window_focus_state", .linkage = .strong },
        );
        @export(
            &accesskit_windows_adapter_handle_wm_getobject,
            .{ .name = "accesskit_windows_adapter_handle_wm_getobject", .linkage = .strong },
        );
        @export(
            &accesskit_windows_adapter_debug,
            .{ .name = "accesskit_windows_adapter_debug", .linkage = .strong },
        );
        @export(
            &accesskit_windows_subclassing_adapter_new,
            .{ .name = "accesskit_windows_subclassing_adapter_new", .linkage = .strong },
        );
        @export(
            &accesskit_windows_subclassing_adapter_free,
            .{ .name = "accesskit_windows_subclassing_adapter_free", .linkage = .strong },
        );
        @export(
            &accesskit_windows_subclassing_adapter_update_if_active,
            .{
                .name = "accesskit_windows_subclassing_adapter_update_if_active",
                .linkage = .strong,
            },
        );
    }
}

// =============================================================================
// The tests. Their subject is the guard structure, not the adapters: nothing
// here calls an exported function, because every one of them dereferences a
// handle the C caller must own.
// =============================================================================

const testing = std.testing;

/// This module's own namespace under a name, so the tests below can ask it
/// what it declares without an inline `@This()` at every use.
const Self = @This();

test "the census is fifty-eight, split six, sixteen, thirteen, thirteen, ten" {
    try testing.expectEqual(@as(usize, 58), export_record_count);
    try testing.expectEqual(@as(usize, 5), all_guards.len);
    try testing.expectEqual(@as(usize, 15), sample_targets.len);
    try testing.expectEqual(@as(usize, 6), declaredCountFor(linux_target, .unix));
    try testing.expectEqual(@as(usize, 16), declaredCountFor(Platform.abiNone(.macos), .macos));
    // The four OS tags the header's `#if` names for the Apple-mobile family,
    // walked with a bound of four, each with the `.none` C ABI it carries.
    inline for ([_]std.Target.Os.Tag{ .ios, .tvos, .visionos, .watchos }) |tag| {
        const count = declaredCountFor(Platform.abiNone(tag), .apple_mobile);
        try testing.expectEqual(@as(usize, 13), count);
    }
    try testing.expectEqual(@as(usize, 13), declaredCountFor(android_target, .android));
    try testing.expectEqual(@as(usize, 10), declaredCountFor(windows_target, .windows));
}

test "a Linux target declares the six unix exports and no other" {
    // The figure `docs/40-capi-build-map.md` section 1.1 measured for the whole
    // library is 446 of 498, and this module's share of it is six. Asserting the
    // six is what a Linux run can see; the 440 is `src/capi/root.zig`'s and no
    // test in this file can count it.
    try testing.expectEqual(@as(usize, 6), declaredCount(linux_target));
    try testing.expectEqual(@as(usize, 6), linux_declared_count);

    inline for (export_records) |record| {
        if (record.guard.declaresOn(linux_target)) {
            try testing.expect(std.mem.startsWith(u8, record.symbol, guardPrefix(record.guard)));
        }
    }
    // A musl Linux is the same six. The unix guard reads the ABI for one reason
    // only, which is to keep Android out, so a libc choice does not change the
    // answer.
    try testing.expectEqual(@as(usize, 6), declaredCount(.{ .os_tag = .linux, .abi = .musl }));
}

test "an Android target declares the thirteen android exports and no unix one" {
    // This is the row a Linux-only build cannot observe and the reason
    // `declaresOn` takes a `Platform` and not an OS tag. Zig gives both Android
    // ABIs the `.linux` tag, so each of them has to be asked about by hand and
    // `sample_targets` carries a row for each.
    var android_rows: usize = 0;
    inline for (sample_targets) |target| {
        if (!target.abi.isAndroid()) continue;
        android_rows += 1;
        try testing.expectEqual(@as(usize, 13), declaredCount(target));
        try testing.expectEqual(@as(usize, 13), declaredCountFor(target, .android));
        try testing.expectEqual(@as(usize, 0), declaredCountFor(target, .unix));
        inline for (export_records) |record| {
            if (record.guard.declaresOn(target)) {
                const family = guardPrefix(record.guard);
                try testing.expect(std.mem.startsWith(u8, record.symbol, family));
            }
        }
    }
    // Both spellings, so a guard that reads only `.android` and misses
    // `.androideabi` fails here rather than on a 32-bit ARM device.
    try testing.expectEqual(@as(usize, 2), android_rows);
    // A Linux target and an Android target share an OS tag and nothing else,
    // so neither can see the other's symbols.
    try testing.expectEqual(@as(usize, 6), declaredCount(linux_target));
    try testing.expect(!declaresSymbol(android_target, "accesskit_unix_adapter_new"));
    try testing.expect(!declaresSymbol(linux_target, "accesskit_android_adapter_new"));
    try testing.expect(declaresSymbol(android_target, "accesskit_android_adapter_new"));
}

test "the six symbols a Linux target declares are the unix family" {
    const expected = [_][]const u8{
        "accesskit_unix_adapter_new",
        "accesskit_unix_adapter_free",
        "accesskit_unix_adapter_set_root_window_bounds",
        "accesskit_unix_adapter_update_if_active",
        "accesskit_unix_adapter_update_window_focus_state",
        "accesskit_unix_adapter_debug",
    };
    try testing.expectEqual(expected.len, declaredCount(linux_target));
    for (expected) |symbol| {
        try testing.expect(declaresSymbol(linux_target, symbol));
        // A symbol another platform owns answers false for a Linux target even
        // though this module declares it, and a symbol it does not own answers
        // false everywhere. Android is the second one to check here, because it
        // shares Linux's OS tag and must still answer false.
        try testing.expect(!declaresSymbol(windows_target, symbol));
        try testing.expect(!declaresSymbol(android_target, symbol));
    }
    try testing.expect(!declaresSymbol(linux_target, "accesskit_windows_adapter_new"));
    try testing.expect(!declaresSymbol(linux_target, "accesskit_node_role"));
}

test "no two guards claim the same target, and every guard and record is claimed" {
    // This is the disjointness the header's five `#if` blocks and upstream's
    // five `cfg` blocks have between them, and it is the property a Linux-only
    // build cannot observe for itself. `sample_targets` carries two Android
    // rows, so the Android guard is checked against the unix guard here on
    // this host.
    //
    // 15 targets against 58 records is 870 calls into `declaresOn`, each
    // re-walking the sixty-arm OS-tag switch, so this test needs more than the
    // default thousand backwards branches.
    @setEvalBranchQuota(200_000);
    inline for (sample_targets) |target| {
        var guards_claiming: usize = 0;
        inline for (all_guards) |guard| {
            if (guard.declaresOn(target)) guards_claiming += 1;
        }
        try testing.expect(guards_claiming <= 1);

        // Which makes the declared set a partition and not a union: every
        // declaration the target sees is declared by exactly one guard.
        var declared: usize = 0;
        inline for (export_records) |record| {
            if (record.guard.declaresOn(target)) declared += 1;
        }
        try testing.expectEqual(declaredCount(target), declared);
    }

    // Every guard claims at least one row, so none of the five is dead and a
    // sixth member of `Guard` without a row in `all_guards` fails here.
    try testing.expectEqual(@as(usize, 5), all_guards.len);
    inline for (all_guards) |guard| {
        var claimed: usize = 0;
        inline for (sample_targets) |target| {
            if (guard.declaresOn(target)) claimed += 1;
        }
        try testing.expect(claimed > 0);
    }

    // Every record is declared on at least one row, so no row of
    // `export_records` is unreachable on every platform.
    inline for (export_records) |record| {
        var seen: usize = 0;
        inline for (sample_targets) |target| {
            if (record.guard.declaresOn(target)) seen += 1;
        }
        try testing.expect(seen > 0);
    }
}

test "every record names a declaration this module holds, under its own guard" {
    // `@hasDecl` answers "does this module declare it", not "does this build
    // emit it". The `comptime` blocks above remove the `@export` call and leave
    // the Zig declaration in place, so all 58 are here on every target and
    // tying `@hasDecl` to the guard would fail on the first Android row. What
    // is checkable, and what the five `comptime` blocks themselves rely on, is
    // that a row names a declaration this file holds and that the declaration
    // belongs to the family its guard is.
    inline for (export_records) |record| {
        try testing.expect(@hasDecl(Self, record.symbol));
        try testing.expect(std.mem.startsWith(u8, record.symbol, guardPrefix(record.guard)));
    }
}

/// The family prefix every symbol behind `guard` carries: `accesskit_`, the
/// platform name, and the separator. It is one table for the five guards, and
/// the five `comptime` blocks above can only be right about which symbols they
/// emit if this table agrees with `export_records`.
fn guardPrefix(guard: Guard) []const u8 {
    return switch (guard) {
        .unix => "accesskit_unix_",
        .macos => "accesskit_macos_",
        .apple_mobile => "accesskit_ios_",
        .android => "accesskit_android_",
        .windows => "accesskit_windows_",
    };
}

test "every declared export is a C-callconv function" {
    inline for (export_records) |record| {
        if (record.guard.declaresOn(this_platform)) {
            const declaration = @typeInfo(@TypeOf(@field(Self, record.symbol)));
            try testing.expect(declaration == .@"fn");
            try testing.expectEqual(
                std.builtin.CallingConvention.c,
                declaration.@"fn".calling_convention,
            );
            try testing.expect(!declaration.@"fn".is_var_args);
        }
    }
}

test "every record's header line and upstream line are unique" {
    // Two records sharing a line number means one of them was copied, and a
    // duplicated symbol means the second `export fn` is unreachable.
    for (export_records, 0..) |record, i| {
        for (export_records[0..i]) |earlier| {
            try testing.expect(!std.mem.eql(u8, earlier.symbol, record.symbol));
            try testing.expect(earlier.header_line != record.header_line);
            try testing.expect(earlier.upstream_line != record.upstream_line);
        }
    }
}

test "every record's header line is inside the platform region of the header" {
    // The region is `include/zaccesskit.h:5701-6454` today, and the first record
    // is the only one that may sit on the guard line itself.
    inline for (export_records) |record| {
        try testing.expect(record.header_line >= 5701);
        try testing.expect(record.header_line <= 6454);
    }
}

test "every record's upstream line is inside the platform region upstream" {
    // `accesskit-c/src/lib.rs:2539-3148` at `8b6ed37`, from
    // `docs/11-accesskit-c-abi.md` section 2.13.
    inline for (export_records) |record| {
        try testing.expect(record.upstream_line >= 2539);
        try testing.expect(record.upstream_line <= 3148);
    }
}

test "the ten platform release functions are all here" {
    // `docs/31-c-abi-design.md` section 3 row 16 names ten platform `*_free`
    // functions. This test is what keeps the count from drifting, and it is why
    // the header's own count of seventeen `*_free` declarations agrees: the
    // other seven are the node, tree-info, tree-update, two custom-action,
    // action-request and string releases.
    const expected = [_][]const u8{
        "accesskit_android_platform_action_free",
        "accesskit_android_adapter_free",
        "accesskit_android_injecting_adapter_free",
        "accesskit_ios_adapter_free",
        "accesskit_ios_subclassing_adapter_free",
        "accesskit_macos_adapter_free",
        "accesskit_macos_subclassing_adapter_free",
        "accesskit_unix_adapter_free",
        "accesskit_windows_adapter_free",
        "accesskit_windows_subclassing_adapter_free",
    };
    var found: usize = 0;
    inline for (export_records) |record| {
        for (expected) |symbol| {
            if (std.mem.eql(u8, record.symbol, symbol)) found += 1;
        }
    }
    try testing.expectEqual(expected.len, found);
}

test "the four queued-events handles and their four raises are all here" {
    // `docs/31-c-abi-design.md` section 3 row 17: four `*_queued_events` handles,
    // released only by the matching `*_queued_events_raise`. The Unix family has
    // none, which is why `accesskit_unix_adapter_update_if_active` returns void.
    const expected = [_][]const u8{
        "accesskit_android_queued_events_raise",
        "accesskit_ios_queued_events_raise",
        "accesskit_macos_queued_events_raise",
        "accesskit_windows_queued_events_raise",
    };
    var found: usize = 0;
    inline for (export_records) |record| {
        for (expected) |symbol| {
            if (std.mem.eql(u8, record.symbol, symbol)) found += 1;
        }
    }
    try testing.expectEqual(expected.len, found);
    // Android's injecting adapter, the two subclassing adapters and the plain
    // Unix adapter return no handle at all.
    try testing.expect(!declaresSymbol(linux_target, "accesskit_unix_queued_events_raise"));
    const macos_target = Platform.abiNone(.macos);
    try testing.expect(declaresSymbol(macos_target, "accesskit_macos_queued_events_raise"));
}

test "the boundary layouts are the ones the header was measured to have" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(COptLResult));
    try testing.expectEqual(@as(usize, 8), @alignOf(COptLResult));
    try testing.expectEqual(@as(usize, 8), @offsetOf(COptLResult, "value"));
    try testing.expectEqual(@as(usize, 32), @sizeOf(CRect));
    try testing.expectEqual(@as(usize, 8), @alignOf(CRect));
    try testing.expectEqual(@as(usize, 0), @offsetOf(CRect, "x0"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(CRect, "y1"));
}

test "the four callback types have the shapes the header declares" {
    // `std.builtin.Type.Pointer` spells the pointee `child` on this compiler,
    // `childFn` hands back the `std.builtin.Type` that describes it, and
    // `std.builtin.Type.Fn` spells its return type and its parameter types as
    // optionals. All three are unwrapped here rather than compared against.
    //
    // `CActionRequest` is itself already the optional pointer the header
    // declares, so the handler's first parameter is `*CActionRequest` and
    // wrapping it a second time would name a pointer to a null.
    try testing.expectEqual(
        std.builtin.CallingConvention.c,
        childFn(TreeUpdateFactory).@"fn".calling_convention,
    );
    try testing.expectEqual(@as(usize, 1), childFn(TreeUpdateFactory).@"fn".params.len);
    try testing.expectEqual(?*anyopaque, childFn(TreeUpdateFactory).@"fn".params[0].type.?);
    try testing.expectEqual(?*CTreeUpdate, childFn(TreeUpdateFactory).@"fn".return_type.?);

    try testing.expectEqual(@as(usize, 2), childFn(ActionHandler).@"fn".params.len);
    try testing.expectEqual(*CActionRequest, childFn(ActionHandler).@"fn".params[0].type.?);
    try testing.expectEqual(?*anyopaque, childFn(ActionHandler).@"fn".params[1].type.?);
    try testing.expectEqual(void, childFn(ActionHandler).@"fn".return_type.?);

    try testing.expectEqual(@as(usize, 1), childFn(DeactivationHandler).@"fn".params.len);
    try testing.expectEqual(?*anyopaque, childFn(DeactivationHandler).@"fn".params[0].type.?);
    try testing.expectEqual(void, childFn(DeactivationHandler).@"fn".return_type.?);

    // The activation handler and the tree-update factory are textually
    // identical in the header and stay identical here, which is why one Zig
    // function can carry both names.
    try testing.expectEqual(TreeUpdateFactory, ActivationHandler);
}

/// The `std.builtin.Type` of the function a function-pointer type points at.
fn childFn(pointer_type: type) std.builtin.Type {
    return @typeInfo(@typeInfo(pointer_type).pointer.child);
}

test "every re-export above names a declaration that exists" {
    // A declaration nothing in this module's own tests reaches is analysed only
    // as far as a reached path refers to it, so the census tests above would
    // otherwise report green about a type that never compiled.
    // Reflection reaches COM declarations even off Windows, so `.winapi` must resolve.
    if (comptime windows.WindowsBoundary.bindings.winapi_resolves) {
        std.testing.refAllDecls(@This());
    } else {
        return error.SkipZigTest;
    }
}

test "Windows C construction off Windows reports NotImplemented rather than fake success" {
    // Constructor cleanup reaches COM declarations even off Windows.
    if (comptime windows.WindowsBoundary.bindings.winapi_resolves) {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        const Callbacks = struct {
            fn action(request: *CActionRequest, userdata: ?*anyopaque) callconv(.c) void {
                _ = request;
                _ = userdata;
                @panic("off-platform constructor dispatched an action");
            }
        };
        allocation.clearError();
        const created = accesskit_windows_adapter_new(null, false, Callbacks.action, null);
        defer if (created) |owner| accesskit_windows_adapter_free(owner);
        try testing.expectEqual(@as(?*windows.WindowsAdapter, null), created);
        try testing.expectEqual(allocation.Tag.operation_failed, allocation.lastError());
        try testing.expectEqualStrings("NotImplemented", std.mem.span(allocation.lastErrorName().?));
    } else {
        return error.SkipZigTest;
    }
}

test "Windows subclass C construction off Windows preserves its exact failure" {
    // Constructor cleanup reaches COM declarations even off Windows.
    if (comptime windows.WindowsBoundary.bindings.winapi_resolves) {
        if (builtin.os.tag == .windows) return error.SkipZigTest;
        const Callbacks = struct {
            fn activate(userdata: ?*anyopaque) callconv(.c) ?*CTreeUpdate {
                _ = userdata;
                @panic("off-platform constructor activated a tree");
            }

            fn action(request: *CActionRequest, userdata: ?*anyopaque) callconv(.c) void {
                _ = request;
                _ = userdata;
                @panic("off-platform constructor dispatched an action");
            }
        };
        allocation.clearError();
        const created = accesskit_windows_subclassing_adapter_new(
            null,
            Callbacks.activate,
            null,
            Callbacks.action,
            null,
        );
        defer if (created) |owner| accesskit_windows_subclassing_adapter_free(owner);
        try testing.expectEqual(@as(?*windows.WindowsSubclassingAdapter, null), created);
        try testing.expectEqual(allocation.Tag.operation_failed, allocation.lastError());
        try testing.expectEqualStrings("NotImplemented", std.mem.span(allocation.lastErrorName().?));
    } else {
        return error.SkipZigTest;
    }
}
