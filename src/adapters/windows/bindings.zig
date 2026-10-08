//! The Windows boundary, as types.
//!
//! **What this file is.** The whole UI Automation, Win32, COM and
//! `oleaut32` boundary of the Windows adapter, reached through
//! `marlersoft/zigwin32` at commit
//! `9f15c276b4e9d05afd34a10d8662a7dfc34647ea`. It declares no function body
//! and names no extern function, so every file that imports it analyses on
//! any host. The functions live in `syscalls.zig`, which is the only module in
//! this namespace that cannot be analysed off Windows.
//!
//! **Which rung of the binding ladder, and why.** Rung 2, a Zig package pinned
//! in `build.zig.zon`. `docs/42-native-adapter-build-map.md` section 2.1
//! settles this: `lib/std` has no UI Automation module, and zigwin32's
//! `build.zig` is seven lines that declare one module and open no header, so no
//! Windows SDK is needed to build it. The decision is made; this file records
//! it and does not reopen it.
//!
//! **Which feature groups are dead.** `docs/42` section 1.1.5 re-derives the
//! ten `windows` feature groups that `adapters/windows/Cargo.toml:28-39`
//! enables and finds **three** of them name nothing. `Win32_Graphics_Gdi` is
//! glob-imported at upstream `util.rs:21` and reaches no symbol, so it is the
//! only one of the three that also produces an unused-import warning.
//! `Win32_UI_Input_KeyboardAndMouse` and `Win32_System_LibraryLoader` are
//! enabled and never imported at all. The other seven are the whole boundary.
//! A port writes no declaration for a dead group, so this namespace has no
//! `graphics`, no `input` and no `library_loader` member.
//!
//! **What is asserted here, and what is not.** The size, the alignment, the
//! field offset and the vtable slot order of every type below are asserted at
//! compile time and are real: a change to the binding that moves any of them
//! fails the build. The **numeric value** of each UI Automation constant comes
//! from zigwin32 and is not re-derived here, because a port cannot check a
//! value against the header it did not read. What the census tests do check is
//! that every constant the adapter names is present, that no class repeats a
//! value, and that each class holds the count the map re-derived.
//!
//! **The five `UIA_*` aliases keep the vendor spelling and Z006 is exempt.**
//! `ControlTypeId`, `EventId`, `PatternId`, `PropertyId` and
//! `TextAttributeId` are this file's names for `UIA_CONTROLTYPE_ID`,
//! `UIA_EVENT_ID`, `UIA_PATTERN_ID`, `UIA_PROPERTY_ID` and
//! `UIA_TEXTATTRIBUTE_ID`. Z006 asks for `snake_case` here because it reads a
//! vendor spelling that carries underscores as a declaration this package made,
//! so it cannot tell an alias from a variable. The alias is the only thing that
//! ties the row to `AK/windows/src/util.rs`, so the spelling is kept and the
//! finding is recorded here instead. `ziglint/src/Linter.zig:2362` is the
//! matcher and `:3385` `isTypeAlias` is the half that misses it.

const std = @import("std");
const builtin = @import("builtin");

/// Whether this compiler and target can express a `callconv(.winapi)`
/// function pointer, which every vtable field in the pinned binding is.
///
/// Measured with Zig 0.16.0 on this host, one `zig test --test-no-exec` per
/// architecture, reading the first error of each:
///
/// | Architecture | What the compiler does |
/// |---|---|
/// | `x86_64-linux` | compiles |
/// | `aarch64-linux` | no `aarch64_aapcs_win` in `stage2_llvm` |
/// | `powerpc64-linux` | `error: reached unreachable code` at `lib/std/builtin.zig:137` |
/// | `riscv64-linux` | the same `unreachable` |
/// | `x86-linux` | accepts the convention, then fails the 64-bit layout assertions in this file |
///
/// The `aarch64-linux` diagnostic in full is `error: calling convention
/// 'aarch64_aapcs_win' not supported by compiler backend 'stage2_llvm'`.
///
/// `lib/std/builtin.zig:132-138` gives `winapi` a value for four
/// architectures: `x86_64`, `x86`, `aarch64` and `thumb`. Two of those four
/// do not survive contact with the compiler. `stage2_llvm` has no
/// `aarch64_aapcs_win`, and a 32-bit `x86` target fails the layout block
/// below, which asserts 64-bit sizes. So this value is measured and is `true`
/// for `x86_64` alone.
///
/// **What this costs, stated as an admission.** Every test below that reads
/// a `VTable` is scoped to this value, so on `aarch64-linux` and
/// `powerpc64-linux` it answers `error.SkipZigTest` and the runner counts it
/// as skipped. Those two rows of `cross-test.profile.sh` therefore do not
/// execute the vtable code at all. They still compile every other statement
/// of this file, still run the other four tests, and still catch every
/// defect that is not a calling convention.
pub const winapi_resolves = builtin.cpu.arch == .x86_64;

/// The pinned binding package. `build.zig.zon` must name it `win32`.
pub const win32 = @import("win32");

/// The UI Automation namespace. Upstream reaches it as
/// `windows::Win32::UI::Accessibility`; zigwin32 spells it
/// `win32.ui.accessibility` (`zigwin32/win32.zig:20`).
pub const uia = win32.ui.accessibility;

/// The COM namespace, which carries `VARIANT`, `SAFEARRAY`, `BSTR` and
/// `HRESULT`.
pub const com = win32.system.com;

/// The Windows messaging namespace, which carries the ten `WM_*` values, the
/// window properties and the three property helpers the adapter calls.
pub const wm = win32.ui.windows_and_messaging;

// --- Native value and identifier types -------------------------------------

/// `VARIANT`, the automation value union. Upstream `util.rs:116`.
pub const Variant = com.VARIANT;
/// `SAFEARRAY`, the bounded array automation passes by pointer.
pub const SafeArray = com.SAFEARRAY;
/// `BSTR`, a counted wide string. zigwin32 spells it `*u16`
/// (`zigwin32/win32/everything.zig:330`).
pub const Bstr = *u16;
/// `HRESULT`, a status code. zigwin32 spells it a `packed struct (u32)` with a
/// `failed` field (`zigwin32/win32/zig.zig`), not an integer newtype.
pub const Hresult = win32.zig.HRESULT;
/// `HWND`, a window handle. zigwin32 spells it `*opaque {}`
/// (`zigwin32/win32/foundation.zig:6668`).
pub const Hwnd = win32.foundation.HWND;
/// `HANDLE`, an opaque system handle.
pub const Handle = win32.foundation.HANDLE;
/// `POINT`, the two signed 32-bit coordinates of a screen position.
pub const Point = win32.foundation.POINT;

/// `LPARAM`, the signed pointer-sized window message parameter. The binding
/// keeps the name private to `windows_and_messaging.zig` and declares it as
/// `LONG_PTR` (`zigwin32/win32/ui/windows_and_messaging.zig:5704`), so the port
/// declares it here and `syscalls.zig` checks the two agree at compile time.
pub const Lparam = isize;
/// `WPARAM`, the unsigned pointer-sized window message parameter.
pub const Wparam = usize;
/// `LRESULT`, the signed pointer-sized window procedure result.
pub const Lresult = isize;

/// `BOOL`, a Win32 boolean. zigwin32 spells it `i32`
/// (`zigwin32/win32/zig.zig`), so `0` is false and every other value is true.
pub const Bool = i32;

/// `UIA_CONTROLTYPE_ID`, the control type of a node.
pub const ControlTypeId = uia.UIA_CONTROLTYPE_ID;
/// `UIA_EVENT_ID`, a UI Automation event.
pub const EventId = uia.UIA_EVENT_ID;
/// `UIA_PATTERN_ID`, a control pattern.
pub const PatternId = uia.UIA_PATTERN_ID;
/// `UIA_PROPERTY_ID`, a property a provider answers.
pub const PropertyId = uia.UIA_PROPERTY_ID;
/// `UIA_TEXTATTRIBUTE_ID`, a text run attribute.
pub const TextAttributeId = uia.UIA_TEXTATTRIBUTE_ID;

/// `LiveSetting`, how loudly a live region announces itself.
pub const LiveSetting = uia.LiveSetting;
/// `ToggleState`, the three states of a toggle.
pub const ToggleState = uia.ToggleState;
/// `ExpandCollapseState`, the four states of an expandable node.
pub const ExpandCollapseState = uia.ExpandCollapseState;
/// `CaretPosition`, where the caret sits in a line.
pub const CaretPosition = uia.CaretPosition;
/// `NavigateDirection`, the six directions of a directional traversal.
pub const NavigateDirection = uia.NavigateDirection;
/// `HorizontalTextAlignment`, the four alignments of a text run.
pub const HorizontalTextAlignment = uia.HorizontalTextAlignment;
/// `TextDecorationLineStyle`, the five underline styles.
pub const TextDecorationLineStyle = uia.TextDecorationLineStyle;
/// `OrientationType`, whether a control scrolls horizontally or vertically.
pub const OrientationType = uia.OrientationType;
/// `UiaRect`, the four `f64` bounds of a node.
pub const UiaRect = uia.UiaRect;
/// `UiaPoint`, the two `f64` coordinates of a hit-test result.
pub const UiaPoint = uia.UiaPoint;

/// `TextUnit`, the granularity a text movement walks in. Upstream also names
/// `SupportedTextSelection`, whose two values the adapter passes as the
/// `move` flag of `ITextProvider::GetSelection`. It is `i32` in the SDK, so
/// this namespace declares it as the integer it is.
pub const TextUnit = uia.TextUnit;
/// `SupportedTextSelection`, the two values of the text `move` flag.
pub const SupportedTextSelection = i32;
/// `TextPatternRangeEndpoint`, which end of a range an endpoint names.
pub const TextPatternRangeEndpoint = uia.TextPatternRangeEndpoint;

// --- COM interfaces --------------------------------------------------------

/// `IUnknown`, referenced at upstream `node.rs:1050`, `:1426` and
/// `util.rs:356` and never implemented. It is the base of every other
/// interface, so every vtable below begins with its three slots.
pub const IUnknown = com.IUnknown;

/// `IRawElementProviderSimple`, the identity of a node.
pub const IRawElementProviderSimple = uia.IRawElementProviderSimple;
/// `IRawElementProviderFragment`, the fragment side of a node.
pub const IRawElementProviderFragment = uia.IRawElementProviderFragment;
/// `IRawElementProviderFragmentRoot`, the root of a fragment tree.
pub const IRawElementProviderFragmentRoot = uia.IRawElementProviderFragmentRoot;
/// `IToggleProvider`, the toggle pattern.
pub const IToggleProvider = uia.IToggleProvider;
/// `IInvokeProvider`, the invoke pattern.
pub const IInvokeProvider = uia.IInvokeProvider;
/// `IValueProvider`, the value pattern.
pub const IValueProvider = uia.IValueProvider;
/// `IRangeValueProvider`, the range value pattern.
pub const IRangeValueProvider = uia.IRangeValueProvider;
/// `IScrollItemProvider`, the scroll item pattern.
pub const IScrollItemProvider = uia.IScrollItemProvider;
/// `ISelectionItemProvider`, the selection item pattern.
pub const ISelectionItemProvider = uia.ISelectionItemProvider;
/// `ISelectionProvider`, the selection pattern.
pub const ISelectionProvider = uia.ISelectionProvider;
/// `ITextProvider`, the text pattern.
pub const ITextProvider = uia.ITextProvider;
/// `ITextRangeProvider`, the text range's complete native COM contract.
pub const ITextRangeProvider = uia.ITextRangeProvider;
/// `IExpandCollapseProvider`, the expand collapse pattern.
pub const IExpandCollapseProvider = uia.IExpandCollapseProvider;
/// `IWindowProvider`, the window pattern. Upstream implements it on the node
/// provider in `node.rs:790-804`. The port implements it on the element in
/// `node.zig`.
pub const IWindowProvider = uia.IWindowProvider;

/// Every interface the adapter implements, in the order
/// `docs/42-native-adapter-build-map.md` section 1.1.2 lists them.
pub const implemented_interfaces = [_]type{
    IRawElementProviderSimple,
    IRawElementProviderFragment,
    IRawElementProviderFragmentRoot,
    IToggleProvider,
    IInvokeProvider,
    IValueProvider,
    IRangeValueProvider,
    IScrollItemProvider,
    ISelectionItemProvider,
    ISelectionProvider,
    ITextProvider,
    ITextRangeProvider,
    IExpandCollapseProvider,
    IWindowProvider,
};

// --- The constant census ---------------------------------------------------

/// The class a named constant belongs to. The fourteen classes are the rows
/// of `docs/42-native-adapter-build-map.md` section 1.1.3 minus the two rows
/// that hold types rather than values.
pub const ConstantClass = enum {
    /// A `UIA_*PropertyId` value. 41 of them.
    property_id,
    /// A `UIA_*ControlTypeId` value. 33 of them, including the two irregular
    /// names `UIA_TabControlTypeId` and `UIA_TabItemControlTypeId`, which drop
    /// the `Control` infix.
    control_type_id,
    /// A `UIA_*PatternId` value. 10 of them.
    pattern_id,
    /// A `UIA_*AttributeId` value. 18 of them.
    text_attribute_id,
    /// A `UIA_*EventId` value. 10 of them.
    event_id,
    /// A `UIA_E_*` status code. 4 of them.
    status_code,
    /// One of the five other UI Automation constants.
    other_uia,
    /// A window message, a window property or an object identifier. 12 of them.
    window_message,
    /// A `TextUnit_*` value. 7 of them.
    text_unit,
    /// A `TextPatternRangeEndpoint_*` value. 2 of them.
    range_endpoint,
    /// A value of one of the nine enumerated types. 31 of them.
    named_enum_value,
    /// A `VT_*` variant type. 4 of them.
    variant_type,
    /// An `HRESULT` code with no `UIA_` prefix. 3 of them.
    hresult_code,
    /// A globalization flag. 1 of them.
    globalization_flag,
};

/// One named constant of the census. The port writes the name of every one of
/// these somewhere, and this table is where the census lives.
pub const Constant = struct {
    /// The class the count is taken over.
    class: ConstantClass,
    /// The header spelling, which is the name upstream writes.
    name: [:0]const u8,
};

/// How many constants each class holds. `docs/42` re-derived each of these
/// from the pinned upstream tree rather than from a summary line, and the
/// tests below fail if a ported class stops matching.
pub const class_count = [_]struct { class: ConstantClass, count: usize }{
    .{ .class = .property_id, .count = 41 },
    .{ .class = .control_type_id, .count = 33 },
    .{ .class = .pattern_id, .count = 10 },
    .{ .class = .text_attribute_id, .count = 18 },
    .{ .class = .event_id, .count = 10 },
    .{ .class = .status_code, .count = 4 },
    .{ .class = .other_uia, .count = 5 },
    .{ .class = .window_message, .count = 12 },
    .{ .class = .text_unit, .count = 7 },
    .{ .class = .range_endpoint, .count = 2 },
    .{ .class = .named_enum_value, .count = 31 },
    .{ .class = .variant_type, .count = 4 },
    .{ .class = .hresult_code, .count = 3 },
    .{ .class = .globalization_flag, .count = 1 },
};

/// Every constant the adapter names, grouped by class. A row here is a claim
/// that the port reaches for this name, so the sweep below is a check on the
/// port and not on the binding.
pub const constants = [_]Constant{
    // 41 property identifiers.
    .{ .class = .property_id, .name = "UIA_AriaPropertiesPropertyId" },
    .{ .class = .property_id, .name = "UIA_AriaRolePropertyId" },
    .{ .class = .property_id, .name = "UIA_AutomationIdPropertyId" },
    .{ .class = .property_id, .name = "UIA_ClassNamePropertyId" },
    .{ .class = .property_id, .name = "UIA_ControlTypePropertyId" },
    .{ .class = .property_id, .name = "UIA_ControllerForPropertyId" },
    .{ .class = .property_id, .name = "UIA_CulturePropertyId" },
    .{ .class = .property_id, .name = "UIA_ExpandCollapseExpandCollapseStatePropertyId" },
    .{ .class = .property_id, .name = "UIA_FrameworkIdPropertyId" },
    .{ .class = .property_id, .name = "UIA_FullDescriptionPropertyId" },
    .{ .class = .property_id, .name = "UIA_HasKeyboardFocusPropertyId" },
    .{ .class = .property_id, .name = "UIA_HelpTextPropertyId" },
    .{ .class = .property_id, .name = "UIA_IsContentElementPropertyId" },
    .{ .class = .property_id, .name = "UIA_IsControlElementPropertyId" },
    .{ .class = .property_id, .name = "UIA_IsDialogPropertyId" },
    .{ .class = .property_id, .name = "UIA_IsEnabledPropertyId" },
    .{ .class = .property_id, .name = "UIA_IsKeyboardFocusablePropertyId" },
    .{ .class = .property_id, .name = "UIA_IsPasswordPropertyId" },
    .{ .class = .property_id, .name = "UIA_IsRequiredForFormPropertyId" },
    .{ .class = .property_id, .name = "UIA_LevelPropertyId" },
    .{ .class = .property_id, .name = "UIA_LiveSettingPropertyId" },
    .{ .class = .property_id, .name = "UIA_LocalizedControlTypePropertyId" },
    .{ .class = .property_id, .name = "UIA_NamePropertyId" },
    .{ .class = .property_id, .name = "UIA_NativeWindowHandlePropertyId" },
    .{ .class = .property_id, .name = "UIA_OrientationPropertyId" },
    .{ .class = .property_id, .name = "UIA_PositionInSetPropertyId" },
    .{ .class = .property_id, .name = "UIA_ProviderDescriptionPropertyId" },
    .{ .class = .property_id, .name = "UIA_RangeValueIsReadOnlyPropertyId" },
    .{ .class = .property_id, .name = "UIA_RangeValueLargeChangePropertyId" },
    .{ .class = .property_id, .name = "UIA_RangeValueMaximumPropertyId" },
    .{ .class = .property_id, .name = "UIA_RangeValueMinimumPropertyId" },
    .{ .class = .property_id, .name = "UIA_RangeValueSmallChangePropertyId" },
    .{ .class = .property_id, .name = "UIA_RangeValueValuePropertyId" },
    .{ .class = .property_id, .name = "UIA_SelectionCanSelectMultiplePropertyId" },
    .{ .class = .property_id, .name = "UIA_SelectionIsSelectionRequiredPropertyId" },
    .{ .class = .property_id, .name = "UIA_SelectionItemIsSelectedPropertyId" },
    .{ .class = .property_id, .name = "UIA_SizeOfSetPropertyId" },
    .{ .class = .property_id, .name = "UIA_ToggleToggleStatePropertyId" },
    .{ .class = .property_id, .name = "UIA_ValueIsReadOnlyPropertyId" },
    .{ .class = .property_id, .name = "UIA_ValueValuePropertyId" },
    .{ .class = .property_id, .name = "UIA_WindowIsModalPropertyId" },
    // 33 control types.
    .{ .class = .control_type_id, .name = "UIA_ButtonControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_CheckBoxControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_ComboBoxControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_CustomControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_DataGridControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_DataItemControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_DocumentControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_EditControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_GroupControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_HyperlinkControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_ImageControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_ListControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_ListItemControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_MenuBarControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_MenuControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_MenuItemControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_PaneControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_ProgressBarControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_RadioButtonControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_ScrollBarControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_SeparatorControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_SliderControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_SpinnerControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_StatusBarControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_TabControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_TabItemControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_TableControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_TextControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_ToolBarControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_ToolTipControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_TreeControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_TreeItemControlTypeId" },
    .{ .class = .control_type_id, .name = "UIA_WindowControlTypeId" },
    // 10 pattern identifiers.
    .{ .class = .pattern_id, .name = "UIA_ExpandCollapsePatternId" },
    .{ .class = .pattern_id, .name = "UIA_InvokePatternId" },
    .{ .class = .pattern_id, .name = "UIA_RangeValuePatternId" },
    .{ .class = .pattern_id, .name = "UIA_ScrollItemPatternId" },
    .{ .class = .pattern_id, .name = "UIA_SelectionItemPatternId" },
    .{ .class = .pattern_id, .name = "UIA_SelectionPatternId" },
    .{ .class = .pattern_id, .name = "UIA_TextPatternId" },
    .{ .class = .pattern_id, .name = "UIA_TogglePatternId" },
    .{ .class = .pattern_id, .name = "UIA_ValuePatternId" },
    .{ .class = .pattern_id, .name = "UIA_WindowPatternId" },
    // 18 text attribute identifiers.
    .{ .class = .text_attribute_id, .name = "UIA_BackgroundColorAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_CaretPositionAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_CultureAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_FontNameAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_FontSizeAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_FontWeightAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_ForegroundColorAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_HorizontalTextAlignmentAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_IsItalicAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_IsReadOnlyAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_IsSubscriptAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_IsSuperscriptAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_OverlineColorAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_OverlineStyleAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_StrikethroughColorAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_StrikethroughStyleAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_UnderlineColorAttributeId" },
    .{ .class = .text_attribute_id, .name = "UIA_UnderlineStyleAttributeId" },
    // 10 event identifiers.
    .{ .class = .event_id, .name = "UIA_AutomationFocusChangedEventId" },
    .{ .class = .event_id, .name = "UIA_LiveRegionChangedEventId" },
    .{ .class = .event_id, .name = "UIA_SelectionItem_ElementAddedToSelectionEventId" },
    .{ .class = .event_id, .name = "UIA_SelectionItem_ElementRemovedFromSelectionEventId" },
    .{ .class = .event_id, .name = "UIA_SelectionItem_ElementSelectedEventId" },
    .{ .class = .event_id, .name = "UIA_Selection_InvalidatedEventId" },
    .{ .class = .event_id, .name = "UIA_Text_TextChangedEventId" },
    .{ .class = .event_id, .name = "UIA_Text_TextSelectionChangedEventId" },
    .{ .class = .event_id, .name = "UIA_Window_WindowClosedEventId" },
    .{ .class = .event_id, .name = "UIA_Window_WindowOpenedEventId" },
    // 4 UI Automation status codes.
    .{ .class = .status_code, .name = "UIA_E_ELEMENTNOTAVAILABLE" },
    .{ .class = .status_code, .name = "UIA_E_ELEMENTNOTENABLED" },
    .{ .class = .status_code, .name = "UIA_E_INVALIDOPERATION" },
    .{ .class = .status_code, .name = "UIA_E_NOTSUPPORTED" },
    // The 5 other UI Automation constants.
    .{ .class = .other_uia, .name = "UiaRootObjectId" },
    .{ .class = .other_uia, .name = "UiaAppendRuntimeId" },
    .{ .class = .other_uia, .name = "ControlType_Property_GUID" },
    .{ .class = .other_uia, .name = "AutomationIdentifierType_Property" },
    .{ .class = .other_uia, .name = "ProviderOptions_ServerSideProvider" },
    // 12 window message and state constants.
    .{ .class = .window_message, .name = "WM_GETOBJECT" },
    .{ .class = .window_message, .name = "WM_GETTEXT" },
    .{ .class = .window_message, .name = "WM_GETTEXTLENGTH" },
    .{ .class = .window_message, .name = "WM_SETFOCUS" },
    .{ .class = .window_message, .name = "WM_KILLFOCUS" },
    .{ .class = .window_message, .name = "WM_NCDESTROY" },
    .{ .class = .window_message, .name = "WM_ENTERMENULOOP" },
    .{ .class = .window_message, .name = "WM_EXITMENULOOP" },
    .{ .class = .window_message, .name = "WM_ENTERSIZEMOVE" },
    .{ .class = .window_message, .name = "WM_EXITSIZEMOVE" },
    .{ .class = .window_message, .name = "GWLP_WNDPROC" },
    .{ .class = .window_message, .name = "OBJID_CLIENT" },
    // 7 text unit values.
    .{ .class = .text_unit, .name = "TextUnit_Character" },
    .{ .class = .text_unit, .name = "TextUnit_Document" },
    .{ .class = .text_unit, .name = "TextUnit_Format" },
    .{ .class = .text_unit, .name = "TextUnit_Line" },
    .{ .class = .text_unit, .name = "TextUnit_Page" },
    .{ .class = .text_unit, .name = "TextUnit_Paragraph" },
    .{ .class = .text_unit, .name = "TextUnit_Word" },
    // 2 range endpoint values.
    .{ .class = .range_endpoint, .name = "TextPatternRangeEndpoint_Start" },
    .{ .class = .range_endpoint, .name = "TextPatternRangeEndpoint_End" },
    // 31 values of the nine enumerated types.
    .{ .class = .named_enum_value, .name = "LiveSetting.Off" },
    .{ .class = .named_enum_value, .name = "LiveSetting.Polite" },
    .{ .class = .named_enum_value, .name = "LiveSetting.Assertive" },
    .{ .class = .named_enum_value, .name = "ToggleState.Off" },
    .{ .class = .named_enum_value, .name = "ToggleState.On" },
    .{ .class = .named_enum_value, .name = "ToggleState.Indeterminate" },
    .{ .class = .named_enum_value, .name = "ExpandCollapseState.Collapsed" },
    .{ .class = .named_enum_value, .name = "ExpandCollapseState.Expanded" },
    .{ .class = .named_enum_value, .name = "ExpandCollapseState.PartiallyExpanded" },
    .{ .class = .named_enum_value, .name = "CaretPosition.Unknown" },
    .{ .class = .named_enum_value, .name = "CaretPosition.EndOfLine" },
    .{ .class = .named_enum_value, .name = "CaretPosition.BeginningOfLine" },
    .{ .class = .named_enum_value, .name = "SupportedTextSelection.None" },
    .{ .class = .named_enum_value, .name = "SupportedTextSelection.Final" },
    .{ .class = .named_enum_value, .name = "NavigateDirection.Parent" },
    .{ .class = .named_enum_value, .name = "NavigateDirection.NextSibling" },
    .{ .class = .named_enum_value, .name = "NavigateDirection.PreviousSibling" },
    .{ .class = .named_enum_value, .name = "NavigateDirection.FirstChild" },
    .{ .class = .named_enum_value, .name = "NavigateDirection.LastChild" },
    .{ .class = .named_enum_value, .name = "HorizontalTextAlignment.Left" },
    .{ .class = .named_enum_value, .name = "HorizontalTextAlignment.Centered" },
    .{ .class = .named_enum_value, .name = "HorizontalTextAlignment.Right" },
    .{ .class = .named_enum_value, .name = "HorizontalTextAlignment.Justified" },
    .{ .class = .named_enum_value, .name = "TextDecorationLineStyle.None" },
    .{ .class = .named_enum_value, .name = "TextDecorationLineStyle.Dotted" },
    .{ .class = .named_enum_value, .name = "TextDecorationLineStyle.Dashed" },
    .{ .class = .named_enum_value, .name = "TextDecorationLineStyle.Double" },
    .{ .class = .named_enum_value, .name = "TextDecorationLineStyle.Solid" },
    .{ .class = .named_enum_value, .name = "OrientationType.None" },
    .{ .class = .named_enum_value, .name = "OrientationType.Horizontal" },
    .{ .class = .named_enum_value, .name = "OrientationType.Vertical" },
    // 4 variant types.
    .{ .class = .variant_type, .name = "VT_I4" },
    .{ .class = .variant_type, .name = "VT_R8" },
    .{ .class = .variant_type, .name = "VT_UNKNOWN" },
    .{ .class = .variant_type, .name = "VT_ARRAY" },
    // 3 HRESULT codes with no prefix.
    .{ .class = .hresult_code, .name = "E_FAIL" },
    .{ .class = .hresult_code, .name = "E_INVALIDARG" },
    .{ .class = .hresult_code, .name = "E_NOTIMPL" },
    // The one globalization flag.
    .{ .class = .globalization_flag, .name = "LOCALE_ALLOW_NEUTRAL_NAMES" },
};

// --- The layout assertions -------------------------------------------------

/// The pointer width of the target this file was compiled for. Every COM
/// interface is one pointer wide, so this is the size the layout sweep below
/// checks them against.
pub const pointer_size = @sizeOf(usize);

comptime {
    // Each interface must remain one vtable word. COM object thunks depend
    // on this declared layout. This does not prove a native SDK or client ABI.
    for (implemented_interfaces) |Interface| {
        std.debug.assert(@sizeOf(Interface) == pointer_size);
        std.debug.assert(@alignOf(Interface) == @alignOf(usize));
        const info = @typeInfo(Interface).@"union";
        std.debug.assert(info.fields.len == 2);
        std.debug.assert(std.mem.eql(u8, info.fields[0].name, "vtable"));
        std.debug.assert(info.fields[0].type == *const Interface.VTable);
        std.debug.assert(std.mem.eql(u8, info.fields[1].name, "IUnknown"));
        std.debug.assert(info.fields[1].type == IUnknown);
    }

    // The automation value is 24 bytes and 8-byte aligned in this binding, not
    // the 16 bytes the SDK documents. The extra eight bytes come from the
    // `DECIMAL` arm of the outer union, which the binding models at its full
    // size. `variant.zig` writes the inner arms, so it must allocate 24 and
    // must not assume the documented 16.
    std.debug.assert(@sizeOf(Variant) == 24);
    std.debug.assert(@alignOf(Variant) == 8);
    std.debug.assert(@offsetOf(Variant, "Anonymous") == 0);

    // The automation value has three nesting levels: the outer union, the
    // header of the tag and the three reserved words, then the payload union.
    // The offsets below are the addresses `variant.zig` writes, so they are the
    // load-bearing part of the layout.
    const VariantArm = @typeInfo(Variant).@"struct".fields[0].type;
    const VariantArms = @typeInfo(VariantArm).@"union";
    std.debug.assert(VariantArms.fields.len == 2);
    std.debug.assert(std.mem.eql(u8, VariantArms.fields[0].name, "Anonymous"));
    const VariantHead = VariantArms.fields[0].type;
    std.debug.assert(@offsetOf(VariantHead, "vt") == 0);
    std.debug.assert(@offsetOf(VariantHead, "wReserved1") == 2);
    std.debug.assert(@offsetOf(VariantHead, "wReserved2") == 4);
    std.debug.assert(@offsetOf(VariantHead, "wReserved3") == 6);
    std.debug.assert(@offsetOf(VariantHead, "Anonymous") == 8);

    // `SAFEARRAY` is a real struct in this binding, not an opaque one. The port
    // only ever holds a pointer to it and never reads through it, so the
    // offsets are recorded to make the 64-bit shape explicit and to catch a
    // binding change before a client dereferences it.
    std.debug.assert(@sizeOf(SafeArray) == 32);
    std.debug.assert(@alignOf(SafeArray) == 8);
    std.debug.assert(@offsetOf(SafeArray, "cDims") == 0);
    std.debug.assert(@offsetOf(SafeArray, "pvData") == 16);
    std.debug.assert(@offsetOf(SafeArray, "rgsabound") == 24);

    // `HRESULT` is a packed 32-bit code in this binding, not an integer
    // newtype, so `error_codes.zig` has to bit-cast in both directions. Its
    // alignment is whatever a packed struct gets, so the port never places one
    // on its own.
    std.debug.assert(@sizeOf(Hresult) == 4);
    std.debug.assert(@bitSizeOf(Hresult) == 32);
    std.debug.assert(@hasField(Hresult, "failed"));

    // `BOOL` is `i32` in this binding. A Win32 boolean is 32 bits wide, so a
    // port that reached for `bool` would write the wrong width across the ABI.
    std.debug.assert(@sizeOf(Bool) == 4);
    std.debug.assert(@alignOf(Bool) == 4);

    // The five enumerated id types are all 32-bit and 32-bit aligned. The
    // adapter stores them in `VARIANT` arms, so the width is not free.
    for (.{ ControlTypeId, EventId, PatternId, PropertyId, TextAttributeId }) |Id| {
        std.debug.assert(@sizeOf(Id) == 4);
        std.debug.assert(@alignOf(Id) == 4);
    }

    // `UiaRect` and `UiaPoint` are the double-precision shapes. The port reads
    // and writes them field by field, so a change of layout is a change of
    // meaning.
    std.debug.assert(@sizeOf(UiaRect) == 32);
    std.debug.assert(@alignOf(UiaRect) == 8);
    std.debug.assert(@offsetOf(UiaRect, "left") == 0);
    std.debug.assert(@offsetOf(UiaRect, "top") == 8);
    std.debug.assert(@offsetOf(UiaRect, "width") == 16);
    std.debug.assert(@offsetOf(UiaRect, "height") == 24);
    std.debug.assert(@sizeOf(UiaPoint) == 16);
    std.debug.assert(@alignOf(UiaPoint) == 8);
    std.debug.assert(@offsetOf(UiaPoint, "x") == 0);
    std.debug.assert(@offsetOf(UiaPoint, "y") == 8);

    // `POINT` is two signed 32-bit coordinates and nothing else. `ClientToScreen`
    // writes it, so the field order is the ABI.
    std.debug.assert(@sizeOf(Point) == 8);
    std.debug.assert(@alignOf(Point) == 4);
    std.debug.assert(@offsetOf(Point, "x") == 0);
    std.debug.assert(@offsetOf(Point, "y") == 4);

    // `HWND` is an opaque pointer. `ClientToScreen` and the four property
    // helpers all take it by value, so the width is the whole of the contract.
    std.debug.assert(@sizeOf(Hwnd) == pointer_size);

    // The three window message types are pointer sized and signed where the
    // SDK says so. `subclass.zig` packs and unpacks `LPARAM` in place.
    std.debug.assert(@sizeOf(Lparam) == pointer_size);
    std.debug.assert(@sizeOf(Wparam) == pointer_size);
    std.debug.assert(@sizeOf(Lresult) == pointer_size);
}

// --- Tests -----------------------------------------------------------------

test "every constant class holds the count the map re-derived" {
    var total: usize = 0;
    inline for (class_count) |entry| {
        var seen: usize = 0;
        for (constants) |constant| {
            if (constant.class == entry.class) seen += 1;
        }
        try std.testing.expectEqual(entry.count, seen);
        total += seen;
    }
    try std.testing.expectEqual(@as(usize, 181), total);
}

test "no constant name repeats inside a class" {
    for (constants, 0..) |outer, outer_index| {
        for (constants, 0..) |inner, inner_index| {
            if (outer_index >= inner_index) continue;
            if (outer.class != inner.class) continue;
            try std.testing.expect(!std.mem.eql(u8, outer.name, inner.name));
        }
    }
}

test "implemented interfaces are distinct COM interfaces" {
    // The skip is the `else` branch and the work is the body, so the body is
    // not analysed on an architecture that cannot express `.winapi`.
    if (comptime winapi_resolves) {
        inline for (implemented_interfaces, 0..) |outer, outer_index| {
            std.debug.assert(@hasDecl(outer, "VTable"));
            try std.testing.expectEqual(@as(usize, 0), @offsetOf(outer.VTable, "base"));
            inline for (implemented_interfaces, 0..) |inner, inner_index| {
                if (outer_index >= inner_index) continue;
                try std.testing.expect(outer != inner);
            }
        }
    } else return error.SkipZigTest;
}

test "every vtable begins with the three IUnknown slots" {
    if (comptime winapi_resolves) {
        const unknown = @typeInfo(IUnknown.VTable).@"struct";
        try std.testing.expectEqual(@as(usize, 3), unknown.fields.len);
        try std.testing.expectEqualStrings("QueryInterface", unknown.fields[0].name);
        try std.testing.expectEqualStrings("AddRef", unknown.fields[1].name);
        try std.testing.expectEqualStrings("Release", unknown.fields[2].name);
        inline for (implemented_interfaces) |Interface| {
            const info = @typeInfo(Interface.VTable).@"struct";
            std.debug.assert(info.fields.len >= 1);
            // One base plus at least one method. `IInvokeProvider` and
            // `IScrollItemProvider` carry exactly one, so the lower bound is
            // two.
            try std.testing.expect(info.fields.len >= 2);
            try std.testing.expectEqualStrings("base", info.fields[0].name);
            try std.testing.expectEqual(@as(usize, 0), @offsetOf(Interface.VTable, "base"));
        }
    } else return error.SkipZigTest;
}

test "every implemented vtable names its slots in the order COM dispatches" {
    // The slot order is the calling convention for that interface. A binding
    // that renames or reorders a field silently moves every thunk, and the
    // failure appears on a screen reader rather than in a build, so the names
    // and the order are pinned here against the values measured from the
    // binding on this host.
    if (comptime winapi_resolves) {
        const Expected = struct { Interface: type, slots: []const []const u8 };
        const expected = [_]Expected{
            .{
                .Interface = IRawElementProviderSimple,
                .slots = &.{
                    "get_ProviderOptions",
                    "GetPatternProvider",
                    "GetPropertyValue",
                    "get_HostRawElementProvider",
                },
            },
            .{
                .Interface = IRawElementProviderFragment,
                .slots = &.{
                    "Navigate",
                    "GetRuntimeId",
                    "get_BoundingRectangle",
                    "GetEmbeddedFragmentRoots",
                    "SetFocus",
                    "get_FragmentRoot",
                },
            },
            .{
                .Interface = IRawElementProviderFragmentRoot,
                .slots = &.{ "ElementProviderFromPoint", "GetFocus" },
            },
            .{
                .Interface = IToggleProvider,
                .slots = &.{ "Toggle", "get_ToggleState" },
            },
            .{
                .Interface = IInvokeProvider,
                .slots = &.{"Invoke"},
            },
            .{
                .Interface = IValueProvider,
                .slots = &.{ "SetValue", "get_Value", "get_IsReadOnly" },
            },
            .{
                .Interface = IRangeValueProvider,
                .slots = &.{
                    "SetValue",
                    "get_Value",
                    "get_IsReadOnly",
                    "get_Maximum",
                    "get_Minimum",
                    "get_LargeChange",
                    "get_SmallChange",
                },
            },
            .{
                .Interface = IScrollItemProvider,
                .slots = &.{"ScrollIntoView"},
            },
            .{
                .Interface = ISelectionItemProvider,
                .slots = &.{
                    "Select",
                    "AddToSelection",
                    "RemoveFromSelection",
                    "get_IsSelected",
                    "get_SelectionContainer",
                },
            },
            .{
                .Interface = ISelectionProvider,
                .slots = &.{
                    "GetSelection",
                    "get_CanSelectMultiple",
                    "get_IsSelectionRequired",
                },
            },
            .{
                .Interface = ITextProvider,
                .slots = &.{
                    "GetSelection",
                    "GetVisibleRanges",
                    "RangeFromChild",
                    "RangeFromPoint",
                    "get_DocumentRange",
                    "get_SupportedTextSelection",
                },
            },
            .{
                .Interface = ITextRangeProvider,
                .slots = &.{
                    "Clone", "Compare", "CompareEndpoints", "ExpandToEnclosingUnit",
                    "FindAttribute", "FindText", "GetAttributeValue",
                    "GetBoundingRectangles", "GetEnclosingElement", "GetText",
                    "Move", "MoveEndpointByUnit", "MoveEndpointByRange",
                    "Select", "AddToSelection", "RemoveFromSelection",
                    "ScrollIntoView", "GetChildren",
                },
            },
            .{
                .Interface = IExpandCollapseProvider,
                .slots = &.{ "Expand", "Collapse", "get_ExpandCollapseState" },
            },
            .{
                .Interface = IWindowProvider,
                .slots = &.{
                    "SetVisualState",
                    "Close",
                    "WaitForInputIdle",
                    "get_CanMaximize",
                    "get_CanMinimize",
                    "get_IsModal",
                    "get_WindowVisualState",
                    "get_WindowInteractionState",
                    "get_IsTopmost",
                },
            },
        };
        inline for (expected) |entry| {
            const info = @typeInfo(entry.Interface.VTable).@"struct";
            try std.testing.expectEqual(entry.slots.len, info.fields.len - 1);
            inline for (entry.slots, 0..) |name, index| {
                try std.testing.expectEqualStrings(name, info.fields[index + 1].name);
            }
        }
    } else return error.SkipZigTest;
}

test "the fourteen interfaces preserve all native method slots" {
    if (comptime winapi_resolves) {
        var total: usize = 0;
        inline for (implemented_interfaces) |Interface| {
            total += @typeInfo(Interface.VTable).@"struct".fields.len - 1;
        }
        try std.testing.expectEqual(
            @as(usize, 4 + 6 + 2 + 2 + 1 + 3 + 7 + 1 + 5 + 3 + 6 + 18 + 3 + 9),
            total,
        );
    } else return error.SkipZigTest;
}

test "text range provider keeps the full native COM vtable" {
    if (!winapi_resolves) return error.SkipZigTest;
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(ITextRangeProvider));
    try std.testing.expectEqual(21 * @sizeOf(usize), @sizeOf(ITextRangeProvider.VTable));
    try std.testing.expectEqual(3 * @sizeOf(usize), @offsetOf(ITextRangeProvider.VTable, "Clone"));
    try std.testing.expectEqual(20 * @sizeOf(usize), @offsetOf(ITextRangeProvider.VTable, "GetChildren"));
}
