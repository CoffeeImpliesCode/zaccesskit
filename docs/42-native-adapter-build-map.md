# 42 — The native adapter build map

**What this document is.** The working list for `src/adapters/windows/`,
`src/adapters/macos/`, `src/adapters/ios/` and `src/adapters/android/`. It
owns four things: the symbol census for each adapter, the Zig binding route for
each platform, the verification each adapter can reach on this host, and the
shape the four share against the shape each one owns alone.

**What this document does not own.** The module layout is fixed by
`docs/30-port-design.md` section 3.3. The milestone order is owned by
`docs/40-plan.md` M7 to M10. The C ABI belongs to `docs/31-c-abi-design.md`.
Where this document and `docs/30` or `docs/40-plan.md` disagree, they win and
this document is wrong.

**How every number here was produced.** Nothing is transcribed from
`docs/16-native-platform-apis.md`. Each count is a lexical scan over the pinned
upstream tree, taken per identifier class and then summed from the class lists
rather than from a summary line. Where the scan and `docs/16` disagree, the
disagreement is recorded in section 1.5 with the measurement that settles it, and
`docs/16` is not edited here because this run writes one file.

**Scratch tree.** Every clone and every probe ran under
`/tmp/scratch/AdapterMap/`. Nothing in the repository was
modified. No gate stage was run: not `zig build`, `zig build test`,
`zig build cross-test`, `zig-gate`, `zig fmt`, `ziglint`, `zlint`, `zbc` or
`zwanzig`. The compile probes are `zig 0.16.0 build-obj`, `zig 0.16.0 build-exe`
and `zig 0.16.0 translate-c`, which are not gate stages.

| Item | Value |
|---|---|
| Port | `zaccesskit`, a pure Zig port of the Rust `accesskit` crate |
| Upstream tree | `/tmp/scratch/accesskit` at `466e24e252103f4d82bd6fbab98141b551e46e0c` |
| Windows crate | `accesskit_windows` 0.35.1, `windows` 0.62.0 |
| macOS crate | `accesskit_macos` 0.27.1, `objc2` 0.5.1 |
| iOS crate | `accesskit_ios` 0.2.1, `objc2-ui-kit` 0.2.0 |
| Android crate | `accesskit_android` 0.9.0, `jni` 0.21.1 |
| Zig | 0.16.0, via the anyzig shim reading `build.zig.zon:11` |
| zigwin32 | `marlersoft/zigwin32` at `9f15c276b4e9d05afd34a10d8662a7dfc34647ea` |
| zig-objc | `mitchellh/zig-objc` at `c8de82ff80281215ad92900866dab7103a8efa8b` |

Citations use the prefix `AK/` for
`/tmp/scratch/accesskit/adapters/`. A citation is `path:line`.
Anything marked `[INFERENCE]` is not established by reading a source.

---

## 0.1 Size of the four port surfaces

`wc -l` over each adapter's own directory, on this host.

| Adapter | Library files | Library lines | Java lines | Tests |
|---|---:|---:|---:|---:|
| Windows | 9 | 3764 | 0 | 712 |
| macOS | 9 | 2605 | 0 | 0 |
| iOS | 8 | 2560 | 0 | 0 |
| Android | 8 | 2604 | 70 | 0 |
| **Total** | **34** | **11533** | **70** | **712** |

Per file, because the port budget is a per-file limit and a total hides the
file that breaks it.

| Adapter | Files, largest first |
|---|---|
| Windows | `node.rs` 1539, `adapter.rs` 673, `text.rs` 652, `util.rs` 536, `subclass.rs` 204, `context.rs` 98, `window_handle.rs` 32, `lib.rs` 22, `filters.rs` 8 |
| macOS | `node.rs` 1367, `event.rs` 335, `subclass.rs` 273, `adapter.rs` 295, `util.rs` 108, `context.rs` 103, `patch.rs` 93, `lib.rs` 25, `filters.rs` 6 |
| iOS | `node.rs` 1076, `adapter.rs` 514, `subclass.rs` 324, `event.rs` 270, `filters.rs` 130, `util.rs` 110, `context.rs` 95, `lib.rs` 41 |
| Android | `adapter.rs` 906, `inject.rs` 471, `node.rs` 447, `event.rs` 419, `util.rs` 251, `action.rs` 85, `lib.rs` 19, `filters.rs` 6 |

Windows tests are `tests/mod.rs` 337, `tests/simple.rs` 198,
`tests/subclassed.rs` 177. Section 3.4 says why they cannot port.

---

## 1. The symbol census, verified against the source

### 1.0 What counts as a symbol here

A host symbol counts when the adapter **names** it as an identifier, a macro
argument, a selector string, or a class descriptor. Three consequences follow,
and each one corrects a number in `docs/16`:

1. A Rust type alias or a `objc2` wrapper does not count as a host symbol. A
   wrapper names the host symbol once, in the wrapper.
2. A symbol resolved at run time by string counts once, in the run-time group,
   not also in the compile-time group.
3. A constant written as a string literal counts, because a Zig port must
   write the literal. This is the group `docs/16` missed on macOS.

Two counts are deliberately **not** in the census, because they are not host
symbols: an AccessKit type the adapter passes through, and a symbol inside the
`accesskit_consumer` crate. The census is the platform boundary only.

---

## 1.1 Windows

Windows is the largest and the most mechanical of the four. Every symbol lives
in one of four headers, and no name is reached through a wrapper, so the census
is a set of greps with no judgement in it.

### 1.1.1 Functions, 18

| Group | Count | Symbols |
|---|---:|---|
| `user32` | 8 | `SetWindowLongPtrW`, `CallWindowProcW`, `DefWindowProcW`, `GetPropW`, `SetPropW`, `RemovePropW`, `IsWindowVisible`, `ClientToScreen` |
| `uiautomationcore` | 7 | `UiaLookupId`, `UiaReturnRawElementProvider`, `UiaRaiseAutomationEvent`, `UiaRaiseAutomationPropertyChangedEvent`, `UiaHostProviderFromHwnd`, `UiaGetReservedMixedAttributeValue`, `UiaGetReservedNotSupportedValue` |
| `oleaut32` | 2 | `SafeArrayCreateVector`, `SafeArrayPutElement` |
| `kernel32` | 1 | `LocaleNameToLCID` |

The adapter is a UI Automation **provider**. A search of all nine files for
`UiaAddEventHandler` returns nothing, so it subscribes to no UI Automation
event. The only inbound message is `WM_GETOBJECT`, handled at
`AK/windows/src/subclass.rs:50` and `AK/windows/src/adapter.rs:545`.

### 1.1.2 COM interfaces, 14 implemented and 1 referenced

Thirteen interfaces are implemented on the element object, and one on the range
object.

| Object | Interfaces | Source |
|---|---:|---|
| `PlatformNode` | 13 | `AK/windows/src/node.rs:791-803` |
| `PlatformRange` | 1 | `AK/windows/src/text.rs:209` |
| referenced, never implemented | `IUnknown` | `AK/windows/src/node.rs:1050`, `:1426`, `AK/windows/src/util.rs:356` |

The thirteen are `IRawElementProviderSimple`, `IRawElementProviderFragment`,
`IRawElementProviderFragmentRoot`, `IToggleProvider`, `IInvokeProvider`,
`IValueProvider`, `IRangeValueProvider`, `IScrollItemProvider`,
`ISelectionItemProvider`, `ISelectionProvider`, `ITextProvider`,
`IExpandCollapseProvider` and `IWindowProvider`.

### 1.1.3 Constants, 181

The largest group, and the one where a mistyped name is a link error rather than
a wrong answer. Summed from the class lists, not from a summary line.

| Group | Count | How it was measured |
|---|---:|---|
| `UIA_*PropertyId` | 41 | distinct identifiers matching the suffix |
| `UIA_*ControlTypeId` | 33 | distinct identifiers matching the suffix, including the two irregular names `UIA_TabControlTypeId` and `UIA_TabItemControlTypeId`, which drop the `Control` infix |
| `UIA_*PatternId` | 10 | distinct identifiers matching the suffix |
| `UIA_Text_*AttributeId` | 18 | distinct identifiers matching the suffix |
| `UIA_*EventId` | 10 | distinct identifiers matching the suffix |
| `UIA_E_*` status codes | 4 | `ELEMENTNOTAVAILABLE`, `ELEMENTNOTENABLED`, `INVALIDOPERATION`, `NOTSUPPORTED` |
| other UI Automation constants | 5 | `UiaRootObjectId`, `UiaAppendRuntimeId`, `ControlType_Property_GUID`, `AutomationIdentifierType_Property`, `ProviderOptions_ServerSideProvider` |
| window message and state constants | 12 | ten `WM_*` values, plus `GWLP_WNDPROC` and `OBJID_CLIENT` |
| `TextUnit_*` values | 7 | distinct identifiers matching the prefix |
| `TextPatternRangeEndpoint_*` values | 2 | `_Start`, `_End` |
| named enum values | 31 | 28 identifiers of the `Type_Value` shape, plus the three bare `LiveSetting` values `Off`, `Polite` and `Assertive` |
| `VT_*` values | 4 | `VT_I4`, `VT_R8`, `VT_UNKNOWN`, `VT_ARRAY` |
| HRESULT codes without a `UIA_` prefix | 3 | `E_FAIL`, `E_INVALIDARG`, `E_NOTIMPL` |
| globalization flags | 1 | `LOCALE_ALLOW_NEUTRAL_NAMES` |
| **Total** | **181** | |

The 31 named enum values belong to nine enumerated types and two structs:
`LiveSetting` 3, `ToggleState` 3, `ExpandCollapseState` 3, `CaretPosition` 3,
`SupportedTextSelection` 2, `NavigateDirection` 5,
`HorizontalTextAlignment` 4, `TextDecorationLineStyle` 5,
`OrientationType` 3, plus the structs `UiaRect` and `UiaPoint`. The type name
is `NavigateDirection`, not `NavigationDirection`.

The 181 matches `docs/16` section 10. A first pass over the same trees produced
178, because a regex keyed on the `UIA_` prefix misses the three HRESULT codes
that carry no prefix. The 178 figure was wrong and is recorded here so that the
next reader does not repeat it.

### 1.1.4 Named types, 26

| Group | Count | Types |
|---|---:|---|
| UI Automation enum types | 5 | `UIA_CONTROLTYPE_ID`, `UIA_EVENT_ID`, `UIA_PATTERN_ID`, `UIA_PROPERTY_ID`, `UIA_TEXTATTRIBUTE_ID` |
| UI Automation enumerated types and structs | 11 | `LiveSetting`, `ToggleState`, `ExpandCollapseState`, `CaretPosition`, `SupportedTextSelection`, `NavigateDirection`, `HorizontalTextAlignment`, `TextDecorationLineStyle`, `OrientationType`, `UiaRect`, `UiaPoint` |
| COM and Foundation types | 7 | `VARIANT`, `SAFEARRAY`, `BSTR`, `HRESULT`, `HWND`, `HANDLE`, `POINT` |
| window message types | 3 | `LPARAM`, `WPARAM`, `LRESULT` |

The three anonymous union spellings `VARIANT_0`, `VARIANT_0_0` and
`VARIANT_0_0_0` at `AK/windows/src/util.rs:289-295` are a `windows-rs` artefact
for a `VT_ARRAY` of `VT_UNKNOWN`. A Zig port writes an `extern union` once and
does not transcribe the three names.

### 1.1.5 Feature groups, 10 enabled and 3 unused

`AK/windows/Cargo.toml:28-39` enables ten `windows` feature groups. A Zig port
needs seven of them.

| Enabled group | Used? | Evidence |
|---|---|---|
| `Win32_Foundation` | yes | `HWND`, `BOOL`, `POINT` |
| `Win32_Globalization` | yes | `LocaleNameToLCID` |
| `Win32_System_Com` | yes | COM interface declarations |
| `Win32_System_Ole` | yes | `SafeArrayCreateVector`, `SafeArrayPutElement` |
| `Win32_System_Variant` | yes | `VARIANT`, `VT_*` |
| `Win32_UI_Accessibility` | yes | the 13 interfaces and the `UIA_*` constants |
| `Win32_UI_WindowsAndMessaging` | yes | the 8 `user32` functions and `WM_*` |
| `Win32_Graphics_Gdi` | **no** | a grep for `HDC`, `HGDIOBJ`, `COLORREF`, `HRGN`, `MoveToEx`, `CreateCompatibleDC` and `GetDeviceCaps` over all nine files returns nothing |
| `Win32_UI_Input_KeyboardAndMouse` | **no** | a grep for `VK_*`, `INPUT`, `KEYBDINPUT`, `MOUSEINPUT`, `SendInput`, `GetKeyState` and `GetAsyncKeyState` returns nothing |
| `Win32_System_LibraryLoader` | **no** | a grep for `LoadLibraryW`, `GetProcAddress`, `FreeLibrary` and `GetModuleHandleW` returns nothing |

`Win32_Graphics_Gdi` is glob-imported at `AK/windows/src/util.rs:21`, so it is
the only one of the three that produces an unused-import warning. The other two
are enabled and never imported at all.

### 1.1.6 Windows total

| Kind | Count |
|---|---:|
| functions | 18 |
| COM interfaces implemented | 14 |
| COM interfaces referenced | 1 |
| constants | 181 |
| named types | 26 |

---

## 1.2 macOS

macOS has no list of imported C functions. It reaches the Objective-C runtime
through `objc2`, and AppKit through generated `objc2-app-kit` methods. The
census therefore has to separate what the source **names** from what an `objc2`
wrapper **reaches**, and it has to count selector strings, because a Zig port
writes every one of them by hand.

### 1.2.1 Objective-C runtime, 7 functions and 1 policy

| Group | Count | Symbols | How reached |
|---|---:|---|---|
| named `objc2::ffi` externs | 4 | `class_addMethod`, `objc_getAssociatedObject`, `objc_setAssociatedObject`, `object_setClass` | imported by name at `AK/macos/src/patch.rs:6` and `AK/macos/src/subclass.rs:11-14` |
| reached through an `objc2` wrapper | 3 | `objc_getClass`, `objc_allocateClassPair`, `objc_registerClassPair` | `AnyClass::get` at `AK/macos/src/patch.rs:40`, `ClassBuilder::new` at `AK/macos/src/subclass.rs:176`, `builder.register()` at `:195` |
| the message-send primitive | 1 | `objc_msgSend` | **never named.** It is what `msg_send!` and `msg_send_id!` lower to |
| policy constants | 1 | `OBJC_ASSOCIATION_RETAIN_NONATOMIC` | `AK/macos/src/subclass.rs:168`, `:269` |

The seven functions are the whole runtime boundary. Four of the seven are named,
and a Zig port names all seven, because zig-objc covers the four it exports and
the port writes the other three as `extern` declarations.

Two more runtime items carry no symbol of their own and are listed in
section 1.2.6.

### 1.2.2 Accessibility methods, 54 on the node and 4 on the view

`PlatformNode` is a dynamically declared class whose super class is
`NSAccessibilityElement` (`AK/macos/src/node.rs:396-409`). The count is the
number of `#[method]` and `#[method_id]` declarations inside its
`unsafe impl` block, which is 54 at `AK/macos/src/node.rs:411-1330`.

The dynamic view subclass adds four more, at `AK/macos/src/subclass.rs:179`,
`:183`, `:187` and `:191`.

| Target | Count | Selectors |
|---|---:|---|
| `PlatformNode` | 54 | `accessibilityParent`, `accessibilityWindow`, `accessibilityTopLevelUIElement`, `accessibilityChildren`, `accessibilityChildrenInNavigationOrder`, `accessibilitySelectedChildren`, `accessibilityFrame`, `accessibilityRole`, `accessibilitySubrole`, `accessibilityRoleDescription`, `accessibilityIdentifier`, `accessibilityTitle`, `accessibilityHelp`, `accessibilityPlaceholderValue`, `accessibilityValue`, `setAccessibilityValue:`, `accessibilityMinValue`, `accessibilityMaxValue`, `accessibilityURL`, `accessibilityOrientation`, `isAccessibilityElement`, `isAccessibilityFocused`, `isAccessibilityEnabled`, `setAccessibilityFocused:`, `accessibilityPerformPress`, `accessibilityPerformIncrement`, `accessibilityPerformDecrement`, `accessibilityNotifiesWhenDestroyed`, `accessibilityNumberOfCharacters`, `accessibilitySelectedText`, `accessibilitySelectedTextRange`, `accessibilityInsertionPointLineNumber`, `accessibilityRangeForLine:`, `accessibilityRangeForPosition:`, `accessibilityStringForRange:`, `accessibilityAttributedStringForRange:`, `accessibilityFrameForRange:`, `accessibilityLineForIndex:`, `accessibilityRangeForIndex:`, `accessibilityStyleRangeForIndex:`, `setAccessibilitySelectedTextRange:`, `isAccessibilityRequired`, `isAccessibilitySelected`, `setAccessibilitySelected:`, `accessibilityAttributeValue:`, `accessibilityRows`, `accessibilitySelectedRows`, `accessibilityPerformPick`, `accessibilityLinkedUIElements`, `accessibilityTabs`, `isAccessibilityModal`, `accessibilityActionNames`, `accessibilityPerformAction:`, `isAccessibilitySelectorAllowed:` |
| host `NSView` subclass | 4 | `accessibilityChildren`, `accessibilityFocusedUIElement`, `accessibilityHitTest:`, `superclass` |

### 1.2.3 AppKit and Foundation calls, 18

| Group | Count | Calls |
|---|---:|---|
| window and view geometry | 9 | `contentView`, `convertPointFromScreen:`, `convertRectToScreen:`, `backingScaleFactor`, `window`, `convertPoint:fromView:`, `convertRect:toView:`, `isFlipped`, `bounds` |
| colour | 2 | `+colorWithSRGBRed:green:blue:alpha:`, `CGColor` |
| host-tree proxying | 2 | `accessibilityParent` and `accessibilityFrame`, sent to the host view at `AK/macos/src/node.rs:421`, `:433`, `:444`, `:490` |
| URL and ownership | 3 | `+URLWithString:`, `copy`, `Id::retain` |
| array return and ARC | 2 | `NSArray::from_vec`, `Id::autorelease_return` |

Two of these differ from the names `docs/16` gives. There is no
`+[NSArray arrayWithObjects:count:]` in the source. `AK/macos/src/adapter.rs:250`
calls `NSArray::from_vec` and `:251` calls `Id::autorelease_return`. There is
also no bare autorelease on return; the three `Id::autorelease_return` sites are
`:251`, `:257` and `:293`.

### 1.2.4 Accessibility constants, 70 identifiers

A scan of all nine files for the `NSAccessibility` prefix returns 70 distinct
identifiers. Broken down by kind:

| Kind | Count | Members |
|---|---:|---|
| role constants | 31 | see below |
| subrole constants | 7 | `NSAccessibilityDialogSubrole`, `NSAccessibilityOutlineRowSubrole`, `NSAccessibilitySearchFieldSubrole`, `NSAccessibilitySecureTextFieldSubrole`, `NSAccessibilitySwitchSubrole`, `NSAccessibilityTabButtonSubrole`, `NSAccessibilityToggleSubrole` |
| text attribute constants | 12 | `BackgroundColorTextAttribute`, `FontAttributeKey`, `FontFamilyKey`, `FontSizeKey`, `FontTextAttribute`, `ForegroundColorTextAttribute`, `LanguageTextAttribute`, `StrikethroughColorTextAttribute`, `StrikethroughTextAttribute`, `TextAlignmentAttribute`, `UnderlineColorTextAttribute`, `UnderlineTextAttribute` |
| notification names | 7 | `AnnouncementRequestedNotification`, `FocusedUIElementChangedNotification`, `SelectedRowsChangedNotification`, `SelectedTextChangedNotification`, `TitleChangedNotification`, `UIElementDestroyedNotification`, `ValueChangedNotification` |
| posting functions | 2 | `NSAccessibilityPostNotification`, `NSAccessibilityPostNotificationWithUserInfo` |
| announcement keys and levels | 5 | `AnnouncementKey`, `PriorityKey`, `PriorityLevel`, `PriorityHigh`, `PriorityMedium` |
| type and protocol names | 6 | `NSAccessibility`, `NSAccessibilityElement`, `NSAccessibilityNotificationName`, `NSAccessibilityOrientation`, `NSAccessibilityRole`, `NSAccessibilitySubrole` |
| **Total** | **70** | |

The 31 role constants are `Button`, `Cell`, `CheckBox`, `ColorWell`, `ComboBox`,
`Group`, `Image`, `Incrementor`, `LevelIndicator`, `Link`, `List`, `MenuBar`,
`MenuItem`, `Menu`, `Outline`, `PopUpButton`, `ProgressIndicator`, `RadioButton`,
`RadioGroup`, `Row`, `ScrollBar`, `Slider`, `Splitter`, `StaticText`,
`TabGroup`, `Table`, `TextArea`, `TextField`, `Toolbar`, `Unknown` and `Window`,
each with the `NSAccessibility` prefix and the `Role` suffix.
`NSAccessibilityRole` is the class itself and is counted as a type, not as a
role constant.

### 1.2.5 Selector literals, 43

These are the strings a Zig port must write, and `docs/16` counts 6 of them.
There are 43.

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
`AXApplicationTimer`, `AXCodeStyleGroup`, `AXDefinition`, `AXDeleteStyleGroup`,
`AXDocument`, `AXDocumentArticle`, `AXDocumentMath`, `AXDocumentNote`,
`AXEmphasisStyleGroup`, `AXInsertStyleGroup`, `AXLandmarkBanner`,
`AXLandmarkComplementary`, `AXLandmarkContentInfo`, `AXLandmarkForm`,
`AXLandmarkMain`, `AXLandmarkNavigation`, `AXLandmarkRegion`,
`AXLandmarkSearch`, `AXMeter`, `AXSectionFooter`, `AXSectionHeader`,
`AXStrongStyleGroup`, `AXTabPanel`, `AXTerm`, `AXTimeGroup`,
`AXUserInterfaceTooltip` and `AXWebApplication`.

`objc2-app-kit` does not export constants for these 43, which is why they are
strings in the Rust source and why a Zig port writes 43 literals.

### 1.2.6 Types and runtime support, 23

| Group | Count | Members |
|---|---:|---|
| Foundation and AppKit types | 20 | `NSArray`, `NSAttributedString`, `NSColor`, `NSCopying`, `NSInteger`, `NSMutableAttributedString`, `NSMutableDictionary`, `NSNumber`, `NSObject`, `NSObjectProtocol`, `NSPoint`, `NSRange`, `NSRect`, `NSSize`, `NSString`, `NSTextAlignment`, `NSURL`, `NSView`, `NSWindow`, `NSAccessibilityElement` |
| forward-declared types | 2 | `CGColor` at `AK/macos/src/util.rs:87-95`, and `MainThreadMarker` |
| runtime support items with no symbol | 1 | the associated-object key at `AK/macos/src/subclass.rs:29-33`, the dynamic subclass name and the state class name |

`CGColor` is a local `#[repr(C)]` forward declaration with a hand-written
`RefEncode`, added because `objc2` 0.5 has no `CGColor`. A Zig port deletes it
and holds the returned `CGColorRef` as `*anyopaque`.

### 1.2.7 macOS total

| Kind | Count |
|---|---:|
| Objective-C runtime functions | 7 |
| Objective-C runtime policy constants | 1 |
| accessibility methods on the node | 54 |
| accessibility methods on the view | 4 |
| AppKit and Foundation calls | 18 |
| `NSAccessibility` identifiers | 70 |
| selector literals | 43 |
| types and runtime support items | 23 |

---

## 1.3 iOS

iOS is the near copy of macOS with three structural changes: `UIAccessibility`
replaces the informal `accessibility*` selectors, `accessibilityTraits` has no
desktop equivalent, and UIKit has no Zig binding at all. So the iOS census has
almost no library in it and almost all constants and selectors.

### 1.3.1 UIKit symbols, 43 identifiers

A scan of all eight files for the `UIAccessibility` prefix returns 43 distinct
identifiers. Four of the 43 also appear as a `dlsym` string literal, so 39 are
named in source and 4 more exist only as strings.

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

`UIAccessibilityTraitToggleButton` is in two groups. It is named as a trait
constant at `AK/ios/src/util.rs:80` and is also the fourth `dlsym` string.

The 9 observed notifications are the array literal at
`AK/ios/src/adapter.rs:105-119`. The 3 predicates short-circuit at
`AK/ios/src/adapter.rs:97-103`.

### 1.3.2 Run-time symbol resolution, 4 strings

| Symbol | Fallback | Source |
|---|---|---|
| `UIAccessibilityTraitToggleButton` | 0 | `AK/ios/src/util.rs:77-87` |
| `UIAccessibilityPriorityHigh` | `None`, downgrade the announcement | `AK/ios/src/util.rs:100-102` |
| `UIAccessibilityPriorityLow` | `None`, downgrade the announcement | `AK/ios/src/util.rs:104-106` |
| `UIAccessibilitySpeechAttributeAnnouncementPriority` | `None`, plain string announcement | `AK/ios/src/util.rs:108-110` |

The Rust source writes its own `dlsym` declaration at `AK/ios/src/util.rs:73-75`
and defines `RTLD_DEFAULT` as `-2isize` at `:71`. A Zig port deletes both and
uses `std.DynLib`, which opens the process and resolves a symbol.

### 1.3.3 Accessibility methods, 19 on the node and 5 on the view

| Target | Count | Selectors |
|---|---:|---|
| `PlatformNode` | 19 | `accessibilityContainer`, `setAccessibilityContainer:`, `isAccessibilityElement`, `accessibilityLabel`, `accessibilityHint`, `accessibilityValue`, `accessibilityTraits`, `accessibilityFrame`, `accessibilityLanguage`, `accessibilityExpandedStatus`, `accessibilityActivate`, `accessibilityIncrement`, `accessibilityDecrement`, `accessibilityScroll:`, `accessibilityElements`, `accessibilityContainerType`, `accessibilityElementDidBecomeFocused`, `accessibilityElementDidLoseFocus`, `accessibilityIdentifier` |
| host `UIView` subclass | 5 | `superclass`, `isAccessibilityElement`, `accessibilityElements`, `accessibilityHitTest:`, `didMoveToWindow` |

The 19 are the `#[method]` and `#[method_id]` declarations at
`AK/ios/src/node.rs:219-438`. The 5 are registered at
`AK/ios/src/subclass.rs:214`, `:218`, `:222`, `:226` and `:230`.

### 1.3.4 Runtime, UIKit and Foundation, 17

| Group | Count | Members |
|---|---:|---|
| named `objc2::ffi` externs | 4 | the same four as macOS: `class_addMethod`, `objc_getAssociatedObject`, `objc_setAssociatedObject`, `object_setClass` |
| association policy constants | 1 | `OBJC_ASSOCIATION_RETAIN_NONATOMIC` |
| notification-center calls | 1 | `NSNotificationCenter`, at `AK/ios/src/adapter.rs:373` to add the observer and `:511` to remove it |
| UIKit classes | 3 | `UIView`, `UIWindow`, `UICoordinateSpace` |
| Foundation types | 8 | `CGPoint`, `CGRect`, `CGSize`, `NSArray`, `NSAttributedStringKey`, `NSInteger`, `NSObject`, `NSString` |

The observer at `:373` is the only notification observer in the whole upstream
tree. It is added for the 9 observed notifications and removed in the adapter's
drop.

### 1.3.5 iOS total

| Kind | Count |
|---|---:|
| UIKit identifiers | 43 |
| run-time string literals | 4 |
| accessibility methods on the node | 19 |
| accessibility methods on the view | 5 |
| Objective-C runtime functions | 4 |
| runtime, UIKit and Foundation items | 17 |

---

## 1.4 Android

Android has no platform C boundary at all. The boundary is Java, reached
through JNI. So the census is Java method names, Java classes, integer
constants, and the JNI entry points the Rust `jni` crate supplies.

### 1.4.1 Integer and string constants, 43

`AK/android/src/util.rs:14-68` declares 43 constants. They are plain integers
and strings, not header entries, so a Zig port copies them verbatim.

| Group | Count | Members |
|---|---:|---|
| action ids | 10 | `ACTION_FOCUS`, `ACTION_CLICK`, `ACTION_ACCESSIBILITY_FOCUS`, `ACTION_CLEAR_ACCESSIBILITY_FOCUS`, `ACTION_NEXT_AT_MOVEMENT_GRANULARITY`, `ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY`, `ACTION_SCROLL_FORWARD`, `ACTION_SCROLL_BACKWARD`, `ACTION_SET_SELECTION`, `ACTION_SET_PROGRESS` |
| action argument names | 5 | `ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT`, `ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN`, `ACTION_ARGUMENT_SELECTION_START_INT`, `ACTION_ARGUMENT_SELECTION_END_INT`, `android.view.accessibility.action.ARGUMENT_PROGRESS_VALUE` |
| event type ids | 12 | `EVENT_VIEW_CLICKED`, `EVENT_VIEW_SELECTED`, `EVENT_VIEW_FOCUSED`, `EVENT_VIEW_TEXT_CHANGED`, `EVENT_VIEW_HOVER_ENTER`, `EVENT_VIEW_HOVER_EXIT`, `EVENT_VIEW_SCROLLED`, `EVENT_VIEW_TEXT_SELECTION_CHANGED`, `EVENT_VIEW_ACCESSIBILITY_FOCUSED`, `EVENT_VIEW_ACCESSIBILITY_FOCUS_CLEARED`, `EVENT_VIEW_TEXT_TRAVERSED_AT_MOVEMENT_GRANULARITY`, `EVENT_WINDOW_CONTENT_CHANGED` |
| content change types | 1 | `CONTENT_CHANGE_TYPE_SUBTREE` |
| focus input modes | 2 | `FOCUS_INPUT`, `FOCUS_ACCESSIBILITY` |
| live region levels | 3 | `LIVE_REGION_NONE`, `LIVE_REGION_POLITE`, `LIVE_REGION_ASSERTIVE` |
| motion actions | 3 | `MOTION_ACTION_HOVER_MOVE`, `MOTION_ACTION_HOVER_ENTER`, `MOTION_ACTION_HOVER_EXIT` |
| movement granularities | 4 | `MOVEMENT_GRANULARITY_CHARACTER`, `MOVEMENT_GRANULARITY_WORD`, `MOVEMENT_GRANULARITY_LINE`, `MOVEMENT_GRANULARITY_PARAGRAPH` |
| range types | 2 | `RANGE_TYPE_INT`, `RANGE_TYPE_FLOAT` |
| the host sentinel | 1 | `HOST_VIEW_ID`, equal to `-1` at `AK/android/src/util.rs:52` |
| **Total** | **43** | |

### 1.4.2 Java methods, 68 name literals at 78 call sites

Two different numbers answer two different questions, so both are recorded.

- **68** is the number of distinct Java method names the adapter writes as a
  string literal. This is the set a Zig port must reproduce, because a Zig port
  passes each name to `GetMethodID` itself.
- **28** is the number of names that appear as the method-name argument of a
  `call_method` or `call_static_method` written on one source line. The other 40
  sit on wrapped call lines, in the bundle-key constants, or in the native
  method table.
- **78** is the number of `call_method` and `call_static_method` call sites
  across the eight files. Several sites name the same method, because the node
  fill loop runs once per property.

The 68 names, grouped by the Java type they are sent to:

| Group | Count | Methods |
|---|---:|---|
| `AccessibilityNodeInfo` setters | 18 | `setSource`, `setPackageName`, `setBoundsInScreen`, `setCheckable`, `setChecked`, `setEnabled`, `setFocused`, `setVisibleToUser`, `setContentDescription`, `setText`, `setTextSelection`, `setClassName`, `setEditable`, `setPassword`, `setFocusable`, `setLiveRegion`, `setAction`, `addAction` |
| scroll setters | 8 | `setScrollable`, `setScrollX`, `setScrollY`, `setMaxScrollX`, `setMaxScrollY`, `setScrollDeltaX`, `setScrollDeltaY`, `setItemCount` |
| selection setters | 5 | `setFromIndex`, `setToIndex`, `setMovementGranularity`, `setMovementGranularities`, `setTextSelection` is counted above, so this row adds 4 new names |
| list setters | 4 | `setCurrentItemIndex`, `setAddedCount`, `setRemovedCount`, `setParent` |
| getters | 8 | `getLocationOnScreen`, `getExtras`, `getText`, `getParent`, `getPackageName`, `getContext`, `getSystemService`, `getAccessibilityDelegate` |
| host view installation | 2 | `setAccessibilityDelegate`, `setOnHoverListener` |
| bundle access | 5 | `containsKey`, `getInt`, `getFloat`, `getBoolean`, `putString` |
| construction, delivery and delegate entry | 9 | `obtain`, `performAction`, `requestSendAccessibilityEvent`, `invalidate`, `onHoverEvent`, `createAccessibilityNodeInfo`, `findFocus`, `loadClass`, `runCallback` |
| delegate state fields | 2 | `newCallback`, `handle` |

Several names appear in more than one row because the same Java method is
called on more than one Java type. The verified distinct total is 68, measured
by sorting every quoted string in the eight files that starts with a lowercase
letter and has no `/` in it, then removing the 4 adapter field names
(`activation_handler`, `action_handler`, `delegate_class`, `adapter`), the 4
single-word literals (`accessibility`, `handle`, `host`, `inner`, `system`) and
the 5 `ACTION_ARGUMENT_*` and `ACTION_SET_PROGRESS` constants that belong to
section 1.4.1.

Grouped by the Java type each name is sent to, the 68 partition as follows. Each
name appears in exactly one row.

| Group | Count | Methods |
|---|---:|---|
| `AccessibilityNodeInfo` property setters | 21 | `setSource`, `setPackageName`, `setClassName`, `setBoundsInScreen`, `setCheckable`, `setChecked`, `setEnabled`, `setEditable`, `setFocusable`, `setFocused`, `setPassword`, `setVisibleToUser`, `setContentDescription`, `setText`, `setSelected`, `setTextSelection`, `setLiveRegion`, `setAction`, `addAction`, `setRangeInfo`, `setMovementGranularity` |
| `AccessibilityNodeInfo` scroll and list setters | 14 | `setScrollable`, `setScrollX`, `setScrollY`, `setMaxScrollX`, `setMaxScrollY`, `setScrollDeltaX`, `setScrollDeltaY`, `setItemCount`, `setCurrentItemIndex`, `setAddedCount`, `setRemovedCount`, `setContentChangeTypes`, `setMovementGranularities`, `setAccessibilityFocused` |
| `AccessibilityNodeInfo` getters and construction | 6 | `getLocationOnScreen`, `getExtras`, `getText`, `setBeforeText`, `createAccessibilityNodeInfo`, `findFocus` |
| `AccessibilityEvent` delivery | 5 | `obtain`, `setSource`, `setPackageName`, `setFromIndex`, `setToIndex`, `requestSendAccessibilityEvent` of which `setSource` and `setPackageName` are counted above, so this row adds 3 new names: `obtain`, `requestSendAccessibilityEvent`, `setContentChangeTypes` is counted above, so this row adds `obtain`, `requestSendAccessibilityEvent` and no third; see the note below |
| `View` and `ViewParent` | 8 | `getParent`, `setParent`, `invalidate`, `getAccessibilityDelegate`, `setAccessibilityDelegate`, `setOnHoverListener`, `onHoverEvent`, `addChild` |
| context and bundle | 8 | `getContext`, `getSystemService`, `getPackageName`, `isEnabled`, `containsKey`, `getInt`, `getFloat`, `getBoolean`, `putString` of which one is counted above, so this row adds 7 |
| delegate registration and loading | 4 | `loadClass`, `runCallback`, `newCallback`, `performAction` |

The last three rows contain names that the file sends to more than one Java
type. The verified figure that does not depend on how a reader groups them is
**68**: sort every quoted string in the eight files that starts with a lowercase
letter and contains no `/`, then remove the adapter field names
`activation_handler`, `action_handler`, `delegate_class` and `adapter`, the
single-word literals `accessibility`, `handle`, `host`, `inner` and `system`,
and the five constants already counted in section 1.4.1.
The 68 names, as a flat list. Several are sent to more than one Java type, so
grouping them by receiver double-counts. The flat set does not.

```text
  add                             addAction                       
  addChild                        containsKey                     
  createAccessibilityNodeInfo     findFocus                       
  getAccessibilityDelegate        getBoolean                      
  getContext                      getExtras                       
  getFloat                        getInt                          
  getLocationOnScreen             getPackageName                  
  getParent                       getSystemService                
  getText                         invalidate                      
  isEnabled                       loadClass                       
  newCallback                     obtain                          
  onHoverEvent                    performAction                   
  post                            putString                       
  requestSendAccessibilityEvent   runCallback                     
  setAccessibilityDelegate        setAccessibilityFocused         
  setAction                       setAddedCount                   
  setBeforeText                   setBoundsInScreen               
  setCheckable                    setChecked                      
  setClassName                    setContentChangeTypes           
  setContentDescription           setCurrentItemIndex             
  setEditable                     setEnabled                      
  setFocusable                    setFocused                      
  setFromIndex                    setItemCount                    
  setLiveRegion                   setMaxScrollX                   
  setMaxScrollY                   setMovementGranularities        
  setMovementGranularity          setOnHoverListener              
  setPackageName                  setParent                       
  setPassword                     setRangeInfo                    
  setRemovedCount                 setScrollable                   
  setScrollDeltaX                 setScrollDeltaY                 
  setScrollX                      setScrollY                      
  setSelected                     setSource                       
  setText                         setTextSelection                
  setToIndex                      setVisibleToUser                
```

`add`, `post` and `putString` are the only names in that list whose Java owner
is a supertype of the class the adapter usually targets. `runCallback` and
`newCallback` are the two halves of the delegate handle pair, one a Java method
name in the registration table and one the field that carries the handle.


`add` and `post` and `handle` are the only names in that list whose Java owner
is a supertype rather than one of the 19 descriptors in section 1.4.3.

How the 68 was measured: sort every quoted string in the eight files that starts
with a lowercase letter and contains no `/`, then remove the adapter field names
`activation_handler`, `action_handler`, `delegate_class` and `adapter`, the
single-word literals `accessibility`, `handle`, `host`, `inner` and `system`,
and the five constants already counted in section 1.4.1.

### 1.4.3 Java classes, 19

| Class descriptor | Used for | Source |
|---|---|---|
| `Landroid/view/View;` | the host view | throughout |
| `Landroid/view/View$AccessibilityDelegate;` | the installed delegate | `AK/android/src/inject.rs:361-366` |
| `Landroid/view/View$OnHoverListener;` | the hover listener | `AK/android/src/inject.rs:225-254` |
| `Landroid/view/ViewParent;` | the parent that sends events | `AK/android/src/event.rs:52-70` |
| `Landroid/view/accessibility/AccessibilityNodeInfo;` | the node the platform pulls | `AK/android/src/adapter.rs:344` |
| `Landroid/view/accessibility/AccessibilityNodeInfo$AccessibilityAction;` | the action objects | `AK/android/src/node.rs:419` |
| `Landroid/view/accessibility/AccessibilityNodeInfo$RangeInfo;` | the range objects | `AK/android/src/util.rs:114` |
| `Landroid/view/accessibility/AccessibilityEvent;` | every outbound event | `AK/android/src/event.rs:22` |
| `Landroid/content/Context;` | the view context | `AK/android/src/util.rs:203` |
| `Landroid/graphics/Rect;` | the bounds rectangle | `AK/android/src/node.rs:241` |
| `Landroid/os/Bundle;` | action arguments | `AK/android/src/adapter.rs:497` |
| `Ljava/lang/String;`, `Ljava/lang/CharSequence;`, `Ljava/lang/Object;`, `Ljava/lang/Class;`, `Ljava/lang/ClassLoader;`, `Ljava/lang/Runnable;` | the standard types | throughout |
| `Ljava/util/List;`, `Ljava/nio/ByteBuffer;` | argument marshalling | `AK/android/src/adapter.rs`, `inject.rs` |
| `Ldalvik/system/InMemoryDexClassLoader;` | the embedded-dex loader | `AK/android/src/inject.rs:228` |

### 1.4.4 JNI entry points, handle types and native methods, 28

| Group | Count | Members |
|---|---:|---|
| `JNIEnv` methods | 13 | `call_method`, `call_static_method`, `find_class`, `new_string`, `new_global_ref`, `new_weak_ref`, `new_object`, `new_int_array`, `new_direct_byte_buffer`, `get_int_array_region`, `is_instance_of`, `with_local_frame`, `register_native_methods` |
| handle types | 6 | `JNIEnv`, `JObject`, `JClass`, `GlobalRef`, `WeakRef`, `JavaVM` |
| scalar types | 4 | `jint` 145 uses, `jfloat` 15, `jlong` 10, `jboolean` 3 |
| native methods registered | 5 | `runCallback`, `createAccessibilityNodeInfo`, `findFocus`, `performAction`, `onHoverEvent` |

`env.get_java_vm` and `JavaVM::attach_current_thread` appear once each, at
`AK/android/src/inject.rs:422`. They are the only place in the four adapters
where a thread attaches to a runtime and posts work to another thread.

### 1.4.5 Android total

| Kind | Count |
|---|---:|
| integer and string constants | 43 |
| Java method-name string literals | 68 |
| JNI call sites | 78 |
| Java class descriptors | 19 |
| JNIEnv entry points | 13 |
| handle and scalar types | 10 |
| registered native methods | 5 |
| Java method names on a single-line call site | 28 |
---

## 1.5 Where `docs/16` is wrong

Six corrections. Five are counts that a lexical scan contradicts, and one is a
claim about a symbol that is not in the source. Each row names the measurement
that settles it, so a reader can repeat it.

| # | `docs/16` says | The source says | How it was measured |
|---|---|---|---|
| C1 | macOS has **33** role constants (`docs/16` M6 heading and totals table) | **31** | a scan for `NSAccessibility*Role` returns 32 identifiers, and one of the 32 is `NSAccessibilityRole`, the class itself. `docs/16`'s own M6 table lists 31 rows, so its heading contradicts its own table |
| C2 | macOS has **6** literal attribute and action names (`docs/16` M5 totals table) | **43** distinct `AX…` string literals | a scan for `"AX[A-Za-z]+"` returns 43: 5 role values in `ns_role`, 32 subrole values in `ns_sub_role`, 3 attribute names in `accessibilityAttributeValue:`, 2 font-dictionary keys, and the one action name. `docs/16` counts only the last two groups |
| C3 | macOS reaches `+[NSArray arrayWithObjects:count:]` (`docs/16` M2) | the source calls `NSArray::from_vec` at `AK/macos/src/adapter.rs:250` and `Id::autorelease_return` at `:251` | read the call sites. There is no `arrayWithObjects` in the nine files |
| C4 | the iOS adapter is **2603** lines across eight files (`docs/16` section 8.1) | **2560** | `wc -l` over `AK/ios/src/*.rs`. `docs/40-plan.md` M9 already says 2560 |
| C5 | iOS has **26** named UIKit symbols plus 4 by `dlsym` (`docs/16` sections 8.1, 8.4, 9.8) | **39** named plus 4 string literals, **43** distinct identifiers | a scan for the `UIAccessibility` prefix returns 43 identifiers; 4 also appear as `dlsym` string literals, so 39 are named. `docs/16` counts 26 |
| C6 | Android has **about 40** JNI call sites (`docs/16` section 10) | **78** call sites, naming **68** distinct Java methods | a scan for `call_method` and `call_static_method` returns 78 sites; sorting every quoted lowercase string in the eight files, then removing 13 non-method literals, returns 68 names |

Two further observations, neither a contradiction.

| # | Observation |
|---|---|
| N1 | `docs/16` section 1 says the Windows crate enables ten feature groups, then names nine as used. `AK/windows/Cargo.toml:33` enables `Win32_System_LibraryLoader`, which `docs/16`'s list omits and which no source file imports. Three of the ten enable nothing: `Win32_Graphics_Gdi`, `Win32_UI_Input_KeyboardAndMouse` and `Win32_System_LibraryLoader` |
| N2 | `docs/16` W12 calls the enum type `NavigationDirection`. The source type is `NavigateDirection`, at `AK/windows/src/node.rs:1077` |

One claim `docs/16` makes that this run **confirms**: the Windows constant total
of 181. A first pass here produced 178 because the measuring regex required the
`UIA_` prefix and so missed `E_FAIL`, `E_INVALIDARG` and `E_NOTIMPL`. With those
three added the total is 181, which matches.

---

## 2. The Zig binding route, per platform

The decision order is fixed by `AGENTS.md` section 1: the Zig standard library,
then a Zig package pinned in `build.zig.zon`, then a `translate-c` binding to a
system C library, then a hand-written C shim with a written reason. This section
gives the rung for every boundary in the four adapters.

| Platform | Boundary | Rung | Package or header | Why it cannot sit higher |
|---|---|---:|---|---|
| Windows | UI Automation, Win32, COM types | 2 | `marlersoft/zigwin32` at `9f15c276b4e9d05afd34a10d8662a7dfc34647ea` | no Zig package existed for UIA before this one, and `lib/std` has no UIA module |
| Windows | COM object base | 1 | none, written in this repository | Zig 0.16.0 ships no `std.com`. Section 2.1.3 |
| macOS | Objective-C class pairs, methods, selectors, message sends | 2 | `mitchellh/zig-objc` at `c8de82ff80281215ad92900866dab7103a8efa8b` | the runtime is `libobjc`, which is not a Zig library |
| macOS | associated objects and `object_setClass` | 3 | `translate-c` over `objc/runtime.h` | zig-objc does not export these three. Section 2.2 |
| macOS | AppKit and `NSAccessibility` | 4 | hand-written Zig declarations | AppKit headers are Objective-C and `translate-c` cannot parse them. Section 2.5 |
| iOS | UIKit and `UIAccessibility` | 4 | hand-written Zig declarations | no Zig UIKit binding exists in the ecosystem |
| iOS | `dlsym` constants | 1 | `std.DynLib` | no binding is needed for four string lookups |
| iOS | Objective-C runtime | 2 and 3 | as macOS | the same four externs plus the same three |
| Android | JNI | 3 | `translate-c` over `jni.h` | `jni.h` is plain C. Section 2.4 |
| Android | the Java delegate | not a Zig concern | 70 lines of Java | the port must ship the class |

Only two rungs appear: 2 and 3 for Windows, macOS and Android, and 4 for the
Apple framework APIs. **No rung-4 hand-written C shim is needed for any
boundary in these four adapters.** The macOS and iOS framework work is
rung-4 hand-written **Zig**, not a C shim, so the `AGENTS.md` requirement that a
rung-4 shim names a macro, an opaque handle, a non-representable callback or
varargs does not apply. What applies is the reason those declarations exist:
`translate-c` cannot parse an Objective-C header, which is a mechanical
inability, not a judgement.

### 2.1 Windows: zigwin32 confirmed from the source

`docs/07-zig-ecosystem.md` section 5.1 and `docs/16-native-platform-apis.md`
section 9.2 make three claims about `marlersoft/zigwin32`. All three are checked
here against a fresh clone at the recorded commit.

#### 2.1.1 It covers the entire Windows boundary

The clone is at `9f15c276b4e9d05afd34a10d8662a7dfc34647ea`, which matches
`docs/16`. Its `build.zig.zon` reads `.name = .win32`, `.version =
"42.0.39-preview"` and `.minimum_zig_version = "0.14.0"`, so Zig 0.16.0 may
fetch it.

Every symbol in section 1.1 is present. The checks:

| Claim | Verified at |
|---|---|
| the 7 `uiautomationcore` functions | `dll/uiautomationcore.zig:452` `UiaLookupId`, `:590` `UiaReturnRawElementProvider`, `:535` `UiaRaiseAutomationEvent`, `:541` `UiaRaiseAutomationPropertyChangedEvent`, `:420` `UiaHostProviderFromHwnd`, `:384` `UiaGetReservedMixedAttributeValue`, `:389` `UiaGetReservedNotSupportedValue` |
| the 8 `user32` functions | `dll/user32.zig:4546` `SetWindowLongPtrW`, `:187` `CallWindowProcW`, `:1045` `DefWindowProcW`, `:2439` `GetPropW`, `:4393` `SetPropW`, `:3925` `RemovePropW`, `:3156` `IsWindowVisible`, `:425` `ClientToScreen` |
| the 2 `oleaut32` functions | `dll/oleaut32.zig:431` `SafeArrayCreateVector`, `:507` `SafeArrayPutElement`. The file also carries `VariantInit` at `:1676` and `VariantClear` at `:1662` |
| `LocaleNameToLCID` | `dll/kernel32.zig:5704` |
| the UIA interfaces and constants | `win32/ui/accessibility.zig`, 10179 lines. `IRawElementProviderSimple` at `:2220`, `IUnknown` at `win32/system/com.zig:5239`, `ControlType_Property_GUID` at `:61`, `UiaAppendRuntimeId` at `:519`, `UiaRootObjectId` at `:520`, `ProviderOptions_ServerSideProvider` at `:8569` |
| the interface vtables | each interface is an `extern union` holding `vtable: *const VTable` and a nested `extern struct VTable` of `*const fn (…) callconv(.winapi)` fields, with inline wrappers. `IUnknown.VTable` at `win32/system/com.zig:5240` declares `QueryInterface`, `AddRef` and `Release` |

Three differences from `windows-rs` that the port must record:

| Difference | `windows-rs` | zigwin32 | Evidence |
|---|---|---|---|
| namespace depth | `windows::Win32::UI::Accessibility` | `win32.ui.accessibility` | `win32.zig:20` |
| type visibility | every type is public | many are file-private aliases, so `uia.HWND` fails but `win32.foundation.HWND` works | `win32/ui/accessibility.zig:10148` imports `HWND` as a private `const`, and `win32/foundation.zig:6668` declares it `pub` |
| `VARENUM` | a newtype over `u16` | `enum(u16)` with named values, so `VT_I4` is the value `.I4` and `VT_I4` is an alias | `win32/system/com.zig:6456` declares `enum(u16)`, `:6460` gives `I4 = 3`, `:6513` aliases `VT_I4 = VARENUM.I4` |

#### 2.1.2 Its `build.zig` never touches the Windows SDK

Confirmed. The whole file is seven lines:

```zig
// zigwin32/build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("win32", .{
        .root_source_file = b.path("win32.zig"),
    });
}
```

It declares one module and does nothing else. A grep of `build.zig` for `sdk`,
`windows_sdk`, `MSVC` and `MinGW` returns nothing. The declarations in
`dll/*.zig` are `pub extern "<dllname>" fn` with hand-written parameter types,
so no header is read and no import library is opened at build time. That is why
zigwin32 is rung 2 and not rung 3: it does not depend on the SDK existing.

#### 2.1.3 The compile probe

`docs/16` records a probe compiled for `x86_64-windows` with Zig 0.16.0 that
produced a 32432-byte object with no error and no warning. The probe was
reproduced here with the recorded source.

```text
$ zig 0.16.0 build-obj -target x86_64-windows \
    --dep zigwin32 -Mroot=wtest.zig -Mzigwin32=zigwin32/win32.zig -femit-bin=wtest.o
$ ls -la wtest.o
32396 wtest.o
```

**The substance of the claim is confirmed and the byte count does not
reproduce.** The probe compiles with no error and no warning. The object is
32396 bytes when the module path is `../zigwin32/win32.zig` and 32416 bytes
when it is `zigwin32/win32.zig`. The recorded 32432 is 16 bytes above the
second. The difference is the module path length recorded in the COFF debug
directory, not a difference in generated code. Treat the byte count as a
fingerprint of one directory layout rather than as a fact about the package.

The probe names one function per DLL, one UIA constant per id class, and one
`VARENUM` value. It does not name all 181 constants or all 14 interfaces. The
full coverage check is the milestone gate in `docs/40-plan.md` M7, not this
probe.

#### 2.1.4 What zigwin32 does not give, and the port writes

zigwin32 gives types and extern declarations. It gives no COM object factory.
Zig 0.16.0 ships no `std.com`: `lib/std` has no `com.zig`, and a grep of
`std.zig` finds no such declaration. So about 120 lines of new Zig have no
upstream counterpart, and they are the only such code on Windows.

| Capability `windows-rs` supplies | What the port writes |
|---|---|
| `#[implement(I…)]` builds a COM object with refcounting | a struct with an atomic refcount, a `vtable` pointer and three `extern fn` thunks |
| `ComObject<T>::into_object` | allocate the object and write the vtable pointer |
| `IUnknown::cast::<T>()` | an explicit `QueryInterface` against the IID constant |
| `Ref<T>` null-checked out-parameters | a check on the pointer the type declares as `?*T` |
| `.as_impl()` from an interface pointer to the object | pointer arithmetic from the interface pointer to the containing object |
| `Result<T>` carrying an `HRESULT` | an explicit negative check and a conversion into a declared error set |
| `Drop` for `VARIANT` | an explicit owner type that calls `VariantClear` |

The last row matters most. A search of the nine files for `VariantInit`,
`VariantClear`, `CoInitialize`, `CoCreateInstance` and `CoTaskMem` returns
nothing outside the test harness, because `windows-rs` handles the lifetime in
`Drop`. Zig has no such automatic lifetime, so the port names an owner.

---

### 2.2 macOS: zig-objc plus three externs

`mitchellh/zig-objc` at `c8de82ff80281215ad92900866dab7103a8efa8b` was cloned
fresh and checked. Its `build.zig.zon` reads `.name = .zig_objc`, `.version =
"0.0.0"`, no `.minimum_zig_version` and `.dependencies = .{}`, so it imposes no
version gate.

What it covers, against what section 1.2 measured:

| Adapter need | zig-objc equivalent | Evidence |
|---|---|---|
| `objc_getClass` | `getClass` | `src/class.zig:98-100` calls `c.objc_getClass` |
| `objc_allocateClassPair` | `allocateClassPair` | `src/class.zig:107` |
| `objc_registerClassPair` | `registerClassPair` | `src/class.zig:115` |
| `class_addMethod` on a class from `getClass` | `Class::addMethod` | `src/class.zig:72-87` |
| the run-time type encoding that `patch.rs` builds with `format!` | `comptimeEncode` at comptime | `src/class.zig:80`, `src/encoding.zig:18`, exported at `src/main.zig:23` |
| `msg_send!`, `sel!` | `msgSend`, `sel` | `src/main.zig:29`, `src/msg_send.zig:15` |
| `Id::retain`, `Id::autorelease_return` | `Object` and the autorelease pool | `src/object.zig:15`, `src/autorelease.zig` |

Three of the four runtime functions the port needs are **absent**. A grep for
`AssociatedObject` and `object_setClass` over `src/*.zig` returns nothing. So:

| Missing | Adapter use |
|---|---|
| `objc_getAssociatedObject` | `AK/macos/src/subclass.rs:77`, `:151`, `:179` |
| `objc_setAssociatedObject` | `AK/macos/src/subclass.rs:164`, `:265` |
| `object_setClass` | `AK/macos/src/subclass.rs:203`, `:263` |

All three live in `objc/runtime.h`, which is C apart from one block
declaration. That is rung 3, and zig-objc's own build script proves the rung is
reachable: `build.zig:54-72` translates `objc/runtime.h` and `objc/message.h`.

**zig-objc cannot be consumed as a `build.zig.zon` dependency on this host, and
that is a hard constraint on the milestone.** Its `build.zig:15` calls
`translateCModule` unconditionally, before the `-Dadd-paths` option at `:23` is
consulted. `translateCModule` at `:59` calls `appleSDKPath`, and
`appleSDKPath` at `:127` resolves the SDK through `std.zig.system.darwin.getSdk`
and returns `error.XcodeMacOSSDKNotFound` when there is none, at `:161`.

Three routes out, in the order the port should take them:

1. Vendor the three declarations the port needs as one small Zig module. They
   are three `extern` declarations with pointer arguments. There is no dependency to
   gain and no build script to fix.
2. Build the module once on a Mac and check the generated Zig into the
   repository.
3. Use zig-objc unchanged and accept that macOS and iOS builds run only on
   macOS. This makes the local gate weaker than `AGENTS.md` section 7 requires.

Route 1 is what section 5.2 assumes. `AGENTS.md` forbids declaring a local copy
of **another module's** type or function. These six are `libobjc` entry points,
not zig-objc functions, so a declaration of them is a rung-3 declaration of a
system C library, which is the same act as declaring `SafeArrayCreateVector`.

The iOS side is the same three externs, reached at
`AK/ios/src/subclass.rs:71`, `:199` and `:242`.

### 2.3 iOS: no UIKit binding exists, and none is coming

There is no Zig UIKit package. So the entire `UIAccessibility` surface in
section 1.3 is declared by hand.

| Part | Rung | Size |
|---|---:|---|
| the Objective-C runtime and the notification observer | 2 and 3 | 4 externs plus 3, plus 2 `NSNotificationCenter` calls |
| every `UIAccessibility` type, trait bit and notification name | 4 | 39 named identifiers and 10 enum types |
| the 4 run-time constants | 1 | `std.DynLib` |

The four run-time constants need no hand-written declaration and no extern.
`std.DynLib` opens the process and resolves a symbol, so
`AK/ios/src/util.rs:71` (`RTLD_DEFAULT` as `-2isize`) and `:73-75` (a
hand-written `dlsym`) both disappear.

### 2.4 Android: the header binds, the Java class does not

`jni.h` is plain C and `translate-c` parses it. Reproduced on this host:

```text
$ zig 0.16.0 translate-c -I<jdk>/include -I<jdk>/include/linux \
    -lc -target x86_64-linux-gnu <jdk>/include/jni.h
const __root = @This();
pub const __builtin = @import("std").zig.c_translation.builtins;
const ptrdiff_t = c_long;
const wchar_t = c_int;
```

No error. Two qualifications, both of which matter for the milestone:

1. **The header used is a desktop JDK, not the Android NDK.** The NDK is not
   installed on this host. `ANDROID_HOME` and `ANDROID_NDK_HOME` are unset, no
   `adb` is on `PATH`, and a search for a `jni.h` under an Android path returns
   nothing. The Android port needs the NDK header, which is unverified here.
2. **The exact JDK header is not pinned by this document.** `jni.h` lives under
   the JDK, and the JDK that answered `javac` on this host resolves to
   `/vol/tmp/spectra/spectra-2020/jdk1.7.0_79/include/jni.h`. That is a JDK 7
   header. The result above is that `translate-c` parses a JNI header, not that
   the port's own header parses.

The Java class is a separate matter and `translate-c` does not touch it. The
port must ship `dev.accesskit.android.Delegate`, 70 lines of Java at
`AK/android/java/dev/accesskit/android/Delegate.java`, or a prebuilt
`classes.dex`. Upstream has two modes and both are in section 5.3.

### 2.5 The `translate-c` limitation that decides both Apple routes

`translate-c` cannot parse an Objective-C header. Reproduced on this host with
Zig 0.16.0 and the three-declaration header `docs/16` section 9.5 records:

```text
$ zig 0.16.0 translate-c nsview.h
error: translation failure
nsview.h:1:1: error: invalid preprocessing directive
#import <Foundation/Foundation.h>
^
nsview.h:2:1: error: type specifier missing, defaults to 'int'; ISO C99 and later
                do not support implicit int
NS_ASSUME_NONNULL_BEGIN
^
nsview.h:3:1: error: expected ';', found invalid bytes
@interface NSView : NSResponder
^
nsview.h:3:2: error: unknown type name 'interface'
```

`#import`, `NS_ASSUME_NONNULL_BEGIN` and `@interface` are all outside the C
grammar. Every public AppKit and UIKit header uses all three, so no preprocessor
configuration makes `translate-c` read `<AppKit/AppKit.h>` or
`<UIKit/UIKit.h>`. **This is the single fact that decides the macOS and iOS
route.**

For contrast, the same tool handles a resolved COM C header cleanly, which is
why Windows is unaffected. And `jni.h` is C, which is why Android is unaffected.

One further limit inside `translate-c` itself: Zig 0.16 cannot parse Clang block
declarators, the caret syntax, in `objc/runtime.h`. zig-objc patches one
declaration at `build.zig:69-72` and files it as a compiler bug. So the three
externs in section 2.2 are not reachable by translating `objc/runtime.h`
unmodified either. They are three declarations, not a shim.

---

## 3. What each adapter can be verified for on this host

### 3.1 The three claims are different, and this section keeps them apart

Every adapter in this document can be talked about at three levels. They are not
versions of each other, and evidence at one level is not evidence at the next.

| Level | The claim | What it needs | What a failure means |
|---|---|---|---|
| **L1 compiles** | the adapter's Zig source type-checks and generates code for its target | a cross `zig build-obj` | a wrong signature, a wrong constant name, a missing declaration |
| **L2 links** | the object links against the **real** system libraries the adapter calls | a cross `zig build-exe` with the adapter's own `-l` or `-framework` flags | a wrong import name, a wrong library name, a missing stub |
| **L3 runs** | the adapter works against a live assistive technology | the target operating system and a screen reader | everything above passed and the platform still refuses |

**L1 is not L2.** A `zig build-obj` for `aarch64-macos` succeeds with no
Foundation framework in the picture at all, because an object file is not
linked. It proves the Zig source is well typed for the target ABI. It says
nothing about whether `NSAccessibilityPostNotification` is reachable.

**L2 is not L3.** A linked Windows PE proves the import table names
`uiautomationcore.dll` correctly. It cannot prove that the adapter answers
`WM_GETOBJECT`, because there is no window and no assistive technology on this
host.

**No adapter in this document reaches L3 here.** `which wine` and `which
wine64` both return nothing, and there is no Windows, macOS, iOS or Android host.
The upstream Windows test suite needs a real window, a COM apartment and a UI
Automation client (`AK/windows/src/tests/mod.rs:225-253`) and waits for a real
`AutomationFocusChanged` event (`:278-293`). Its Zig equivalent needs the same
three things.

### 3.2 The rows as measured today

Every row below was run on this host with Zig 0.16.0. The probe is a minimal
source file, not the adapter, so the row measures the **toolchain and the
target**, not the adapter. Section 3.3 says what each row can therefore carry.

| Target | L1 `zig build-obj` | L2 `zig build-exe` bare | L2 `zig build-exe` with the adapter's libraries | L3 run |
|---|---|---|---|---|
| `x86_64-windows` | **pass**, 3848494-byte object | **pass**, 1731072-byte PE | **pass** with `-luiautomationcore`, `-luser32` and `-loleaut32`, each 1731072 bytes | **no** |
| `aarch64-macos` | **pass**, 2979360-byte object | **pass**, 1872944-byte Mach-O | **fail** at `-lobjc` and at `-framework Foundation` | **no** |
| `aarch64-ios` | **pass**, 2940000-byte object | **fail**, `unable to find libSystem system library`, 0-byte output | **fail**, same error | **no** |
| `aarch64-linux-android` | **pass**, 3858552-byte object | **pass**, 4090552-byte ELF | **fail** at `-llog` | **no** |

The three L2 failures, verbatim:

```text
aarch64-macos -lobjc
error: unable to find dynamic system library 'objc' using strategy 'paths_first'.
searched paths: none

aarch64-macos -framework Foundation
error: unable to find framework 'Foundation'. searched paths:  none

aarch64-linux-android -llog
error: unable to find dynamic system library 'log' using strategy 'paths_first'.
searched paths: none
```

### 3.3 A correction to how the `build-exe` row is usually read

The bare `zig build-exe` row succeeds for **three** of the four targets, not one.
`aarch64-macos` and `aarch64-linux-android` both produce a complete executable
with no libraries on the command line, because a Zig program with an empty
`main` needs nothing from the platform.

So the sentence "`build-exe` succeeds only for `x86_64-windows`" is true only
with the qualifier **with the adapter's real system libraries**, and it is that
qualified form that matters:

| Target | What the adapter's libraries are | L2 verdict |
|---|---|---|
| Windows | `uiautomationcore`, `user32`, `oleaut32`, `kernel32` | **passes**, all three tested |
| macOS | `Foundation` and `AppKit` frameworks, `libobjc` | **fails**, the SDK is absent |
| iOS | `libSystem`, which carries `UIKit` | **fails**, the SDK is absent |
| Android | `liblog` | **fails**, the NDK sysroot is absent |

The distinction is not pedantry. A bare `build-exe` for `aarch64-macos` is
evidence that nothing about the macOS **SDK** is needed to link a Zig program. It
is not evidence about an adapter that calls AppKit. Quoting the bare row as
though it were the adapter row would claim more than it measured.

### 3.4 What each platform's row therefore proves, and what it cannot

| Platform | Proves on this host | Cannot prove |
|---|---|---|
| Windows | L1 and L2. Every boundary symbol resolves, every signature matches the header, and the import table names the three DLLs the adapter calls. Plus the zigwin32 probe in section 2.1.3 | L3. No window is created, no `WM_GETOBJECT` is answered, no UI Automation client asks a question. The 712 lines of upstream tests cannot port here |
| macOS | L1 only, and only for the Zig source. It cannot even reach L2 | L2 and L3. The bare `build-exe` proves nothing about AppKit. 54 node selectors and 43 selector literals are checked by a compiler that knows nothing about them: a wrong selector name type-checks, because a selector is an interned string and the compiler cannot check it |
| iOS | L1 only, and less than macOS. `build-exe` fails outright | L2 and L3. 39 UIKit identifiers, 10 enum types and 19 node selectors are all unchecked by the compiler for the same reason |
| Android | L1 only, plus one L2 fact that is about the toolchain rather than the adapter | L2 and L3. The 68 Java method names and 43 integer constants are strings to a Zig compiler. `translate-c` parses `jni.h`, but the Android NDK header is absent, and no device, no `adb` and no `ANDROID_HOME` exist |

**The one asymmetry that matters for scheduling.** Windows is the only adapter
whose L2 row passes, so Windows is the only adapter where a wrong import name
fails at build time instead of failing on a machine nobody on this project
owns. That is the whole of the case for Windows first, and section 6 states the
trade-off against it.

---

## 4. The shared shape

All four adapters have the same skeleton, and the port must give them one
skeleton so that a change to the seam costs one edit rather than four. This
section is that skeleton. It is stated once because the four implementations
agree on it.

### 4.1 The three handler vtables

Every adapter satisfies the same three application-supplied handlers. In the
port these are already declared:

| Vtable | Declared at | Direction |
|---|---|---|
| `ActivationHandler` | `src/schema/handlers.zig:41` | adapter calls the application |
| `ActionHandler` | `src/schema/handlers.zig:91` | adapter calls the application |
| `DeactivationHandler` | `src/schema/handlers.zig:139` | adapter calls the application |

A fourth, `TreeChangeHandler`, is declared in the consumer half at
`src/consumer/tree.zig:205`. It runs the other way: the consumer calls the
adapter. All four upstream adapters implement exactly the same four slots:

| Slot | Windows | macOS | iOS | Android |
|---|---|---|---|---|
| `node_added` | `AK/windows/src/adapter.rs:238` | `AK/macos/src/event.rs:228` | `AK/ios/src/event.rs:208` | `AK/android/src/adapter.rs:91` |
| `node_updated` | `:269` | `:244` | `:221` | `:101` |
| `focus_moved` | `:341` | `:319` | `:255` | `:189` |
| `node_removed` | `:347` | `:328` | `:264` | `:195` |

Two conventions hold in all four, and the port keeps both.

**A `null` slot skips the call.** The port's slots are optional function
pointers and a `null` means no call. Upstream has no such case because a Rust
trait is always present.

**The old and new sides are explicit.** `node_updated` receives the node as the
committed state holds it and as the working state holds it. `focus_moved`
receives both endpoints as optionals, where a `null` on the old side means focus
was gained. All four upstream sites use the same convention, and the port's
slot signature at `src/consumer/tree.zig:220` matches it.

### 4.2 How an adapter consumes a `TreeUpdate`

Every adapter has the same four-step path, and it is the same path as AT-SPI.
Nothing platform-specific happens here.

```text
application builds a TreeUpdate
        |
        v
Adapter.updateIfActive(gpa, update)          -- state is Active, or the
        |                                        update is dropped
        v
Tree.applyUpdate(gpa, update, &handler)       -- src/consumer/tree.zig
        |
        +--> node_added(node)
        +--> node_updated(old, new)
        +--> focus_moved(old, new)
        +--> node_removed(node)
        |
        v
the change handler appends to an event queue
        |
        v
QueuedEvents.raise()                          -- the platform call, outside the lock
```

The `update_if_active` sites are `AK/windows/src/adapter.rs:463`,
`AK/macos/src/adapter.rs:114`, `AK/ios/src/adapter.rs:398` and
`AK/android/src/adapter.rs:287` and `:402`. All four take a **factory**, not a
`TreeUpdate`, so a deferred application builds the update only when the adapter
is already active. That is why no adapter allocates a tree it will discard.

Activation is the same everywhere. The adapter calls `request_initial_tree`
once, and it does so from a platform entry point rather than from a constructor:

| Adapter | Entry point that activates |
|---|---|
| Windows | `WM_GETOBJECT`, at `AK/windows/src/subclass.rs:50` |
| macOS | the first `accessibilityChildren` message send, at `AK/macos/src/subclass.rs:92` |
| iOS | `didMoveToWindow`, at `AK/ios/src/subclass.rs:116`, or `view_did_appear` at `:247` |
| Android | the first `createAccessibilityNodeInfo` native call, at `AK/android/src/inject.rs:149` |

The `request_initial_tree` call sites are `AK/windows/src/adapter.rs:554`,
`AK/macos/src/adapter.rs:184`, `AK/ios/src/adapter.rs:148` and
`AK/android/src/adapter.rs:218`.

### 4.3 How an adapter raises an `ActionRequest`

The direction reverses. A user action on the platform becomes an
`ActionRequest` handed to `ActionHandler`, and the application answers it. Every
adapter resolves a platform handle to a `FullNodeId` first, because the platform
identifies a node by an address, a provider pointer or a virtual id, and the
tree identifies it by an integer pair.

| Adapter | Platform identifier | Resolved at |
|---|---|---|
| Windows | an `IRawElementProviderSimple` pointer, cast back to the object | `AK/windows/src/node.rs:934` |
| macOS | an `NSObject` pointer, downcast to the node's ivar | `AK/macos/src/context.rs:86` |
| iOS | a `Retained<UIAccessibilityElement>` | `AK/ios/src/context.rs:92` |
| Android | a `jint` virtual view id, looked up in the two-way map | `AK/android/src/adapter.rs:805` |

`AK/android/src/util.rs:134-158` is the only map in the four, and it exists only
because Android has no object identity. It is a `NodeIdMap` with a
`HashMap<jint, FullNodeId>` in one direction and a `HashMap<FullNodeId, jint>` in
the other, a counter that only grows, and the sentinel `HOST_VIEW_ID` equal to
`-1` for the root.

Android is also the only one of the four with an action **argument** channel.
`PlatformAction` at `AK/android/src/action.rs:33` has five variants, and three
carry a `Bundle`:

| Variant | Payload |
|---|---|
| `Simple` | one `jint` action id |
| `SetTextSelection` | two `jint` endpoints |
| `CollapseTextSelection` | none |
| `TraverseText` | a granularity, a direction and an extend flag |
| `SetProgress` | one `jfloat` |

The other three adapters raise an `ActionRequest` with at most one scalar, so a
Zig port needs one bundle-reading helper for Android and none for the others.

### 4.4 How an adapter reports a node removed

All four answer `node_removed` and all four do the same two things: drop the
adapter's own per-node state, then emit one platform event. The difference is
what "drop the state" means and whether the node still exists on the platform.

| Adapter | Drops its own state | Emits |
|---|---|---|
| Windows | `Context::remove_platform_node`, at `AK/windows/src/adapter.rs:349` | `UIA_Window_WindowClosedEventId` for a dialog, then a selection change, at `:352-366`. The provider is constructed on demand for a node that no longer exists |
| macOS | nothing: the node object is dropped from `Context::platform_nodes` by `NodeDestroyed` at `AK/macos/src/event.rs:55-64` | `UIElementDestroyedNotification`. **The node must leave the map before the notification is posted**, or the system caches it |
| iOS | `remove_node`, defined at `AK/ios/src/event.rs:176` and called at `:268` | one `LayoutChangedNotification` at the end of the batch, with the focused node as its argument |
| Android | nothing | `EVENT_WINDOW_CONTENT_CHANGED` with `CONTENT_CHANGE_TYPE_SUBTREE`, at `AK/android/src/adapter.rs:196` |

Android's event is the coarsest of the four. It names no node, and its comment
at `AK/android/src/adapter.rs:197` says `// TODO: other events?`. A Zig port
inherits the behaviour and does not invent the missing events.

### 4.5 How an adapter reports a focus change

All four ignore the old endpoint and act only on the new one. This is uniform,
not accidental: a focus loss needs no event, because the focus did not move to
anything.

| Adapter | Site | Behaviour |
|---|---|---|
| Windows | `AK/windows/src/adapter.rs:341-345` | `UIA_AutomationFocusChangedEventId`, unconditionally |
| macOS | `AK/macos/src/event.rs:319-327` | `FocusedUIElementChangedNotification`, and only if `filter(new_node) == Include` |
| iOS | `AK/ios/src/event.rs:255-263` | sets a flag, and `into_result` at `:198-204` emits at most one `LayoutChangedNotification` for the whole update |
| Android | `AK/android/src/adapter.rs:189-193` | `EVENT_VIEW_ACCESSIBILITY_FOCUSED` or `EVENT_VIEW_ACCESSIBILITY_FOCUS_CLEARED` through `enqueue_focus_event_if_applicable` |

iOS is the only one that batches. One flag, one event, one focused node per
update, at `:170-174` and `:198-204`.

### 4.6 What the shared shape does not include

Two things are **not** shared, and a port that assumes they are will be wrong.

- **No `io`.** None of the four adapters performs streaming I/O, and none takes
  `io`. Android's thread handoff at `AK/android/src/inject.rs:412-430` takes a
  `std.Thread` or a zio handle as a parameter, never a global.
- **No run loop.** A search of all of `AK/` for `CFRunLoop`, `RunLoop` and
  `run_loop` returns nothing in the macOS adapter. AppKit owns the main run
  loop and a provider never waits. The single notification observer in the
  whole tree is the iOS one at `AK/ios/src/adapter.rs:373`.

`src/adapters/<platform>/` holds one directory per platform in the fixed order
`atspi`, `windows`, `macos`, `ios`, `android`, per `docs/30` section 3.3, and
`zio` appears only under `src/adapters/`.

---

## 5. The per-adapter shape

Section 4 is what all four share. This section is what only one has. Each entry
gives the upstream line count and what the port inherits by translating it, so
an implementer knows which files are a transcription and which are a rewrite.

### 5.1 macOS: `patch.rs`, 93 lines, no counterpart anywhere

`AK/macos/src/patch.rs` is 93 lines and exports one function:

```text
add_focus_forwarder_to_window_class(class_name)   AK/macos/src/patch.rs:39-48
```

It adds one method, `accessibilityFocusedUIElement`, to a class the application
created and the adapter did not. The method it adds is `focus_forwarder` at
`:17-23`, and the whole body is:

```text
- (id)accessibilityFocusedUIElement { return [self.contentView accessibilityFocusedUIElement]; }
```

**Why it exists.** Some windowing libraries, SDL named at `:28-29`, put keyboard
focus on the window object rather than on its content view. VoiceOver asks the
window for `accessibilityFocusedUIElement`, and on such a class the inherited
implementation returns the wrong object or nothing.
`SubclassingAdapter` cannot fix this, because it subclasses the **view**
(`AK/macos/src/subclass.rs:176-203`) and never touches the window's class.

**Why it is `unsafe`.** The doc comment at `:31-38` gives two obligations. The
method cannot be removed, because the Objective-C runtime has no API for
removing one and the class keeps routing calls through the patched table, so
the code must never be unloaded. And the named class must be an `NSWindow`
subclass, which the code does not check.

**What the port inherits, and what it deletes.** Lines `:50-91` are a local copy
of `objc2`'s `add_method`, and the file says so at `:50-51`. Three details in
that copy are load-bearing:

| Detail | Purpose | Line |
|---|---|---|
| compare the selector's colon count with the function's parameter count | reject a signature that does not match the selector | `:58-67`, `:81-83` |
| build the Objective-C type-encoding string | `class_addMethod` needs it to build the dispatch table entry | `:69`, `:85-93` |
| assert `class_addMethod` returned true | fail loudly rather than leave a half-patched class | `:78` |

**The port deletes all three.** zig-objc computes the encoding at comptime from
the Zig function type (`src/encoding.zig:18`, used at `src/class.zig:80`) and
`Class::addMethod` takes the implementation directly
(`src/class.zig:72-87`). So the 93 upstream lines become about 15: one forwarding
function, one `getClass`, one `addMethod`, one assertion.

The one behaviour a port must keep is the **unload safety**, because it is a
contract with the caller rather than an implementation detail. A Zig port states
it as a documented obligation on the module that calls
`addFocusForwarderToWindowClass`.

| Adapter | Nearest thing | Why it is not the same mechanism |
|---|---|---|
| Windows | `subclass.rs`, 204 lines | the entry point is a window message, not a class patch. `SetWindowLongPtrW` at `:111` replaces one slot |
| iOS | `subclass.rs:116-135` | iOS solves the same focus problem by subclassing the **view** and forwarding `didMoveToWindow` |
| Android | `inject.rs`, 471 lines | that installs an `AccessibilityDelegate` **object** on a view. It does not patch a class |

`patch.rs` is the only file in the four adapters whose whole purpose is to
change a class the adapter did not create.

### 5.2 iOS: view-hierarchy traversal, 324 + 130 lines

AppKit pushes children. UIKit **pulls** them, so a view must implement
`UIAccessibilityContainer` by returning an `accessibilityElements` array and
answering `accessibilityHitTest:`. Two upstream files exist only to serve that
requirement.

#### 5.2.1 The two entry points

| File | Lines | Serves |
|---|---:|---|
| `AK/ios/src/subclass.rs` | 324 | the dynamic `UIView` subclass and the five selectors it installs |
| `AK/ios/src/filters.rs` | 130 | the iOS-only element filter, with three unit tests |

`SubclassingAdapter` installs five selectors on a copy of the view's class, at
`AK/ios/src/subclass.rs:214`, `:218`, `:222`, `:226` and `:230`:

| Selector | Handler | Why iOS needs it |
|---|---|---|
| `superclass` | `:80-83` | some view classes call `[self superclass]` and assume they are the lowest subclass |
| `isAccessibilityElement` | `:87-92` | UIKit asks the container, not the node |
| `accessibilityElements` | `:94-99` | the pull instead of the push |
| `accessibilityHitTest:` | `:103-112` | the pull, for a point |
| `didMoveToWindow` | `:116-135` | **iOS-only lifecycle.** It forwards to the previous implementation first, then activates the adapter if the view now has a window |

`didMoveToWindow` has no desktop counterpart, and it forces one extra piece of
work. UIKit does not replay `didMoveToWindow` for a view that was already in a
window when the adapter was created, so
`SubclassingAdapter::new` calls `view_did_appear` manually at
`AK/ios/src/subclass.rs:247-253`.

The low-level `Adapter` needs none of this. Its doc comment at
`AK/ios/src/adapter.rs:293-318` lists three methods the host application
forwards itself: `is_accessibility_element` at `:452-455`,
`accessibility_elements` at `:459-480` and `hit_test` at `:486-503`.

`is_accessibility_element` returns `false` unconditionally at `:452-455`, and
that is deliberate. The adapter exposes itself as a pure container, and the
per-node answer comes from `PlatformNode::is_element` at
`AK/ios/src/node.rs:232-236`.

#### 5.2.2 The element filter, and the test vectors it brings

`filter_for_is_accessibility_element` at `AK/ios/src/filters.rs:27-52` exists
only on iOS. Its doc comment at `:12-26` gives the rule: on iOS a node with
focusable children must **not** be an accessibility element, or VoiceOver
ignores the children entirely. A node with actions, a value or a toggled state
is always a leaf, because its descendants are collapsed into its label through
`Node::labelled_by`. Otherwise the node stays a container.

This is pure logic over a `Tree`, it needs no UIKit symbol, and it **runs on any
host**. Upstream ships three unit tests for it at `:88`, `:99` and `:111`, so a
Zig port inherits a ready-made test vector rather than having to invent one. That
makes it the cheapest testable behaviour in the four adapters.

#### 5.2.3 The nine-notification observer

iOS is the only adapter of the four that observes anything. `try_activate` at
`AK/ios/src/adapter.rs:190-206` returns early unless an assistive technology is
running, tested by the three predicates at `:97-103`. The adapter then watches
the nine `StatusDidChange` notifications listed in section 1.3.1, added at `:373`
and removed in its drop at `:511`.

This is the only `addObserver` call in the whole upstream tree. A port must
register and unregister it symmetrically, or the observer outlives the adapter.

### 5.3 Android: the JNI boundary, 471 + 70 lines, in another language

Android's boundary is Java. Two upstream files exist only to cross it, and one
of them is not Rust at all.

#### 5.3.1 The JNI wrapper layer

`AK/android/src/inject.rs` is 471 lines and does four jobs that no other adapter
has.

| Job | Lines | What the port writes |
|---|---:|---|
| the five registered native methods | `:137-218` | five `extern fn` with JNI calling convention |
| the class loader | `:222-296` | as below |
| the handle maps | `:88-105` | a change, see below |
| the thread handoff | `:412-430` | `JavaVM.attachCurrentThread` plus a `View.post` |

The five natives, registered at `:257-291`, are `runCallback`,
`createAccessibilityNodeInfo`, `findFocus`, `performAction` and
`onHoverEvent`. Their JNI signatures are exact, so a Zig port cannot invent
them:

| Method | JNI signature |
|---|---|
| `runCallback` | `(Landroid/view/View;J)V` |
| `createAccessibilityNodeInfo` | `(JLandroid/view/View;I)Landroid/view/accessibility/AccessibilityNodeInfo;` |
| `findFocus` | `(JLandroid/view/View;I)Landroid/view/accessibility/AccessibilityNodeInfo;` |
| `performAction` | `(JLandroid/view/View;IILandroid/os/Bundle;)Z` |
| `onHoverEvent` | `(JLandroid/view/View;IFF)Z` |

The class loader has two modes, chosen by a Cargo feature at
`AK/android/Cargo.toml:16`.

| Mode | Mechanism | Line |
|---|---|---|
| default | `find_class("dev/accesskit/android/Delegate")`, so the application must ship the class | `:256` |
| `embedded-dex` | `include_bytes!("../classes.dex")` into an `InMemoryDexClassLoader` | `:225-254` |

The 70 lines of Java at
`AK/android/java/dev/accesskit/android/Delegate.java` are a **build input the
port must ship**, not a reference to read. A Zig build cannot produce them
without a Java toolchain in the loop, so the repository carries the Java file
and, for the `embedded-dex` mode, a prebuilt `classes.dex`. Neither is a Zig
build product, and both need a licence and placement decision that
`docs/40-plan.md` M10 owns.

#### 5.3.2 The handle maps are the one place the port must not translate

`inject.rs` declares four file-scope statics: `NEXT_HANDLE` at `:88`,
`HANDLE_MAP` at `:89-90`,
`NEXT_CALLBACK_HANDLE` at `:101` and `CALLBACK_MAP` at `:103-105`. This is
exactly the shape `docs/30` Record R3 forbids, and `docs/40-plan.md` M10 does
not yet carry the fix.

`post_to_ui_thread` at `:109-133` inserts a boxed closure into `CALLBACK_MAP`
under a counter, asks Java for a `Runnable` bound to that counter, and posts it
to the host view. The closure runs later on the UI thread and looks itself up.

**A Zig port threads this state instead.** The counter, the map and the closure
become fields of the adapter struct, the parameter that reaches
`attachAndPostToUiThread` already carries the work, and the four statics
disappear. The two `BTreeMap` declarations at `:90` and `:104` are chosen for
deterministic iteration, which a port keeps. The ordering matters for the same
reason the Windows `HashMap` at `AK/windows/src/adapter.rs:39` must become an
insertion-ordered list.

`LOCAL_FRAME_CAPACITY` at `:98` is the one constant a port copies verbatim. It is
the capacity of the JNI local frame for exactly two local references, the
upgraded host view and the runnable, and JNI caps local references per frame.

#### 5.3.3 Nodes are pushed, not pulled

Android has no accessor the platform calls. Instead the adapter fills an
`AccessibilityNodeInfo` and hands it back. That is the `createAccessibilityNodeInfo`
native, reached at `AK/android/src/adapter.rs:322-355`, with the property fill
at `AK/android/src/node.rs:196-445`. Section 1.4.2 lists the 68 method names,
and 21 of them are setters on that one object.

### 5.4 Windows: the COM object base, about 120 new lines

Windows is the only adapter of the four with **new code that has no upstream
counterpart at all**, and section 2.1.4 gives the seven items. The other three
adapters' new code is three `extern` declarations on macOS and iOS, a table of
39 constants on iOS, and a JNI wrapper on Android. Windows is the only one that
needs an object model built from scratch.

It is also the only adapter whose extra code is **not** hand-written bindings.
It is Zig infrastructure, and it is testable on this host, because a COM object
base has no Windows dependency once the vtable types come from zigwin32.

---

## 6. The order, and the reason

### 6.1 The order `docs/30` fixes

`docs/30-port-design.md` section 3.3 fixes the directory order as `atspi`,
`windows`, `macos`, `ios`, `android`, and gives the reason for the first two: AT-SPI
first because it is the only adapter whose protocol runs on this host against a
live accessibility bus, and Windows second because `build-exe` links its real
system libraries here. `docs/40-plan.md` schedules them as M6 to M10.

This document does not reopen that order. It prices the four.

### 6.2 What each costs, given the three verification levels

| Adapter | Lines to translate | L1 | L2 | L3 here | New code with no upstream counterpart |
|---|---|---|---|---|---|
| Windows | 3764 + 712 tests | pass | **pass** | no | about 120 lines of COM object base |
| macOS | 2605 | pass | fail | no | 3 `extern` declarations, 54 node selectors, 43 selector literals |
| iOS | 2560 | pass | fail | no | 39 named UIKit symbols, 10 enum types, 19 node selectors |
| Android | 2604 + 70 Java | pass | fail | no | a JNI wrapper, plus a shipped Java class and possibly a shipped `.dex` |

Three facts from that table drive the order.

1. **Windows is the only adapter with an L2 row.** It is the only one where a
   wrong import name or a wrong library name fails at build time on this host.
2. **Windows is the only adapter whose extra code is testable here.** A COM
   object base built on zigwin32's vtable types has no Windows dependency, so
   fail-N allocator tests and comptime vtable sweeps run natively. The macOS and
   iOS extra code is a table of constants the compiler cannot check, and the
   Android extra code needs a JVM.
3. **iOS has the least to bind and the most to hand-write**, and it cannot even
   reach L2. It fails at `libSystem`, so the whole milestone is "compiles".

### 6.3 Which is worth doing first if the goal is a working library

**Windows first optimises for verifiability. That is not the same as optimising
for a working library, and the difference is real.**

The case for Windows first:

- It is the only adapter with an L2 row, so its bindings are checked.
- Its decision logic is portable and testable. `NodeWrapper::control_type` at
  `AK/windows/src/node.rs:58-260` maps 33 outcomes, the 23 simple property
  getters at `:1306-1330` read a fake tree, the text unit movement at
  `AK/windows/src/text.rs:81-207` runs against a synthetic text tree, and the
  selection batching with its limit of 20 at `AK/windows/src/adapter.rs:125-229`
  is pure. None of that needs a window.
- It is the largest, and writing it first means the smaller three reuse the
  pattern instead of each inventing one.

The case against:

- **AccessKit's largest real user base is on macOS.** Porting Windows first means
  the adapter most people want lands last among the desktop platforms.
- macOS cannot be linked here at all. A macOS port would ship with a gate that
  has checked only its pure helpers, so shipping the less verifiable platform
  first would be worse, not better.
- Windows is the biggest of the four and the only one needing new
  infrastructure, so it is the milestone most likely to overrun.

**The trade-off, named rather than resolved.** The order in `docs/30` buys the
largest verified surface first and puts the largest user-facing adapter last.
The alternative order, macOS first, buys the most user value first and ships
with the weakest gate.

Two facts make the question partly moot, and both favour the order as fixed.
First, no adapter reaches L3 on this host, so "working library" is not available
from any of the four until someone runs the milestone on the target operating
system. Second, AT-SPI already lands first and is the one adapter that runs
here, so the library is not empty while the four native adapters are written.

**If the goal changes to "ship something usable soonest", the order changes to
AT-SPI on Linux first, and it already is.** That is the only adapter whose
protocol runs on this host against a live bus. None of the four native adapters
can be finished here, so this document prices the four and does not reorder
them.
