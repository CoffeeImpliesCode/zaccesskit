# 16. Native platform APIs: Windows, macOS, iOS, Android

Consumed by `docs/30-port-design.md`, then by `docs/40-plan.md`.

**Corrected on 2026-10-05.** Twelve figures in this document did not survive
measurement against the pinned upstream tree, and all twelve are corrected
below. Eight come from `docs/42-native-adapter-build-map.md`, which re-derived
its census from the source rather than from this document; four were settled in
the same pass and are marked A1 to A4. Section 12 holds the full record: what
the old claim was, what is true, and the measurement or `path:line` that settles
it.

## Scope and path convention

This document lists every Win32, UI Automation, Objective-C, AppKit, UIKit and JNI
symbol that the four platform adapters in the AccessKit tree touch. It records
what each symbol does and where the adapter calls it. It then states what a Zig
port can and cannot verify on the build host.

All source citations below use this prefix:

```
AK = /tmp/scratch/accesskit/adapters
```

So `AK/windows/src/node.rs:1064` means line 1064 of that file. The checkout is
at commit `466e24e252103f4d82bd6fbab98141b551e46e0c`, crate `accesskit` 0.25.1.

Line counts for the files that matter, from `wc -l`:

| File | Lines |
|---|---|
| `AK/windows/src/node.rs` | 1539 |
| `AK/windows/src/text.rs` | 652 |
| `AK/windows/src/adapter.rs` | 673 |
| `AK/windows/src/util.rs` | 536 |
| `AK/macos/src/node.rs` | 1367 |
| `AK/ios/src/node.rs` | 1076 |
| `AK/android/src/adapter.rs` | 906 |

Crate versions from each `Cargo.toml`:

| Crate | Path | Version | Main external dependency |
|---|---|---|---|
| `accesskit_windows` | `AK/windows/Cargo.toml:3` | 0.35.1 | `windows` 0.62.0 (`Cargo.toml:27`) |
| `accesskit_macos` | `AK/macos/Cargo.toml:3` | 0.27.1 | `objc2` 0.5.1 (`Cargo.toml:21`) |
| `accesskit_ios` | `AK/ios/Cargo.toml:3` | 0.2.1 | `objc2-ui-kit` 0.2.0 (`Cargo.toml:31`) |
| `accesskit_android` | `AK/android/Cargo.toml:3` | 0.9.0 | `jni` 0.21.1 (`Cargo.toml:21`) |

The Windows crate enables ten `windows` feature groups, listed at
`AK/windows/Cargo.toml:28-39`. Seven of the ten are used: `Win32_Foundation`,
`Win32_Globalization`, `Win32_System_Com`, `Win32_System_Ole`,
`Win32_System_Variant`, `Win32_UI_Accessibility` and
`Win32_UI_WindowsAndMessaging`. Three enable nothing, so a Zig port drops all
three:

- `Win32_Graphics_Gdi`. A grep for `HDC`, `HGDIOBJ`, `COLORREF`, `HRGN`,
  `MoveToEx`, `CreateCompatibleDC` and `GetDeviceCaps` over the nine files under
  `AK/windows/src/` returns nothing. The group is glob-imported at
  `AK/windows/src/util.rs:19`, so it is the only one of the three that produces
  an unused-import warning.
- `Win32_UI_Input_KeyboardAndMouse`. A grep for `VK_`, `KEYBDINPUT`,
  `MOUSEINPUT`, `SendInput`, `GetKeyState` and `GetAsyncKeyState` over the nine
  files returns nothing, and no file imports the group.
- `Win32_System_LibraryLoader`. A grep for `LoadLibraryW`, `GetProcAddress`,
  `FreeLibrary` and `GetModuleHandleW` over the nine files returns nothing. The
  upstream test harness is the only caller, at
  `AK/windows/src/tests/mod.rs:18`, `:38`, `:145` and
  `AK/windows/src/tests/subclassed.rs:14`, `:127`, `:142`. The other two groups
  are enabled and never imported at all.

---

## 1. Windows: symbol table

### How complete this table is

A symbol counts as listed when the adapter names it. That covers five kinds:

1. imported Win32 or `uiautomationcore.dll` functions,
2. COM interfaces the adapter implements on its own objects,
3. `UIA_EVENT_ID` values,
4. `UIA_PATTERN_ID` and `UIA_PROPERTY_ID` values,
5. enums, flags, structs and message constants that appear in a call.

The adapter does not import `windows-rs` by path. Each file glob-imports whole
namespaces (`AK/windows/src/adapter.rs:13-17`, `node.rs:22-29`, `util.rs:15-24`,
`text.rs:14-21`, `subclass.rs:12-15`). The tables below are the result of reading
every file in `AK/windows/src/`, not of the import lists.

### W1. Window management and the window procedure (8 functions)

Header `winuser.h`. Library `user32.dll`.

| Symbol | C signature | Purpose | `path:line` |
|---|---|---|---|
| `SetWindowLongPtrW` | `LONG_PTR WINAPI SetWindowLongPtrW(HWND, int nIndex, LONG_PTR dwNewLong);` | install the subclass procedure; restore the previous one | `AK/windows/src/subclass.rs:111`, `:131` |
| `CallWindowProcW` | `LRESULT WINAPI CallWindowProcW(WNDPROC, HWND, UINT, WPARAM, LPARAM);` | chain an unhandled message to the previous procedure | `AK/windows/src/subclass.rs:73` |
| `DefWindowProcW` | `LRESULT WINAPI DefWindowProcW(HWND, UINT, WPARAM, LPARAM);` | read the window caption without messaging the window | `AK/windows/src/util.rs:390`, `:398` |
| `GetPropW` | `HANDLE WINAPI GetPropW(HWND, LPCWSTR);` | find the adapter pointer stored on the window | `AK/windows/src/subclass.rs:45`, `:96` |
| `SetPropW` | `BOOL WINAPI SetPropW(HWND, LPCWSTR, HANDLE);` | store the adapter pointer on the window | `AK/windows/src/subclass.rs:103` |
| `RemovePropW` | `BOOL WINAPI RemovePropW(HWND, LPCWSTR);` | clear the property on uninstall | `AK/windows/src/subclass.rs:140` |
| `IsWindowVisible` | `BOOL WINAPI IsWindowVisible(HWND);` | refuse to subclass an already shown window | `AK/windows/src/subclass.rs:167` |
| `ClientToScreen` | `BOOL WINAPI ClientToScreen(HWND, LPPOINT);` | move client coordinates into screen coordinates | `AK/windows/src/util.rs:380` |

**W1 total: 8 functions.**

### W1b. Window messages and window-state constants (12)

| Symbol | Value | Purpose | `path:line` |
|---|---|---|---|
| `WM_GETOBJECT` | `0x003D` | the message UI Automation sends to discover a provider | `AK/windows/src/adapter.rs:545`, `AK/windows/src/subclass.rs:50` |
| `WM_GETTEXT` | `0x000D` | read the caption text | `AK/windows/src/util.rs:400` |
| `WM_GETTEXTLENGTH` | `0x000E` | read the caption length | `AK/windows/src/util.rs:390` |
| `WM_SETFOCUS` | `0x0007` | mark the host window focused | `AK/windows/src/subclass.rs:62` |
| `WM_KILLFOCUS` | `0x0008` | mark the host window unfocused | `AK/windows/src/subclass.rs:65` |
| `WM_NCDESTROY` | `0x0082` | note that the window is gone so uninstall does nothing | `AK/windows/src/subclass.rs:68` |
| `WM_EXITMENULOOP` | `0x02A3` | treat menu-exit as focus gained | `AK/windows/src/subclass.rs:62` |
| `WM_ENTERMENULOOP` | `0x02A1` | treat menu-entry as focus lost | `AK/windows/src/subclass.rs:65` |
| `WM_EXITSIZEMOVE` | `0x0232` | treat move-end as focus gained | `AK/windows/src/subclass.rs:62` |
| `WM_ENTERSIZEMOVE` | `0x0231` | treat move-start as focus lost | `AK/windows/src/subclass.rs:65` |
| `GWLP_WNDPROC` | `-4` | index of the window procedure slot | `AK/windows/src/subclass.rs:111`, `:131` |
| `OBJID_CLIENT` | `0xFFFFFFFC` | the only MSAA object id the adapter answers | `AK/windows/src/adapter.rs:545` |

### W2. UI Automation entry points (7 functions, 5 constants)

Header `uiautomationclient.h` and `uiautomationcore.h`. Library
`uiautomationcore.dll`.

| Symbol | C signature | Purpose | `path:line` |
|---|---|---|---|
| `UiaLookupId` | `int WINAPI UiaLookupId(AutomationIdentifierType, const GUID*);` | force UI Automation to load before `WM_GETOBJECT` arrives | `AK/windows/src/adapter.rs:599` |
| `UiaReturnRawElementProvider` | `LRESULT WINAPI UiaReturnRawElementProvider(HWND, WPARAM, LPARAM, IRawElementProviderSimple*);` | answer `WM_GETOBJECT` with the root provider | `AK/windows/src/adapter.rs:624` |
| `UiaRaiseAutomationEvent` | `HRESULT WINAPI UiaRaiseAutomationEvent(IRawElementProviderSimple*, UIA_EVENT_ID);` | raise a plain event | `AK/windows/src/adapter.rs:647` |
| `UiaRaiseAutomationPropertyChangedEvent` | `HRESULT WINAPI UiaRaiseAutomationPropertyChangedEvent(IRawElementProviderSimple*, UIA_PROPERTY_ID, VARIANT oldValue, VARIANT newValue);` | raise a property change with old and new values | `AK/windows/src/adapter.rs:656` |
| `UiaHostProviderFromHwnd` | `HRESULT WINAPI UiaHostProviderFromHwnd(HWND, IRawElementProviderSimple**);` | find the host's own native provider, to proxy it for child hwnds | `AK/windows/src/node.rs:1064` |
| `UiaGetReservedMixedAttributeValue` | `HRESULT WINAPI UiaGetReservedMixedAttributeValue(IUnknown**);` | build the VARIANT that means "mixed" | `AK/windows/src/util.rs:275` |
| `UiaGetReservedNotSupportedValue` | `HRESULT WINAPI UiaGetReservedNotSupportedValue(IUnknown**);` | build the VARIANT that means "not supported" | `AK/windows/src/text.rs:488` |

| Constant | Purpose | `path:line` |
|---|---|---|
| `UiaRootObjectId` | the root provider object id in `WM_GETOBJECT` | `AK/windows/src/adapter.rs:545` |
| `UiaAppendRuntimeId` | first slot of a runtime id, marks a provider as out of process | `AK/windows/src/node.rs:44` |
| `ControlType_Property_GUID` | property id passed to `UiaLookupId` | `AK/windows/src/adapter.rs:601` |
| `AutomationIdentifierType_Property` | id type passed to `UiaLookupId` | `AK/windows/src/adapter.rs:600` |
| `ProviderOptions_ServerSideProvider` | advertise that the provider handles its own focus | `AK/windows/src/node.rs:1010` |

**W2 total: 7 functions, 5 constants.**

### W3. COM interfaces the adapter implements (14) and references (1)

Declared at `AK/windows/src/node.rs:790-804` for the element object and
`AK/windows/src/text.rs:209` for the range object.

| Interface | Implemented on | `path:line` |
|---|---|---|
| `IRawElementProviderSimple` | `PlatformNode_Impl` | `AK/windows/src/node.rs:791`, impl at `:1008` |
| `IRawElementProviderFragment` | `PlatformNode_Impl` | `AK/windows/src/node.rs:792`, impl at `:1073` |
| `IRawElementProviderFragmentRoot` | `PlatformNode_Impl` | `AK/windows/src/node.rs:793`, impl at `:1148` |
| `IToggleProvider` | `PlatformNode_Impl` | `AK/windows/src/node.rs:794`, impl at `:1292` |
| `IInvokeProvider` | `PlatformNode_Impl` | `AK/windows/src/node.rs:795`, impl at `:1292` |
| `IValueProvider` | `PlatformNode_Impl` | `AK/windows/src/node.rs:796`, impl at `:1292` |
| `IRangeValueProvider` | `PlatformNode_Impl` | `AK/windows/src/node.rs:797`, impl at `:1292` |
| `IScrollItemProvider` | `PlatformNode_Impl` | `AK/windows/src/node.rs:798`, impl at `:1292` |
| `ISelectionItemProvider` | `PlatformNode_Impl` | `AK/windows/src/node.rs:799`, impl at `:1292` |
| `ISelectionProvider` | `PlatformNode_Impl` | `AK/windows/src/node.rs:800`, impl at `:1292` |
| `ITextProvider` | `PlatformNode_Impl` | `AK/windows/src/node.rs:801`, impl at `:1292` |
| `IExpandCollapseProvider` | `PlatformNode_Impl` | `AK/windows/src/node.rs:802`, impl at `:1292` |
| `IWindowProvider` | `PlatformNode_Impl` | `AK/windows/src/node.rs:803`, impl at `:1292` |
| `ITextRangeProvider` | `PlatformRange_Impl` | `AK/windows/src/text.rs:209`, impl at `:320` |
| `IUnknown` | referenced, not implemented | `AK/windows/src/node.rs:1050`, `:1426`, `AK/windows/src/util.rs:172` |

**W3 total: 14 implemented, 1 referenced.**

### W4. UI Automation event ids (10)

The adapter raises these. It subscribes to none.

| Event | `path:line` |
|---|---|
| `UIA_AutomationFocusChangedEventId` | `AK/windows/src/adapter.rs:31` |
| `UIA_Text_TextChangedEventId` | `AK/windows/src/adapter.rs:71` |
| `UIA_Text_TextSelectionChangedEventId` | `AK/windows/src/node.rs:767` |
| `UIA_SelectionItem_ElementSelectedEventId` | `AK/windows/src/adapter.rs:155`, `:199` |
| `UIA_SelectionItem_ElementAddedToSelectionEventId` | `AK/windows/src/adapter.rs:198` |
| `UIA_SelectionItem_ElementRemovedFromSelectionEventId` | `AK/windows/src/adapter.rs:217` |
| `UIA_Selection_InvalidatedEventId` | `AK/windows/src/adapter.rs:186` |
| `UIA_Window_WindowOpenedEventId` | `AK/windows/src/adapter.rs:253`, `:330` |
| `UIA_Window_WindowClosedEventId` | `AK/windows/src/adapter.rs:281`, `:358` |
| `UIA_LiveRegionChangedEventId` | `AK/windows/src/adapter.rs:261`, `:322` |

**W4 total: 10 events.**

### W5. UI Automation pattern ids (10)

Declared once in the `patterns!` macro invocation at
`AK/windows/src/node.rs:1332-1531`. The macro body at `:1245-1304` turns each row
into a `GetPatternProvider` case, a property-change loop, and an `impl` block.

| Pattern | `path:line` |
|---|---|
| `UIA_TogglePatternId` | `AK/windows/src/node.rs:1333` |
| `UIA_InvokePatternId` | `AK/windows/src/node.rs:1340` |
| `UIA_ValuePatternId` | `AK/windows/src/node.rs:1345` |
| `UIA_RangeValuePatternId` | `AK/windows/src/node.rs:1356` |
| `UIA_ScrollItemPatternId` | `AK/windows/src/node.rs:1370` |
| `UIA_SelectionItemPatternId` | `AK/windows/src/node.rs:1382` |
| `UIA_SelectionPatternId` | `AK/windows/src/node.rs:1416` |
| `UIA_TextPatternId` | `AK/windows/src/node.rs:1432` |
| `UIA_ExpandCollapsePatternId` | `AK/windows/src/node.rs:1485` |
| `UIA_WindowPatternId` | `AK/windows/src/node.rs:1496` |

**W5 total: 10 patterns.**

### W6. UI Automation property ids (41)

| Property | `path:line` |
|---|---|
| `UIA_ControlTypePropertyId` | `AK/windows/src/node.rs:1307` |
| `UIA_LocalizedControlTypePropertyId` | `AK/windows/src/node.rs:1308` |
| `UIA_AriaRolePropertyId` | `AK/windows/src/node.rs:1309` |
| `UIA_NamePropertyId` | `AK/windows/src/node.rs:1310`, `:1028` |
| `UIA_FullDescriptionPropertyId` | `AK/windows/src/node.rs:1311` |
| `UIA_CulturePropertyId` | `AK/windows/src/node.rs:1312` |
| `UIA_HelpTextPropertyId` | `AK/windows/src/node.rs:1313` |
| `UIA_IsContentElementPropertyId` | `AK/windows/src/node.rs:1314` |
| `UIA_IsControlElementPropertyId` | `AK/windows/src/node.rs:1315` |
| `UIA_IsEnabledPropertyId` | `AK/windows/src/node.rs:1316` |
| `UIA_IsKeyboardFocusablePropertyId` | `AK/windows/src/node.rs:1317` |
| `UIA_HasKeyboardFocusPropertyId` | `AK/windows/src/node.rs:1318` |
| `UIA_LiveSettingPropertyId` | `AK/windows/src/node.rs:1319` |
| `UIA_AutomationIdPropertyId` | `AK/windows/src/node.rs:1320` |
| `UIA_ClassNamePropertyId` | `AK/windows/src/node.rs:1321` |
| `UIA_OrientationPropertyId` | `AK/windows/src/node.rs:1322` |
| `UIA_IsRequiredForFormPropertyId` | `AK/windows/src/node.rs:1323` |
| `UIA_IsPasswordPropertyId` | `AK/windows/src/node.rs:1324` |
| `UIA_LevelPropertyId` | `AK/windows/src/node.rs:1325` |
| `UIA_PositionInSetPropertyId` | `AK/windows/src/node.rs:1326` |
| `UIA_SizeOfSetPropertyId` | `AK/windows/src/node.rs:1327` |
| `UIA_AriaPropertiesPropertyId` | `AK/windows/src/node.rs:1328` |
| `UIA_IsDialogPropertyId` | `AK/windows/src/node.rs:1329` |
| `UIA_NativeWindowHandlePropertyId` | `AK/windows/src/node.rs:1031` |
| `UIA_FrameworkIdPropertyId` | `AK/windows/src/node.rs:1038` |
| `UIA_ProviderDescriptionPropertyId` | `AK/windows/src/node.rs:1041` |
| `UIA_ControllerForPropertyId` | `AK/windows/src/node.rs:1044`, `:1235` |
| `UIA_ToggleToggleStatePropertyId` | `AK/windows/src/node.rs:1334` |
| `UIA_ValueValuePropertyId` | `AK/windows/src/node.rs:1346` |
| `UIA_ValueIsReadOnlyPropertyId` | `AK/windows/src/node.rs:1347` |
| `UIA_RangeValueValuePropertyId` | `AK/windows/src/node.rs:1357` |
| `UIA_RangeValueIsReadOnlyPropertyId` | `AK/windows/src/node.rs:1358` |
| `UIA_RangeValueMinimumPropertyId` | `AK/windows/src/node.rs:1359` |
| `UIA_RangeValueMaximumPropertyId` | `AK/windows/src/node.rs:1360` |
| `UIA_RangeValueSmallChangePropertyId` | `AK/windows/src/node.rs:1361` |
| `UIA_RangeValueLargeChangePropertyId` | `AK/windows/src/node.rs:1362` |
| `UIA_SelectionCanSelectMultiplePropertyId` | `AK/windows/src/node.rs:1417` |
| `UIA_SelectionIsSelectionRequiredPropertyId` | `AK/windows/src/node.rs:1418` |
| `UIA_SelectionItemIsSelectedPropertyId` | `AK/windows/src/adapter.rs:162`, `:170`, `:207`, `:219` |
| `UIA_ExpandCollapseExpandCollapseStatePropertyId` | `AK/windows/src/node.rs:1486` |
| `UIA_WindowIsModalPropertyId` | `AK/windows/src/node.rs:1497` |

**W6 total: 41 properties.**

### W7. UI Automation control type ids (33)

`NodeWrapper::control_type` maps every AccessKit `Role` to a UIA control type at
`AK/windows/src/node.rs:58-260`.

| Control type | `path:line` |
|---|---|
| `UIA_ButtonControlTypeId` | `AK/windows/src/node.rs:92`, `:102`, `:121` |
| `UIA_CheckBoxControlTypeId` | `AK/windows/src/node.rs:77`, `:163` |
| `UIA_ComboBoxControlTypeId` | `AK/windows/src/node.rs:122` |
| `UIA_CustomControlTypeId` | `AK/windows/src/node.rs:62`, `:63`, `:217` |
| `UIA_DataGridControlTypeId` | `AK/windows/src/node.rs:146`, `:208` |
| `UIA_DataItemControlTypeId` | `AK/windows/src/node.rs:64`, `:68`, `:74`, `:94`, `:95`, `:99`, `:100` |
| `UIA_DocumentControlTypeId` | `AK/windows/src/node.rs:138`, `:150` |
| `UIA_EditControlTypeId` | `AK/windows/src/node.rs:91` |
| `UIA_GroupControlTypeId` | `AK/windows/src/node.rs:70`, `:75`, `:76`, `:96`, `:97`, `:113`, `:114`, `:119` |
| `UIA_HyperlinkControlTypeId` | `AK/windows/src/node.rs:66`, `:226`, `:229` |
| `UIA_ImageControlTypeId` | `AK/windows/src/node.rs:66`, `:117`, `:197` |
| `UIA_ListControlTypeId` | `AK/windows/src/node.rs:97`, `:129`, `:156` |
| `UIA_ListItemControlTypeId` | `AK/windows/src/node.rs:69`, `:70`, `:72`, `:201`, `:227` |
| `UIA_MenuBarControlTypeId` | `AK/windows/src/node.rs:162` |
| `UIA_MenuControlTypeId` | `AK/windows/src/node.rs:103` |
| `UIA_MenuItemControlTypeId` | `AK/windows/src/node.rs:73` |
| `UIA_PaneControlTypeId` | `AK/windows/src/node.rs:93`, `:107`, `:112` |
| `UIA_ProgressBarControlTypeId` | `AK/windows/src/node.rs:166`, `:170` |
| `UIA_RadioButtonControlTypeId` | `AK/windows/src/node.rs:78`, `:164` |
| `UIA_ScrollBarControlTypeId` | `AK/windows/src/node.rs:185` |
| `UIA_SeparatorControlTypeId` | `AK/windows/src/node.rs:193`, `:251` |
| `UIA_SliderControlTypeId` | `AK/windows/src/node.rs:191` |
| `UIA_SpinnerControlTypeId` | `AK/windows/src/node.rs:192` |
| `UIA_StatusBarControlTypeId` | `AK/windows/src/node.rs:194` |
| `UIA_TabControlTypeId` | `AK/windows/src/node.rs:199` |
| `UIA_TabItemControlTypeId` | `AK/windows/src/node.rs:198` |
| `UIA_TableControlTypeId` | `AK/windows/src/node.rs:98`, `:101` |
| `UIA_TextControlTypeId` | `AK/windows/src/node.rs:65`, `:104`, `:105`, `:118` |
| `UIA_ToolBarControlTypeId` | `AK/windows/src/node.rs:205` |
| `UIA_ToolTipControlTypeId` | `AK/windows/src/node.rs:206` |
| `UIA_TreeControlTypeId` | `AK/windows/src/node.rs:207` |
| `UIA_TreeItemControlTypeId` | `AK/windows/src/node.rs:71` |
| `UIA_WindowControlTypeId` | `AK/windows/src/node.rs:108`, `:110` |

**W7 total: 33 control types.**

### W8. Text pattern symbols (27)

The attribute ids appear in the `GetAttributeValue` match at
`AK/windows/src/text.rs:420-491`.

| `UIA_TEXTATTRIBUTE_ID` | `path:line` |
|---|---|
| `UIA_IsReadOnlyAttributeId` | `AK/windows/src/text.rs:421` |
| `UIA_CaretPositionAttributeId` | `AK/windows/src/text.rs:426` |
| `UIA_CultureAttributeId` | `AK/windows/src/text.rs:438` |
| `UIA_FontNameAttributeId` | `AK/windows/src/text.rs:439` |
| `UIA_FontSizeAttributeId` | `AK/windows/src/text.rs:446` |
| `UIA_FontWeightAttributeId` | `AK/windows/src/text.rs:449` |
| `UIA_IsItalicAttributeId` | `AK/windows/src/text.rs:452` |
| `UIA_BackgroundColorAttributeId` | `AK/windows/src/text.rs:453` |
| `UIA_ForegroundColorAttributeId` | `AK/windows/src/text.rs:454` |
| `UIA_OverlineStyleAttributeId` | `AK/windows/src/text.rs:455` |
| `UIA_OverlineColorAttributeId` | `AK/windows/src/text.rs:458` |
| `UIA_StrikethroughStyleAttributeId` | `AK/windows/src/text.rs:461` |
| `UIA_StrikethroughColorAttributeId` | `AK/windows/src/text.rs:464` |
| `UIA_UnderlineStyleAttributeId` | `AK/windows/src/text.rs:467` |
| `UIA_UnderlineColorAttributeId` | `AK/windows/src/text.rs:470` |
| `UIA_HorizontalTextAlignmentAttributeId` | `AK/windows/src/text.rs:473` |
| `UIA_IsSubscriptAttributeId` | `AK/windows/src/text.rs:474` |
| `UIA_IsSuperscriptAttributeId` | `AK/windows/src/text.rs:480` |

| `TextUnit` | `path:line` |
|---|---|
| `TextUnit_Character` | `AK/windows/src/text.rs:83`, `:137`, `:150`, `:163` |
| `TextUnit_Format` | `AK/windows/src/text.rs:89`, `:138`, `:151`, `:164` |
| `TextUnit_Word` | `AK/windows/src/text.rs:96`, `:139`, `:152`, `:165` |
| `TextUnit_Line` | `AK/windows/src/text.rs:103`, `:140`, `:153`, `:166` |
| `TextUnit_Paragraph` | `AK/windows/src/text.rs:110`, `:141`, `:154`, `:167` |
| `TextUnit_Page` | `AK/windows/src/text.rs:117`, `:142`, `:155`, `:168` |
| `TextUnit_Document` | `AK/windows/src/text.rs:124`, `:143`, `:156`, `:170` |

| `TextPatternRangeEndpoint` | `path:line` |
|---|---|
| `TextPatternRangeEndpoint_Start` | `AK/windows/src/text.rs:45`, `:56`, `:68`, `:563` |
| `TextPatternRangeEndpoint_End` | `AK/windows/src/text.rs:46`, `:57`, `:71`, `:563` |

**W8 total: 18 attribute ids, 7 text units, 2 endpoints.**

### W9. COM value plumbing, VARIANT and SAFEARRAY (2 functions)

Headers `ole2.h` and `oautdl.h`. Libraries `oleaut32.dll`.

| Symbol | C signature | Purpose | `path:line` |
|---|---|---|---|
| `SafeArrayCreateVector` | `HRESULT SafeArrayCreateVector(VARTYPE, ULONG lLbound, ULONG cElements, SAFEARRAY**);` | build the runtime id array and the rectangle array | `AK/windows/src/util.rs:304`, `:324` |
| `SafeArrayPutElement` | `HRESULT SafeArrayPutElement(SAFEARRAY*, LONG* lIndex, void* pv);` | fill a SAFEARRAY slot | `AK/windows/src/util.rs:310`, `:330` |

| Type or constant | Purpose | `path:line` |
|---|---|---|
| `VT_I4` | element type of the runtime id array | `AK/windows/src/util.rs:316` |
| `VT_R8` | element type of the bounding rectangle array | `AK/windows/src/util.rs:320` |
| `VT_UNKNOWN` | element type of the child and selection arrays | `AK/windows/src/util.rs:291`, `:324` |
| `VT_ARRAY` | array flag for `VT_UNKNOWN` | `AK/windows/src/util.rs:291` |
| `VARIANT` | the value type every property returns | `AK/windows/src/util.rs:288`, `:116` |
| `VARIANT_0`, `VARIANT_0_0`, `VARIANT_0_0_0` | the hand-built anonymous union for a `VT_ARRAY` of `VT_UNKNOWN` | `AK/windows/src/util.rs:289`, `:290`, `:295` |
| `SAFEARRAY` | the array handle | `AK/windows/src/util.rs:303`, `:315`, `:319`, `:323` |
| `BSTR` | the wide string type | `AK/windows/src/util.rs:100`, `:410` |
| `HRESULT` | the error code type | `AK/windows/src/util.rs:361`, `:365`, `:369`, `:373` |
| `HANDLE` | the property value type on `SetPropW` | `AK/windows/src/subclass.rs:106` |

### W10. Globalization (1 function, 1 flag)

Header `winnls.h`. Library `kernel32.dll`.

| Symbol | C signature | Purpose | `path:line` |
|---|---|---|---|
| `LocaleNameToLCID` | `LCID WINAPI LocaleNameToLCID(LPCWSTR lpName, DWORD dwFlags);` | turn an ARIA language tag into a Windows LCID | `AK/windows/src/util.rs:111` |

| Flag | Purpose | `path:line` |
|---|---|---|
| `LOCALE_ALLOW_NEUTRAL_NAMES` | accept `"en"` as well as `"en-US"` | `AK/windows/src/util.rs:111` |

**W10 total: 1 function, 1 flag.**

### W11. HRESULT constants (7)

| Symbol | Purpose | `path:line` |
|---|---|---|
| `E_NOTIMPL` | `not_implemented()` | `AK/windows/src/util.rs:349` |
| `E_INVALIDARG` | `invalid_arg()` | `AK/windows/src/util.rs:353` |
| `UIA_E_ELEMENTNOTAVAILABLE` | the node or range is gone | `AK/windows/src/util.rs:361` |
| `UIA_E_ELEMENTNOTENABLED` | the node is disabled | `AK/windows/src/util.rs:365` |
| `UIA_E_INVALIDOPERATION` | the call does not apply to this node | `AK/windows/src/util.rs:369` |
| `UIA_E_NOTSUPPORTED` | the call is never supported | `AK/windows/src/util.rs:373` |
| `E_FAIL` | no selection container | `AK/windows/src/node.rs:1411` |

**W11 total: 7 error codes.**

### W12. Remaining UI Automation enums and structs (11 types, 31 values)

| Type | Values used | `path:line` |
|---|---|---|
| `LiveSetting` | `Off`, `Polite`, `Assertive` | `AK/windows/src/node.rs:549`, `:550`, `:551` |
| `ToggleState` | `ToggleState_Off`, `_On`, `_Indeterminate` | `AK/windows/src/node.rs:582`, `:583`, `:584` |
| `ExpandCollapseState` | `_Expanded`, `_Collapsed`, `_LeafNode` | `AK/windows/src/node.rs:720`, `:721`, `:723` |
| `CaretPosition` | `_Unknown`, `_BeginningOfLine`, `_EndOfLine` | `AK/windows/src/text.rs:427`, `:431`, `:433` |
| `SupportedTextSelection` | `_Single`, `_None` | `AK/windows/src/node.rs:1478`, `:1480` |
| `NavigateDirection` | `_Parent`, `_NextSibling`, `_PreviousSibling`, `_FirstChild`, `_LastChild` | `AK/windows/src/node.rs:1077`, `:1078`, `:1079`, `:1082`, `:1083` |
| `HorizontalTextAlignment` | `_Left`, `_Right`, `_Centered`, `_Justified` | `AK/windows/src/util.rs:250`, `:251`, `:252`, `:253` |
| `TextDecorationLineStyle` | `_Single`, `_Dot`, `_Dash`, `_Double`, `_Wavy` | `AK/windows/src/util.rs:237`, `:238`, `:239`, `:240`, `:241` |
| `OrientationType` | `_Horizontal`, `_Vertical`, `_None` | `AK/windows/src/node.rs:570`, `:571`, `:572` |
| `UiaRect` | bounding rectangle of a node | `AK/windows/src/node.rs:1110`, `:1112`, `:1114` |
| `UiaPoint` | point argument to `RangeFromPoint` | `AK/windows/src/node.rs:1457` |

### W1 to W12 totals

| Kind | Count |
|---|---|
| Win32 and `uiautomationcore` functions | 18 |
| COM interfaces implemented | 14 |
| COM interfaces referenced | 1 |
| UI Automation event ids | 10 |
| UI Automation pattern ids | 10 |
| UI Automation property ids | 41 |
| UI Automation control type ids | 33 |
| UI Automation text attribute ids | 18 |
| `TextUnit` values | 7 |
| `TextPatternRangeEndpoint` values | 2 |
| Window message and window-state constants | 12 |
| Other UI Automation constants | 5 |
| VARIANT type and tag values | 4 |
| HRESULT codes | 7 |
| Globalization flags | 1 |
| Named UI Automation enums and structs | 11 |
| Enum values in those 11 types | 31 |

---

## 2. Windows: the event model

### The adapter subscribes to nothing

The Windows adapter is a UI Automation **provider**, not a client. It never
registers an event handler. A search of all of `AK/windows/src/` for
`UiaAddEventHandler` returns nothing. The complete list of `uiautomationcore`
functions it calls is the seven in table W2, and none of them registers a
handler. So the question "which UI Automation events are subscribed to" has the
answer: none.

There is one incoming message. UI Automation probes a window by sending
`WM_GETOBJECT` to it. The adapter answers that message with a pointer to its
root `IRawElementProviderSimple`. The handling path is:

| Step | Function | `path:line` |
|---|---|---|
| Normalize the object id | `normalize_objid` | `AK/windows/src/adapter.rs:606-613` |
| Reject ids that are not ours | early return of `None` | `AK/windows/src/adapter.rs:544-547` |
| Build the tree on first call | `ActivationHandler::request_initial_tree` | `AK/windows/src/adapter.rs:554` |
| Hold a placeholder tree when the app defers | `State::Placeholder` | `AK/windows/src/adapter.rs:564-578` |
| Convert the provider into an `LRESULT` | `impl From<WmGetObjectResult> for LRESULT` | `AK/windows/src/adapter.rs:622-626` |

After `WM_GETOBJECT`, every later call arrives as a COM method call on a
`PlatformNode` or a `PlatformRange`. Those are the 14 interfaces in table W3.

### How tree updates become UI Automation events

The adapter never looks at the tree diff itself. It passes a
`TreeChangeHandler` to `accesskit_consumer`, which reports one call per change.
The handler is `AdapterChangeHandler`, declared at
`AK/windows/src/adapter.rs:35`, implemented at `:237-372`.

| Change handler callback | Events it queues | `path:line` |
|---|---|---|
| `node_added` | `WindowOpened`, `LiveRegionChanged`, selection change | `AK/windows/src/adapter.rs:238-267` |
| `node_updated` | `WindowClosed`, `WindowOpened`, `LiveRegionChanged`, property changes, selection change | `AK/windows/src/adapter.rs:269-339` |
| `focus_moved` | `AutomationFocusChanged` | `AK/windows/src/adapter.rs:341-345` |
| `node_removed` | `WindowClosed`, selection change | `AK/windows/src/adapter.rs:347-369` |

Three ordering rules sit on top of this:

1. Text change events come first. `insert_text_change_if_needed_parent` inserts at
   index 0 of the queue, not at the end. The comment at
   `AK/windows/src/adapter.rs:64-66` gives the reason: text change events must
   precede selection change events, but the reverse does not matter.
2. Selection events are batched. Each change records the selection container as
   the map key at `AK/windows/src/adapter.rs:105-109`, and
   `enqueue_selection_changes` at `:125-229` emits one coherent sequence per
   container after the whole update.
3. A container with exactly one selected child emits the cheap
   `ElementSelected` pair instead of an add-or-remove pair
   (`AK/windows/src/adapter.rs:149-174`). A container that changes more than 20
   items emits `SelectionInvalidated` instead of individual events
   (`AK/windows/src/adapter.rs:176-187`).

Property changes do not go through the change handler. Two macros generate the
comparison code:

| Macro | What it generates | `path:line` |
|---|---|---|
| `properties!` | `get_property_value` and `enqueue_simple_property_changes` for 23 plain properties | `AK/windows/src/node.rs:1183-1243`, invoked at `:1306-1330` |
| `patterns!` | `pattern_provider`, `enqueue_pattern_property_changes` and one `impl` block per pattern | `AK/windows/src/node.rs:1245-1304`, invoked at `:1332-1531` |

The entry point is `enqueue_property_changes` at `AK/windows/src/node.rs:743-753`.
It calls the simple pass, the pattern pass, and one implied-event pass that turns
a raw text selection change into `UIA_Text_TextSelectionChangedEventId`
(`AK/windows/src/node.rs:755-770`).

### Which thread events arrive on

The rules are written into the doc comments, not enforced by types.

| Operation | Thread rule | `path:line` |
|---|---|---|
| `Adapter::new` | any thread, but never inside the `WM_GETOBJECT` handler | `AK/windows/src/adapter.rs:416-422` |
| `Adapter::update_if_active` | any thread | `AK/windows/src/adapter.rs:460-462` |
| `Adapter::update_window_focus_state` | any thread | `AK/windows/src/adapter.rs:497-499` |
| `QueuedEvents::raise` | the thread that owns the window | `AK/windows/src/adapter.rs:639-642` |
| `SubclassingAdapter::new` | the thread that owns the window | `AK/windows/src/subclass.rs:155-157` |
| `ActivationHandler` | always the window thread under subclassing | `AK/windows/src/subclass.rs:156` |
| `ActionHandler` | may or may not be the window thread | `AK/windows/src/adapter.rs:413-414` |

`QueuedEvents` carries `unsafe impl Send` at `AK/windows/src/adapter.rs:673`. The
comment at `:670-672` states the reason: the queue holds COM pointers, but the
adapter does no COM apartment marshalling, so moving the queue between threads
is safe as long as `raise` runs on the window thread.

`raise` calls the platform synchronously, in queue order, with no batching and no
locking (`AK/windows/src/adapter.rs:643-667`). It unwraps both HRESULTs at
`:647` and `:663`, so a platform refusal panics rather than being swallowed.

---

## 3. Windows: subclassing

### What `subclass.rs` installs

`subclass.rs` is 204 lines. It installs one window procedure and stores one
pointer.

| Item | Value | `path:line` |
|---|---|---|
| Property name on the window | `AccessKitAdapter` | `AK/windows/src/subclass.rs:30` |
| Replacement procedure | `wnd_proc` | `AK/windows/src/subclass.rs:44-74` |
| Pointer storage | `SetPropW(hwnd, PROP_NAME, HANDLE(&SubclassImpl))` | `AK/windows/src/subclass.rs:103-108` |
| Procedure install | `SetWindowLongPtrW(hwnd, GWLP_WNDPROC, wnd_proc)` | `AK/windows/src/subclass.rs:111` |
| Previous procedure | stored in `SubclassImpl::prev_wnd_proc` | `AK/windows/src/subclass.rs:115` |
| Window type alias | `LongPtr` is `isize` on 64-bit, `i32` elsewhere | `AK/windows/src/subclass.rs:25-28` |
| Installed state | `SubclassImpl { hwnd, state, prev_wnd_proc, window_destroyed }` | `AK/windows/src/subclass.rs:37-42` |

`wnd_proc` reads the pointer back with `GetPropW`, asserts that it is not null at
`AK/windows/src/subclass.rs:47`, and dispatches on six messages. Everything else
goes to `CallWindowProcW` with the saved procedure
(`AK/windows/src/subclass.rs:73`).

| Message | Action | `path:line` |
|---|---|---|
| `WM_GETOBJECT` | ask the adapter, convert to `LRESULT`, return it | `AK/windows/src/subclass.rs:50-61` |
| `WM_SETFOCUS`, `WM_EXITMENULOOP`, `WM_EXITSIZEMOVE` | set focus state true | `AK/windows/src/subclass.rs:62-64` |
| `WM_KILLFOCUS`, `WM_ENTERMENULOOP`, `WM_ENTERSIZEMOVE` | set focus state false | `AK/windows/src/subclass.rs:65-67` |
| `WM_NCDESTROY` | set the `window_destroyed` flag | `AK/windows/src/subclass.rs:68-70` |

### Why a hook is needed instead of an event subscription

UI Automation has no registration that says "tell me when someone asks about
this window". The only way for a provider to enter the conversation is to answer
the `WM_GETOBJECT` window message. A window message goes to the window
procedure. There are three ways to reach the window procedure:

1. The host application owns its window class, so it forwards `WM_GETOBJECT`
   itself. This is the `Adapter` path. `Adapter::handle_wm_getobject` is public
   at `AK/windows/src/adapter.rs:534`, so the app can call it from its own
   procedure.
2. The window belongs to a toolkit that does not forward `WM_GETOBJECT`. This is
   the case for SDL, for many game toolkits, and for windows created by third
   party code. The doc comment at `AK/windows/src/subclass.rs:144-145` says
   exactly this: "on a window that provides no other way of adding custom
   message handlers".
3. The window is a child window with its own procedure. The adapter can reach
   it through `UiaHostProviderFromHwnd` at `AK/windows/src/node.rs:1064` instead
   of subclassing.

So the hook is not a substitute for an event subscription. It is the only way to
receive the first message, and an event subscription cannot supply it.

### Lifetime of the hook

The hook lives exactly as long as the `SubclassingAdapter` value.

| Step | Code | `path:line` |
|---|---|---|
| Construct | `SubclassingAdapter::new` builds a `SubclassImpl` and calls `install` | `AK/windows/src/subclass.rs:162-176` |
| Guard | refuse if the window is already visible | `AK/windows/src/subclass.rs:167-171` |
| Duplicate guard | refuse if `GetPropW` already returns a value | `AK/windows/src/subclass.rs:96-101` |
| Uninstall | restore `prev_wnd_proc`, then `RemovePropW` | `AK/windows/src/subclass.rs:126-141` |
| Drop | `Drop for SubclassingAdapter` calls `uninstall` | `AK/windows/src/subclass.rs:200-203` |
| Window gone | `uninstall` returns early when `WM_NCDESTROY` was seen | `AK/windows/src/subclass.rs:127-129` |

Two borrow-ordering rules in this file are load-bearing, and both exist because
raising a UI Automation event can re-enter the window procedure:

1. In `WM_GETOBJECT`, the `RefCell` borrow of the state is dropped before the
   result is converted to `LRESULT`. See `AK/windows/src/subclass.rs:58-59`. The
   conversion calls `UiaReturnRawElementProvider`, which can send a nested
   `WM_GETOBJECT` to the same window. If the borrow were still live, the nested
   message would panic at `:47`.
2. In `update_window_focus_state`, the borrow is dropped before `events.raise`.
   See `AK/windows/src/subclass.rs:121-122`.

`Adapter::handle_wm_getobject` is shaped to support rule 1. Its return type is
`Option<impl Into<LRESULT>>`, not `Option<LRESULT>`, and the doc comment at
`AK/windows/src/adapter.rs:527-533` explains that the platform call is moved out
so it can run after the caller's borrow ends.

One more ordering rule sits in `Adapter::new`. `init_uia()` at
`AK/windows/src/adapter.rs:596-604` calls `UiaLookupId` purely to force UI
Automation to load. The doc comment at `AK/windows/src/adapter.rs:416-422` says
this must happen before `WM_GETOBJECT` is handled, to avoid a nested `WM_GETOBJECT`
and a race that makes assistive technology think the window has no native
provider.

---

## 4. Windows: text

`text.rs` is 652 lines, the second largest file in the adapter. It exists
because UI Automation models text as a pair of movable endpoints inside a
document, not as a string property.

### What the file holds

| Item | Count | `path:line` |
|---|---|---|
| `ITextRangeProvider` methods implemented | 18 | `AK/windows/src/text.rs:321-643` |
| Unit movement functions | 4 | `AK/windows/src/text.rs:81-172` |
| Endpoint helpers | 4 | `AK/windows/src/text.rs:40-79` |
| Repeated-movement driver | 1 | `AK/windows/src/text.rs:174-207` |
| Weak reference upgrade helpers | 2 | `AK/windows/src/text.rs:24-38` |
| Lock and read helpers on `PlatformRange` | 9 | `AK/windows/src/text.rs:215-303` |

The COM object is `PlatformRange`, declared at `AK/windows/src/text.rs:209-213`.
Its whole state is two fields: a `Weak<Context>` and an `RwLock<WeakRange>`. There
is no cached text, no cached rectangle, and no index.

### The algorithm

A UIA text range is a pair of endpoints. Each endpoint is a `TextPosition` in
the `accesskit_consumer` text model. Each position carries a comparable key: a
node path plus an offset, used for ordering without touching the tree. That key
is what `weak_comparable_position_from_endpoint` returns at
`AK/windows/src/text.rs:40-49`.

Movement by unit is a four-way dispatch:

| Function | Direction and target | `path:line` |
|---|---|---|
| `back_to_unit_start` | backward to the start of the unit | `AK/windows/src/text.rs:81-133` |
| `move_forward_to_start` | forward to the start of the unit | `AK/windows/src/text.rs:135-146` |
| `move_forward_to_end` | forward to the end of the unit | `AK/windows/src/text.rs:148-159` |
| `move_backward` | backward to the start of the unit | `AK/windows/src/text.rs:161-172` |
| `move_position` | repeat one of the above `count` times, stopping at a document edge | `AK/windows/src/text.rs:174-207` |

`move_position` is the fixed-bound loop that satisfies the house rule on loop
bounds. It iterates at most `abs(count)` times, breaks at the document start or
end, and returns both the new position and the number of units it actually moved.
Callers compare that count against zero to decide whether to commit
(`AK/windows/src/text.rs:541`, `:562`).

Reading a value needs no movement. `GetText` writes the range text into a
leased buffer (`AK/windows/src/text.rs:520-529`). `GetAttributeValue` matches on
18 attribute ids and falls through to `UiaGetReservedNotSupportedValue`
(`AK/windows/src/text.rs:419-492`). `GetBoundingRectangles` unions nothing; it
flattens every rectangle into a `VT_R8` SAFEARRAY and returns null when the list
is empty (`AK/windows/src/text.rs:494-510`).

Ranges enter the adapter through `ITextProvider`:

| Entry point | `path:line` |
|---|---|
| `GetSelection` | `AK/windows/src/node.rs:1433-1443` |
| `RangeFromPoint` | `AK/windows/src/node.rs:1457-1466` |
| `DocumentRange` | `AK/windows/src/node.rs:1468-1473` |

### Why it is not a simple property read

Three properties of the UI Automation text model force this shape.

1. `ITextProvider` has no text property at all. Text only exists as the result
   of a method on a range. There is nothing to read on the element.
2. A range is mutable and addressable. An assistive technology holds a range
   across many calls and expects it to keep pointing at the same place, or to
   fail cleanly when it stops being valid. `PlatformRange` stores a weak range
   and upgrades it against the current tree state on every call
   (`AK/windows/src/text.rs:243-251`). A failed upgrade becomes
   `UIA_E_ELEMENTNOTAVAILABLE` (`AK/windows/src/text.rs:28`, `:37`).
3. Endpoints move independently. `MoveEndpointByUnit` and `MoveEndpointByRange`
   each set one endpoint and leave the other alone
   (`AK/windows/src/text.rs:554-592`).

### The cases a naive implementation gets wrong

Each of these is a deliberate choice with a stated reason in the source.

| Case | Behaviour | Reason in source | `path:line` |
|---|---|---|---|
| compare two endpoints of the same range | compare comparable keys without upgrading | lets an assistive technology test whether a stale range is degenerate | `AK/windows/src/text.rs:339-350` |
| `ExpandToEnclosingUnit(Document)` with dead endpoints | rebuild the range from the node's document range | observed need of Narrator | `AK/windows/src/text.rs:366-376` |
| `ExpandToEnclosingUnit(Character)` at document end | do nothing | observed behaviour of some Windows assistive technologies | `AK/windows/src/text.rs:379-385` |
| `GetText` with `max_length` | ignore the limit | the Microsoft docs do not require truncation | `AK/windows/src/text.rs:520-523` |
| `MoveEndpointByRange` across two ranges | take both locks in a fixed order | deadlock avoidance | `AK/windows/src/text.rs:577-591` |
| `FindAttribute` | return `Error::empty()` | no variable formatting yet; JUCE does not implement it | `AK/windows/src/text.rs:396-405` |
| `FindText` | return `Error::empty()` | no real-world use case; Quorum does not implement it | `AK/windows/src/text.rs:407-417` |
| `AddToSelection`, `RemoveFromSelection` | return `UIA_E_INVALIDOPERATION` | AccessKit has no multiple text selections | `AK/windows/src/text.rs:606-614` |
| `GetChildren`, `RangeFromChild` | empty array, `UIA_E_NOTIMPL` | no embedded objects in text | `AK/windows/src/text.rs:640-643`, `AK/windows/src/node.rs:1452-1455` |
| `GetVisibleRanges` | return null | the reference toolkit does not implement it | `AK/windows/src/node.rs:1445-1450` |

### Two assumptions the file states out loud

| Assumption | `path:line` |
|---|---|
| AccessKit is the only UI Automation provider in the process, so casting an incoming interface pointer to the concrete implementation is safe | `AK/windows/src/text.rs:314-317` |
| `PlatformRange` is safe to use free-threaded, matching the advertised `ProviderOptions` | `AK/windows/src/text.rs:646-652` |

---

## 5. macOS: symbol table

### How complete this table is

The macOS adapter has no list of imported C functions. It talks to the
Objective-C runtime through `objc2` message sends and typed method calls. A
symbol counts as listed when the adapter names the runtime function, the
Objective-C selector, or the `NSAccessibility` constant. The source files are
`AK/macos/src/adapter.rs`, `context.rs`, `event.rs`, `node.rs`, `patch.rs`,
`subclass.rs`, `util.rs` and `filters.rs`.

### M1. Objective-C runtime (7 functions and 1 primitive)

Header `objc/runtime.h`. Library `libobjc`.

| Symbol | C signature | Purpose | `path:line` |
|---|---|---|---|
| `objc_getClass` | `Class _Nullable objc_getClass(const char *name);` | find the window class to patch | `AK/macos/src/patch.rs:40` |
| `class_addMethod` | `BOOL class_addMethod(Class cls, SEL name, IMP imp, const char *types);` | add a method to an existing class | `AK/macos/src/patch.rs:71` |
| `objc_allocateClassPair` | `Class _Nullable objc_allocateClassPair(Class superclass, const char *name, size_t extraBytes);` | create the dynamic subclass | `AK/macos/src/subclass.rs:176` |
| `objc_registerClassPair` | `void objc_registerClassPair(Class cls);` | make the dynamic subclass usable | `AK/macos/src/subclass.rs:195` |
| `objc_getAssociatedObject` | `id _Nullable objc_getAssociatedObject(id object, const void *key);` | find the state attached to the view | `AK/macos/src/subclass.rs:77`, `:151`, `:179` |
| `objc_setAssociatedObject` | `void objc_setAssociatedObject(id object, const void *key, id value, objc_AssociationPolicy policy);` | attach and detach the state | `AK/macos/src/subclass.rs:164`, `:265` |
| `object_setClass` | `Class object_setClass(id object, Class cls);` | swap the view's class, and swap it back on drop | `AK/macos/src/subclass.rs:203`, `:263` |
| `objc_msgSend` | `id _Nullable objc_msgSend(id self, SEL _op, ...);` | the message-send primitive, never named in the source | `AK/macos/src/patch.rs:20`, `AK/macos/src/util.rs:106`, `AK/macos/src/node.rs:520`, `AK/macos/src/node.rs:1337`, `AK/macos/src/subclass.rs:71` |

Four of the seven functions are named in the source, as `objc2::ffi` externs
imported at `AK/macos/src/patch.rs:6` and `AK/macos/src/subclass.rs:11-14`. The
other three are reached through an `objc2` wrapper: `objc_getClass` through
`AnyClass::get` at `AK/macos/src/patch.rs:40`, `objc_allocateClassPair` through
`ClassBuilder::new` at `AK/macos/src/subclass.rs:176`, and
`objc_registerClassPair` through `builder.register()` at
`AK/macos/src/subclass.rs:195`. A Zig port names all seven, because zig-objc
exports the four it covers and the port writes the other three as `extern`
declarations. `objc_msgSend` is not among the seven: it is what `msg_send!` and
`msg_send_id!` lower to, which is why the row above cites the macro sites rather
than the function.

| Item | Value | `path:line` |
|---|---|---|
| Association policy | `OBJC_ASSOCIATION_RETAIN_NONATOMIC` | `AK/macos/src/subclass.rs:168`, `:269` |
| Association key | address of a static `u8` | `AK/macos/src/subclass.rs:29-33` |
| Dynamic subclass name | `AccessKitSubclassOf<ClassName>` | `AK/macos/src/subclass.rs:175` |
| State object class name | `AccessKitSubclassAssociatedObject` | `AK/macos/src/subclass.rs:51` |
| Node object class name | `AccessKitNode` | `AK/macos/src/node.rs:404` |
| Subclass cache | `static SUBCLASSES: Mutex<Vec<(&AnyClass, &AnyClass)>>` | `AK/macos/src/subclass.rs:27` |

**M1 total: 7 runtime functions, plus `objc_msgSend` as the primitive they lower to.**

### M2. AppKit and Foundation calls (18)

| Selector | Purpose | `path:line` |
|---|---|---|
| `-[NSWindow contentView]` | get the view that carries the accessibility tree | `AK/macos/src/patch.rs:19`, `AK/macos/src/subclass.rs:229` |
| `-[NSWindow convertPointFromScreen:]` | move a hit-test point into window coordinates | `AK/macos/src/util.rs:40` |
| `-[NSWindow convertRectToScreen:]` | move a node rectangle to screen coordinates | `AK/macos/src/util.rs:80` |
| `-[NSWindow backingScaleFactor]` | convert physical pixels to logical points | `AK/macos/src/util.rs:44`, `:62` |
| `-[NSView window]` | find the owning window | `AK/macos/src/util.rs:39`, `:57`, `:79`, `AK/macos/src/event.rs:73`, `AK/macos/src/node.rs:480`, `:823`, `:963` |
| `-[NSView convertPoint:fromView:]` | move a hit-test point into view coordinates | `AK/macos/src/util.rs:41` |
| `-[NSView convertRect:toView:]` | move a rectangle into view coordinates | `AK/macos/src/util.rs:78` |
| `-[NSView isFlipped]` | flip the y axis for a non-flipped view | `AK/macos/src/util.rs:47`, `:66` |
| `-[NSView bounds]` | get the view height for the y flip | `AK/macos/src/util.rs:50`, `:70` |
| `+[NSColor colorWithSRGBRed:green:blue:alpha:]` | build an sRGB colour from an AccessKit colour | `AK/macos/src/util.rs:99-104` |
| `-[NSColor CGColor]` | get the `CGColor` for a text attribute | `AK/macos/src/util.rs:106` |
| `-[NSAccessibility accessibilityParent]` | proxy the host view's own place in the AX tree | `AK/macos/src/node.rs:421`, `:433`, `:444` |
| `-[NSAccessibility accessibilityFrame]` | proxy the host view's own frame | `AK/macos/src/node.rs:490` |
| `+[NSURL URLWithString:]` | build the URL attribute | `AK/macos/src/node.rs:628` |
| `-[NSObject copy]` | return a retained role or subrole constant | `AK/macos/src/node.rs:505`, `:510` |
| `Id::retain` | take ownership of an object the runtime handed over | `AK/macos/src/adapter.rs:94`, `AK/macos/src/subclass.rs:140`, `AK/macos/src/util.rs:107` |
| `NSArray::from_vec` | return child arrays to the assistive technology | `AK/macos/src/adapter.rs:244`, `AK/macos/src/node.rs:472`, `:1117`, `:1134`, `:1172`, `:1189`, `:1215`, `:1364` |
| `Id::autorelease_return` | hand an owned object to the caller under ARC rules | `AK/macos/src/adapter.rs:245`, `:257`, `:293` |

Types and constructors from `objc2-foundation` and `objc2-app-kit`:

| Type | Purpose | `path:line` |
|---|---|---|
| `NSView` | the host view type | `AK/macos/src/context.rs:35`, `AK/macos/src/adapter.rs:28` |
| `NSWindow` | the window type | `AK/macos/src/subclass.rs:228` |
| `NSAccessibilityElement` | super class of `PlatformNode` | `AK/macos/src/node.rs:402` |
| `NSString` | text attributes | `AK/macos/src/node.rs:518`, `:538`, `:545`, `:557` |
| `NSNumber` | numeric and boolean attributes | `AK/macos/src/node.rs:567`, `:570`, `:610`, `:617` |
| `NSURL` | the URL attribute | `AK/macos/src/node.rs:624` |
| `NSMutableDictionary` | announcement user info and text attributes | `AK/macos/src/event.rs:80`, `AK/macos/src/node.rs:863`, `:876` |
| `NSAttributedString` | the attributed text attribute | `AK/macos/src/node.rs:855`, `:947` |
| `NSMutableAttributedString` | the attributed text builder | `AK/macos/src/node.rs:859` |
| `NSPoint`, `NSRect`, `NSSize`, `NSRange` | geometry and text index types | `AK/macos/src/util.rs:11`, `AK/macos/src/node.rs:821`, `:960` |
| `MainThreadMarker` | the main-thread proof carried in `Context` | `AK/macos/src/adapter.rs:96`, `AK/macos/src/context.rs:39` |
| `CGColor` | a forward declaration, because `objc2` 0.5 lacks it | `AK/macos/src/util.rs:87-95` |

**M2 total: 18 AppKit and Foundation calls, 12 types.**

### M3. Accessibility methods implemented on `PlatformNode` (54)

`PlatformNode` is a dynamically declared Objective-C class whose super class is
`NSAccessibilityElement` (`AK/macos/src/node.rs:396-409`). It is registered once
at `AK/macos/src/node.rs:1337` and then answers message sends. The methods below
are declared with the `objc2` `#[method]` and `#[method_id]` attributes inside
the `unsafe impl PlatformNode` block at `AK/macos/src/node.rs:411-1330`.

| Accessibility method | `path:line` |
|---|---|
| `accessibilityParent` | `AK/macos/src/node.rs:412` |
| `accessibilityWindow` | `AK/macos/src/node.rs:427` |
| `accessibilityTopLevelUIElement` | `AK/macos/src/node.rs:438` |
| `accessibilityChildren` | `AK/macos/src/node.rs:449` |
| `accessibilityChildrenInNavigationOrder` | `AK/macos/src/node.rs:454` |
| `accessibilitySelectedChildren` | `AK/macos/src/node.rs:460` |
| `accessibilityFrame` | `AK/macos/src/node.rs:477` |
| `accessibilityRole` | `AK/macos/src/node.rs:501` |
| `accessibilitySubrole` | `AK/macos/src/node.rs:508` |
| `accessibilityRoleDescription` | `AK/macos/src/node.rs:514` |
| `accessibilityIdentifier` | `AK/macos/src/node.rs:526` |
| `accessibilityTitle` | `AK/macos/src/node.rs:534` |
| `accessibilityHelp` | `AK/macos/src/node.rs:543` |
| `accessibilityPlaceholderValue` | `AK/macos/src/node.rs:552` |
| `accessibilityValue` | `AK/macos/src/node.rs:561` |
| `setAccessibilityValue:` | `AK/macos/src/node.rs:580` |
| `accessibilityMinValue` | `AK/macos/src/node.rs:607` |
| `accessibilityMaxValue` | `AK/macos/src/node.rs:615` |
| `accessibilityURL` | `AK/macos/src/node.rs:623` |
| `accessibilityOrientation` | `AK/macos/src/node.rs:634` |
| `isAccessibilityElement` | `AK/macos/src/node.rs:646` |
| `isAccessibilityFocused` | `AK/macos/src/node.rs:652` |
| `isAccessibilityEnabled` | `AK/macos/src/node.rs:658` |
| `setAccessibilityFocused:` | `AK/macos/src/node.rs:663` |
| `accessibilityPerformPress` | `AK/macos/src/node.rs:693` |
| `accessibilityPerformIncrement` | `AK/macos/src/node.rs:712` |
| `accessibilityPerformDecrement` | `AK/macos/src/node.rs:731` |
| `accessibilityNotifiesWhenDestroyed` | `AK/macos/src/node.rs:750` |
| `accessibilityNumberOfCharacters` | `AK/macos/src/node.rs:755` |
| `accessibilitySelectedText` | `AK/macos/src/node.rs:767` |
| `accessibilitySelectedTextRange` | `AK/macos/src/node.rs:781` |
| `accessibilityInsertionPointLineNumber` | `AK/macos/src/node.rs:794` |
| `accessibilityRangeForLine:` | `AK/macos/src/node.rs:807` |
| `accessibilityRangeForPosition:` | `AK/macos/src/node.rs:820` |
| `accessibilityStringForRange:` | `AK/macos/src/node.rs:840` |
| `accessibilityAttributedStringForRange:` | `AK/macos/src/node.rs:854` |
| `accessibilityFrameForRange:` | `AK/macos/src/node.rs:960` |
| `accessibilityLineForIndex:` | `AK/macos/src/node.rs:985` |
| `accessibilityRangeForIndex:` | `AK/macos/src/node.rs:998` |
| `accessibilityStyleRangeForIndex:` | `AK/macos/src/node.rs:1011` |
| `setAccessibilitySelectedTextRange:` | `AK/macos/src/node.rs:1031` |
| `isAccessibilityRequired` | `AK/macos/src/node.rs:1049` |
| `isAccessibilitySelected` | `AK/macos/src/node.rs:1055` |
| `setAccessibilitySelected:` | `AK/macos/src/node.rs:1066` |
| `accessibilityAttributeValue:` | `AK/macos/src/node.rs:1090` |
| `accessibilityRows` | `AK/macos/src/node.rs:1106` |
| `accessibilitySelectedRows` | `AK/macos/src/node.rs:1122` |
| `accessibilityPerformPick` | `AK/macos/src/node.rs:1139` |
| `accessibilityLinkedUIElements` | `AK/macos/src/node.rs:1161` |
| `accessibilityTabs` | `AK/macos/src/node.rs:1178` |
| `isAccessibilityModal` | `AK/macos/src/node.rs:1194` |
| `accessibilityActionNames` | `AK/macos/src/node.rs:1207` |
| `accessibilityPerformAction:` | `AK/macos/src/node.rs:1218` |
| `isAccessibilitySelectorAllowed:` | `AK/macos/src/node.rs:1234` |

**M3 total: 54 accessibility methods.**

One further method is added to the **view** rather than to a node. The four
selectors in `SubclassingAdapter` are:

| View selector | Handler | `path:line` |
|---|---|---|
| `accessibilityChildren` | `children` | `AK/macos/src/subclass.rs:92-99`, registered at `:183` |
| `accessibilityFocusedUIElement` | `focus` | `AK/macos/src/subclass.rs:101-106`, registered at `:187` |
| `accessibilityHitTest:` | `hit_test` | `AK/macos/src/subclass.rs:108-115`, registered at `:191` |
| `superclass` | `superclass` | `AK/macos/src/subclass.rs:87-90`, registered at `:179` |

---

### M4. Accessibility notifications (2 functions, 7 names, 5 keys)

The adapter posts notifications. It observes none. A search of all of
`AK/` for `CFRunLoop`, `RunLoop` and `addObserver` finds no run loop call and
only one observer, and that one is in the iOS adapter.

| Symbol | Purpose | `path:line` |
|---|---|---|
| `NSAccessibilityPostNotification` | post a notification about an element | `AK/macos/src/context.rs:96`, `AK/macos/src/event.rs:53`, `:58` |
| `NSAccessibilityPostNotificationWithUserInfo` | post an announcement with a dictionary payload | `AK/macos/src/event.rs:97-102` |
| `NSAccessibilityUIElementDestroyedNotification` | announce that an element left the tree | `AK/macos/src/context.rs:98`, `AK/macos/src/event.rs:60` |
| `NSAccessibilityFocusedUIElementChangedNotification` | announce a focus move | `AK/macos/src/event.rs:136` |
| `NSAccessibilityValueChangedNotification` | announce a value or text change | `AK/macos/src/event.rs:189`, `:281`, `:287` |
| `NSAccessibilitySelectedRowsChangedNotification` | announce a selection change | `AK/macos/src/event.rs:211` |
| `NSAccessibilityTitleChangedNotification` | announce a title change | `AK/macos/src/event.rs:267` |
| `NSAccessibilitySelectedTextChangedNotification` | announce a text selection change | `AK/macos/src/event.rs:297` |
| `NSAccessibilityAnnouncementRequestedNotification` | carry a live region announcement | `AK/macos/src/event.rs:99` |
| `NSAccessibilityAnnouncementKey` | the announcement text key | `AK/macos/src/event.rs:85` |
| `NSAccessibilityPriorityKey` | the announcement priority key | `AK/macos/src/event.rs:92` |
| `NSAccessibilityPriorityLevel` | the priority value type | `AK/macos/src/event.rs:30`, `:39`, `:41` |
| `NSAccessibilityPriorityHigh` | assertive live region priority | `AK/macos/src/event.rs:39` |
| `NSAccessibilityPriorityMedium` | polite live region priority | `AK/macos/src/event.rs:41` |

**M4 total: 2 posting functions, 7 notification names, 5 keys and levels.**

### M5. Text attribute names and the 43 `AX` selector literals

`objc2-app-kit` exports no constant for any of these, so the source spells them
as string literals and a Zig port writes all 43 of them by hand. A scan for
`"AX…"` over the nine files under `AK/macos/src/` returns 43 distinct strings at
47 sites, every site in `AK/macos/src/node.rs`:

| Where | Count | Strings |
|---|---:|---|
| `ns_role`, `AK/macos/src/node.rs:36-242` | 5 | `AXListMarker`, `AXDateField`, `AXTimeField`, `AXWebArea`, `AXHeading` |
| `ns_sub_role`, `AK/macos/src/node.rs:244-296` | 32 | the 32 landmark, application, document and style-group subroles |
| `accessibilityAttributeValue:`, `AK/macos/src/node.rs:1090-1105` | 3 | `AXBrailleLabel`, `AXBrailleRoleDescription`, `AXDOMIdentifier` |
| the font dictionary, `AK/macos/src/node.rs:892`, `:899` | 2 | `AXFontBold`, `AXFontItalic` |
| the one legacy action name, `AK/macos/src/node.rs:34` | 1 | `AXScrollToVisible` |
| **Total** | **43** | |

The 32 subrole strings are `AXApplicationAlert`, `AXApplicationGroup`,
`AXApplicationLog`, `AXApplicationMarquee`, `AXApplicationStatus`,
`AXApplicationTimer`, `AXCodeStyleGroup`, `AXDeleteStyleGroup`,
`AXDefinition`, `AXDocument`, `AXDocumentArticle`, `AXDocumentMath`,
`AXDocumentNote`, `AXEmphasisStyleGroup`, `AXInsertStyleGroup`,
`AXLandmarkBanner`, `AXLandmarkComplementary`, `AXLandmarkContentInfo`,
`AXLandmarkForm`, `AXLandmarkMain`, `AXLandmarkNavigation`, `AXLandmarkRegion`,
`AXLandmarkSearch`, `AXMeter`, `AXSectionFooter`, `AXSectionHeader`,
`AXStrongStyleGroup`, `AXTabPanel`, `AXTerm`, `AXTimeGroup`,
`AXUserInterfaceTooltip` and `AXWebApplication`.

The twelve named constants the attributed string is built from are the
`NSAccessibility` text attributes, in `accessibilityAttributedStringForRange:`
at `AK/macos/src/node.rs:854-958`:

| Attribute name | Applied to | `path:line` |
|---|---|---|
| `NSAccessibilityBackgroundColorTextAttribute` | background colour | `AK/macos/src/node.rs:866` |
| `NSAccessibilityForegroundColorTextAttribute` | foreground colour | `AK/macos/src/node.rs:872` |
| `NSAccessibilityFontTextAttribute` | the nested font dictionary | `AK/macos/src/node.rs:905` |
| `NSAccessibilityFontAttributeKey` | the font dictionary key type | `AK/macos/src/node.rs:876` |
| `NSAccessibilityFontFamilyKey` | font family | `AK/macos/src/node.rs:879` |
| `NSAccessibilityFontSizeKey` | font size | `AK/macos/src/node.rs:885` |
| `NSAccessibilityUnderlineTextAttribute` | underline present | `AK/macos/src/node.rs:911` |
| `NSAccessibilityUnderlineColorTextAttribute` | underline colour | `AK/macos/src/node.rs:915` |
| `NSAccessibilityStrikethroughTextAttribute` | strikethrough present | `AK/macos/src/node.rs:921` |
| `NSAccessibilityStrikethroughColorTextAttribute` | strikethrough colour | `AK/macos/src/node.rs:925` |
| `NSAccessibilityLanguageTextAttribute` | language | `AK/macos/src/node.rs:931` |
| `NSAccessibilityTextAlignmentAttribute` | text alignment | `AK/macos/src/node.rs:943` |

**M5 total: 12 named text-attribute constants and 43 selector literals.**

### M6. Roles and subroles (31 roles, 7 subroles)

`ns_role` at `AK/macos/src/node.rs:36-242` and `ns_sub_role` at `:244-296` map
every AccessKit `Role` to an `NSAccessibilityRole` or `NSAccessibilitySubrole`.

The same two tables also carry the 5 role and 32 subrole strings of section M5,
so `ns_role` and `ns_sub_role` each name two kinds of thing: a typed constant
where AppKit exports one, and an `AX…` string where it does not. The class
`NSAccessibilityRole` is counted as a type in the block below rather than as a
role constant, which is why a scan for `NSAccessibility…Role` returns 32 names
for 31 constants.

| Role constant | `path:line` |
|---|---|
| `NSAccessibilityButtonRole` | `AK/macos/src/node.rs:69`, `:113`, `:181` |
| `NSAccessibilityCellRole` | `AK/macos/src/node.rs:43`, `:74`, `:75` |
| `NSAccessibilityCheckBoxRole` | `AK/macos/src/node.rs:56`, `:67`, `:82` |
| `NSAccessibilityColorWellRole` | `AK/macos/src/node.rs:101` |
| `NSAccessibilityComboBoxRole` | `AK/macos/src/node.rs:103` |
| `NSAccessibilityGroupRole` | `AK/macos/src/node.rs:100`, `:104`, `:105` |
| `NSAccessibilityImageRole` | `AK/macos/src/node.rs:45`, `:185`, `:197` |
| `NSAccessibilityIncrementorRole` | `AK/macos/src/node.rs:159` |
| `NSAccessibilityLevelIndicatorRole` | `AK/macos/src/node.rs:142` |
| `NSAccessibilityLinkRole` | `AK/macos/src/node.rs:190`, `:210`, `:213` |
| `NSAccessibilityListRole` | `AK/macos/src/node.rs:77`, `:110`, `:132` |
| `NSAccessibilityMenuBarRole` | `AK/macos/src/node.rs:138` |
| `NSAccessibilityMenuItemRole` | `AK/macos/src/node.rs:52`, `:139`, `:140` |
| `NSAccessibilityMenuRole` | `AK/macos/src/node.rs:83`, `:141` |
| `NSAccessibilityOutlineRole` | `AK/macos/src/node.rs:174` |
| `NSAccessibilityPopUpButtonRole` | `AK/macos/src/node.rs:102` |
| `NSAccessibilityProgressIndicatorRole` | `AK/macos/src/node.rs:146` |
| `NSAccessibilityRadioButtonRole` | `AK/macos/src/node.rs:57`, `:165` |
| `NSAccessibilityRadioGroupRole` | `AK/macos/src/node.rs:147` |
| `NSAccessibilityRowRole` | `AK/macos/src/node.rs:47`, `:50` |
| `NSAccessibilityScrollBarRole` | `AK/macos/src/node.rs:152` |
| `NSAccessibilitySliderRole` | `AK/macos/src/node.rs:158` |
| `NSAccessibilitySplitterRole` | `AK/macos/src/node.rs:160`, `:215` |
| `NSAccessibilityStaticTextRole` | `AK/macos/src/node.rs:44`, `:51`, `:171` |
| `NSAccessibilityTabGroupRole` | `AK/macos/src/node.rs:166` |
| `NSAccessibilityTableRole` | `AK/macos/src/node.rs:78`, `:122`, `:175` |
| `NSAccessibilityTextAreaRole` | `AK/macos/src/node.rs:84`, `:228` |
| `NSAccessibilityTextFieldRole` | `AK/macos/src/node.rs:64` |
| `NSAccessibilityToolbarRole` | `AK/macos/src/node.rs:172` |
| `NSAccessibilityUnknownRole` | `AK/macos/src/node.rs:117`, `:128`, `:129`, `:504` |
| `NSAccessibilityWindowRole` | `AK/macos/src/node.rs:91`, `:112` |

| Subrole constant | `path:line` |
|---|---|
| `NSAccessibilityDialogSubrole` | `AK/macos/src/node.rs:250`, `:261` |
| `NSAccessibilityOutlineRowSubrole` | `AK/macos/src/node.rs:291` |
| `NSAccessibilitySearchFieldSubrole` | `AK/macos/src/node.rs:280` |
| `NSAccessibilitySecureTextFieldSubrole` | `AK/macos/src/node.rs:277` |
| `NSAccessibilitySwitchSubrole` | `AK/macos/src/node.rs:285` |
| `NSAccessibilityTabButtonSubrole` | `AK/macos/src/node.rs:286` |
| `NSAccessibilityToggleSubrole` | `AK/macos/src/node.rs:254` |

| Other accessibility type | Purpose | `path:line` |
|---|---|---|
| `NSAccessibilityOrientation` | the orientation value type and its three values | `AK/macos/src/node.rs:634-644` |
| `NSAccessibilityRole` | the role value type | `AK/macos/src/node.rs:36`, `:502` |
| `NSAccessibilitySubrole` | the subrole value type | `AK/macos/src/node.rs:244`, `:509` |
| `NSTextAlignment` | maps AccessKit text alignment | `AK/macos/src/node.rs:937-941` |

**M6 total: 31 roles, 7 subroles, 4 other types.**

### M1 to M6 totals

| Kind | Count |
|---|---|
| Objective-C runtime functions | 8 |
| AppKit and Foundation selectors | 17 |
| Objective-C runtime support items (policy, keys, class names, cache) | 6 |
| AppKit and Foundation types | 12 |
| Accessibility methods on `PlatformNode` | 54 |
| Accessibility methods added to the host view | 4 |
| Notification posting functions | 2 |
| Notification names | 7 |
| Announcement keys and priority levels | 5 |
| Named text attribute constants | 12 |
| Selector literals | 43 |
| Role constants | 31 |
| Subrole constants | 7 |
| Other accessibility types | 4 |

---

## 6. macOS: the run loop and the delegate

### There is no run loop integration

The adapter creates no run loop, runs no run loop, schedules no source and
registers no observer. A search of every file under `AK/` for `CFRunLoop`,
`RunLoop`, `run_loop` and `addObserver` returns exactly one hit, and it is the
iOS adapter's `NSNotificationCenter` call at `AK/ios/src/adapter.rs:373`.

That is correct for this platform. AppKit already owns the main run loop of the
application process. An accessibility provider does not need a run loop of its
own because it never waits for anything. It answers message sends when the
system asks, and it posts notifications when the tree changes.

### How work reaches the adapter

There is one entry point from outside: the Objective-C runtime dispatches a
message to an object the adapter registered.

| Path | Entry | `path:line` |
|---|---|---|
| The system asks the window for its children | `children` on the dynamic view subclass | `AK/macos/src/subclass.rs:92-99` |
| The system asks the window for the focused element | `focus` | `AK/macos/src/subclass.rs:101-106` |
| The system hit-tests a point | `hit_test` | `AK/macos/src/subclass.rs:108-115` |
| The system asks about one node | any of the 54 methods in table M3 | `AK/macos/src/node.rs:411-1330` |

Each of those three view handlers immediately calls the adapter with a mutable
activation handler:

```text
children  -> Adapter::view_children  AK/macos/src/adapter.rs:223-246
focus     -> Adapter::focus         AK/macos/src/adapter.rs:248-262
hit_test  -> Adapter::hit_test      AK/macos/src/adapter.rs:275-294
```

All three go through `get_or_init_context` at `AK/macos/src/adapter.rs:174-221`,
which is where the tree is created on first use. There is no explicit activation
call. The first assistive technology query activates the adapter.

### How notifications become callbacks

They do not. The direction is the other way round. The adapter is the sender.
Nothing calls back into it because of a notification it posted.

| Step | Code | `path:line` |
|---|---|---|
| The tree changes | `EventGenerator` implements `TreeChangeHandler` | `AK/macos/src/event.rs:227-334` |
| The generator is drained | `into_result` | `AK/macos/src/event.rs:157-159` |
| The application raises the batch | `QueuedEvents::raise` | `AK/macos/src/event.rs:126-130` |
| Each event is posted to the platform | `QueuedEvent::raise` | `AK/macos/src/event.rs:46-105` |
| The system delivers to the assistive technology | outside the process | not observable here |

The three event variants are:

| Variant | What it posts | `path:line` |
|---|---|---|
| `Generic` | a notification about the node | `AK/macos/src/event.rs:48-54` |
| `NodeDestroyed` | `UIElementDestroyed`, after removing the node from the context | `AK/macos/src/event.rs:55-64` |
| `Announcement` | `AnnouncementRequested` on the window, with a text and priority | `AK/macos/src/event.rs:65-103` |

`NodeDestroyed` is the reason macOS and Windows differ. On macOS the node object
has to be taken out of `Context::platform_nodes` before the notification is
posted, because posting about a node that is still in the map would let the
system cache it (`AK/macos/src/event.rs:55-64`). On Windows the element is
constructed on demand for a node that no longer exists
(`AK/windows/src/adapter.rs:86-98`).

Context teardown posts a destroy notification for every node still registered
(`AK/macos/src/context.rs:91-102`).

### Ordering rules

| Rule | Reason in source | `path:line` |
|---|---|---|
| text change events are inserted at the front of the batch | text change events must precede selection change events | `AK/macos/src/event.rs:182-191` |
| a boolean value change on an unfocused node is inserted at the front | so that the focused node's boolean change is announced by VoiceOver last | `AK/macos/src/event.rs:272-283` |
| removing a subtree walks it with a queue, not recursion | bounded, non-recursive walk | `AK/macos/src/event.rs:161-172` |

### The threading rule

The rule is main thread only, and it is enforced by types rather than by checks.

| Mechanism | Where | `path:line` |
|---|---|---|
| `Context` is held in `Rc`, so it cannot cross a thread boundary | `Rc<Context>` | `AK/macos/src/context.rs:37-38`, `:61`, `AK/macos/src/adapter.rs:187` |
| the action handler is held in a `RefCell`, so it is not `Sync` | `ActionHandlerWrapper<H>(RefCell<H>)` | `AK/macos/src/context.rs:20`, `:27-32` |
| the adapter asserts the main thread once, at construction | `MainThreadMarker::new().unwrap()` | `AK/macos/src/adapter.rs:96` |
| the marker is carried in the context | `Context::mtm` | `AK/macos/src/context.rs:39`, `:65` |
| the doc comment states the rule | "This function must be called on the main thread" | `AK/macos/src/adapter.rs:81-82` |
| the subclassing entry point repeats it | "The action handler will always be called on the main thread" | `AK/macos/src/subclass.rs:129`, `:213` |

The lock rule that follows from this: no borrow may be held while
`QueuedEvents::raise` runs. The doc comment at `AK/macos/src/event.rs:120-125`
says so, because posting a notification can cause an accessibility method on the
view to run, and that method would try to borrow the same context. The Windows
adapter states the same rule at `AK/windows/src/adapter.rs:633-638`.

---

## 7. macOS: the patch

### What `patch.rs` is

`patch.rs` is 93 lines. It exports one public function:

```text
add_focus_forwarder_to_window_class(class_name: &str)  AK/macos/src/patch.rs:39-48
```

The function adds a method named `accessibilityFocusedUIElement` to an existing
`NSWindow` subclass. The method it adds is `focus_forwarder` at
`AK/macos/src/patch.rs:17-23`, and it forwards to the window's content view:

```text
- (id)accessibilityFocusedUIElement { return [self.contentView accessibilityFocusedUIElement]; }
```

### Why it exists

Some windowing libraries, SDL named in the doc comment at
`AK/macos/src/patch.rs:28-29`, put keyboard focus on the window object rather
than on its content view. VoiceOver asks the window for
`accessibilityFocusedUIElement`. On such a window class the inherited
implementation returns the wrong object or nothing, and the assistive technology
loses the focused element.

`SubclassingAdapter` does not fix this, because it works on the other object.
It subclasses the **view** and adds the four selectors in table M3's view block
to the view's class (`AK/macos/src/subclass.rs:176-203`). The window's class is
created by the application and the adapter never touches it. So the adapter
needs a separate, narrower operation: add one method to a class it did not
create.

No other adapter has an equivalent file.

| Adapter | Nearest equivalent | Why it is different |
|---|---|---|
| Windows | none | the entry point is a window message, handled by the subclass hook in `subclass.rs` |
| iOS | none | the same problem is solved by subclassing the view and forwarding `didMoveToWindow` (`AK/ios/src/subclass.rs:116-135`) |
| Android | `inject.rs`, 471 lines | that installs an `AccessibilityDelegate` object on a Java view; it does not patch a class, and it is a different mechanism |

### Why it is `unsafe`

The function is declared `unsafe` at `AK/macos/src/patch.rs:39`. The doc comment
at `AK/macos/src/patch.rs:31-38` gives two obligations on the caller:

1. The code must never be unloaded from the process, because a method added to
   an existing class cannot be removed. The Objective-C runtime offers no way to
   delete a method, and the class keeps its own copy of the method table layout
   that the runtime will keep routing calls through.
2. The named class must be a subclass of `NSWindow`. The code does not check it,
   and `AnyClass::get` returns `Option`, unwrapped at `AK/macos/src/patch.rs:40`.

### The local copy of `add_method`

The comment at `AK/macos/src/patch.rs:50-51` says the rest of the file is copied
from `objc2` with small changes, so that a method can be added to an existing
class. Two details in the local copy are load-bearing.

| Detail | Purpose | `path:line` |
|---|---|---|
| compare selector colon count with the number of function parameters | reject a signature that does not match the selector | `AK/macos/src/patch.rs:58-67`, `:81-83` |
| build the Objective-C type encoding string | `class_addMethod` needs the encoding to build the dispatch table entry | `AK/macos/src/patch.rs:69`, `:85-93` |
| assert `class_addMethod` returned true | fail loudly rather than leaving a half-patched class | `AK/macos/src/patch.rs:78` |

The encoding string is built at run time by `format!` at
`AK/macos/src/patch.rs:87-92`. That is a run-time allocation on a path that runs
once per class. A Zig port does better: `mitchellh/zig-objc` computes the
encoding at comptime from the Zig function type
(`/tmp/scratch/NativePlatformApis/zig-objc/src/class.zig:80`,
`comptimeEncode` exported at `src/main.zig:23`), and its `Class::addMethod`
(`src/class.zig:72-87`) calls `class_addMethod` on any class value, including one
from `getClass` (`src/class.zig:98-100`). So this file shrinks to the forwarding
function plus one call. The upstream local copy is not worth porting.

---

## 8. iOS and Android

### 8.1 iOS: what the adapter does that macOS does not

The iOS adapter is 2560 lines across eight files and is a near copy of the macOS
adapter with three structural changes. The crate is `accesskit_ios` 0.2.1
(`AK/ios/Cargo.toml:3`).

| Change | macOS | iOS | `path:line` |
|---|---|---|---|
| Framework | `objc2-app-kit` 0.2.0 | `objc2-ui-kit` 0.2.0 | `AK/macos/Cargo.toml:28`, `AK/ios/Cargo.toml:31` |
| Node super class | `NSAccessibilityElement` | `UIAccessibilityElement` | `AK/macos/src/node.rs:402`, `AK/ios/src/node.rs:206` |
| Element protocol | informal `accessibility*` selectors | `UIAccessibilityElement` formal protocol | `AK/ios/src/node.rs:215` |
| Actions | `accessibilityPerformPress`, `Pick`, `Increment`, `Decrement` | `accessibilityActivate`, `accessibilityIncrement`, `accessibilityDecrement` | `AK/ios/src/node.rs:303`, `:323`, `:341` |
| Traits | none, macOS has no trait bitmask | `accessibilityTraits` | `AK/ios/src/node.rs:267` |
| Container type | none | `accessibilityContainerType` | `AK/ios/src/node.rs:411` |
| Scroll | a legacy string action name `AXScrollToVisible` | `accessibilityScroll:` with a direction enum | `AK/ios/src/node.rs:359` |
| Expand state | not present | `accessibilityExpandedStatus` | `AK/ios/src/node.rs:293` |
| Focus tracking | none, the system asks the window | `accessibilityElementDidBecomeFocused` and `accessibilityElementDidLoseFocus` | `AK/ios/src/node.rs:420`, `:427` |
| Element filter | `common_filter` | `filter_for_is_accessibility_element` | `AK/macos/src/filters.rs:6`, `AK/ios/src/filters.rs:27-52` |

### 8.2 iOS: the element filter is a new rule, and it is unit tested

`filter_for_is_accessibility_element` at `AK/ios/src/filters.rs:27-52` exists
only on iOS. Its doc comment at `AK/ios/src/filters.rs:12-26` gives the reason:
on iOS a node with focusable children must not itself be an accessibility
element, or VoiceOver ignores the children. A node with actions, a value or a
toggled state is always a leaf, because its descendants are collapsed into its
label. Otherwise the node stays a container.

This is pure logic over an `accesskit_consumer::Tree`. It runs on any host. The
upstream ships three unit tests for it at `AK/ios/src/filters.rs:54-129`, so a
Zig port inherits a ready-made test vector:

| Test | `path:line` |
|---|---|
| `leaf_button_is_element` | `AK/ios/src/filters.rs:88-97` |
| `hidden_node_excluded` | `AK/ios/src/filters.rs:99-109` |
| `checkbox_with_label_child_is_leaf` | `AK/ios/src/filters.rs:111-129` |

### 8.3 iOS: view-hierarchy traversal and subclassing

UIKit does not push children. It pulls them. The view must implement
`UIAccessibilityContainer` by returning an `accessibilityElements` array and
answering `accessibilityHitTest:`.

The adapter offers two ways to supply that. The low-level `Adapter` requires the
host application to forward the messages itself. Its doc comment at
`AK/ios/src/adapter.rs:293-318` lists the five steps, and the three methods it
expects are:

| Adapter method | Selector to forward | `path:line` |
|---|---|---|
| `Adapter::is_accessibility_element` | `isAccessibilityElement` | `AK/ios/src/adapter.rs:452-455` |
| `Adapter::accessibility_elements` | `accessibilityElements` | `AK/ios/src/adapter.rs:459-480` |
| `Adapter::hit_test` | `accessibilityHitTest:` | `AK/ios/src/adapter.rs:486-503` |

Note that `is_accessibility_element` returns `false` unconditionally at
`AK/ios/src/adapter.rs:452-455`. That is deliberate. The adapter exposes itself
as a pure container, and the per-node answer comes from
`PlatformNode::is_element` at `AK/ios/src/node.rs:232-236`, which does apply the
filter from section 8.2.

`SubclassingAdapter` does the forwarding itself, through dynamic subclassing.
It adds five selectors to a copy of the view's class:

| Selector | Handler | `path:line` |
|---|---|---|
| `superclass` | `superclass` | `AK/ios/src/subclass.rs:80-83`, registered at `:214` |
| `isAccessibilityElement` | `is_accessibility_element` | `AK/ios/src/subclass.rs:87-92`, registered at `:218` |
| `accessibilityElements` | `accessibility_elements` | `AK/ios/src/subclass.rs:94-99`, registered at `:222` |
| `accessibilityHitTest:` | `accessibility_hit_test` | `AK/ios/src/subclass.rs:103-112`, registered at `:226` |
| `didMoveToWindow` | `did_move_to_window` | `AK/ios/src/subclass.rs:116-135`, registered at `:230` |

`superclass` exists because some view classes call `[self superclass]` to find
their own super class, and the comment at `AK/ios/src/subclass.rs:77-79` says
those classes assume they are the lowest subclass. The macOS adapter has the
same handler at `AK/macos/src/subclass.rs:87-90`.

`didMoveToWindow` is the iOS-only lifecycle hook. It forwards to the previous
implementation first, then activates the adapter if the view now has a window
(`AK/ios/src/subclass.rs:116-135`).

### 8.4 iOS: lifecycle differences

iOS adds three lifecycle facts that neither desktop adapter has.

| Fact | Consequence | `path:line` |
|---|---|---|
| the adapter may be created after the view is already in a window | `SubclassingAdapter::new` calls `view_did_appear` manually, because UIKit will not replay `didMoveToWindow` | `AK/ios/src/subclass.rs:247-253` |
| assistive technology can be switched on and off at run time | the adapter watches nine system notifications and activates or deactivates the tree | `AK/ios/src/adapter.rs:105-119`, `:258-275`, `:371-380` |
| the tree must not be built when nothing needs it | `try_activate` returns early unless an assistive technology is running | `AK/ios/src/adapter.rs:190-206` |

The nine observed notifications are:

| Notification | `path:line` |
|---|---|
| `UIAccessibilityVoiceOverStatusDidChangeNotification` | `AK/ios/src/adapter.rs:108` |
| `UIAccessibilitySwitchControlStatusDidChangeNotification` | `AK/ios/src/adapter.rs:109` |
| `UIAccessibilitySpeakScreenStatusDidChangeNotification` | `AK/ios/src/adapter.rs:110` |
| `UIAccessibilityInvertColorsStatusDidChangeNotification` | `AK/ios/src/adapter.rs:111` |
| `UIAccessibilityReduceMotionStatusDidChangeNotification` | `AK/ios/src/adapter.rs:112` |
| `UIAccessibilityBoldTextStatusDidChangeNotification` | `AK/ios/src/adapter.rs:113` |
| `UIAccessibilityDarkerSystemColorsStatusDidChangeNotification` | `AK/ios/src/adapter.rs:114` |
| `UIAccessibilityOnOffSwitchLabelsDidChangeNotification` | `AK/ios/src/adapter.rs:115` |
| `UIAccessibilityVideoAutoplayStatusDidChangeNotification` | `AK/ios/src/adapter.rs:116` |

The three assistive-technology predicates that gate activation are
`UIAccessibilityIsVoiceOverRunning`, `UIAccessibilityIsSwitchControlRunning` and
`UIAccessibilityIsSpeakScreenEnabled`, short-circuited at
`AK/ios/src/adapter.rs:97-103`. This is the only notification observer in the
whole tree. It is removed in `Drop` at `AK/ios/src/adapter.rs:506-513`.

iOS events are a small closed set. The adapter posts exactly four notification
values, all through `UIAccessibilityPostNotification`:

| Notification | `path:line` |
|---|---|
| `UIAccessibilityLayoutChangedNotification` | `AK/ios/src/event.rs:135` |
| `UIAccessibilityScreenChangedNotification` | `AK/ios/src/event.rs:142` |
| `UIAccessibilityAnnouncementNotification` | `AK/ios/src/event.rs:92`, `:99` |
| `UIAccessibilitySpeechAttributeQueueAnnouncement` | `AK/ios/src/event.rs:85` |

iOS collapses the desktop event set into one layout-changed event per update,
with the focused node as its argument. `insert_layout_changed_event_if_needed`
at `AK/ios/src/event.rs:170-174` sets a flag, and `into_result` at
`AK/ios/src/event.rs:198-204` emits at most one at the end.

### 8.5 iOS: runtime symbol resolution

Four UIKit constants are read at run time with `dlsym` instead of being linked,
because they may not exist on older iOS versions:

| Symbol | Fallback | `path:line` |
|---|---|---|
| `UIAccessibilityTraitToggleButton` | 0 | `AK/ios/src/util.rs:77-87` |
| `UIAccessibilityPriorityHigh` | `None`, downgrade the announcement | `AK/ios/src/util.rs:100-102` |
| `UIAccessibilityPriorityLow` | `None`, downgrade the announcement | `AK/ios/src/util.rs:104-106` |
| `UIAccessibilitySpeechAttributeAnnouncementPriority` | `None`, plain string announcement | `AK/ios/src/util.rs:108-110` |

The `dlsym` declaration is written by hand at `AK/ios/src/util.rs:73-75` and
`RTLD_DEFAULT` is `-2isize` at `AK/ios/src/util.rs:71`. This is the one place in
the whole tree where a port can use `std.DynLib` instead of a hand-written
declaration.

### 8.6 Android: the boundary is Java, not a platform C API

The Android adapter is `accesskit_android` 0.9.0 (`AK/android/Cargo.toml:3`).
It depends on `jni` 0.21.1 (`AK/android/Cargo.toml:21`) and on `log` 0.4.17
(`AK/android/Cargo.toml:22`). It calls no native platform API at all. It calls
Java methods on `android.view.View`,
`android.view.accessibility.AccessibilityNodeInfo` and
`android.view.accessibility.AccessibilityEvent` through JNI.

The Java boundary has a size, and it is worth stating once because it decides
how much of the port is hand-written. Measured across the eight files under
`AK/android/src/`:

| Kind | Count | How it was measured |
|---|---:|---|
| `call_method` and `call_static_method` call sites | 78 | a scan for the two method names: 3 in `adapter.rs`, 31 in `event.rs`, 9 in `inject.rs`, 26 in `node.rs`, 9 in `util.rs` |
| distinct Java method names written as string literals | 68 | every quoted lowercase string with no `/` in it, less 10 non-method literals |
| Java class descriptors | 19 | a scan for `L…;` returns 22 matches, 3 of which are the tail of a Rust identifier such as `GRANULARITY`, `SCROLL_BACKWARD` or `JNI_FALSE` rather than a descriptor |
| integer and string constants | 43 | `AK/android/src/util.rs:14-68` |
| `JNIEnv` entry points | 13 | the method names the adapter calls on `JNIEnv` |
| native methods registered for the Java delegate | 5 | `runCallback`, `createAccessibilityNodeInfo`, `findFocus`, `performAction`, `onHoverEvent` |

The 68 is the figure that matters for the port, because a Zig port passes each
name to `GetMethodID` itself.
`docs/42-native-adapter-build-map.md` section 1.4.2 holds the flat list of all
68.

Three structural things follow from that and none of them exist on the desktop
adapters.

#### 8.6.1 Nodes are pushed, not pulled

The desktop adapters answer method calls. Android has no such method. Instead
the adapter fills an `AccessibilityNodeInfo` and hands it back:

| Step | `path:line` |
|---|---|
| obtain a node info object for a virtual view id | `AK/android/src/adapter.rs:322-355` |
| set the package name | `AK/android/src/adapter.rs:357-364` |
| fill every property | `AK/android/src/node.rs:196-445` |
| set the accessibility focus flag and action | `AK/android/src/adapter.rs:369-385` |

The property setters called in `populate_node_info` are:

| Setter | `path:line` |
|---|---|
| `setSource`, `setPackageName`, bounds from `getLocationOnScreen` | `AK/android/src/node.rs:204-241` |
| `android.graphics.Rect` construction | `AK/android/src/node.rs:241` |
| `setCheckable`, `setChecked` | `AK/android/src/node.rs:264-269` |
| `setEnabled` | `AK/android/src/node.rs:276` |
| `setFocused` | `AK/android/src/node.rs:285` |
| `setVisibleToUser` | `AK/android/src/node.rs:309` |
| `setContentDescription`, `setText` | `AK/android/src/node.rs:313-333` |
| `getExtras` for extra properties | `AK/android/src/node.rs:344` |
| `AccessibilityAction` construction | `AK/android/src/node.rs:419` |
| `setLiveRegion` | `AK/android/src/node.rs:444` |
| `addAction` | `AK/android/src/node.rs:17-23` |

#### 8.6.2 Every node needs a numeric virtual view id

Android identifies a node inside a host view by an integer, not by an object.
The adapter therefore maintains its own two-way map:

| Item | `path:line` |
|---|---|
| the map itself | `AK/android/src/util.rs:134-138` |
| `jint -> FullNodeId` | `AK/android/src/util.rs:141-143` |
| `NodeRef -> jint`, allocating on demand | `AK/android/src/util.rs:145-158` |
| the root maps to the sentinel `-1` | `AK/android/src/util.rs:52`, `:146-148` |
| the counter starts at 0 and only grows | `AK/android/src/util.rs:137`, `:153-154` |

The sentinel `HOST_VIEW_ID = -1` is `AK/android/src/util.rs:52`. It appears in
every event the adapter sends (`AK/android/src/adapter.rs:31-33`).

#### 8.6.3 Events go out through the parent view

An `AccessibilityEvent` is delivered by asking the host's parent to send it:

| Step | `path:line` |
|---|---|
| obtain an event object | `AK/android/src/event.rs:21-33` |
| set the package name and source | `AK/android/src/event.rs:34-48` |
| ask the parent to send it | `AK/android/src/event.rs:52-70` |
| a null parent means the view was detached, so skip | `AK/android/src/event.rs:58-62` |

Text change events need before and after indices. The adapter computes them with
a UTF-16 diff of the old and new text at `AK/android/src/event.rs:96-152`. The
comment at `AK/android/src/event.rs:126-127` says the index arithmetic assumes
signed indices, translated from Flutter.

The event constants are all in `AK/android/src/util.rs:14-68`, which declares 43
of them. They are plain integers and strings, not a header, so a Zig port copies
them verbatim. Examples: `EVENT_WINDOW_CONTENT_CHANGED` at `:47`,
`CONTENT_CHANGE_TYPE_SUBTREE` at `:34`, `ACTION_SET_PROGRESS` at `:23`.

### 8.7 Android: the lifecycle difference is a hard Java dependency

The low-level `Adapter` at `AK/android/src/adapter.rs:257-264` needs no Java
class. It takes a `JNIEnv` and a host `JObject` from its caller.

The high-level `InjectingAdapter` does. Its doc comment at
`AK/android/src/inject.rs:297-307` says it depends on the Java class
`dev.accesskit.android.Delegate`, whose source is in the crate's `java`
directory. That file is 70 lines of Java.

There are two ways to load it, selected by a Cargo feature:

| Mode | Mechanism | `path:line` |
|---|---|---|
| default | `find_class("dev/accesskit/android/Delegate")`, so the app must ship it | `AK/android/src/inject.rs:256` |
| `embedded-dex` | `include_bytes!("../classes.dex")` into an `InMemoryDexClassLoader` | `AK/android/src/inject.rs:225-254` |

Either way, native methods are registered with `register_native_methods` at
`AK/android/src/inject.rs:257`.

Threading is the last lifecycle difference. `InjectingAdapter::update_if_active`
may be called from any thread. It attaches the calling thread to the JVM and
posts the work to the UI thread:

| Step | `path:line` |
|---|---|
| the rule in the doc comment | `AK/android/src/inject.rs:398-401` |
| attach and post | `AK/android/src/inject.rs:412-430` |
| the shared state that makes this safe | `AK/android/src/inject.rs:313`, an `Arc<Mutex<InnerInjectingAdapter>>` |

That is the only adapter in the tree that takes its handlers on a background
thread and marshals them to the UI thread itself.

---

## 9. Zig binding reality

### 9.1 The decision order, applied to each platform

The house rule for dependencies is: Zig standard library first, a Zig package
second, `translate-c` third, a hand-written C shim fourth. This section states
the rung for every boundary in this document and why it cannot sit higher.

| Platform | Boundary | Rung | Package or header | Why not higher |
|---|---|---|---|---|
| Windows | UI Automation and Win32 | 2, Zig package | `marlersoft/zigwin32` | no Zig package was found for UIA until this one; `mitchellh/zig-objc` does not apply |
| Windows | COM object plumbing | 1, Zig source in this project | none | Zig 0.16 has no `std.com`; the vtables come from zigwin32 but the object base does not exist anywhere |
| macOS | Objective-C runtime | 2, Zig package | `mitchellh/zig-objc` | the runtime is libobjc, which is not a Zig library |
| macOS | associated objects, `object_setClass` | 3, `translate-c` | `objc/runtime.h` | zig-objc does not expose these three functions; the header is plain C apart from one declaration |
| macOS | AppKit | 4, hand-written | none | AppKit headers are Objective-C; `translate-c` cannot parse them |
| iOS | UIKit | 4, hand-written | none | UIKit headers are Objective-C; `translate-c` cannot parse them |
| iOS | `dlsym` constants | 1, Zig standard library | `std.DynLib` | no binding needed |
| Android | JNI | 3, `translate-c` | `jni.h` | plain C header that `translate-c` parses; verified below |
| Android | the Java delegate | not a Zig concern | Java source | 70 lines of Java the port must ship |

### 9.2 Windows: `marlersoft/zigwin32` covers the whole boundary

Repository: `https://github.com/marlersoft/zigwin32`. Checked out at commit
`9f15c276b4e9d05afd34a10d8662a7dfc34647ea`, dated 2026-07-20, licence MIT.
Package name `.win32`, version `42.0.39-preview`, and
`minimum_zig_version = "0.14.0"`, so a Zig 0.16.0 build may fetch it.

Its `build.zig` is seven lines. It only exposes a module and never touches the
Windows SDK:

```text
/tmp/scratch/NativePlatformApis/zigwin32/build.zig:3-6
    pub fn build(b: *std.Build) void {
        _ = b.addModule("win32", .{
            .root_source_file = b.path("win32.zig"),
        });
    }
```

Every symbol in tables W1 to W12 is present. Verified by grep in the checkout:

| File | Lines | Contains |
|---|---|---|
| `win32/ui/accessibility.zig` | 10179 | `IRawElementProviderSimple`, `ITextRangeProvider`, `ITextProvider`, `IWindowProvider` and every other UIA interface with a full `VTable` struct |
| `dll/uiautomationcore.zig` | 694 | all seven `uiautomationcore` functions |
| `dll/user32.zig` | not counted | all eight `user32` functions |
| `dll/oleaut32.zig` | not counted | `SafeArrayCreateVector`, `SafeArrayPutElement`, `VariantInit`, `VariantClear` |
| `dll/ole32.zig` | not counted | `CoInitializeEx`, `CoCreateInstance`, `CoTaskMemFree` |
| `dll/kernel32.zig` | not counted | `LocaleNameToLCID` |

The interface declarations carry the vtable layout that a Zig implementation has
to fill. For example `IRawElementProviderSimple` at
`win32/ui/accessibility.zig:2220-2262` declares `VTable` as an `extern struct`
whose fields are `*const fn (...) callconv(.winapi) HRESULT`, and `IUnknown` at
`win32/system/com.zig:5239-5263` declares `QueryInterface`, `AddRef` and
`Release` the same way.

Two differences from `windows-rs` that the port design must record:

| Difference | `windows-rs` | zigwin32 | `path` |
|---|---|---|---|
| namespace depth | `windows::Win32::UI::Accessibility` | `win32.ui.accessibility`, reached through the `win32` root module | `win32.zig:5-23` |
| visibility of types | every type is public | many are private aliases, so `uia.HWND` fails but `win32.foundation.HWND` works | `win32/ui/accessibility.zig:10148` |
| `VARENUM` | a newtype that wraps a `u16` | `enum(u16)` with named values, so `VT_I4` is the value `.I4` and not a type | `win32/system/com.zig:6456`, `:6513` |

#### Compile probe, run on this host

A probe file that names the seven `uiautomationcore` functions, the UIA
constants and the `user32` and `oleaut32` entry points was compiled for
`x86_64-windows` with Zig 0.16.0:

```text
$ zig 0.16.0 build-obj -target x86_64-windows --dep zigwin32 -Mroot=wtest.zig -Mzigwin32=zigwin32/win32.zig -femit-bin=wtest.o
$ ls -la wtest.o
32432 wtest.o
```

No error, no warning. The probe source, recorded here so the claim can be
reproduced after the scratch checkout is removed:

```zig
const w = @import("zigwin32");
const uia = w.ui.accessibility;

pub export fn probe(hwnd: w.foundation.HWND) callconv(.winapi) i64 {
    const id: i32 = w.uiautomationcore.UiaLookupId(.Property, &uia.ControlType_Property_GUID);
    var provider: ?*uia.IRawElementProviderSimple = null;
    _ = w.uiautomationcore.UiaHostProviderFromHwnd(hwnd, &provider);
    const attr: uia.UIA_TEXTATTRIBUTE_ID = uia.UIA_IsReadOnlyAttributeId;
    const evt: uia.UIA_EVENT_ID = uia.UIA_Text_TextChangedEventId;
    const prop: uia.UIA_PROPERTY_ID = uia.UIA_NamePropertyId;
    const vt: w.system.com.VARENUM = .I4;
    _ = w.user32.ClientToScreen(hwnd, null);
    _ = w.uiautomationcore.UiaRaiseAutomationEvent(provider, evt);
    _ = prop; _ = vt; _ = attr;
    return id;
}
```

The zigwin32 checkout used for every citation in this section was at
`/tmp/scratch/NativePlatformApis/zigwin32`, cloned at depth 1 from
the repository and commit named above. The zig-objc checkout was at
`/tmp/scratch/NativePlatformApis/zig-objc`. Both are temporary and
are removed. Fetch them at the recorded commits to re-check any line number here.

### 9.3 Windows: what zigwin32 does not give

zigwin32 provides types and extern declarations. It provides no COM object
factory. Zig 0.16.0 ships no `std.com`: the standard library directory listing
for `/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/std`
has no `com.zig`, and a grep of `std.zig` for `com` finds no such declaration.

So a Zig port writes the object base itself. What `windows-rs` gives for free and
`zigwin32` does not:

| Capability the Rust code uses | Where the Rust code uses it | What a Zig port must write |
|---|---|---|
| `#[implement(I...)]` builds a COM object with refcounting | `AK/windows/src/node.rs:790`, `AK/windows/src/text.rs:209` | a struct with an atomic refcount, a `vtable` pointer and three `extern fn` thunks |
| `ComObject<T>::into_object` | `AK/windows/src/node.rs:816`, `:824` | allocate the object and write the vtable pointer |
| `IUnknown::cast::<T>()` | `AK/windows/src/node.rs:1050`, `:1426` | an explicit `QueryInterface` call with the IID constant |
| `Ref<T>` null-checked parameters | `AK/windows/src/text.rs:326`, `:338`, `:575`; `util.rs:356-358` | a check on the pointer that `translate-c` or zigwin32 types as `?*T` |
| `.as_impl()` to get from an interface pointer to the object | `AK/windows/src/text.rs:326`, `:338`, `:575` | pointer arithmetic from the interface pointer to the containing object |
| `Result<T>` carrying `HRESULT` | everywhere | an explicit check that the HRESULT is not negative, plus a conversion to an error set |
| `Send` and `Sync` assertions | `AK/windows/src/node.rs:1535-1538`, `AK/windows/src/text.rs:648-651` | a compile-time check on the Zig struct |

None of that is in the way. It is about 120 lines of one module, it is pure Zig,
and it is the only place in the Windows port where new code appears that has no
upstream counterpart.

### 9.4 Windows: the adapter never calls a COM apartment function

A search of `AK/windows/src/` for `CoInitialize`, `CoCreateInstance`,
`VariantInit`, `VariantClear` and `CoTaskMem` finds nothing outside the test
harness. The adapter relies on the application having initialized COM, and on
`windows-rs` to manage `VARIANT` lifetimes. A Zig port must decide who calls
`VariantClear` for every `VARIANT` it hands to the platform. `[INFERENCE]`
`windows-rs` does this in the `Drop` implementation of `windows::core::VARIANT`,
which is why the adapter source never names the function. The Zig port has no
such automatic lifetime, so it needs an explicit owner type.

The test harness shows the sequence a Windows test needs, and why it is out of
reach here:

| Step | `path:line` |
|---|---|
| create a real window on a real thread | `AK/windows/src/tests/mod.rs:225-231` |
| `CoInitializeEx(None, COINIT_MULTITHREADED)` | `AK/windows/src/tests/mod.rs:249` |
| `CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER)` | `AK/windows/src/tests/mod.rs:252-253` |
| wait for a real `AutomationFocusChanged` event | `AK/windows/src/tests/mod.rs:302-...`, wait loop at `:278-293` |

The test suite is three files, 337, 198 and 177 lines. It needs a window manager,
a COM apartment and a UI Automation client. None of those exist on this host.

---

### 9.5 macOS and iOS: `translate-c` cannot parse an Objective-C header

This is the single fact that decides the rung for both Apple adapters. It was
tested with Zig 0.16.0 on this host. The input file was a three-declaration
Objective-C header:

```text
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface NSView : NSResponder
@property (nonatomic, getter=isAccessibilityElement) BOOL accessibilityElement;
- (nullable NSArray *)accessibilityChildren;
@end
NS_ASSUME_NONNULL_END
```

The command and its output:

```text
$ zig 0.16.0 translate-c nsview.h
error: translation failure
nsview.h:1:1: error: invalid preprocessing directive
#import <Foundation/Foundation.h>
^
nsview.h:2:1: error: type specifier missing, defaults to 'int'; ISO C99 and later do not support implicit int
NS_ASSUME_NONNULL_BEGIN
^
nsview.h:3:1: error: expected ';', found invalid bytes
@interface NSView : NSResponder
^
nsview.h:3:2: error: unknown type name 'interface'
@interface NSView : NSResponder
 ^
nsview.h:3:19: error: expected ';', found ':'
@interface NSView : NSResponder
                  ^
```

`#import`, `NS_ASSUME_NONNULL_BEGIN` and `@interface` are all outside the C
grammar. Every AppKit and UIKit public header uses all three. So no amount of
preprocessor configuration makes `translate-c` read `<AppKit/AppKit.h>` or
`<UIKit/UIKit.h>`.

For contrast, `translate-c` handles a resolved COM C header cleanly. The probe
declared a vtable struct and two `__stdcall` functions and produced this:

```text
pub const struct_IUnknownVtbl = extern struct {
    QueryInterface: ?*const fn (self: ?*anyopaque, riid: ?*const anyopaque, ppv: [*c]?*anyopaque) callconv(.c) HRESULT = null,
    AddRef: ?*const fn (self: ?*anyopaque) callconv(.c) ULONG = null,
    Release: ?*const fn (self: ?*anyopaque) callconv(.c) ULONG = null,
};
pub const struct_IRawElementProviderSimple = extern struct {
    lpVtbl: [*c]const IUnknownVtbl = null,
    GetPropertyValue: ?*const fn (self: [*c]struct_IRawElementProviderSimple, propertyId: PROPERTYID, pRetVal: [*c]VARIANT) callconv(.c) HRESULT = null,
};
```

So the split is clean. Windows and JNI headers are C and translate. Apple
framework headers are Objective-C and do not.

One more limit inside `translate-c` itself, reported by the zig-objc build script:
Zig 0.16 cannot parse Clang block declarators, the caret syntax, in
`objc/runtime.h`. The zig-objc authors patch one declaration to work around it,
and they file that as a compiler bug at
`codeberg.org/ziglang/zig/issues/31917`
(`/tmp/scratch/NativePlatformApis/zig-objc/build.zig:68-85`).

### 9.6 macOS: what `mitchellh/zig-objc` covers

Repository `https://github.com/mitchellh/zig-objc`, commit
`c8de82ff80281215ad92900866dab7103a8efa8b` dated 2026-04-16, 355 stars at the
time of checking, MIT licence. Its `build.zig.zon` declares `.name = .zig_objc`,
version `0.0.0`, no `.minimum_zig_version` and `.dependencies = .{}`. Twelve
source files, 364 KB.

| Adapter need | zig-objc equivalent | `path` |
|---|---|---|
| `AnyClass::get` | `getClass` | `src/class.zig:98-100` |
| `ClassBuilder::new`, `builder.add_method`, `builder.register` | `allocateClassPair`, `Class::addMethod`, `registerClassPair` | `src/class.zig:107-117`, `:72-87` |
| add a method to an existing class in `patch.rs` | `Class::addMethod` on a class from `getClass` | `src/class.zig:72-87` |
| `class_addMethod` type encoding string built at run time | `comptimeEncode` at comptime | `src/class.zig:80`, exported at `src/main.zig:23` |
| `msg_send!`, `sel!` | `msg_send`, `sel` | `src/main.zig:29-30` |
| `Id::retain`, `Id::autorelease_return` | `Object`, autorelease pool | `src/main.zig:14-15`, `src/object.zig`, `src/autorelease.zig` |

Three functions the macOS and iOS adapters need are absent. A grep for
`AssociatedObject` and `object_setClass` over `src/*.zig` returns nothing.

| Missing function | Adapter use | `path` |
|---|---|---|
| `objc_getAssociatedObject` | find the state attached to the view | `AK/macos/src/subclass.rs:77`, `AK/ios/src/subclass.rs:71` |
| `objc_setAssociatedObject` | attach and detach the state | `AK/macos/src/subclass.rs:164`, `AK/ios/src/subclass.rs:199` |
| `object_setClass` | swap the view's class | `AK/macos/src/subclass.rs:203`, `AK/ios/src/subclass.rs:242` |

Those three live in `objc/runtime.h`, which is plain C apart from one block
declaration. That is rung 3, and zig-objc's own build script proves it works: it
translates `objc/runtime.h` and `objc/message.h` at
`/tmp/scratch/NativePlatformApis/zig-objc/build.zig:96-111`.

So the macOS port uses two dependencies: zig-objc for class pairs, methods,
selectors and message sends, plus a three-function `translate-c` module for the
associated-object calls. Nothing in the macOS port needs a C shim, and nothing
needs a hand-written Objective-C parser.

### 9.7 macOS: the zig-objc build script cannot run on this host

`zig-objc` cannot be consumed as a `build.zig.zon` dependency on a Linux machine.
Its `build.zig` calls `translateCModule` unconditionally at `build.zig:15`, before
the `-Dadd-paths` option is consulted at `build.zig:23`. `translateCModule` calls
`appleSDKPath` at `build.zig:59`, and `appleSDKPath` runs `xcrun` and returns
`error.XcodeMacOSSDKNotFound` when there is no SDK, at `build.zig:161`.

Three ways out, in order of preference:

1. Vendor the six needed declarations as one small Zig module. The functions are
   three `extern` declarations with pointer arguments. There is no dependency to
   gain and no build script to fix.
2. Build the module once on a Mac, check the generated Zig into the repository,
   and consume it as a checked-in source file.
3. Use zig-objc unchanged, and accept that macOS and iOS builds only run on
   macOS. This makes the local gate weaker than the house rules require.

### 9.8 iOS: there is no UIKit binding, and none is coming from the ecosystem

A GitHub repository search for Zig UIKit bindings returns nothing. The searches
run were `zig+win32+bindings`, `windows+bindings+language:zig`,
`uiautomation+language:zig` and `zig+objc+bindings`. The only Objective-C
projects found were `mitchellh/zig-objc` on GitHub, a fork at
`codeberg.org/dotcarmen/zig-objc` with 1 star and 4 commits, and
`codeberg.org/zig-release-compat/mach-objc`, a generated binding collection for
Metal and AVFAudio that does not cover UIKit.

So the iOS port has two parts:

| Part | Rung | Size |
|---|---|---|
| the Objective-C runtime and the notification observer | rung 2, zig-objc plus three hand-declared externs | small |
| every `UIAccessibility` constant, trait bit and notification name | rung 4, hand-written Zig constants | 39 named identifiers plus 4 resolved by `dlsym`, 43 distinct |

A scan for the `UIAccessibility` prefix over the eight files under
`AK/ios/src/` returns 43 distinct identifiers. Four of them also appear as a
`dlsym` string literal, so 39 are named in source and 4 exist only as strings:

| Kind | Count | Members |
|---|---:|---|
| class, protocol and enum types | 10 | `UIAccessibilityContainer`, `UIAccessibilityContainerType`, `UIAccessibilityConvertFrameToScreenCoordinates`, `UIAccessibilityElement`, `UIAccessibilityExpandedStatus`, `UIAccessibilityHitTest`, `UIAccessibilityNotifications`, `UIAccessibilityPriority`, `UIAccessibilityScrollDirection`, `UIAccessibilityTraits` |
| trait constants | 13 | `Adjustable`, `AllowsDirectInteraction`, `Button`, `Header`, `Image`, `Link`, `None`, `NotEnabled`, `SearchField`, `Selected`, `StaticText`, `ToggleButton`, `UpdatesFrequently` |
| observed notifications | 9 | `BoldTextStatusDidChange`, `DarkerSystemColorsStatusDidChange`, `InvertColorsStatusDidChange`, `OnOffSwitchLabelsDidChange`, `ReduceMotionStatusDidChange`, `SpeakScreenStatusDidChange`, `SwitchControlStatusDidChange`, `VideoAutoplayStatusDidChange`, `VoiceOverStatusDidChange` |
| posted notifications | 4 | `AnnouncementNotification`, `LayoutChangedNotification`, `ScreenChangedNotification`, `SpeechAttributeQueueAnnouncement` |
| accessibility-status predicates | 3 | `UIAccessibilityIsVoiceOverRunning`, `UIAccessibilityIsSwitchControlRunning`, `UIAccessibilityIsSpeakScreenEnabled` |
| posting function | 1 | `UIAccessibilityPostNotification` |
| run-time string literals only | 3 | `UIAccessibilityPriorityHigh`, `UIAccessibilityPriorityLow`, `UIAccessibilitySpeechAttributeAnnouncementPriority` |
| **Total** | **43** | |

Each member carries the `UIAccessibility` prefix, plus a `Trait` or
`Notification` infix where the name repeats one. Twelve of the trait constants
are named in the `traits` function at `AK/ios/src/node.rs:124-165`; the
thirteenth, `ToggleButton`, comes from `toggle_button_trait()`, which is the
first of the four `dlsym` lookups. The container types are named in
`container_type` at `:167-188`. The 9 observed notifications are the array
literal at `AK/ios/src/adapter.rs:105-119`, the 3 predicates short-circuit at
`:97-103`, and the 4 posted notifications are listed in section 8.4.

The four `dlsym` constants need no hand-written declarations. `std.DynLib` opens
the process and resolves a symbol. The Rust code writes its own `dlsym` binding
at `AK/ios/src/util.rs:73-75`; a Zig port replaces that with `std.DynLib`.

### 9.9 Android: the header is bindable, the Java class is not

`jni.h` is plain C and `translate-c` parses it. Test run on this host against a
host JDK 25 header:

```text
$ zig 0.16.0 translate-c -I$JH -I$JH/linux -lc -target x86_64-linux-gnu $JH/jni.h
const __root = @This();
pub const __builtin = @import("std").zig.c_translation.builtins;
...
```

No error. So the JNI boundary is rung 3 and needs no shim. Note that this test
used a desktop JDK header, not an Android NDK header. The NDK is not installed
on this host, so the exact header the port would use is unverified here.

The Android port still cannot be tested here, for two independent reasons:

1. It needs an Android device or emulator. There is no `adb` on this host and no
   `ANDROID_HOME`.
2. It needs a Java class, `dev.accesskit.android.Delegate`, 70 lines of Java at
   `AK/android/java/dev/accesskit/android/Delegate.java`, or a prebuilt
   `classes.dex`. A Zig build cannot produce either one without a Java toolchain
   in the loop, and the crate solves this with an `include_bytes!` of a prebuilt
   dex at `AK/android/src/inject.rs:230`.

### 9.10 What this host can and cannot do, stated plainly

**Windows and macOS cannot be built or tested on this host.** There is no
Windows machine, no macOS machine, no Windows SDK and no Apple SDK. A build that
produces a PE or Mach-O file here produces an artifact that cannot be run, and
the platform behaviour that matters, which is the answer to `WM_GETOBJECT` and
the Objective-C message traffic, cannot be observed at all.

The Rust upstream agrees. The Windows test suite creates a real window and a
real UI Automation client (`AK/windows/src/tests/mod.rs:225-253`) and waits for
a real focus event (`:278-293`). Those tests cannot run here and neither can
their Zig equivalent.

What this host can verify, measured, not guessed:

| Check | Command shape | Result on this host |
|---|---|---|
| cross compile | `zig build-obj -target x86_64-windows` | works, 3848432-byte object |
| cross compile | `zig build-obj -target aarch64-macos` | works, 2979320-byte object |
| cross compile | `zig build-obj -target aarch64-ios` | works, 2939968-byte object |
| cross compile | `zig build-obj -target aarch64-linux-android` | works, 3902912-byte object |
| cross link | `zig build-exe -target x86_64-windows` | works, 1731584-byte PE, header `MZ` |
| cross link | `zig build-exe -target x86_64-windows -luiautomationcore` | works, 1731584 bytes |
| cross link | `zig build-exe -target x86_64-windows -luser32` | works, 1731584 bytes |
| cross link | `zig build-exe -target aarch64-macos` | works, 1873120-byte Mach-O, magic `feedfacf` |
| cross link | `zig build-exe -target aarch64-macos -lobjc` | fails, `unable to find dynamic system library 'objc' using strategy 'paths_first'. searched paths: none` |
| cross link | `zig build-exe -target aarch64-macos -framework Foundation` | fails, `unable to find framework 'Foundation'. searched paths:  none` |
| cross link | `zig build-exe -target aarch64-ios` | fails, `unable to find libSystem system library`, output file is 0 bytes |
| cross link | `zig build-exe -target aarch64-linux-android -llog -lc` | fails, `unable to find dynamic system library 'log'` |
| header parsing | `zig translate-c` on an Objective-C header | fails, see section 9.5 |
| header parsing | `zig translate-c` on a resolved COM C header | works |
| header parsing | `zig translate-c` on `jni.h` | works |
| package compile | `zig build-obj -target x86_64-windows` against zigwin32 | works, 32432-byte object |
| run a built binary | `wine` or a Mac | not available, `which wine` returns nothing |

The consequence for the plan: the Linux gate can prove that every Windows
boundary symbol resolves, that every signature matches, that every vtable is
complete, and that every pure helper is correct. It cannot prove that a single
byte reaches an assistive technology.

### 9.11 Host inventory that the above depends on

| Item | State | How it was checked |
|---|---|---|
| Zig | 0.16.0 | `zig version` in the project directory reads `build.zig.zon` |
| Windows SDK headers | absent | `find / -maxdepth 6 -iname "UIAutomationClient.h"` returns nothing |
| Apple SDK headers | absent | `find / -maxdepth 6 -iname "NSAccessibility*.h"` returns nothing |
| Android SDK and NDK | absent | `ANDROID_HOME` and `ANDROID_NDK_HOME` unset, no `adb` |
| `javac` and a JDK | present, OpenJDK 25.0.4.1 | `java -version` |
| Wine | absent | `which wine wine64` returns nothing |

---

## 10. Port order

### The order

**Windows first. macOS second. iOS third. Android fourth.**

### Why Windows first

The deciding factor is how much of the file set the Linux gate can check. Windows
wins on every axis that matters here.

| Criterion | Windows | macOS | iOS | Android |
|---|---|---|---|---|
| boundary rung | 2 for everything | 2 plus 3 | 4 for all of UIKit | 3 for the header |
| a package covers it | yes, zigwin32 | mostly, zig-objc | no | no, `jni.h` |
| `build-obj` on this host | works | works | works | works |
| `build-exe` with real system libraries on this host | works | fails at `-lobjc` | fails at `libSystem` | fails at `-llog` |
| new code with no upstream counterpart | about 120 lines of COM base | 3 externs, 58 selectors typed by hand | 39 named UIKit identifiers typed by hand | a JNI wrapper |
| symbol count to transcribe | 18 functions, 14 interfaces, 181 constants | 7 runtime functions plus `objc_msgSend`, 58 accessibility selectors, 50 constants | 39 named UIKit identifiers, 4 by `dlsym`, 43 distinct | 70 lines of Java, 78 JNI call sites naming 68 methods |

Three of the four columns are measured in section 9. The one that matters most
is the third row of the link column. A Windows cross build on this host links
against the real `uiautomationcore` and the real `user32`, so a wrong import
name or a wrong signature fails the build rather than waiting for a runtime
crash on a machine nobody here owns.

### What the Windows order buys

It buys the largest verified surface. With zigwin32 pinned, the local gate
proves that all 18 functions and all 14 COM interfaces exist, that their
signatures match the header, that every vtable slot is filled, and that every
pure helper is correct. The compile probe in section 9.2 is that proof, in one
command.

It also buys the clearest path to a fixture-based oracle. The pure parts of the
Windows adapter are:

| Pure part | `path:line` | Portable test on this host |
|---|---|---|
| role to control type, 33 outcomes | `AK/windows/src/node.rs:58-260` | yes |
| the 23 simple property getters | `AK/windows/src/node.rs:1306-1330` | yes, with a fake tree |
| pattern support predicates | `AK/windows/src/node.rs:576-741` | yes |
| `AriaProperties` writer | `AK/windows/src/util.rs:433-468` | yes |
| `StringBuffer` pool behaviour, already tested upstream | `AK/windows/src/util.rs:470-536` | yes |
| runtime id construction | `AK/windows/src/node.rs:40-50` | yes |
| text unit movement | `AK/windows/src/text.rs:81-207` | yes, with a synthetic text tree |
| selection event batching and the limit of 20 | `AK/windows/src/adapter.rs:125-229` | yes |

That is most of the adapter's decision logic, and none of it needs a window.

### The trade-off, stated plainly

Windows first optimises for verifiability, not for user value. AccessKit's
largest real user base is on macOS. Porting Windows first means the macOS port,
which is probably the one most people want, lands last among the desktop
platforms.

The counter-argument is that macOS cannot be linked here at all, so a macOS
port would ship with a gate that has checked only its pure helpers. Shipping the
less verifiable platform first would be worse, not better.

The second trade-off is that the Windows port is the largest of the four. It has
14 COM interfaces and 181 constants, and it is the only one that needs new
infrastructure, the COM object base. macOS and iOS reuse the same tree code and
differ only in the boundary, so the later ports get cheaper.

### Why iOS third

iOS has the least to bind and the most to hand-write. There is no UIKit binding
in the Zig ecosystem at all, so 39 named identifiers and the whole
`UIAccessibilityElement` method set are declared by hand. And it cannot even be
cross-linked here: `zig build-exe -target aarch64-ios` fails with
`unable to find libSystem system library`. Until someone runs the iOS milestone
on a Mac, its status is "compiles", not "works".

### Why Android fourth

Android is the only adapter whose boundary is another language. It needs 70
lines of Java and, by default, a prebuilt `classes.dex` loaded through
`InMemoryDexClassLoader`. It has no device path on this host, no NDK, and no
`adb`. It is last because nothing about it can be finished here.

If the goal changes to "ship something usable soonest", the order changes to
AT-SPI on Linux first, because that adapter needs nothing but a socket and is
covered by `docs/13-atspi-protocol.md`. This document only orders the four
native adapters.

---

## 11. House rules: where this subject complies and where it fights

This section covers every rule in section 2 of `~/ozai/AGENTS.md`
and the relevant rules from section 1, as they apply to the four platform
adapters. Three rules are satisfied, three need a design decision, and three are
fought by the upstream code itself.

### Complied with, with no change needed

| Rule | Why it holds here |
|---|---|
| state is a parameter, not a capture | every change handler takes the old and new node as arguments and returns an event list. `node_updated(old_node, new_node)` at `AK/windows/src/adapter.rs:269`, `AK/macos/src/event.rs:244` and `AK/android/src/adapter.rs:101` is the same shape on all three platforms |
| network logic is pure over decoded input | the analogue holds exactly. A `TreeUpdate` is decoded input, the change handler is a pure state machine, and the output is a `Vec<QueuedEvent>`. No socket, no clock, no allocator in `EventGenerator` (`AK/macos/src/event.rs:146-205`) or `AdapterChangeHandler` (`AK/windows/src/adapter.rs:35-51`) |
| split at the bridges | the four stages are already separate functions in every adapter: window procedure to adapter, adapter to change handler, change handler to event queue, event queue to platform raise. `AK/windows/src/subclass.rs:44`, `adapter.rs:463`, `adapter.rs:237`, `adapter.rs:643` are four separate layers |
| explicit control flow | state is an enum, never a flag pair. `AK/windows/src/adapter.rs:376-384`, `AK/macos/src/adapter.rs:26-39`, `AK/ios/src/adapter.rs:54-65`, `AK/android/src/adapter.rs:203-209` |
| no backwards compatibility | the port is a clean cutover. The public surface is small and fixed: `Adapter`, `SubclassingAdapter`, `QueuedEvents` on Windows; `Adapter`, `SubclassingAdapter`, `QueuedEvents`, `add_focus_forwarder_to_window_class` on macOS; `Adapter`, `SubclassingAdapter`, `QueuedEvents` on iOS; `Adapter`, `InjectingAdapter`, `PlatformAction`, `QueuedEvents` on Android |

### Needs a design decision in `docs/30-port-design.md`

#### `io: std.Io` threaded explicitly

None of the four adapters takes an `io`, and none should. They perform no
streaming I/O. The one place a handle is needed is Android, where
`InjectingAdapter::update_if_active` attaches a thread and posts to the UI
thread (`AK/android/src/inject.rs:412-430`). In Zig that is a `std.Thread` or a
zio handle passed as an argument, never a global.

Decision to record: the adapters take no `io`. The zio runtime belongs to the
consumer side and to the D-Bus transport, not to a platform boundary.

#### Explicit error sets

The Rust code returns `Result<T, windows::core::Error>`, which wraps a raw
HRESULT. A Zig port needs a closed error set. The mapping is finite:

| Error value | Returned by | `path:line` |
|---|---|---|
| `UIA_E_ELEMENTNOTAVAILABLE` | `element_not_available` | `AK/windows/src/util.rs:360-362` |
| `UIA_E_ELEMENTNOTENABLED` | `element_not_enabled` | `AK/windows/src/util.rs:364-366` |
| `UIA_E_INVALIDOPERATION` | `invalid_operation` | `AK/windows/src/util.rs:368-370` |
| `UIA_E_NOTSUPPORTED` | `not_supported` | `AK/windows/src/util.rs:372-374` |
| `E_NOTIMPL` | `not_implemented` | `AK/windows/src/util.rs:348-350` |
| `E_INVALIDARG` | `invalid_arg` | `AK/windows/src/util.rs:352-354` |
| `E_FAIL` | inline, no selection container | `AK/windows/src/node.rs:1411` |

Seven named errors plus one catch-all for any other negative HRESULT. A comptime
sweep over that set satisfies the house rule on error-set coverage.

#### Loops have fixed upper bounds

One loop already complies. `move_position` at `AK/windows/src/text.rs:174-207`
runs at most `abs(count)` times and breaks at a document edge.

Three do not, and cannot, because the bound is a property of the tree:

| Loop | Bound | `path:line` |
|---|---|---|
| remove a subtree, breadth-first with a queue | the number of nodes in the subtree | `AK/macos/src/event.rs:161-172`, `AK/ios/src/event.rs:185-196` |
| walk the filtered children of a node | the number of children | `AK/macos/src/node.rs:1360-1364` |
| write the text of a range | the number of segments in the range | `AK/windows/src/text.rs:526` |

Decision to record: the house rule is applied as "the bound is a compile-time
constant where the input is a compile-time constant, and an asserted runtime
bound otherwise, with `unreachable` reserved for a bound that cannot be
exceeded". A literal fixed iteration count would break the adapters.

### Fought by the upstream code, and the port must fix it

These three are real conflicts. Each has a concrete cost and a concrete fix.

#### Allocators as parameters, against a thread-local buffer pool

`AK/windows/src/util.rs:28-30` declares a thread-local pool:

```text
thread_local! {
    static STRING_SCRATCH: RefCell<Vec<Vec<u16>>> = const { RefCell::new(Vec::new()) };
}
```

`StringBuffer::acquire` pops from it (`AK/windows/src/util.rs:39-41`) and `Drop`
pushes back (`:44-58`). Every property read leases a buffer this way, for
example at `AK/windows/src/node.rs:1002`, `AK/windows/src/adapter.rs:243` and
`AK/windows/src/util.rs:440`.

That is a hidden global and a hidden allocation. It also has a hidden cost: the
pool is bounded at two buffers (`MAX_POOLED_BUFFERS` at
`AK/windows/src/util.rs:33`) and at 4096 units of retained capacity
(`MAX_RETAINED_SCRATCH_CAPACITY` at `:32`), and the four unit tests at
`AK/windows/src/util.rs:470-536` exist only to pin that behaviour.

Fix: the port takes a buffer as an explicit parameter. The `NodeWrapper`
struct already carries `string_buffer: &'a mut Vec<u16>` at
`AK/windows/src/node.rs:52-55`. A Zig port threads that buffer down from the one
place that owns an allocator, which is the adapter entry point, and deletes the
pool and its four tests. This removes 67 lines of upstream code and the hidden
state with them.

Second related problem in the same file: `safe_array_from_primitive_slice`
panics on allocation failure at `AK/windows/src/util.rs:306`, and
`safe_array_from_com_slice` panics at `:326`. A Zig port returns
`error.OutOfMemory` and lets the fail-N allocator tests reach it.

#### Determinism, against hash-based iteration

The event queue order is not reproducible today, because it is built from hash
containers:

| Container | Effect on event order | `path:line` |
|---|---|---|
| `selection_changed: HashMap<FullNodeId, SelectionChanges>` | `enqueue_selection_changes` iterates it, so the order of selection containers is arbitrary | `AK/windows/src/adapter.rs:39`, `:127` |
| `text_changed: HashSet<FullNodeId>` | only a membership test, so order is unaffected | `AK/windows/src/adapter.rs:38` |
| `selected_rows_changed: HashSet<FullNodeId>` | membership test only, so order is unaffected. The iOS generator has no such set at all, it uses a single `Option` | `AK/macos/src/event.rs:144`, `AK/ios/src/event.rs:149` |

The `HashMap` is the real defect. Two runs with the same tree update can emit
the same selection events in a different order, and assistive technologies are
order sensitive. Fix: an insertion-ordered list, and the map becomes a lookup
table that is never iterated. That is a house-rule improvement the port makes
and the upstream does not have.

#### Small functions, against a 200-line role match

`NodeWrapper::control_type` at `AK/windows/src/node.rs:58-260` is a single
`match` with roughly one arm per AccessKit role. It has 33 distinct outcomes and
exceeds the house limit on function size.

Fix: a comptime table keyed by the role enum, built with `inline for` over the
enumerable domain. The house rule on comptime exhaustiveness then covers it for
free, because a new role that is not in the table fails to compile.

### What the port has that Rust does not

Summary of new code across all four adapters, and where it comes from.

| New thing | Why Rust did not need it | Where |
|---|---|---|
| a COM object base with an atomic refcount and three `extern fn` thunks | `windows-rs` supplies it through the `#[implement]` macro | `AK/windows/src/node.rs:790`, `AK/windows/src/text.rs:209` |
| an explicit `VARIANT` owner that calls `VariantClear` | `windows-rs` handles `VARIANT` lifetimes in `Drop`, and the adapter never names `VariantClear` | `AK/windows/src/util.rs:288-298` |
| an interface-pointer to object-pointer cast | `windows-rs` supplies `.as_impl()` | `AK/windows/src/text.rs:326`, `:338`, `:575` |
| a null check on every COM out-parameter | `windows-rs` wraps them in `Ref<T>` | `AK/windows/src/util.rs:356-358` |
| three `extern` declarations for associated objects and `object_setClass` | `objc2` 0.5 supplies them | `AK/macos/src/subclass.rs:77`, `:164`, `:203` |
| 58 Objective-C selector signatures written by hand | `objc2-app-kit` supplies generated signatures from the SDK headers, and no Zig package can parse those headers | table M3 |
| 39 named `UIAccessibility` identifiers written by hand | `objc2-ui-kit` supplies them | section 9.8 |
| a JNI function table wrapper | the `jni` crate supplies it | `AK/android/src/util.rs:161-206` |

Everything else in this document is a transcription. That is the whole cost
model for the port: one new module on Windows, three externs on macOS, a table
of constants on iOS, and a JNI wrapper on Android.

## 12. Correction record, 2026-10-05

Twelve figures in this document were wrong. Each is recorded here with the old
claim, what is true, and the measurement or `path:line` that settles it. Eight
come from `docs/42-native-adapter-build-map.md`, which re-derived its census from
the upstream tree rather than from this document; four were settled in the same
pass and are marked A1 to A4.

**Upstream tree.** `/tmp/scratch/accesskit` at
`466e24e252103f4d82bd6fbab98141b551e46e0c`, the checkout this document already
cites. Every measurement below is a lexical scan over that tree, a `wc -l` over
it, or a `grep -n` on one file of it. The checkout is at the recorded commit and
the working tree is clean.

### C1. macOS role constants, 33 to 31

**Old.** Table M6's heading and the M1 to M6 totals table each said 33.

**True.** 31.

**Measurement.** A scan for `NSAccessibility[A-Za-z]*Role` over the nine files
under `AK/macos/src/` returns 32 distinct identifiers. One of the 32 is
`NSAccessibilityRole`, the class itself, which is a type rather than a
constant, so 32 - 1 = 31. That is also the number of rows M6's own table
carries, so the old heading contradicted its own table.
`docs/42` section 1.2.4 and section 1.5.

### C2. macOS selector literals, 6 to 43

**Old.** Table M5's total and the M1 to M6 totals table each said 6 literal
attribute and action names. Those 6 are the 3 names read in
`accessibilityAttributeValue:`, the 2 font-dictionary keys and the 1 legacy
action name. The role and subrole tables were not counted at all.

**True.** 43 distinct `AX…` string literals: 5 role values, 32 subrole values,
3 attribute names, 2 font-dictionary keys and 1 action name.

**Measurement.** A scan for `"AX[A-Za-z]+"` over the nine files returns 43
distinct strings at 47 sites, which the five rows of the new table in M5
reproduce. `docs/42` section 1.2.5.

### C3. the array return is `NSArray::from_vec`, not `+[NSArray arrayWithObjects:count:]`

**Old.** Table M2 listed `+[NSArray arrayWithObjects:count:]` as the call that
returns child arrays to the assistive technology.

**True.** `NSArray::from_vec`.

**Measurement.** `grep -rn 'arrayWithObjects'` over the nine files returns
nothing, so no call site uses the selector the old table named.
`grep -n 'NSArray::from_vec\|Id::autorelease_return'` over
`AK/macos/src/adapter.rs` returns `:244`, `:245`, `:257` and `:293`. The eight
`from_vec` sites are `AK/macos/src/adapter.rs:244` and
`AK/macos/src/node.rs:472`, `:1117`, `:1134`, `:1172`, `:1189`, `:1215` and
`:1364`. `docs/42` section 1.2.3.

### C4. the iOS adapter is 2560 lines, not 2603

**Old.** Section 8.1 said 2603 lines across eight files.

**True.** 2560.

**Measurement.** `wc -l` over `AK/ios/src/*.rs` returns 514, 95, 270, 130, 41,
1076, 324 and 110, which sum to 2560. `docs/40-plan.md` M9 already says 2560.
`docs/42` section 0.1.

### C5. iOS has 43 distinct `UIAccessibility` identifiers, not 26 plus 4

**Old.** Sections 8.1, 9.8, 10 and 11 said 26 named symbols plus 4 resolved by
`dlsym`.

**True.** 43 distinct identifiers, of which 39 are named in source and 4 exist
only as C-string literals handed to `dlsym`.

**Measurement.** A scan for the `UIAccessibility` prefix over the eight files
under `AK/ios/src/` returns 43 distinct identifiers. A `grep -n` for each of the
four `dlsym` names shows that `UIAccessibilityTraitToggleButton` at
`AK/ios/src/util.rs:80`, `UIAccessibilityPriorityHigh` at `:101`,
`UIAccessibilityPriorityLow` at `:105` and
`UIAccessibilitySpeechAttributeAnnouncementPriority` at `:109` occur only inside
`dlsym` calls, so 43 - 4 = 39 are named in source. The breakdown by kind is the
new table in section 9.8. `docs/42` section 1.3.1.

### C6. Android has 78 JNI call sites naming 68 Java methods, not about 40

**Old.** Section 10's transcription row said about 40 JNI call sites.

**True.** 78 call sites, naming 68 distinct Java method names.

**Measurement.** A scan for `call_method` and `call_static_method` over the
eight files returns 78 sites: 3 in `adapter.rs`, 31 in `event.rs`, 9 in
`inject.rs`, 26 in `node.rs` and 9 in `util.rs`. Several sites name the same
method, because the node fill loop runs once per property. Sorting every quoted
lowercase string with no `/` in it returns 78 names; removing the 4 adapter
field names `activation_handler`, `action_handler`, `delegate_class` and
`adapter`, the 5 single-word literals `accessibility`, `handle`, `host`, `inner`
and `system`, and the 1 bundle key `vm` at `AK/android/src/inject.rs:319`, leaves
68. `docs/42` section 1.4.2 holds the flat list of all 68.

### C7. three Windows feature groups enable nothing, not two

**Old.** The scope section named nine of the ten enabled groups as used, and
said `Win32_Graphics_Gdi` and `Win32_UI_Input_KeyboardAndMouse` are the two that
name no symbol. It did not mention `Win32_System_LibraryLoader` at all.

**True.** Seven of the ten are used. Three enable nothing:
`Win32_Graphics_Gdi`, `Win32_UI_Input_KeyboardAndMouse` and
`Win32_System_LibraryLoader`.

**Measurement.** `AK/windows/Cargo.toml:28-39` enables ten groups, and
`Win32_System_LibraryLoader` is the fifth name in that list. A grep for
`LoadLibraryW`, `GetProcAddress`, `FreeLibrary` and `GetModuleHandleW` over the
nine library files under `AK/windows/src/` returns nothing; the only hits in the
whole adapter are in the upstream test harness, at
`AK/windows/src/tests/mod.rs:18`, `:38`, `:145` and
`AK/windows/src/tests/subclassed.rs:14`, `:127`, `:142`.
`Win32_Graphics_Gdi` is glob-imported at `AK/windows/src/util.rs:19` and names
nothing, so it is the only one of the three that produces an unused-import
warning; the other two are enabled and never imported at all. `docs/42` section
1.1.5.

### C8. the enum type is `NavigateDirection`, not `NavigationDirection`

**Old.** Table W12 called the type `NavigationDirection`.

**True.** `NavigateDirection`.

**Measurement.** A grep for `Navigat.*Direction` over the nine files under
`AK/windows/src/` returns hits for `NavigateDirection` at `node.rs:1074`,
`:1077`, `:1078`, `:1079`, `:1082` and `:1083`, and nothing for
`NavigationDirection`. `docs/42` section 1.5, row N2.

### A1. the macOS runtime boundary is 7 functions plus a primitive

**Old.** Table M1 counted 8 runtime functions, with `objc_msgSend` as the
eighth.

**True.** 7 functions, of which 4 are named as `objc2::ffi` externs and 3 are
reached through an `objc2` wrapper. `objc_msgSend` is never named; it is what
`msg_send!` and `msg_send_id!` lower to, so it is the message-send primitive
rather than a symbol the adapter names.

**Measurement.** The four named externs are imported at
`AK/macos/src/patch.rs:6` and `AK/macos/src/subclass.rs:11-14`. The three
wrapped ones are `objc_getClass` through `AnyClass::get` at
`AK/macos/src/patch.rs:40`, `objc_allocateClassPair` through `ClassBuilder::new`
at `AK/macos/src/subclass.rs:176`, and `objc_registerClassPair` through
`builder.register()` at `AK/macos/src/subclass.rs:195`. `docs/42` section 1.2.1.

### A2. the AppKit and Foundation call total is 18, not 17

**Old.** Table M2's heading and total each said 17 calls.

**True.** 18.

**Measurement.** `Id::retain` is an ownership call of the same class as
`Id::autorelease_return`, which M2 already counted, and it appears three times:
`AK/macos/src/adapter.rs:94`, `AK/macos/src/subclass.rs:140` and
`AK/macos/src/util.rs:107`. 17 + 1 = 18. `docs/42` section 1.2.3.

### A3. the macOS constant total in section 10 is 50, not 52

**Old.** Section 10's transcription row said 52 constants for macOS, which is
M6's 33 roles plus M6's 7 subroles plus M5's 12 text-attribute constants.

**True.** 50. Follows from C1: 31 + 7 + 12 = 50.

### A4. four iOS constants are read by `dlsym`, not three

**Old.** Section 8.5 opened by saying three UIKit constants are read at run
time, and then listed four rows.

**True.** Four.

**Measurement.** The table under that sentence has four rows, at
`AK/ios/src/util.rs:77-87`, `:100-102`, `:104-106` and `:108-110`. `docs/42`
section 1.3.2.

### Two places where `docs/42` is wrong and this document was right

Both are line numbers rather than counts, both were measured against the same
pinned tree, and neither changes a figure.

1. `docs/42` section 1.2.3 puts `NSArray::from_vec` at
   `AK/macos/src/adapter.rs:250` and `Id::autorelease_return` at `:251`. They are
   at `:244` and `:245`, which is what table M2 now carries. The record's other
   two `autorelease_return` sites, `:257` and `:293`, are right.
2. `docs/42` section 1.2.5 puts the `Win32_Graphics_Gdi` glob import at
   `AK/windows/src/util.rs:21`. It is at `:19`, inside the `use windows::{`
   block that opens at `:15`.

### What did not change

The Windows constant total of 181 stands, and so does every count in tables W1
to W12 apart from the type name in C8. The line counts in the scope table, the
54 node methods and 4 view methods on macOS, the 31 role rows and 7 subrole rows
of M6, the 70 lines of Java, and the 181 Windows constants were each
re-measured and each held.

---
