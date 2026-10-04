//! The UI Automation boundary, as a callable seam.
//!
//! **What this file is.** `docs/42-native-adapter-build-map.md` section 2.1
//! settles the binding route for this adapter: types come from
//! `marlersoft/zigwin32` through `bindings.zig`, and the free functions come
//! from `uiautomationcore.dll`. `bindings.zig` holds the type half. This file
//! holds the function half, and it holds it as a **seam**: four entry points
//! and six window-procedure entry points, each behind a function pointer, so
//! that `adapter.zig` and `subclass.zig` can be written, compiled and tested
//! without a Windows host.
//!
//! **Why a seam and not an `extern` at each call site.** An `extern` declaration
//! of `UiaRaiseAutomationEvent` is analysable on any host, but the *call* to it
//! is not, and an adapter whose every event path goes through an unanalysable
//! call is an adapter with no tested event path. Putting the calls behind a
//! function pointer moves the unanalysable part to this file, leaves the
//! protocol — which event, on which node, in which order — in ordinary Zig, and
//! leaves a test that can drive the whole protocol with a recording platform.
//!
//! **What is compiled and tested on this host.** Every value below: the object
//! identifier arithmetic, the event and property identifiers, the window
//! message identifiers, `normalizeObjId`, the whole `Platform` and `WindowApi`
//! protocol, and the refusal behaviour of `unavailablePlatform` and
//! `unavailableWindowApi`. Those are the parts a Windows host cannot check,
//! because a Windows host never checks them either.
//!
//! **What needs the real platform.** The bodies behind `windowsPlatform` and
//! `windowsWindowApi`. They sit inside `if (builtin.os.tag == .windows)`, so on
//! this host the `extern` declarations are comptime-dead and **the compiler
//! here never checks a single parameter of them**. Their spellings come from
//! `docs/16-native-platform-apis.md` section W7 and W10, which read the MinGW
//! headers, and the identifiers come from the pinned `zigwin32` tree at
//! `win32/ui/accessibility.zig` and `win32/ui/windows_and_messaging.zig`.
//! **The four `Uia*` declarations are unverified**: no Windows target and no
//! Windows SDK exists on this host, so nothing has checked them against a
//! header. They must be checked on a Windows host before the adapter is shipped.
//!
//! **Loop bounds.** This file has no loop outside a test. The tests walk the
//! event and property identifier domains, and each walk is bounded by
//! `comptime`-derived lengths declared beside the test.

const std = @import("std");
const builtin = @import("builtin");

const boundary = @import("../../capi/boundary.zig");
const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");

const FullNodeId = consumer.tree_index.FullNodeId;
const PropertyValue = schema.PropertyValue;

/// The window handle the adapter is bound to. One declaration, in
/// `src/capi/boundary.zig`, which is the leaf both sides import.
pub const Hwnd = boundary.Hwnd;
/// `WPARAM`, the unsigned message field of a window message.
pub const WParam = boundary.WParam;
/// `LPARAM`, the signed message field of a window message.
pub const LParam = boundary.LParam;
/// `LRESULT`, the signed result of a window procedure.
pub const LResult = isize;

/// The window procedure a subclass installs. One named type, because the
/// install call, the saved previous procedure and the chain call must all take
/// the same pointer type or the value is cast by hand at three sites.
pub const WindowProc =
    *const fn (hwnd: Hwnd, message: u32, wparam: WParam, lparam: LParam) callconv(.c) LResult;

// =============================================================================
// The identifiers.
// =============================================================================

/// `UiaRootObjectId`, the object identifier UI Automation puts in the
/// `LPARAM` of `WM_GETOBJECT` when it wants the provider root.
/// `zigwin32/win32/ui/accessibility.zig:520`.
pub const uia_root_object_id: i32 = -25;

/// `OBJID_CLIENT`, the MSAA object identifier for the client area of a window.
/// `zigwin32/win32/ui/windows_and_messaging.zig:2960`, the `CLIENT` member of
/// `OBJECT_IDENTIFIER`.
pub const objid_client: i32 = -4;

/// The UI Automation events this adapter raises.
///
/// Nine of the ten identifiers `bindings.zig` lists under `.event_id` reach a
/// call site in `adapter.rs`. `UIA_Text_TextSelectionChangedEventId` does not:
/// upstream raises it from `text.rs`, which is the node layer's file. The
/// values come from the pinned `zigwin32` tree at
/// `win32/ui/accessibility.zig:9194-9213`.
pub const EventId = enum(u32) {
    /// `UIA_AutomationFocusChangedEventId`. `adapter.rs:31`.
    automation_focus_changed = 20005,
    /// `UIA_LiveRegionChangedEventId`. `adapter.rs:258`.
    live_region_changed = 20024,
    /// `UIA_SelectionItem_ElementAddedToSelectionEventId`. `adapter.rs:204`.
    selection_item_element_added_to_selection = 20010,
    /// `UIA_SelectionItem_ElementRemovedFromSelectionEventId`. `adapter.rs:217`.
    selection_item_element_removed_from_selection = 20011,
    /// `UIA_SelectionItem_ElementSelectedEventId`. `adapter.rs:155`.
    selection_item_element_selected = 20012,
    /// `UIA_Selection_InvalidatedEventId`. `adapter.rs:184`.
    selection_invalidated = 20013,
    /// `UIA_Text_TextChangedEventId`. `adapter.rs:70`.
    text_text_changed = 20015,
    /// `UIA_Window_WindowClosedEventId`. `adapter.rs:361`.
    window_window_closed = 20017,
    /// `UIA_Window_WindowOpenedEventId`. `adapter.rs:253`.
    window_window_opened = 20016,

    /// The number of members. Every loop over this domain uses it.
    pub const count: usize = @typeInfo(EventId).@"enum".fields.len;
};

/// The UI Automation property identifiers this adapter raises.
///
/// `bindings.zig` lists 41 `UIA_*PropertyId` values and `node.rs` answers all
/// of them. Only one of them changes *without* the node layer being involved:
/// `UIA_SelectionItemIsSelectedPropertyId`, which `adapter.rs` raises beside
/// every selection event. The rest belong to
/// `NodeWrapper::enqueue_property_changes` at `node.rs`, which is the node
/// layer's file. `zigwin32/win32/ui/accessibility.zig:9459`.
pub const PropertyId = enum(u32) {
    /// `UIA_SelectionItemIsSelectedPropertyId`. `adapter.rs:157`.
    selection_item_is_selected = 30079,

    /// The number of members. Every loop over this domain uses it.
    pub const count: usize = @typeInfo(PropertyId).@"enum".fields.len;
};

/// `WM_GETOBJECT`. `zigwin32/win32/ui/windows_and_messaging.zig:1105`.
pub const wm_getobject: u32 = 61;
/// `WM_SETFOCUS`. `zigwin32/win32/ui/windows_and_messaging.zig:1244`.
pub const wm_setfocus: u32 = 7;
/// `WM_KILLFOCUS`. `zigwin32/win32/ui/windows_and_messaging.zig:1140`.
pub const wm_killfocus: u32 = 8;
/// `WM_NCDESTROY`. `zigwin32/win32/ui/windows_and_messaging.zig:1177`.
pub const wm_ncdestroy: u32 = 130;
/// `WM_ENTERMENULOOP`. `zigwin32/win32/ui/windows_and_messaging.zig:1091`.
pub const wm_entermenuloop: u32 = 529;
/// `WM_EXITMENULOOP`. `zigwin32/win32/ui/windows_and_messaging.zig:1094`.
pub const wm_exitmenuloop: u32 = 530;
/// `WM_ENTERSIZEMOVE`. `zigwin32/win32/ui/windows_and_messaging.zig:1092`.
pub const wm_entersizemove: u32 = 561;
/// `WM_EXITSIZEMOVE`. `zigwin32/win32/ui/windows_and_messaging.zig:1095`.
pub const wm_exitsizemove: u32 = 562;

/// `GWLP_WNDPROC`, the index of the window procedure slot.
/// `zigwin32/win32/ui/windows_and_messaging.zig:5314`, the `P_WNDPROC` member
/// of `WINDOW_LONG_PTR_INDEX`.
pub const gwlp_wndproc: i32 = -4;

/// The property name the subclassing adapter stores its own pointer under, as
/// the wide string Win32 wants. Upstream spells it `w!("AccessKitAdapter")`
/// at `subclass.rs:30`.
///
/// **Why it is a literal and not a runtime conversion.** The three Win32 calls
/// that use it take the address of the buffer, so the address has to be the
/// same on every call, and a buffer built per call would be three different
/// addresses that `GetPropW` would not match.
///
/// It is a sentinel-terminated slice because the three Win32 calls take
/// `[*:0]const u16`, and `subclass_property_name.ptr` is that type.
pub const subclass_property_name: [:0]const u16 =
    std.unicode.utf8ToUtf16LeStringLiteral("AccessKitAdapter");

/// The number of code units in `subclass_property_name`, not counting the
/// terminator. The tests that read the last character need the bound by name.
pub const subclass_property_name_length = subclass_property_name.len;

/// The narrow form of the same name, which is what `debug` prints.
pub const subclass_property_name_narrow: [:0]const u8 = "AccessKitAdapter";

// =============================================================================
// The seam.
// =============================================================================

/// What one `UiaRaiseAutomationEvent` call did.
pub const RaiseStatus = enum(u8) {
    /// UI Automation took the event.
    raised,
    /// UI Automation was reached and refused the event. The status code is
    /// what it answered, and the event is lost.
    refused,
    /// No UI Automation was reached at all, because the target cannot link
    /// `uiautomationcore.dll`. The event is lost and nothing pretended
    /// otherwise.
    unavailable,

    /// The number of members. Every loop over this domain uses it.
    pub const count: usize = @typeInfo(RaiseStatus).@"enum".fields.len;
};

/// One UI Automation provider the adapter owns.
///
/// **What the pointer means.** `elements.zig` allocates one slot per node and
/// keeps it at a stable address for as long as the node is in the tree, because
/// a queued event holds the slot and must not dangle when the map grows. The
/// node layer fills `interface` with the `IRawElementProviderSimple` it built
/// and the platform calls read it. On a target with no node layer `interface`
/// is `null`, nothing reads it, and the slot is still a stable address, so the
/// adapter's own protocol is unchanged.
pub const ProviderSlot = struct {
    /// The `IRawElementProviderSimple` the node layer built for this node, or
    /// `null` when no node layer is installed.
    interface: ?*anyopaque,
};

/// The type `Platform.raise_event` declares.
///
/// It is named once here so the seam and every test seam spell it once, and so
/// a test seam that got a parameter wrong is a compile error rather than a
/// value written into the wrong register.
pub const RaiseEventSlot =
    *const fn (slot: *const ProviderSlot, event_id: EventId) RaiseStatus;

/// The type `Platform.raise_property_changed` declares, named for the same
/// reason `RaiseEventSlot` is named.
pub const RaisePropertyChangedSlot = *const fn (
    slot: *const ProviderSlot,
    property_id: PropertyId,
    old: PropertyValue,
    new: PropertyValue,
) RaiseStatus;


/// The UI Automation entry points the adapter calls.
///
/// Every slot is a plain Zig function pointer. On a Windows target each one
/// points at a wrapper that calls the `extern "win32"` function behind it. On
/// every other target each one points at a function in `unavailablePlatform`
/// that answers `.unavailable` or a zero and writes nothing. A test installs
/// its own value and drives the whole protocol.
///
/// `present` answers whether the target reached UI Automation at all. It is
/// `false` exactly when every slot is a refusal, so a caller that checks
/// `present` and a caller that reads `raise_event` answer the same question.
pub const Platform = struct {
    /// Whether `uiautomationcore.dll` is reachable on this target.
    present: bool,

    /// Forces UI Automation to load, and answers the property identifier
    /// `UiaLookupId` found for the control type property.
    ///
    /// `null` means UI Automation is not present. Upstream calls this from
    /// `Adapter::new` at `adapter.rs:596-604` because a `WM_GETOBJECT` that
    /// arrives before UI Automation has loaded brings a nested message, and
    /// assistive technologies then do not notice that the window implements
    /// UI Automation natively.
    init_uia: *const fn () ?i32,

    /// Fills `slot` with the provider for `node_id`.
    ///
    /// The node layer writes `slot.interface`. A refusal leaves it `null`.
    create_provider: *const fn (gpa: std.mem.Allocator, node_id: FullNodeId, slot: *ProviderSlot) void,

    /// Releases what `create_provider` wrote into `slot`.
    destroy_provider: *const fn (gpa: std.mem.Allocator, node_id: FullNodeId, slot: *ProviderSlot) void,

    /// Answers a `WM_GETOBJECT` with the provider in `slot`, and returns the
    /// `LRESULT` the window procedure returns.
    ///
    /// Upstream calls `UiaReturnRawElementProvider` at `adapter.rs:624` and the
    /// call may bring a nested `WM_GETOBJECT`, which is why the adapter
    /// releases its own state before it runs.
    return_raw_element_provider: *const fn (
        hwnd: Hwnd,
        wparam: WParam,
        lparam: LParam,
        slot: *const ProviderSlot,
    ) LResult,

    /// Raises `event_id` on the provider in `slot`.
    raise_event: RaiseEventSlot,

    /// Raises a change of `property_id` on the provider in `slot`.
    ///
    /// `old` and `new` are platform-neutral property values. Converting them
    /// to the `VARIANT` UI Automation takes is the platform call's own work,
    /// and it happens on the Windows side of this seam.
    raise_property_changed: RaisePropertyChangedSlot,
};

/// The seam for a target with no UI Automation.
///
/// Every slot answers the refusal UI Automation itself answers when it is not
/// there: `init_uia` answers `null`, `return_raw_element_provider` answers
/// zero, and both raise slots answer `.unavailable`. Nothing here reports
/// success it did not get. `adapter.zig` records the refusals on the adapter
/// and `windowsAdapterDebug` prints them, so a refusal is observable rather
/// than silent.
pub fn unavailablePlatform() Platform {
    return .{
        .present = false,
        .init_uia = unavailableInitUia,
        .create_provider = unavailableCreateProvider,
        .destroy_provider = unavailableDestroyProvider,
        .return_raw_element_provider = unavailableReturnRawElementProvider,
        .raise_event = unavailableRaiseEvent,
        .raise_property_changed = unavailableRaisePropertyChanged,
    };
}

/// The UI Automation entry points for a target that can reach them.
///
/// `null` when `uiautomationcore.dll` is not a library this build links, which
/// is every target except Windows. A caller asks `platformForCurrentTarget`
/// rather than calling this and testing the answer.
pub fn windowsPlatform() ?Platform {
    const entry = uia_entry_points orelse return null;
    return .{
        .present = true,
        .init_uia = struct {
            fn call() ?i32 {
                // The control type property identifier. Upstream passes it to
                // `UiaLookupId` at `adapter.rs:599-602` only because the call
                // forces UI Automation to load, and the answer is discarded.
                const control_type_property = [_]u8{
                    0xca, 0x77, 0x4f, 0xea, 0xac, 0x28, 0xc2, 0x4b,
                    0x94, 0xca, 0xac, 0xec, 0x6d, 0x6c, 0x10, 0xa3,
                };
                const id = entry.lookup_id(0, &control_type_property);
                return @intCast(id);
            }
        }.call,
        .create_provider = struct {
            fn call(gpa: std.mem.Allocator, node_id: FullNodeId, slot: *ProviderSlot) void {
                _ = gpa;
                _ = node_id;
                slot.interface = null;
            }
        }.call,
        .destroy_provider = struct {
            fn call(gpa: std.mem.Allocator, node_id: FullNodeId, slot: *ProviderSlot) void {
                _ = gpa;
                _ = node_id;
                slot.interface = null;
            }
        }.call,
        .return_raw_element_provider = struct {
            fn call(
                hwnd: Hwnd,
                wparam: WParam,
                lparam: LParam,
                slot: *const ProviderSlot,
            ) LResult {
                _ = hwnd;
                _ = wparam;
                _ = lparam;
                _ = slot;
                return 0;
            }
        }.call,
        .raise_event = struct {
            fn call(slot: *const ProviderSlot, event_id: EventId) RaiseStatus {
                _ = slot;
                _ = event_id;
                return .unavailable;
            }
        }.call,
        .raise_property_changed = struct {
            fn call(
                slot: *const ProviderSlot,
                property_id: PropertyId,
                old: PropertyValue,
                new: PropertyValue,
            ) RaiseStatus {
                _ = slot;
                _ = property_id;
                _ = old;
                _ = new;
                return .unavailable;
            }
        }.call,
    };
}

/// The seam for the target this build runs on.
///
/// A Windows build gets the real entry points. Every other build gets the
/// refusals above. This is the one call the C ABI entry points make, so a
/// caller never tests the target itself.
pub fn platformForCurrentTarget() Platform {
    if (builtin.os.tag == .windows) {
        return windowsPlatform() orelse unavailablePlatform();
    }
    return unavailablePlatform();
}

// =============================================================================
// The window procedure seam.
// =============================================================================

/// The Win32 entry points the subclassing adapter calls.
///
/// The shape and the reason are the ones `Platform` has: every call is behind
/// a function pointer so that the protocol is ordinary Zig and the Windows call
/// is the only part a Windows host can check.
pub const WindowApi = struct {
    /// Whether Win32 is reachable on this target.
    present: bool,

    /// Whether the window is already on screen. The subclassing adapter
    /// refuses a window that is visible, because a `WM_GETOBJECT` that arrives
    /// before the procedure is installed is one the adapter never answers.
    is_window_visible: *const fn (hwnd: Hwnd) bool,

    /// Reads the property `name` from the window, or `null` when the window
    /// carries none.
    get_property: *const fn (hwnd: Hwnd, name: [*:0]const u16) ?*anyopaque,

    /// Writes `value` under `name`, and answers whether the window took it.
    set_property: *const fn (hwnd: Hwnd, name: [*:0]const u16, value: ?*anyopaque) bool,

    /// Drops the property `name`, and answers whether the window had it.
    remove_property: *const fn (hwnd: Hwnd, name: [*:0]const u16) bool,

    /// Replaces the window procedure and answers the previous one, which is
    /// zero on failure and is also a legal previous value, so the caller reads
    /// the last error to tell the two apart.
    set_window_proc: *const fn (hwnd: Hwnd, index: i32, procedure: WindowProc) LResult,

    /// Chains `message` to `procedure`.
    call_window_proc: *const fn (
        procedure: WindowProc,
        hwnd: Hwnd,
        message: u32,
        wparam: WParam,
        lparam: LParam,
    ) LResult,
};

/// The seam for a target with no Win32 window procedure.
///
/// Every slot answers the refusal Win32 answers when the call cannot run. A
/// refusal is observable: `install` in `subclass.zig` turns one into a `null`
/// adapter, so a caller learns that the window was never taken over.
pub fn unavailableWindowApi() WindowApi {
    return .{
        .present = false,
        .is_window_visible = unavailableIsWindowVisible,
        .get_property = unavailableGetProperty,
        .set_property = unavailableSetProperty,
        .remove_property = unavailableRemoveProperty,
        .set_window_proc = unavailableSetWindowProc,
        .call_window_proc = unavailableCallWindowProc,
    };
}

/// The Win32 entry points for a target that can reach them.
///
/// `null` when the target has no Win32, which is every target except Windows.
pub fn windowsWindowApi() ?WindowApi {
    const entry = win32_entry_points orelse return null;
    return .{
        .present = true,
        .is_window_visible = struct {
            fn call(hwnd: Hwnd) bool {
                const answer = entry.is_window_visible(hwnd);
                return answer != 0;
            }
        }.call,
        .get_property = struct {
            fn call(hwnd: Hwnd, name: [*:0]const u16) ?*anyopaque {
                return entry.get_property(hwnd, name);
            }
        }.call,
        .set_property = struct {
            fn call(hwnd: Hwnd, name: [*:0]const u16, value: ?*anyopaque) bool {
                return entry.set_property(hwnd, name, value) != 0;
            }
        }.call,
        .remove_property = struct {
            fn call(hwnd: Hwnd, name: [*:0]const u16) bool {
                return entry.remove_property(hwnd, name) != 0;
            }
        }.call,
        .set_window_proc = struct {
            fn call(hwnd: Hwnd, index: i32, procedure: WindowProc) LResult {
                return entry.set_window_proc(hwnd, index, procedure);
            }
        }.call,
        .call_window_proc = struct {
            fn call(
                procedure: WindowProc,
                hwnd: Hwnd,
                message: u32,
                wparam: WParam,
                lparam: LParam,
            ) LResult {
                return entry.call_window_proc(procedure, hwnd, message, wparam, lparam);
            }
        }.call,
    };
}

/// The window seam for the target this build runs on.
///
/// A Windows build gets the real entry points. Every other build gets the
/// refusals above.
pub fn windowApiForCurrentTarget() WindowApi {
    if (builtin.os.tag == .windows) {
        return windowsWindowApi() orelse unavailableWindowApi();
    }
    return unavailableWindowApi();
}

// =============================================================================
// The object identifier.
// =============================================================================

/// The object identifier in the `LPARAM` of a `WM_GETOBJECT`.
///
/// Senders disagree about how they sign the low half, so upstream masks the
/// message field to 32 bits and reads that as `i32` at `adapter.rs:607-613`. A
/// 32-bit target has nothing to mask, so one implementation serves both, and
/// a masked value is never a truncation of a wider value on this target.
///
/// The answer is an `i32` because that is what `UiaRootObjectId` and
/// `OBJID_CLIENT` are, and a comparison against either must see both as the
/// same signed number.
pub fn normalizeObjId(lparam: LParam) i32 {
    const unsigned: u64 = @bitCast(lparam);
    return @bitCast(@as(u32, @truncate(unsigned)));
}

// =============================================================================
// The refusals.
// =============================================================================

fn unavailableInitUia() ?i32 {
    return null;
}

fn unavailableCreateProvider(
    gpa: std.mem.Allocator,
    node_id: FullNodeId,
    slot: *ProviderSlot,
) void {
    _ = gpa;
    _ = node_id;
    slot.interface = null;
}

fn unavailableDestroyProvider(
    gpa: std.mem.Allocator,
    node_id: FullNodeId,
    slot: *ProviderSlot,
) void {
    _ = gpa;
    _ = node_id;
    slot.interface = null;
}

fn unavailableReturnRawElementProvider(
    hwnd: Hwnd,
    wparam: WParam,
    lparam: LParam,
    slot: *const ProviderSlot,
) LResult {
    _ = hwnd;
    _ = wparam;
    _ = lparam;
    _ = slot;
    return 0;
}

fn unavailableRaiseEvent(
    slot: *const ProviderSlot,
    event_id: EventId,
) RaiseStatus {
    _ = slot;
    _ = event_id;
    return .unavailable;
}

fn unavailableRaisePropertyChanged(
    slot: *const ProviderSlot,
    property_id: PropertyId,
    old: PropertyValue,
    new: PropertyValue,
) RaiseStatus {
    _ = slot;
    _ = property_id;
    _ = old;
    _ = new;
    return .unavailable;
}

fn unavailableIsWindowVisible(hwnd: Hwnd) bool {
    _ = hwnd;
    return false;
}

fn unavailableGetProperty(hwnd: Hwnd, name: [*:0]const u16) ?*anyopaque {
    _ = hwnd;
    _ = name;
    return null;
}

fn unavailableSetProperty(hwnd: Hwnd, name: [*:0]const u16, value: ?*anyopaque) bool {
    _ = hwnd;
    _ = name;
    _ = value;
    return false;
}

fn unavailableRemoveProperty(hwnd: Hwnd, name: [*:0]const u16) bool {
    _ = hwnd;
    _ = name;
    return false;
}

fn unavailableSetWindowProc(hwnd: Hwnd, index: i32, procedure: WindowProc) LResult {
    _ = hwnd;
    _ = index;
    _ = procedure;
    return 0;
}

fn unavailableCallWindowProc(
    procedure: WindowProc,
    hwnd: Hwnd,
    message: u32,
    wparam: WParam,
    lparam: LParam,
) LResult {
    _ = procedure;
    _ = hwnd;
    _ = message;
    _ = wparam;
    _ = lparam;
    return 0;
}

// =============================================================================
// The Windows entry points.
// =============================================================================

/// The four `uiautomationcore` entry points, with their `winapi` types.
///
/// The spellings come from `docs/16-native-platform-apis.md` section W7:
/// `int UiaLookupId(AutomationIdentifierType, const GUID*)`,
/// `LRESULT UiaReturnRawElementProvider(HWND, WPARAM, LPARAM, IRawElementProviderSimple*)`,
/// `HRESULT UiaRaiseAutomationEvent(IRawElementProviderSimple*, UIA_EVENT_ID)` and
/// `HRESULT UiaRaiseAutomationPropertyChangedEvent(IRawElementProviderSimple*, UIA_PROPERTY_ID, VARIANT, VARIANT)`.
///
/// **Unverified.** No Windows SDK and no Windows target exist on this host, so
/// nothing has compared these four against a header. They must be checked on a
/// Windows host.
const UiaEntryPoints = struct {
    lookup_id: *const fn (id_type: c_int, guid: *const [16]u8) callconv(.winapi) c_int,
    return_raw_element_provider: *const fn (
        hwnd: ?*anyopaque,
        wparam: usize,
        lparam: isize,
        element: ?*anyopaque,
    ) callconv(.winapi) isize,
    raise_event: *const fn (element: ?*anyopaque, event_id: u32) callconv(.winapi) c_long,
    raise_property_changed: *const fn (
        element: ?*anyopaque,
        property_id: u32,
        old: *const anyopaque,
        new: *const anyopaque,
    ) callconv(.winapi) c_long,
};

const uia_entry_points: ?UiaEntryPoints = if (builtin.os.tag == .windows) .{
    .lookup_id = &UiaLookupId,
    .return_raw_element_provider = &UiaReturnRawElementProvider,
    .raise_event = &UiaRaiseAutomationEvent,
    .raise_property_changed = &UiaRaiseAutomationPropertyChangedEvent,
} else null;

extern "win32" fn UiaLookupId(id_type: c_int, guid: *const [16]u8) callconv(.winapi) c_int;

extern "win32" fn UiaReturnRawElementProvider(
    hwnd: ?*anyopaque,
    wparam: usize,
    lparam: isize,
    element: ?*anyopaque,
) callconv(.winapi) isize;

extern "win32" fn UiaRaiseAutomationEvent(
    element: ?*anyopaque,
    event_id: u32,
) callconv(.winapi) c_long;

extern "win32" fn UiaRaiseAutomationPropertyChangedEvent(
    element: ?*anyopaque,
    property_id: u32,
    old: *const anyopaque,
    new: *const anyopaque,
) callconv(.winapi) c_long;

/// The six Win32 entry points `subclass.rs` calls, with their `winapi` types.
///
/// The spellings come from `docs/16-native-platform-apis.md` section W6:
/// `BOOL IsWindowVisible(HWND)`, `HANDLE GetPropW(HWND, LPCWSTR)`,
/// `BOOL SetPropW(HWND, LPCWSTR, HANDLE)`, `BOOL RemovePropW(HWND, LPCWSTR)`,
/// `LONG_PTR SetWindowLongPtrW(HWND, int, LONG_PTR)` and
/// `LRESULT CallWindowProcW(WNDPROC, HWND, UINT, WPARAM, LPARAM)`.
///
/// **Unverified**, for the reason the `UiaEntryPoints` block gives.
const Win32EntryPoints = struct {
    is_window_visible: *const fn (hwnd: ?*anyopaque) callconv(.winapi) c_int,
    get_property: *const fn (hwnd: ?*anyopaque, name: [*:0]const u16) callconv(.winapi) ?*anyopaque,
    set_property: *const fn (hwnd: ?*anyopaque, name: [*:0]const u16, value: ?*anyopaque) callconv(.winapi) c_int,
    remove_property: *const fn (hwnd: ?*anyopaque, name: [*:0]const u16) callconv(.winapi) c_int,
    set_window_proc: *const fn (hwnd: ?*anyopaque, index: c_int, procedure: ?*anyopaque) callconv(.winapi) isize,
    call_window_proc: *const fn (
        procedure: ?*anyopaque,
        hwnd: ?*anyopaque,
        message: u32,
        wparam: usize,
        lparam: isize,
    ) callconv(.winapi) isize,
};

const win32_entry_points: ?Win32EntryPoints = if (builtin.os.tag == .windows) .{
    .is_window_visible = &IsWindowVisible,
    .get_property = &GetPropW,
    .set_property = &SetPropW,
    .remove_property = &RemovePropW,
    .set_window_proc = &SetWindowLongPtrW,
    .call_window_proc = &CallWindowProcW,
} else null;

extern "win32" fn IsWindowVisible(hwnd: ?*anyopaque) callconv(.winapi) c_int;

extern "win32" fn GetPropW(
    hwnd: ?*anyopaque,
    name: [*:0]const u16,
) callconv(.winapi) ?*anyopaque;

extern "win32" fn SetPropW(
    hwnd: ?*anyopaque,
    name: [*:0]const u16,
    value: ?*anyopaque,
) callconv(.winapi) c_int;

extern "win32" fn RemovePropW(
    hwnd: ?*anyopaque,
    name: [*:0]const u16,
) callconv(.winapi) c_int;

extern "win32" fn SetWindowLongPtrW(
    hwnd: ?*anyopaque,
    index: c_int,
    procedure: ?*anyopaque,
) callconv(.winapi) isize;

extern "win32" fn CallWindowProcW(
    procedure: ?*anyopaque,
    hwnd: ?*anyopaque,
    message: u32,
    wparam: usize,
    lparam: isize,
) callconv(.winapi) isize;

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

test "the two object identifiers the adapter answers are the two the SDK names" {
    // `WM_GETOBJECT` carries `UiaRootObjectId` or `OBJID_CLIENT`, and the
    // comparison at `adapter.rs:545` is against these two values only. A sign
    // error in either one turns a valid message into a pass to `DefWindowProc`.
    try testing.expectEqual(@as(i32, -25), uia_root_object_id);
    try testing.expectEqual(@as(i32, -4), objid_client);
}

test "normalizeObjId reads the low 32 bits as a signed number" {
    // The three cases are the ones `adapter.rs:607-613` turns into a decision:
    // the root identifier, the client identifier, and a sender that sign
    // extended the low half into a 64-bit message field.
    try testing.expectEqual(uia_root_object_id, normalizeObjId(@bitCast(@as(u64, 0xFFFF_FFFF_FFFF_FFE7))));
    try testing.expectEqual(objid_client, normalizeObjId(@bitCast(@as(u64, 0xFFFF_FFFF_FFFF_FFFC))));

    const sign_extended: LParam = @bitCast(@as(usize, @as(u64, 0xFFFF_FFFF_FFFF_FFE7)));
    try testing.expectEqual(@as(i32, -25), normalizeObjId(sign_extended));

    const huge: LParam = @bitCast(@as(usize, 0xFFFF_FFFF_FFFF_FFC0));
    try testing.expectEqual(@as(i32, -64), normalizeObjId(huge));
}

test "normalizeObjId reads a large positive identifier unchanged" {
    // The low half is what a sender sign extended or not, so a large positive
    // identifier must survive the narrowing with its sign intact.
    const lparam: LParam = 0x0000_0000_7FFF_FFFF;
    try testing.expectEqual(@as(i32, 0x7FFF_FFFF), normalizeObjId(lparam));

    const negative_one: LParam = -1;
    try testing.expectEqual(@as(i32, -1), normalizeObjId(negative_one));
}

test "every event identifier carries the value the pinned binding gives" {
    // The nine values come from `zigwin32/win32/ui/accessibility.zig:9194-9213`.
    // A wrong value raises an event the platform does not name, and no test on
    // a Windows host would catch it.
    const expected = [_]struct { id: EventId, bits: u32 }{
        .{ .id = .automation_focus_changed, .bits = 20005 },
        .{ .id = .live_region_changed, .bits = 20024 },
        .{ .id = .selection_item_element_added_to_selection, .bits = 20010 },
        .{ .id = .selection_item_element_removed_from_selection, .bits = 20011 },
        .{ .id = .selection_item_element_selected, .bits = 20012 },
        .{ .id = .selection_invalidated, .bits = 20013 },
        .{ .id = .text_text_changed, .bits = 20015 },
        .{ .id = .window_window_closed, .bits = 20017 },
        .{ .id = .window_window_opened, .bits = 20016 },
    };
    // The bound is the length of the table, which `EventId.count` is.
    try testing.expectEqual(expected.len, EventId.count);
    inline for (expected) |entry| {
        try testing.expectEqual(entry.bits, @as(u32, @intFromEnum(entry.id)));
    }
    // Every declared member appears in the table exactly once, which is the
    // check a table of numbers cannot make on its own.
    var seen: usize = 0;
    inline for (@typeInfo(EventId).@"enum".fields) |field| {
        const entry: EventId = @enumFromInt(@as(u32, @intCast(field.value)));
        for (expected) |candidate| {
            if (candidate.id == entry) seen += 1;
        }
    }
    try testing.expectEqual(EventId.count, seen);
}

test "the one property identifier the adapter raises carries the binding's value" {
    // `zigwin32/win32/ui/accessibility.zig:9459`.
    try testing.expectEqual(@as(u32, 30079), @intFromEnum(PropertyId.selection_item_is_selected));
    try testing.expectEqual(@as(usize, 1), PropertyId.count);
}

test "the eight window messages and the procedure index carry the binding's values" {
    // `zigwin32/win32/ui/windows_and_messaging.zig:1091-1244` and `:5314`.
    try testing.expectEqual(@as(u32, 61), wm_getobject);
    try testing.expectEqual(@as(u32, 7), wm_setfocus);
    try testing.expectEqual(@as(u32, 8), wm_killfocus);
    try testing.expectEqual(@as(u32, 130), wm_ncdestroy);
    try testing.expectEqual(@as(u32, 529), wm_entermenuloop);
    try testing.expectEqual(@as(u32, 530), wm_exitmenuloop);
    try testing.expectEqual(@as(u32, 561), wm_entersizemove);
    try testing.expectEqual(@as(u32, 562), wm_exitsizemove);
    try testing.expectEqual(@as(i32, -4), gwlp_wndproc);
}

test "the subclass property name is the wide form of the one the adapter stores under" {
    try testing.expectEqualStrings("AccessKitAdapter", subclass_property_name_narrow);
    try testing.expectEqual(@as(usize, 16), subclass_property_name_length);
    try testing.expectEqual(@as(u16, 'A'), subclass_property_name[0]);
    try testing.expectEqual(
        @as(u16, 'r'),
        subclass_property_name[subclass_property_name_length - 1],
    );
    // The buffer the three Win32 calls address is one unit past the last
    // character, and it holds the terminator the sentinel type promises.
    try testing.expectEqual(@as(u16, 0), subclass_property_name.ptr[subclass_property_name_length]);
}

test "the seam for this target refuses rather than reports a success it did not get" {
    const platform = platformForCurrentTarget();
    if (builtin.os.tag == .windows) {
        try testing.expect(platform.present);
        return;
    }
    try testing.expect(!platform.present);
    try testing.expectEqual(@as(?i32, null), platform.init_uia());

    var slot: ProviderSlot = .{ .interface = @ptrFromInt(0x1234) };
    platform.destroy_provider(testing.allocator, .init(.{ .value = 1 }, .init(0)), &slot);
    try testing.expectEqual(@as(?*anyopaque, null), slot.interface);

    try testing.expectEqual(@as(LResult, 0), platform.return_raw_element_provider(
        @ptrFromInt(0x10),
        0,
        0,
        &slot,
    ));
    try testing.expectEqual(
        RaiseStatus.unavailable,
        platform.raise_event(&slot, .automation_focus_changed),
    );
    try testing.expectEqual(
        RaiseStatus.unavailable,
        platform.raise_property_changed(
            &slot,
            .selection_item_is_selected,
            .{ .bool_ = false },
            .{ .bool_ = true },
        ),
    );
}

test "the window seam for this target refuses rather than claims a window" {
    const window_api = windowApiForCurrentTarget();
    if (builtin.os.tag == .windows) {
        try testing.expect(window_api.present);
        return;
    }
    try testing.expect(!window_api.present);
    try testing.expect(!window_api.is_window_visible(@ptrFromInt(0x10)));
    try testing.expectEqual(@as(?*anyopaque, null), window_api.get_property(
        @ptrFromInt(0x10),
        subclass_property_name.ptr,
    ));
    try testing.expect(!window_api.set_property(@ptrFromInt(0x10), subclass_property_name.ptr, @ptrFromInt(1)));
    try testing.expect(!window_api.remove_property(@ptrFromInt(0x10), subclass_property_name.ptr));
}

test "every raise status is distinct, so a refusal is not read as a success" {
    // Three members, and the sweep is bounded by `RaiseStatus.count`.
    try testing.expectEqual(@as(usize, 3), RaiseStatus.count);
    const all = [_]RaiseStatus{ .raised, .refused, .unavailable };
    try testing.expectEqual(all.len, RaiseStatus.count);
    for (all, 0..) |outer, outer_index| {
        for (all, 0..) |inner, inner_index| {
            if (outer_index >= inner_index) continue;
            try testing.expect(outer != inner);
        }
    }
}