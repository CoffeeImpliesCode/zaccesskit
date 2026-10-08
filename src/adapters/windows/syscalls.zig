//! Callable Windows UI Automation, window-procedure, and automation-value boundaries.
//!
//! Native wrappers use the pinned zigwin32 declarations. Injectable function
//! tables let portable tests exercise event delivery without a Windows host.
//! Property events borrow raw VARIANT values. Their queue owns cleanup.
//! Provider construction uses the context factory and propagates its failures.
//!
//! Off Windows, platform calls report unavailable and the native automation
//! table is absent. Injected tests are not proof of native Windows behavior.
//! Native linking, COM clients, and resource ownership need Windows verification.
//! This module adds no production loop.

const std = @import("std");
const builtin = @import("builtin");

const boundary = @import("../../capi/boundary.zig");
const consumer = @import("../../consumer/root.zig");
const bindings = @import("bindings.zig");
const context = @import("context.zig");
const util = @import("util.zig");

const FullNodeId = consumer.tree_index.FullNodeId;

/// The window handle the adapter is bound to. One declaration, in
/// `src/capi/boundary.zig`, which is the leaf both sides import.
pub const Hwnd = boundary.Hwnd;
/// `WPARAM`, the unsigned message field of a window message.
pub const WParam = boundary.WParam;
/// `LPARAM`, the signed message field of a window message.
pub const LParam = boundary.LParam;
/// `LRESULT`, the signed result of a window procedure.
pub const LResult = isize;

/// Windows callbacks use the native convention. Portable injected callbacks
/// use the host C convention.
pub const window_proc_callconv: std.builtin.CallingConvention =
    if (builtin.os.tag == .windows) .winapi else .c;
/// The callback installed by the subclass and passed to CallWindowProcW.
pub const WindowProc = *const fn (
    hwnd: Hwnd,
    message: u32,
    wparam: WParam,
    lparam: LParam,
) callconv(window_proc_callconv) LResult;

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
    /// `UIA_Text_TextSelectionChangedEventId`, raised by the text provider.
    text_text_selection_changed = 20014,
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
    aria_properties = @intFromEnum(bindings.uia.UIA_AriaPropertiesPropertyId),
    aria_role = @intFromEnum(bindings.uia.UIA_AriaRolePropertyId),
    automation_id = @intFromEnum(bindings.uia.UIA_AutomationIdPropertyId),
    class_name = @intFromEnum(bindings.uia.UIA_ClassNamePropertyId),
    control_type = @intFromEnum(bindings.uia.UIA_ControlTypePropertyId),
    controller_for = @intFromEnum(bindings.uia.UIA_ControllerForPropertyId),
    culture = @intFromEnum(bindings.uia.UIA_CulturePropertyId),
    expand_collapse_expand_collapse_state =
        @intFromEnum(bindings.uia.UIA_ExpandCollapseExpandCollapseStatePropertyId),
    framework_id = @intFromEnum(bindings.uia.UIA_FrameworkIdPropertyId),
    full_description = @intFromEnum(bindings.uia.UIA_FullDescriptionPropertyId),
    has_keyboard_focus = @intFromEnum(bindings.uia.UIA_HasKeyboardFocusPropertyId),
    help_text = @intFromEnum(bindings.uia.UIA_HelpTextPropertyId),
    is_content_element = @intFromEnum(bindings.uia.UIA_IsContentElementPropertyId),
    is_control_element = @intFromEnum(bindings.uia.UIA_IsControlElementPropertyId),
    is_dialog = @intFromEnum(bindings.uia.UIA_IsDialogPropertyId),
    is_enabled = @intFromEnum(bindings.uia.UIA_IsEnabledPropertyId),
    is_keyboard_focusable = @intFromEnum(bindings.uia.UIA_IsKeyboardFocusablePropertyId),
    is_password = @intFromEnum(bindings.uia.UIA_IsPasswordPropertyId),
    is_required_for_form = @intFromEnum(bindings.uia.UIA_IsRequiredForFormPropertyId),
    level = @intFromEnum(bindings.uia.UIA_LevelPropertyId),
    live_setting = @intFromEnum(bindings.uia.UIA_LiveSettingPropertyId),
    localized_control_type = @intFromEnum(bindings.uia.UIA_LocalizedControlTypePropertyId),
    name = @intFromEnum(bindings.uia.UIA_NamePropertyId),
    native_window_handle = @intFromEnum(bindings.uia.UIA_NativeWindowHandlePropertyId),
    orientation = @intFromEnum(bindings.uia.UIA_OrientationPropertyId),
    position_in_set = @intFromEnum(bindings.uia.UIA_PositionInSetPropertyId),
    provider_description = @intFromEnum(bindings.uia.UIA_ProviderDescriptionPropertyId),
    range_value_is_read_only = @intFromEnum(bindings.uia.UIA_RangeValueIsReadOnlyPropertyId),
    range_value_large_change = @intFromEnum(bindings.uia.UIA_RangeValueLargeChangePropertyId),
    range_value_maximum = @intFromEnum(bindings.uia.UIA_RangeValueMaximumPropertyId),
    range_value_minimum = @intFromEnum(bindings.uia.UIA_RangeValueMinimumPropertyId),
    range_value_small_change = @intFromEnum(bindings.uia.UIA_RangeValueSmallChangePropertyId),
    range_value_value = @intFromEnum(bindings.uia.UIA_RangeValueValuePropertyId),
    selection_can_select_multiple = @intFromEnum(bindings.uia.UIA_SelectionCanSelectMultiplePropertyId),
    selection_is_selection_required = @intFromEnum(bindings.uia.UIA_SelectionIsSelectionRequiredPropertyId),
    selection_item_is_selected = @intFromEnum(bindings.uia.UIA_SelectionItemIsSelectedPropertyId),
    size_of_set = @intFromEnum(bindings.uia.UIA_SizeOfSetPropertyId),
    toggle_toggle_state = @intFromEnum(bindings.uia.UIA_ToggleToggleStatePropertyId),
    value_is_read_only = @intFromEnum(bindings.uia.UIA_ValueIsReadOnlyPropertyId),
    value_value = @intFromEnum(bindings.uia.UIA_ValueValuePropertyId),
    window_is_modal = @intFromEnum(bindings.uia.UIA_WindowIsModalPropertyId),

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
///
/// **The units are built as UTF-16 code units, not read out of little-endian
/// bytes.** `std.unicode.utf8ToUtf16LeStringLiteral` answers a pointer to a
/// little-endian-encoded array, and coercing that to `u16` reinterprets its
/// bytes as native. On the `powerpc64-linux` row of `cross-test.profile.sh`
/// that byte-swaps every unit: `0x4100` where the name starts with `0x0041`,
/// which is the `expected 65, found 16640` this test reported. The name is
/// ASCII, so building the units directly is endian-neutral by construction and
/// there is no byte order left to get wrong on either row.
///
/// A global slice pointing into a `var` declared inside a `blk` block is a
/// reference to a comptime var, which this compiler rejects. `asciiUnits`
/// therefore returns an **array**, and the slice is taken from a global
/// `const`, which is an ordinary constant.
///
/// **A byte above `0x7f` would need a real encoder.** The check is comptime so
/// that mistake is a build error rather than a mojibake property name on a live
/// window.
fn asciiUnits(comptime text: []const u8) [text.len + 1]u16 {
    var units: [text.len + 1]u16 = undefined;
    for (text, 0..) |byte, index| {
        if (byte > 0x7f) @compileError("this name is ASCII; a non-ASCII byte needs an encoder");
        units[index] = byte;
    }
    units[text.len] = 0;
    return units;
}

/// The name is spelled once and its length derived from it, so the slice below
/// cannot disagree with the buffer it slices.
const subclass_property_name_text = "AccessKitAdapter";

pub const subclass_property_name: [:0]const u16 =
    asciiUnits(subclass_property_name_text)[0..subclass_property_name_text.len :0];

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

/// A stable registry slot. Registry and queued events own references to this
/// slot; the slot owns one COM reference until its final release.
pub const ProviderSlot = struct {
    ref_count: std.atomic.Value(u32) = .init(1),
    /// Null identifies the unspecified placeholder root.
    node_id: ?FullNodeId = null,
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
    old: bindings.Variant,
    new: bindings.Variant,
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

    /// Builds a provider from the borrowed context. The slot must be empty.
    /// Failure leaves it unchanged. The factory consumes its cloned weak
    /// reference only on success. slot.node_id selects a node or placeholder root.
    create_provider: *const fn (
        gpa: std.mem.Allocator,
        weak: context.WeakContext,
        node_id: FullNodeId,
        slot: *ProviderSlot,
    ) context.ProviderError!void,

    /// Releases what `create_provider` wrote into `slot`.
    destroy_provider: *const fn (
        gpa: std.mem.Allocator,
        node_id: FullNodeId,
        slot: *ProviderSlot,
    ) void,

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

    /// Raises a property change. Both raw VARIANTs are borrowed for this call;
    /// the queue retains ownership and clears them after delivery or cancellation.
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
    if (builtin.os.tag != .windows) return null;
    return platformWithEntryPoints(.{
        .lookup_id = &bindings.win32.uiautomationcore.UiaLookupId,
        .return_raw_element_provider = &bindings.win32.uiautomationcore.UiaReturnRawElementProvider,
        .raise_event = &bindings.win32.uiautomationcore.UiaRaiseAutomationEvent,
        .raise_property_changed = &bindings.win32.uiautomationcore.UiaRaiseAutomationPropertyChangedEvent,
    });
}

fn platformWithEntryPoints(comptime entry: UiaEntryPoints) Platform {
    return .{
        .present = true,
        .init_uia = struct {
            fn call() ?i32 {
                return entry.lookup_id(.Property, &bindings.uia.ControlType_Property_GUID);
            }
        }.call,
        .create_provider = nativeCreateProvider,
        .destroy_provider = nativeDestroyProvider,
        .return_raw_element_provider = struct {
            fn call(
                hwnd: Hwnd,
                wparam: WParam,
                lparam: LParam,
                slot: *const ProviderSlot,
            ) LResult {
                return entry.return_raw_element_provider(@ptrCast(hwnd), wparam, lparam, simple(slot));
            }
        }.call,
        .raise_event = struct {
            fn call(slot: *const ProviderSlot, event_id: EventId) RaiseStatus {
                const provider = simple(slot) orelse return .refused;
                const result = entry.raise_event(provider, @enumFromInt(@intFromEnum(event_id)));
                return if (!result.failed) .raised else .refused;
            }
        }.call,
        .raise_property_changed = struct {
            fn call(
                slot: *const ProviderSlot,
                property_id: PropertyId,
                old: bindings.Variant,
                new: bindings.Variant,
            ) RaiseStatus {
                const provider = simple(slot) orelse return .refused;
                const result = entry.raise_property_changed(
                    provider,
                    @enumFromInt(@intFromEnum(property_id)),
                    old,
                    new,
                );
                return if (!result.failed) .raised else .refused;
            }
        }.call,
    };
}

fn simple(slot: *const ProviderSlot) ?*bindings.IRawElementProviderSimple {
    return @ptrCast(@alignCast(slot.interface));
}

fn nativeCreateProvider(
    gpa: std.mem.Allocator,
    weak: context.WeakContext,
    node_id: FullNodeId,
    slot: *ProviderSlot,
) context.ProviderError!void {
    _ = gpa;
    _ = node_id;
    std.debug.assert(slot.interface == null);
    slot.interface = try weak.createNode(slot.node_id);
}

fn nativeDestroyProvider(
    gpa: std.mem.Allocator,
    node_id: FullNodeId,
    slot: *ProviderSlot,
) void {
    _ = gpa;
    _ = node_id;
    if (simple(slot)) |provider| {
        slot.interface = null;
        _ = provider.vtable.base.Release(@ptrCast(provider));
    }
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
    if (builtin.os.tag != .windows) return null;
    return .{
        .present = true,
        .is_window_visible = struct {
            fn call(hwnd: Hwnd) bool {
                return bindings.win32.user32.IsWindowVisible(@ptrCast(hwnd)) != 0;
            }
        }.call,
        .get_property = struct {
            fn call(hwnd: Hwnd, name: [*:0]const u16) ?*anyopaque {
                return @ptrCast(bindings.win32.user32.GetPropW(@ptrCast(hwnd), name));
            }
        }.call,
        .set_property = struct {
            fn call(hwnd: Hwnd, name: [*:0]const u16, value: ?*anyopaque) bool {
                return bindings.win32.user32.SetPropW(
                    @ptrCast(hwnd),
                    name,
                    @ptrCast(value),
                ) != 0;
            }
        }.call,
        .remove_property = struct {
            fn call(hwnd: Hwnd, name: [*:0]const u16) bool {
                return bindings.win32.user32.RemovePropW(@ptrCast(hwnd), name) != null;
            }
        }.call,
        .set_window_proc = struct {
            fn call(hwnd: Hwnd, index: i32, procedure: WindowProc) LResult {
                return bindings.win32.windowlongptr.SetWindowLongPtrW(
                    @ptrCast(hwnd),
                    @enumFromInt(index),
                    @bitCast(@intFromPtr(procedure)),
                );
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
                return bindings.win32.user32.CallWindowProcW(
                    @ptrCast(procedure),
                    @ptrCast(hwnd),
                    message,
                    wparam,
                    lparam,
                );
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
    weak: context.WeakContext,
    node_id: FullNodeId,
    slot: *ProviderSlot,
) context.ProviderError!void {
    _ = gpa;
    _ = weak;
    _ = node_id;
    _ = slot;
    return error.NotImplemented;
}

fn unavailableDestroyProvider(
    gpa: std.mem.Allocator,
    node_id: FullNodeId,
    slot: *ProviderSlot,
) void {
    if (comptime bindings.winapi_resolves or builtin.os.tag == .windows) {
        nativeDestroyProvider(gpa, node_id, slot);
    } else {
        std.debug.assert(slot.interface == null);
    }
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
    old: bindings.Variant,
    new: bindings.Variant,
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

/// Native types come directly from zigwin32, including by-value VARIANTs.
/// This source mapping does not replace a Windows-native ABI and client check.
const UiaEntryPoints = struct {
    lookup_id: @TypeOf(&bindings.win32.uiautomationcore.UiaLookupId),
    return_raw_element_provider: @TypeOf(&bindings.win32.uiautomationcore.UiaReturnRawElementProvider),
    raise_event: @TypeOf(&bindings.win32.uiautomationcore.UiaRaiseAutomationEvent),
    raise_property_changed: @TypeOf(&bindings.win32.uiautomationcore.UiaRaiseAutomationPropertyChangedEvent),
};

/// The complete native value backend, borrowed for the provider lifetime.
/// Null means this target cannot call Windows APIs.
pub fn nativeAutomationApi() ?*const util.AutomationApi {
    if (builtin.os.tag != .windows) return null;
    return &native_automation_api;
}

const native_automation_api: util.AutomationApi = .{
    .alloc_string_len = struct {
        fn call(_: ?*anyopaque, source: ?[*]const u16, length: u32) ?bindings.Bstr {
            // SysAllocStringLen reads the explicit count, not a sentinel.
            return @ptrCast(bindings.win32.oleaut32.SysAllocStringLen(@ptrCast(source), length));
        }
    }.call,
    .string_len = struct {
        fn call(_: ?*anyopaque, value: bindings.Bstr) u32 {
            return bindings.win32.oleaut32.SysStringLen(@ptrCast(value));
        }
    }.call,
    .free_string = struct {
        fn call(_: ?*anyopaque, value: bindings.Bstr) void {
            bindings.win32.oleaut32.SysFreeString(@ptrCast(value));
        }
    }.call,
    .variant_clear = struct {
        fn call(_: ?*anyopaque, value: *bindings.Variant) bindings.Hresult {
            return bindings.win32.oleaut32.VariantClear(value);
        }
    }.call,
    .array_create_vector = struct {
        fn call(_: ?*anyopaque, kind: u16, lower_bound: i32, count: u32) ?*bindings.SafeArray {
            return bindings.win32.oleaut32.SafeArrayCreateVector(
                @enumFromInt(kind),
                lower_bound,
                count,
            );
        }
    }.call,
    .array_put_element = struct {
        fn call(
            _: ?*anyopaque,
            array: *bindings.SafeArray,
            index: *const i32,
            value: *const anyopaque,
        ) bindings.Hresult {
            return bindings.win32.oleaut32.SafeArrayPutElement(
                array,
                @constCast(index),
                @constCast(value),
            );
        }
    }.call,
    .array_destroy = struct {
        fn call(_: ?*anyopaque, array: *bindings.SafeArray) bindings.Hresult {
            return bindings.win32.oleaut32.SafeArrayDestroy(array);
        }
    }.call,
    .host_provider_from_hwnd = struct {
        fn call(
            _: ?*anyopaque,
            hwnd: bindings.Hwnd,
            output: *?*bindings.IRawElementProviderSimple,
        ) bindings.Hresult {
            return bindings.win32.uiautomationcore.UiaHostProviderFromHwnd(hwnd, output);
        }
    }.call,
    .reserved_mixed_value = struct {
        fn call(_: ?*anyopaque, output: *?*bindings.IUnknown) bindings.Hresult {
            return bindings.win32.uiautomationcore.UiaGetReservedMixedAttributeValue(output);
        }
    }.call,
    .reserved_not_supported_value = struct {
        fn call(_: ?*anyopaque, output: *?*bindings.IUnknown) bindings.Hresult {
            return bindings.win32.uiautomationcore.UiaGetReservedNotSupportedValue(output);
        }
    }.call,
    .locale_name_to_lcid = struct {
        fn call(_: ?*anyopaque, name: [*:0]const u16, flags: u32) u32 {
            return bindings.win32.kernel32.LocaleNameToLCID(name, flags);
        }
    }.call,
    .client_to_screen = struct {
        fn call(_: ?*anyopaque, hwnd: bindings.Hwnd, point: *bindings.Point) bindings.Bool {
            return bindings.win32.user32.ClientToScreen(hwnd, point);
        }
    }.call,
    .def_window_proc = struct {
        fn call(
            _: ?*anyopaque,
            hwnd: bindings.Hwnd,
            message: u32,
            wparam: bindings.Wparam,
            lparam: bindings.Lparam,
        ) bindings.Lresult {
            return bindings.win32.user32.DefWindowProcW(hwnd, message, wparam, lparam);
        }
    }.call,
};

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
    try testing.expectEqual(
        uia_root_object_id,
        normalizeObjId(@bitCast(@as(u64, 0xFFFF_FFFF_FFFF_FFE7))),
    );
    try testing.expectEqual(
        objid_client,
        normalizeObjId(@bitCast(@as(u64, 0xFFFF_FFFF_FFFF_FFFC))),
    );

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
        .{ .id = .text_text_selection_changed, .bits = 20014 },
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

test "selection property belongs to the complete provider property domain" {
    // `zigwin32/win32/ui/accessibility.zig:9459`.
    try testing.expectEqual(@as(u32, 30079), @intFromEnum(PropertyId.selection_item_is_selected));
    try testing.expectEqual(@as(usize, 41), PropertyId.count);
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

    var slot: ProviderSlot = .{ .interface = null };
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
            std.mem.zeroes(bindings.Variant),
            std.mem.zeroes(bindings.Variant),
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
    try testing.expect(!window_api.set_property(
        @ptrFromInt(0x10),
        subclass_property_name.ptr,
        @ptrFromInt(1),
    ));
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

test "complete node property events use the upstream UIA property domain" {
    try testing.expectEqual(@as(u32, 30005), @intFromEnum(PropertyId.name));
    try testing.expectEqual(@as(u32, 30003), @intFromEnum(PropertyId.control_type));
    try testing.expectEqual(@as(u32, 30159), @intFromEnum(PropertyId.full_description));
    try testing.expectEqual(@as(u32, 30174), @intFromEnum(PropertyId.is_dialog));
    try testing.expectEqual(@as(u32, 30079), @intFromEnum(PropertyId.selection_item_is_selected));
    try testing.expectEqual(@as(u32, 30086), @intFromEnum(PropertyId.toggle_toggle_state));
    try testing.expectEqual(@as(u32, 20014), @intFromEnum(EventId.text_text_selection_changed));
}

test "native BSTR preserves embedded NUL and VariantClear transfers cleanup" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const api = nativeAutomationApi().?;
    const units = [_]u16{ 'a', 0, 'b' };
    const value = api.alloc_string_len(api.context, &units, units.len) orelse
        return error.OutOfMemory;
    var raw_value = std.mem.zeroes(bindings.Variant);
    raw_value.Anonymous.Anonymous.vt = .BSTR;
    raw_value.Anonymous.Anonymous.Anonymous.bstrVal = value;
    defer {
        const result = api.variant_clear(api.context, &raw_value);
        if (result.failed) @panic("native VariantClear failed");
    }
    try testing.expectEqual(@as(u32, 3), api.string_len(api.context, value));
    try testing.expectEqualSlices(u16, &units, @as([*]const u16, @ptrCast(value))[0..3]);
    const result = api.variant_clear(api.context, &raw_value);
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(result)));
    try testing.expectEqual(bindings.com.VARENUM.EMPTY, raw_value.Anonymous.Anonymous.vt);
}

test "native SAFEARRAY stores scalar data and preserves invalid-index HRESULT" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const api = nativeAutomationApi().?;
    const array = api.array_create_vector(api.context, 3, 0, 1) orelse
        return error.OutOfMemory;
    defer {
        const result = api.array_destroy(api.context, array);
        if (result.failed) @panic("native SafeArrayDestroy failed");
    }
    const index: i32 = 0;
    const input: i32 = -23;
    const inserted = api.array_put_element(api.context, array, &index, &input);
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(inserted)));
    var output: i32 = 0;
    const fetched = bindings.win32.oleaut32.SafeArrayGetElement(
        array,
        @constCast(&index),
        &output,
    );
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(fetched)));
    try testing.expectEqual(input, output);
    const invalid_index: i32 = 1;
    const rejected = api.array_put_element(api.context, array, &invalid_index, &input);
    try testing.expectEqual(@as(u32, 0x8002000b), @as(u32, @bitCast(rejected)));
}

test "native provider factory failure preserves slot and borrowed context" {
    if (!bindings.winapi_resolves) return error.SkipZigTest;
    const adapter = @import("adapter.zig");
    const Failure = struct {
        fn create(_: std.mem.Allocator, _: context.WeakContext, _: ?FullNodeId) context.ProviderError!*bindings.IRawElementProviderSimple {
            return error.OutOfMemory;
        }
        fn action(_: *boundary.CActionRequest, _: ?*anyopaque) callconv(.c) void {
            @panic("provider construction must not dispatch an action");
        }
    };
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var abi = util.AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    var factory = adapter.testProviderFactory();
    factory.create_node = Failure.create;
    const owner = try adapter.WindowsAdapter.create(testing.allocator, .{
        .io = threaded.io(),
        .platform = unavailablePlatform(),
        .factory = factory,
        .automation = &api,
        .hwnd = null,
        .is_window_focused = false,
        .action_sink = .{ .c = .{ .callback = Failure.action, .userdata = null } },
    });
    defer owner.deinit();
    var weak = owner.context.weak();
    defer weak.deinit();
    var slot: ProviderSlot = .{ .interface = null };
    try testing.expectError(error.NotImplemented, unavailableCreateProvider(
        testing.allocator,
        weak,
        .init(.{ .value = 1 }, .init(0)),
        &slot,
    ));
    try testing.expectError(error.OutOfMemory, nativeCreateProvider(
        testing.allocator,
        weak,
        .init(.{ .value = 1 }, .init(0)),
        &slot,
    ));
    try testing.expectEqual(@as(?*anyopaque, null), slot.interface);
    var lease = try weak.control.enter();
    lease.deinit();
}

test "native provider Release reclaims its weak context after adapter destruction" {
    if (!bindings.winapi_resolves) return error.SkipZigTest;
    const adapter = @import("adapter.zig");
    const Callback = struct {
        fn action(_: *boundary.CActionRequest, _: ?*anyopaque) callconv(.c) void {
            @panic("provider construction must not dispatch an action");
        }
    };
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var abi = util.AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    const owner = try adapter.WindowsAdapter.create(testing.allocator, .{
        .io = threaded.io(),
        .platform = unavailablePlatform(),
        .factory = adapter.testProviderFactory(),
        .automation = &api,
        .hwnd = null,
        .is_window_focused = false,
        .action_sink = .{ .c = .{ .callback = Callback.action, .userdata = null } },
    });
    var weak = owner.context.weak();
    var slot: ProviderSlot = .{ .interface = null };
    nativeCreateProvider(
        testing.allocator,
        weak,
        .init(.{ .value = 1 }, .init(0)),
        &slot,
    ) catch |err| {
        weak.deinit();
        owner.deinit();
        return err;
    };
    defer weak.deinit();
    owner.deinit();
    defer nativeDestroyProvider(
        testing.allocator,
        .init(.{ .value = 1 }, .init(0)),
        &slot,
    );
    var closed_slot: ProviderSlot = .{ .interface = null };
    try testing.expectError(error.ElementNotAvailable, nativeCreateProvider(
        testing.allocator,
        weak,
        .init(.{ .value = 2 }, .init(0)),
        &closed_slot,
    ));
    try testing.expectEqual(@as(?*anyopaque, null), closed_slot.interface);
    try testing.expect(slot.interface != null);
    const provider = simple(&slot).?;
    try testing.expectEqual(@as(u32, 2), provider.vtable.base.AddRef(@ptrCast(provider)));
    try testing.expectEqual(@as(u32, 1), provider.vtable.base.Release(@ptrCast(provider)));
    try testing.expectEqual(@as(u32, 2), provider.vtable.base.AddRef(@ptrCast(provider)));
    unavailableDestroyProvider(testing.allocator, .init(.{ .value = 1 }, .init(0)), &slot);
    const remaining = provider.vtable.base.Release(@ptrCast(provider));
    // Clean the old implementation's leaked slot reference before reporting red.
    if (remaining != 0) {
        _ = provider.vtable.base.Release(@ptrCast(provider));
    }
    try testing.expectEqual(@as(u32, 0), remaining);
    try testing.expectEqual(@as(?*anyopaque, null), slot.interface);
}

test "native reserved text attributes remain distinct COM values" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try util.checkAutomationStatus(bindings.win32.ole32.CoInitializeEx(null, .{}));
    defer bindings.win32.ole32.CoUninitialize();
    const api = nativeAutomationApi().?;
    var mixed: ?*bindings.IUnknown = null;
    try util.checkAutomationStatus(api.reserved_mixed_value(api.context, &mixed));
    const mixed_value = mixed orelse return error.UnexpectedNativeFailure;
    defer {
        _ = mixed_value.vtable.Release(mixed_value);
    }
    var unsupported: ?*bindings.IUnknown = null;
    try util.checkAutomationStatus(api.reserved_not_supported_value(api.context, &unsupported));
    const unsupported_value = unsupported orelse return error.UnexpectedNativeFailure;
    defer {
        _ = unsupported_value.vtable.Release(unsupported_value);
    }
    try testing.expect(mixed_value != unsupported_value);
}

test "native locale conversion preserves the English US culture identifier" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const api = nativeAutomationApi().?;
    const english_us = [_:0]u16{ 'e', 'n', '-', 'U', 'S' };
    try testing.expectEqual(
        @as(u32, 0x0409),
        api.locale_name_to_lcid(api.context, &english_us, 0),
    );
}

test "unavailable provider destruction releases its COM holder" {
    if (!bindings.winapi_resolves) return error.SkipZigTest;
    const com_object = @import("com.zig");
    const State = struct {
        finalized: *u32,
        pub fn deinit(self: *@This()) void {
            self.finalized.* += 1;
        }
    };
    const Object = com_object.Object(State, .{com_object.Descriptor{
        .Interface = bindings.IRawElementProviderSimple,
        .Iid = bindings.uia.IID_IRawElementProviderSimple,
    }});
    const base = Object.baseVTable(0);
    var finalized: u32 = 0;
    // Only IUnknown methods are called, as in com.zig's base-vtable fixtures.
    const object = try Object.create(testing.allocator, .{&base}, .{ .finalized = &finalized });
    const unknown: *bindings.IUnknown = &object.words[0];
    try testing.expectEqual(@as(u32, 2), unknown.vtable.AddRef(unknown));
    var slot: ProviderSlot = .{ .interface = unknown };
    unavailableDestroyProvider(testing.allocator, .init(.{ .value = 1 }, .init(0)), &slot);
    const remaining = unknown.vtable.Release(unknown);
    if (remaining != 0) {
        _ = unknown.vtable.Release(unknown);
    }
    try testing.expectEqual(@as(u32, 0), remaining);
    try testing.expectEqual(@as(u32, 1), finalized);
    try testing.expectEqual(@as(?*anyopaque, null), slot.interface);
}

test "native UIA preload resolves the control type GUID" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const platform = windowsPlatform().?;
    try testing.expectEqual(@as(?i32, 30003), platform.init_uia());
}
