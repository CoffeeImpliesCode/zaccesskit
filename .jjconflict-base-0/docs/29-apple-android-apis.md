# 29 — iOS and Android platform APIs

> Consumed by `docs/30-port-design.md`, which turns the symbol tables below into bindings
> and decides what the port may claim from this machine.

Scope: AccessKit at commit `466e24e252103f4d82bd6fbab98141b551e46e0c`, core 0.25.1. Sources
`adapters/ios/`, `adapters/ios/Cargo.toml`, `adapters/android/` and
`adapters/android/Cargo.toml`. Every row carries a `path:line`. Anything not read off those
files is marked `[INFERENCE]`.

---

## 1. Ownership: what this document owns and what `docs/16` owns

`docs/16-native-platform-apis.md` is 2045 lines and owns the Windows and macOS material.
This document does not repeat it. It owns the two Apple-adjacent gaps: iOS as an
enumeration rather than a section, and the Android JNI boundary in full.

| Subject | Owner |
|---|---|
| Windows symbol table, event model, subclassing, text | `docs/16-native-platform-apis.md:52-701` |
| macOS symbol table (groups M1 to M6), run loop, delegate, `patch.rs` | `docs/16-native-platform-apis.md:703-1168` |
| iOS and Android, one section each | `docs/16-native-platform-apis.md:1169-1424` |
| Zig binding reality for all four platforms | `docs/16-native-platform-apis.md:1425-1807` |
| **This document** | iOS and the JNI boundary, symbol by symbol (sections 2 and 3); the Zig side (4); attribution (5); what this host proves (6) |

Two findings from `docs/16` carry the rest of this document, so they are named once here.

1. `zig translate-c` cannot parse an Objective-C header, proven with a three-declaration
   `NSView` header on Zig 0.16.0 (`docs/16-native-platform-apis.md:1580-1647`). The same
   command parses a resolved COM C header and `jni.h` cleanly (`:1729-1743`, `:1785-1786`),
   so Android binds and the Apple side does not.
2. `mitchellh/zig-objc` covers class pairs, `addMethod`, selectors and message sends
   (`:1648-1683`) but not `objc_getAssociatedObject`, `objc_setAssociatedObject` or
   `object_setClass`, which are the three functions both Apple adapters need
   (`ios/src/subclass.rs:71`, `:199`, `:242`).

---

## 2. iOS: what the adapter calls

### 2.1 Symbol table and group totals

A symbol is a named entry point the adapter implements for UIKit to call or calls into the
platform. Rows are marked `impl` or `call`, and the signature column is the Rust binding
signature as written at the cited line. The framework header paths are `[INFERENCE]`: this
host has no iOS SDK, so no header was opened. The feature list is source-confirmed at
`adapters/ios/Cargo.toml:22-43`.

| Group | Rows | Source |
|---|---|---|
| I1 Native functions the adapter calls | 2 | `event.rs`, `util.rs` |
| I2 Notification names observed | 9 | `adapter.rs` |
| I3 Assistive-technology queries | 3 | `adapter.rs` |
| I4 Notifications posted | 4 | `event.rs` |
| I5 Runtime symbol resolution | 6 | `util.rs` |
| I6 Selectors implemented on the element | 19 | `node.rs` |
| I7 Selectors installed on the host view | 5 | `subclass.rs` |
| I8 Objective-C runtime functions | 3 | `subclass.rs` |
| I9 Methods called on Foundation and UIKit objects | 12 | `adapter.rs`, `node.rs`, `subclass.rs`, `util.rs` |
| **Total** | **63** | |


| # | Symbol, groups I1 to I5 | Dir | Signature as used | Used for | Evidence |
|---|---|---|---|---|---|
| 1 | `UIAccessibilityPostNotification` | call | `UIAccessibilityPostNotification(notification, argument)` | post one notification with an optional argument | `event.rs:57`, `:91`, `:99` |
| 2 | `UIAccessibilityConvertFrameToScreenCoordinates` | call | `unsafe fn(CGRect, &UIView) -> CGRect` | screen-space frame conversion | `util.rs:46-48` |
| 3 | `UIAccessibilityVoiceOverStatusDidChangeNotification` | data | `&'static NSNotificationName` | activation trigger | `adapter.rs:108` |
| 4 | `UIAccessibilitySwitchControlStatusDidChangeNotification` | data | same | activation trigger | `adapter.rs:109` |
| 5 | `UIAccessibilitySpeakScreenStatusDidChangeNotification` | data | same | activation trigger | `adapter.rs:110` |
| 6 | `UIAccessibilityInvertColorsStatusDidChangeNotification` | data | same | activation trigger | `adapter.rs:111` |
| 7 | `UIAccessibilityReduceMotionStatusDidChangeNotification` | data | same | activation trigger | `adapter.rs:112` |
| 8 | `UIAccessibilityBoldTextStatusDidChangeNotification` | data | same | activation trigger | `adapter.rs:113` |
| 9 | `UIAccessibilityDarkerSystemColorsStatusDidChangeNotification` | data | same | activation trigger | `adapter.rs:114` |
| 10 | `UIAccessibilityOnOffSwitchLabelsDidChangeNotification` | data | same | activation trigger, spelled this way upstream | `adapter.rs:115` |
| 11 | `UIAccessibilityVideoAutoplayStatusDidChangeNotification` | data | same | activation trigger | `adapter.rs:116` |
| 12 | `UIAccessibilityIsVoiceOverRunning` | call | `unsafe fn() -> Bool` | is assistive technology running | `adapter.rs:99` |
| 13 | `UIAccessibilityIsSwitchControlRunning` | call | same | same test, second term | `adapter.rs:100` |
| 14 | `UIAccessibilityIsSpeakScreenEnabled` | call | same | same test, third term | `adapter.rs:101` |
| 15 | `UIAccessibilityLayoutChangedNotification` | data | `UIAccessibilityNotifications` enum value | coalesced per-update layout event | `event.rs:135` |
| 16 | `UIAccessibilityScreenChangedNotification` | data | same | first full tree | `event.rs:142` |
| 17 | `UIAccessibilityAnnouncementNotification` | data | same | live-region announcement | `event.rs:92`, `:99` |
| 18 | `UIAccessibilitySpeechAttributeQueueAnnouncement` | data | `NSAttributedStringKey` | queue the announcement behind the current speech | `event.rs:85` |
| 19 | `dlsym` | call | `extern "C" fn(*mut c_void, *const c_char) -> *mut c_void` | resolve weak-linked constants | `util.rs:73-75` |
| 20 | `RTLD_DEFAULT` | data | `-2isize as *mut c_void` | search the global namespace | `util.rs:71` |
| 21 | `"UIAccessibilityTraitToggleButton"` | call | `dlsym(RTLD_DEFAULT, ...)` cast to `UIAccessibilityTraits` | toggle trait, absent before iOS 17 | `util.rs:77-87` |
| 22 | `"UIAccessibilityPriorityHigh"` | call | `dlsym` to `*const NSString` | assertive announcement priority | `util.rs:100-102` |
| 23 | `"UIAccessibilityPriorityLow"` | call | same | polite announcement priority | `util.rs:104-106` |
| 24 | `"UIAccessibilitySpeechAttributeAnnouncementPriority"` | call | same to `*const NSAttributedStringKey` | the key that carries the priority | `util.rs:108-110` |

**I6: the 19 selectors implemented on `PlatformNode`, a `UIAccessibilityElement` subclass.**

| # | Selector | Signature as used | Used for | Evidence |
|---|---|---|---|---|
| 25 | `accessibilityContainer` | `fn container(&self) -> Option<Retained<AnyObject>>` | the AccessKit parent, else the host view | `node.rs:219-222`, body `:497-515` |
| 26 | `setAccessibilityContainer:` | `fn set_container(&self, _container: Option<&AnyObject>)` | explicit no-op so UIKit cannot cache the init value | `node.rs:229-230`, reason `:224-228` |
| 27 | `isAccessibilityElement` | `fn is_element(&self) -> bool` | the structural filter decides | `node.rs:232-233` |
| 28 | `accessibilityLabel` | `fn label(&self) -> Option<Retained<NSString>>` | label | `node.rs:238-239` |
| 29 | `accessibilityHint` | `fn hint(&self) -> Option<Retained<NSString>>` | hint | `node.rs:247-248` |
| 30 | `accessibilityValue` | `fn value(&self) -> Option<Retained<NSString>>` | toggled, value or numeric value, rendered as a string | `node.rs:256-257` |
| 31 | `accessibilityTraits` | `fn traits(&self) -> UIAccessibilityTraits` | the trait bitmask | `node.rs:267-268`, mapping `:124-165` |
| 32 | `accessibilityFrame` | `fn frame(&self) -> CGRect` | one of three frame sources | `node.rs:273-274`, sources `:92-100` |
| 33 | `accessibilityLanguage` | `fn language(&self) -> Option<Retained<NSString>>` | text language | `node.rs:287-288` |
| 34 | `accessibilityExpandedStatus` | `fn expanded_status(&self) -> UIAccessibilityExpandedStatus` | expanded, collapsed or unsupported | `node.rs:293-294`, enum `util.rs:20-27` |
| 35 | `accessibilityActivate` | `fn activate(&self) -> bool` | push a `Click` action | `node.rs:303-304` |
| 36 | `accessibilityIncrement` | `fn increment(&self)` | push an `Increment` action, returns void | `node.rs:323-324` |
| 37 | `accessibilityDecrement` | `fn decrement(&self)` | push a `Decrement` action, returns void | `node.rs:341-342` |
| 38 | `accessibilityScroll:` | `fn scroll(&self, direction: UIAccessibilityScrollDirection) -> Bool` | scroll action, vertical directions inverted | `node.rs:359-391`, comment `:361-364` |
| 39 | `accessibilityElements` | `fn elements(&self) -> Option<Retained<NSArray<NSObject>>>` | filtered children, empty for a leaf element | `node.rs:393-394` |
| 40 | `accessibilityContainerType` | `fn container_type(&self) -> UIAccessibilityContainerType` | list, data table, landmark or semantic group | `node.rs:411-412`, mapping `:167-188` |
| 41 | `accessibilityElementDidBecomeFocused` | `fn element_did_become_focused(&self)` | record the focused element | `node.rs:420-421` |
| 42 | `accessibilityElementDidLoseFocus` | `fn element_did_lose_focus(&self)` | clear the focused element | `node.rs:427-428` |
| 43 | `accessibilityIdentifier` | `fn identifier(&self) -> Option<Retained<NSString>>` | HTML id, else author id | `node.rs:437-438` |


| # | Symbol, groups I7 to I9 | Dir | Signature as used | Used for | Evidence |
|---|---|---|---|---|---|
| 44 | `superclass` | impl | `fn superclass(this: &UIView, _cmd: Sel) -> Option<&AnyClass>` | satisfy view classes that call `[self superclass]` | `subclass.rs:80-83`, selector `:213-216` |
| 45 | `isAccessibilityElement` | impl | `fn is_accessibility_element(this: &UIView, _cmd: Sel) -> Bool` | forward to the adapter | `subclass.rs:87-92`, selector `:217-220` |
| 46 | `accessibilityElements` | impl | `fn accessibility_elements(this: &UIView, _cmd: Sel) -> *mut NSArray<NSObject>` | forward to the adapter | `subclass.rs:94-99`, selector `:221-224` |
| 47 | `accessibilityHitTest:` | impl | `fn accessibility_hit_test(this: &UIView, _cmd: Sel, point: CGPoint) -> *mut AnyObject` | forward to the adapter | `subclass.rs:103-112`, selector `:225-228` |
| 48 | `didMoveToWindow` | impl | `fn did_move_to_window(this: &UIView, _cmd: Sel)` | chain to super, then activate | `subclass.rs:116-135`, selector `:229-232` |
| 49 | `objc_getAssociatedObject` | call | `unsafe fn(id, *const c_void) -> *mut AnyObject` | read the per-view adapter state | `subclass.rs:71`, `:179` |
| 50 | `objc_setAssociatedObject` | call | `unsafe fn(id, *const c_void, *mut AnyObject, u64)` | store it, and clear it in `Drop` | `subclass.rs:199-205`, `:316-321` |
| 51 | `object_setClass` | call | `unsafe fn(*mut AnyObject, *const AnyClass)` | swap in the dynamic subclass, and revert in `Drop` | `subclass.rs:242`, `:314` |
| 52 | `-[NSNotificationCenter defaultCenter]` | call | `unsafe fn() -> &'static NSNotificationCenter` | the centre for registration and removal | `adapter.rs:370`, `:508` |
| 53 | `-[NSNotificationCenter addObserver:selector:name:object:]` | call | `addObserver_selector_name_object(observer, sel, Some(name), None)` | register the nine names | `adapter.rs:373-378` |
| 54 | `-[NSNotificationCenter removeObserver:]` | call | `removeObserver(observer)` | deregister in `Drop` | `adapter.rs:510-512` |
| 55 | `-[UIView window]` | call | `fn window(&self) -> Option<Retained<UIWindow>>` | walk to the window for coordinates | `subclass.rs:125`, `:249`, `util.rs:38`, `adapter.rs:488` |
| 56 | `-[UIScreen coordinateSpace]` | call | `fn coordinateSpace(&self) -> UICoordinateSpace` | the screen space for hit tests | `util.rs:39` |
| 57 | `-[UIView convertPoint:fromCoordinateSpace:]` | call | `convertPoint_fromCoordinateSpace(point, &screen_space)` | screen point to view point | `util.rs:40` |
| 58 | `-[UIView contentScaleFactor]` | call | `fn contentScaleFactor(&self) -> CGFloat` | physical pixels against logical points | `util.rs:41`, `:51` |
| 59 | `-[UIView bounds]` | call | `fn bounds(&self) -> CGRect` | frame source for a root with no bounding box | `node.rs:279` |
| 60 | `-[UIWindow rootViewController]` | call | `fn rootViewController(&self) -> Option<Retained<UIViewController>>` | `for_window` entry point | `subclass.rs:277-279` |
| 61 | `-[UIViewController view]` | call | `fn view(&self) -> Option<Retained<UIView>>` | the view that gets subclassed | `subclass.rs:280-282` |
| 62 | `-[UIAccessibilityElement initWithAccessibilityContainer:]` | call | `msg_send_id![super(this), initWithAccessibilityContainer: &*container]` | the only initializer that does not raise | `node.rs:459-473` |
| 63 | `-[UIView didMoveToWindow]` on super | call | `msg_send![super(this, prev_class), didMoveToWindow]` | chain the lifecycle method | `subclass.rs:122` |

Traits and container types are data rather than entry points, so they sit outside the 63:
12 trait values, 5 container types, 3 expanded-status values and 4 scroll directions.

### 2.2 What iOS does that macOS does not

| Subject | macOS | iOS | Evidence |
|---|---|---|---|
| View subclass methods | 4 | 5, the fifth being `didMoveToWindow` | `macos/src/subclass.rs:177-193`, `ios/src/subclass.rs:212-233`, `:116-135` |
| State layout | `RefCell` around `Adapter` plus `ActivationHandler` | `Adapter` stored directly | `macos/src/subclass.rs:35-43`, `ios/src/subclass.rs:35-38` |
| Window entry point | `window.contentView()` | `window.rootViewController().view()` | `macos/src/subclass.rs:228-230`, `ios/src/subclass.rs:276-282` |
| Activation trigger | first message from the OS | first message, or `viewDidAppear` while assistive technology runs | `macos/src/adapter.rs:174-221`, `ios/src/adapter.rs:190-206`, `:444-446` |
| Deactivation | none | `DeactivationHandler` resets to `Inactive` | `ios/src/adapter.rs:208-237` |
| Element filter | per-selector gate `isAccessibilitySelectorAllowed:` | one structural filter, unit tested | `macos/src/node.rs:1234-1329`, `ios/src/filters.rs:27-52`, tests `:54-129` |
| Role mapping | role and subrole string tables | traits bitmask and container type | `macos/src/node.rs:36-296`, `ios/src/node.rs:124-188` |
| Weak-linked constants | none | four, through `dlsym` | `ios/src/util.rs:71-110` |

### 2.3 View hierarchy traversal: there is none

`grep -rn 'subview\|superview\|recursiveDescription'` over `adapters/ios/src` returns no
output: the iOS adapter never walks a `UIView` hierarchy. The traversal is over the AccessKit
tree, anchored on one view. `accessibility_elements` (`adapter.rs:459-480`) returns the root
node when the filter includes it and the root's filtered children otherwise, and each
element's `accessibilityElements` (`node.rs:393-409`) does the same one level down. Walking
up, `accessibilityContainer` (`node.rs:219-222`, body `:497-515`) follows the AccessKit parent
and falls back to the host `UIView`. The init-time container is always the host view, whatever
the node's real parent, because `initWithAccessibilityContainer:` is the designated
initializer and plain `init` raises (`node.rs:459-473`, comment `:460-465`).

macOS differs on all three points: three calls to `accessibilityParent:` on the host view
answer parent, window and top-level element (`macos/src/node.rs:421`, `:433`, `:444`), points
convert through the window with `convertPointFromScreen` (`macos/src/util.rs:39-41`), and a
node with no bounding box falls back to the view's own `accessibilityFrame` (`:487-494`).

---

## 3. Android: the JNI boundary

### 3.1 The two halves

The adapter is split in two. Rust is 2604 lines across eight files; Java is one class,
`adapters/android/java/dev/accesskit/android/Delegate.java`, 70 lines, whose class extends
`View.AccessibilityDelegate` and implements `View.OnHoverListener` (`Delegate.java:14-15`),
holds one `long adapterHandle` (`:15`) and declares five `native` methods (`:22-34`). Rust
registers them once through `JNIEnv::register_native_methods` (`inject.rs:257-291`).

### 3.2 Symbol table and group totals

A symbol here is a JNI entry point, a Java member reached through one, a registered native
method, or a Rust-side table that carries state across the boundary.

| Group | Rows | Source |
|---|---|---|
| A1 JNI types and reference handles | 8 | `inject.rs`, `adapter.rs`, `event.rs` |
| A2 `JNIEnv` and `JavaVM` methods | 15 | all files |
| A3 The five registered native methods | 5 | `inject.rs`, `Delegate.java` |
| A4 Java members reached by name and signature | 18 | `inject.rs`, `event.rs`, `node.rs`, `util.rs`, `adapter.rs` |
| A5 Rust-side tables and helpers | 10 | `inject.rs`, `util.rs`, `action.rs` |
| **Total** | **56** | |

**A1 and A2: the JNI entry points, 23 rows.**

| # | Symbol | Signature as used | Used for | Evidence |
|---|---|---|---|---|
| 1 | `JNIEnv<'local>` | `&mut JNIEnv<'local>` threaded through every entry point | the per-thread environment | `inject.rs:14`, `adapter.rs:322`, `node.rs:198`, `event.rs:16` |
| 2 | `JavaVM` | `vm.attach_current_thread()` | the process-wide VM | `inject.rs:14`, `:309`, `:384`, `:422` |
| 3 | `NativeMethod` | `name`, `sig`, `fn_ptr` triple | one registration | `inject.rs:14`, `:260-288` |
| 4 | `JObject<'local>` | local reference to a `java.lang.Object` | the host view, events, bundles | `inject.rs:16`, `adapter.rs:18`, `event.rs:12` |
| 5 | `JClass<'static>` | local or global class reference | every `find_class` result | `inject.rs:16`, `:222-295` |
| 6 | `GlobalRef` | `OnceLock<GlobalRef>` for the delegate class | outlives the frame that made it | `inject.rs:16`, `:223`, `:292`, `util.rs:241` |
| 7 | `WeakRef` | host view held weakly | the host may be collected | `inject.rs:16`, `:311`, `:386` |
| 8 | `jlong`, `jint`, `jfloat`, `jboolean`, `JNI_TRUE`, `JNI_FALSE` | `jni::sys` scalars | every numeric argument and result | `inject.rs:17`, `:186`, `:198` |
| 9 | `JNIEnv::call_method` | `call_method(obj, name, sig, &[args])` | 30 call sites across five files | `event.rs:35`, `:42`, `:63`, `:79`, `:111`, `:123`, `:129`, `:140`, `:147`, `:178`, `:185`, `:187`, `:189`, `:214`, `:226`, `:228`, `:230`, `:249`, `:251`, `:269`, `:272`, `:274`, `:277`, `:282`, `:284`, `:287`, `:414`; `node.rs:23`, `:204`, `:214`, `:222`, `:234`; `adapter.rs:358`, `:370`; `util.rs:54`, `:66` |
| 10 | `JNIEnv::call_static_method` | `call_static_method(class, name, sig, &[args])` | four static factories | `event.rs:25`, `util.rs:116`, `adapter.rs:347`, `inject.rs:118` |
| 11 | `JNIEnv::find_class` | `find_class("android/view/accessibility/AccessibilityEvent")` | resolve a class by JNI name | `event.rs:21`, `util.rs:114`, `node.rs:241`, `:419`, `adapter.rs:344`, `inject.rs:227`, `:256` |
| 12 | `JNIEnv::new_object` | `new_object(class, sig, &[args])` | `Rect`, `RangeInfo`, the dex loader, `Delegate` | `node.rs:243`, `inject.rs:237`, `:364` |
| 13 | `JNIEnv::new_string` | `new_string(&str)` | every `CharSequence` payload | `event.rs:110`, `:123`, `:177`; `util.rs:162`, `:175`, `:183`, `:196`, `:230`; `node.rs:312`, `:323`, `:348`, `:349`, `:359` |
| 14 | `JNIEnv::new_int_array` | `new_int_array(2)` | the two-element location buffer | `node.rs:233` |
| 15 | `JNIEnv::get_int_array_region` | `get_int_array_region(arr, 0, &mut [i32; 2])` | read that buffer back | `node.rs:237` |
| 16 | `JNIEnv::new_direct_byte_buffer` | `new_direct_byte_buffer(ptr, len)` | wrap the embedded `classes.dex` | `inject.rs:232` |
| 17 | `JNIEnv::new_weak_ref` | `new_weak_ref(host)` | the host handle | `inject.rs:386` |
| 18 | `JNIEnv::new_global_ref` | `new_global_ref(class)` | the cached delegate class | `inject.rs:292`, `util.rs:241` |
| 19 | `JNIEnv::register_native_methods` | `register_native_methods(&class, &[NativeMethod])` | bind the five natives once | `inject.rs:257-291` |
| 20 | `JNIEnv::with_local_frame` | `with_local_frame(LOCAL_FRAME_CAPACITY, f)` | bound the local references of one hop | `inject.rs:423`, capacity `:99` |
| 21 | `JNIEnv::get_java_vm` | `env.get_java_vm()` | keep the VM after `new` returns | `inject.rs:384` |
| 22 | `JNIEnv::is_instance_of` | `is_instance_of(&delegate, delegate_class)` | only uninstall our own delegate | `inject.rs:444` |
| 23 | `JavaVM::attach_current_thread` | `vm.attach_current_thread()` | let any caller thread reach Java | `inject.rs:422` |


| # | A3: Java declaration and JNI signature | Rust function | Passes across | Returns |
|---|---|---|---|---|
| 24 | `private static native void runCallback(View host, long handle)` `(Landroid/view/View;J)V` (`Delegate.java:22`, `inject.rs:262`) | `run_callback` (`inject.rs:137-147`) | the host view and a callback handle | `void` |
| 25 | `private static native AccessibilityNodeInfo createAccessibilityNodeInfo(long adapterHandle, View host, int virtualViewId)` `(JLandroid/view/View;I)Landroid/view/accessibility/AccessibilityNodeInfo;` (`Delegate.java:24-25`, `inject.rs:267-268`) | `create_accessibility_node_info` (`inject.rs:149-161`) | adapter handle, host view, virtual view id | a fresh `AccessibilityNodeInfo`, or null |
| 26 | `private static native AccessibilityNodeInfo findFocus(long adapterHandle, View host, int focusType)` `(JLandroid/view/View;I)Landroid/view/accessibility/AccessibilityNodeInfo;` (`Delegate.java:27-28`, `inject.rs:274-275`) | `find_focus` (`inject.rs:163-175`) | adapter handle, host view, focus type | a node, or null |
| 27 | `private static native boolean performAction(long adapterHandle, View host, int virtualViewId, int action, Bundle arguments)` `(JLandroid/view/View;IILandroid/os/Bundle;)Z` (`Delegate.java:30-31`, `inject.rs:280-281`) | `perform_action` (`inject.rs:177-199`) | handle, host, node id, action id, `Bundle` | `JNI_TRUE` on success, `JNI_FALSE` otherwise |
| 28 | `private static native boolean onHoverEvent(long adapterHandle, View host, int action, float x, float y)` `(JLandroid/view/View;IFF)Z` (`Delegate.java:33-34`, `inject.rs:285-286`) | `on_hover_event` (`inject.rs:201-220`) | handle, host, hover action, two coordinates | `JNI_TRUE` if focus moved |


| # | A4: Java member and JNI signature | Used for | Evidence |
|---|---|---|---|
| 29 | `View.getAccessibilityDelegate()` `()Landroid/view/View$AccessibilityDelegate;` | check whether a delegate is already installed | `inject.rs:352-357`, `:435-441` |
| 30 | `View.setAccessibilityDelegate(View$AccessibilityDelegate)` `(Landroid/view/View$AccessibilityDelegate;)V` | install and clear ours | `inject.rs:367-373`, `:448-454` |
| 31 | `View.setOnHoverListener(View$OnHoverListener)` `(Landroid/view/View$OnHoverListener;)V` | route hover into the adapter | `inject.rs:374-380`, `:455-461` |
| 32 | `View.post(Runnable)` `(Ljava/lang/Runnable;)Z` | the hop to the UI thread | `inject.rs:128-134` |
| 33 | `View.getParent()` `()Landroid/view/ViewParent;` | find the delivery target | `event.rs:53-57` |
| 34 | `View.getLocationOnScreen(int[])` `([I)V` | the host origin for node bounds | `node.rs:234` |
| 35 | `ViewParent.requestSendAccessibilityEvent(View, AccessibilityEvent)` | deliver an event; the parent may be null | `event.rs:63-69`, null check `:53-62` |
| 36 | `AccessibilityEvent.obtain(int)` `(I)Landroid/view/accessibility/AccessibilityEvent;` | take an event from the pool | `event.rs:25-33` |
| 37 | `AccessibilityEvent.setPackageName(CharSequence)` `(Ljava/lang/CharSequence;)V` | stamp the package | `event.rs:35-41`, value from `util.rs:215-225` |
| 38 | `AccessibilityEvent.setSource(View, int)` `(Landroid/view/View;I)V` | bind the event to the host and node id | `event.rs:42-48` |
| 39 | `AccessibilityEvent.setContentChangeTypes(int)` `(I)V` | mark a subtree change | `event.rs:79-85`, constant `util.rs:34` |
| 40 | `AccessibilityNodeInfo.obtain(View, int)` `(Landroid/view/View;I)Landroid/view/accessibility/AccessibilityNodeInfo;` | build the node for a virtual view id | `adapter.rs:349-351` |
| 41 | `AccessibilityNodeInfo.addChild(View, int)` `(Landroid/view/View;I)V` | one child edge | `node.rs:204-209` |
| 42 | `AccessibilityNodeInfo.setParent(View)` `(Landroid/view/View;)V` | the root's parent is the host | `node.rs:214-218` |
| 43 | `AccessibilityNodeInfo.setParent(View, int)` `(Landroid/view/View;I)V` | any other parent | `node.rs:222-226` |
| 44 | `AccessibilityNodeInfo.addAction(int)` `(I)V` | advertise an action | `node.rs:23` |
| 45 | `AccessibilityNodeInfo$RangeInfo.obtain(float, float, float, float)` `(IFFF)Landroid/view/accessibility/AccessibilityNodeInfo$RangeInfo;` | a text range | `util.rs:114-119` |
| 46 | `android.graphics.Rect.<init>(int, int, int, int)` `(IIII)V` | a node's screen rect | `node.rs:241-243` |

`AccessibilityNodeInfo$AccessibilityAction.<init>` (`node.rs:419`),
`AccessibilityNodeInfo.invalidate()` (`event.rs:414`),
`java.util.List.add(Object)` (`event.rs:124`) and
`dev.accesskit.android.Delegate.newCallback(View, long)`
(`Delegate.java:36-43`, called at `inject.rs:118-127`) are also reached by name; they are
helpers and constructors rather than distinct platform symbols, so they sit outside the 56.


| # | A5 item | Signature or type | Used for | Evidence |
|---|---|---|---|---|
| 47 | `NEXT_HANDLE` | `AtomicI64` | mint an adapter handle | `inject.rs:88`, `:340` |
| 48 | `HANDLE_MAP` | `Mutex<BTreeMap<jlong, Weak<Mutex<InnerInjectingAdapter>>>>` | map the Java `long` to the adapter | `inject.rs:89-95` |
| 49 | `NEXT_CALLBACK_HANDLE` | `AtomicI64` | mint a one-shot callback handle | `inject.rs:101`, `:113` |
| 50 | `CALLBACK_MAP` | `Mutex<BTreeMap<jlong, Box<dyn FnOnce(&mut JNIEnv, &JClass, &JObject) + Send>>>` | park a closure until the UI thread runs it | `inject.rs:103-105`, removed `:143` |
| 51 | `LOCAL_FRAME_CAPACITY` | `i32 = 2` | the local reference budget for one hop | `inject.rs:99` |
| 52 | `HOST_VIEW_ID` | `jint = -1` | the id that means the host view itself | `util.rs:52`, tested `adapter.rs:331`, `:428`, `:573` |
| 53 | `NodeIdMap::get_or_create_java_id` | `(&mut self, &NodeRef) -> jint` | give each node a stable `int` | `util.rs:145-159` |
| 54 | `NodeIdMap::get_accesskit_id` | `(&self, jint) -> Option<FullNodeId>` | map back | `util.rs:141` |
| 55 | `bundle_contains_key`, `bundle_get_int`, `bundle_get_float`, `bundle_get_bool` | four helpers over `Bundle` | read `ACTION_ARGUMENT_*` | `util.rs:161`, `:174`, `:182`, `:195` |
| 56 | `PlatformAction::from_java` | `(&mut JNIEnv, jint, &JObject) -> Option<Self>` | decode an action id plus its `Bundle` | `action.rs:36`, called `inject.rs:186` |

### 3.3 What happens when a lookup fails

There are three different answers in this crate, and a port must keep all three.

| Failure | Behaviour | Evidence |
|---|---|---|
| The adapter handle is dead, because the `Weak` in `HANDLE_MAP` cannot upgrade | the `extern` function returns `JObject::null()` or `JNI_FALSE`, and Java sees a null node or `false` | `inject.rs:156-158`, `:170-172`, `:189-191`, `:210-212` |
| The action id or its `Bundle` cannot be decoded | `PlatformAction::from_java` returns `None` and the function returns `JNI_FALSE` without touching the adapter | `inject.rs:186-188`, `action.rs:36` |
| Any JNI call itself errors, which includes `find_class`, `new_object`, `call_method` and `register_native_methods` | the call is `.unwrap()`, so the process aborts with a panic | `inject.rs:125`, `:134`, `:250`, `:291`, `:292`, `:386`; `event.rs:23`, `:32`, `:110`; `node.rs:234`, `:235`, `:242`; `util.rs:162`, `:241` |
| The host has already been collected | `WeakRef::upgrade_local` returns `Ok(None)` and the hop is skipped | `inject.rs:424-426` |
| The host view has been detached when an event is posted | `getParent` returns null and the event is dropped | `event.rs:53-62` |
| The thread cannot be attached, or a one-shot callback is already gone | `Drop` logs through `debug!` and continues | `inject.rs:466-468`, `:143-145` |

So a missing class or a wrong signature on this adapter is a **panic**, not a `null`. A Zig
port that returned `error` instead would change the observable behaviour.

### 3.4 What `inject.rs` does

It is the only file that owns the process-level wiring, 471 lines in three parts.

1. **Handle table and delegate installation.** `InjectingAdapter::new` (`inject.rs:329-390`)
   parks the adapter behind a `Weak` in `HANDLE_MAP` (`:340-344`) and keeps a `WeakRef` to
   the host view (`:386`), then posts to the UI thread a closure that refuses to run if the
   host already has a delegate (`:361-363`) and otherwise sets the delegate and the hover
   listener (`:367-380`).
2. **Class bootstrap and UI-thread hops.** `delegate_class` (`inject.rs:222-295`) runs once
   under a `OnceLock<GlobalRef>`: load the class, register the five natives, take a global
   reference (`:257-292`). `post_to_ui_thread` (`:107-135`) parks a closure under a fresh
   handle and calls `View.post`; `run_callback` (`:137-147`) removes and runs it.
3. **Teardown.** `Drop` (`inject.rs:464-470`) posts `uninstall_delegate` (`:433-462`), which
   clears both setters only if the current delegate is one of ours (`:444-446`).

`Adapter` is public on its own (`android/src/lib.rs:13`) and `InjectingAdapter` wraps it
(`android/src/lib.rs:17`).

### 3.5 What only Android has to do

| Task | Why no other platform needs it | Evidence |
|---|---|---|
| Marshal every value through `JNIEnv` | there is no message send; every argument crosses a C ABI by hand | `inject.rs:149-220` |
| Manage local reference frames | JNI references are bounded per frame | `inject.rs:99`, `:423` |
| Post to the UI thread | the Android UI thread is not the thread the adapter was built on | `inject.rs:305-307`, `:398-401` |
| Keep Java objects alive | `GlobalRef` and `WeakRef` instead of a borrow of a Rust struct | `inject.rs:292`, `:386` |
| Decode a `Bundle` per action | Android passes action arguments as a `Bundle` | `action.rs:36`, `util.rs:161-206` |
| Build `AccessibilityEvent` objects | there is no post-a-name API; the event is data | `event.rs:15-70` |

The thread rule is the sharpest contrast. macOS and iOS are main-thread only and reject any
other thread at construction (`macos/src/adapter.rs:96`, `ios/src/adapter.rs:352`). Android
accepts any thread and pays for it (`inject.rs:398-401`).

---

## 4. What the Zig side does instead

`jni.h` is plain C and `zig translate-c` parses it; the run on this host against a host
JDK 25 header produced declarations and no error (`docs/16-native-platform-apis.md:1729-1743`).
So the JNI boundary is rung 3 and needs no C shim. The five thunks are `callconv(.c)` on
every target except 32-bit Windows, where `JNICALL` is `__stdcall` and they are
`callconv(.winapi)`. `register_native_methods` is the one part a `translate-c` binding
cannot produce, because it is a data structure rather than a declaration, so a Zig port
declares a `[5]jni.NativeMethod` literal from `inject.rs:260-288`.

The same command fails on a three-declaration Objective-C header with `error: translation
failure` (`docs/16-native-platform-apis.md:1580-1647`), so section 2 is declared by hand and
`UIKit` is never parsed. No Zig UIKit binding exists (`:1702-1728`).

`mitchellh/zig-objc` covers class pairs, `Class::addMethod`, selectors and message sends
(`docs/16-native-platform-apis.md:1648-1683`). It does **not** cover
`objc_getAssociatedObject`, `objc_setAssociatedObject` or `object_setClass`, which are rows
49 to 51 and are unavoidable for both Apple adapters. Its `build.zig` calls `translateCModule`
unconditionally at line 15, before `-Dadd-paths` is consulted at line 23, and that reaches
`appleSDKPath` at line 59, which runs `xcrun` (`docs/16-native-platform-apis.md:1684-1701`).

**Verdict: `zig-objc` is disqualified for a port that must build from this host.** A
`build.zig.zon` dependency resolves and builds on Linux, so a dependency whose configure
step always fails cannot be one. `docs/30-port-design.md` owns the replacement; the three
needed `extern "C"` declarations are the first option at `docs/16-native-platform-apis.md:1694-1696`.

Android still needs by hand: the five thunks with the JNI signature of `extern "system"`
(`inject.rs:149-220`, `:260-288`); the handle map and the callback map (`inject.rs:88-105`);
the three failure shapes of 3.3, which are a design choice; and the Java class plus the
prebuilt `classes.dex` and its 7-line builder `android/build-dex.sh`.

---

## 5. Attribution, and what the port must carry

`adapters/android/src/adapter.rs:1-9` and `adapters/android/src/event.rs:1-9` both carry
the AccessKit Apache-2.0-or-MIT header, then this block:

> // Derived from the Flutter engine.
> // Copyright 2013 The Flutter Authors. All rights reserved.
> // Use of this source code is governed by a BSD-style license that can be
> // found in the LICENSE.chromium file.

The holder named is The Flutter Authors and the file named is a Chromium file.
`docs/21-licensing.md:390-396` records this as section 3.3, "The four Flutter files", and
lists these two files as rows 9 and 10 of its twelve-file inventory (`:369-370`).
`[INFERENCE]` AccessKit reads the Flutter engine's three-clause BSD grant as the same text
as Chromium's, so the pointer still reaches a three-clause BSD licence; the file name does
not match the holder. Two more headers sit in the crate: `inject.rs:6-10` is `Derived from
jni-rs` with `MIT OR Apache-2.0` (`docs/21-licensing.md:450`), and `node.rs:1-9` names The
Chromium Authors, row 6 (`:365`).

What a port must carry instead:

1. The holder line verbatim, with its year:
   `Copyright 2013 The Flutter Authors. All rights reserved.` (`docs/21-licensing.md:510`).
2. A pointer to a licence file the port **ships**; `docs/21-licensing.md:462-466` calls a
   dangling pointer an upstream defect a translating port must not copy.
3. The jni-rs holder line and its `MIT OR Apache-2.0` terms on any file derived from
   `inject.rs`, and the per-file inventory in `NOTICE.md` (`docs/21-licensing.md:970`, N3).
4. Nothing in the generated C header: `docs/21-licensing.md:468-503` shows `accesskit.h`
   carries no Chromium or Flutter copyright line, and item A10 covers it.

---

## 6. What can be verified on this host

This host is Linux, with no macOS SDK, no iOS SDK, no Android NDK, no `adb`, no
`ANDROID_HOME` and no Wine. **Nothing in section 2, 3 or 4 is runtime-testable here.** The
three claims below are kept apart on purpose.

### 6.1 What a cross build proves, measured

Every row was run on this host against Zig 0.16.0; see `docs/16-native-platform-apis.md:1770-1789`.

| Check | Command shape | Result |
|---|---|---|
| cross compile | `zig build-obj -target aarch64-ios` | works, 2939968-byte object |
| cross compile | `zig build-obj -target aarch64-macos` | works, 2979320-byte object |
| cross compile | `zig build-obj -target aarch64-linux-android` | works, 3902912-byte object |
| cross link | `zig build-exe -target aarch64-ios` | fails, `unable to find libSystem system library`, 0-byte output |
| cross link | `zig build-exe -target aarch64-macos` | works, Mach-O magic `feedfacf` |
| cross link | `zig build-exe -target aarch64-macos -lobjc` | fails, `unable to find dynamic system library 'objc'` |
| cross link | `zig build-exe -target aarch64-macos -framework Foundation` | fails, `unable to find framework 'Foundation'` |
| cross link | `zig build-exe -target aarch64-linux-android -llog -lc` | fails, `unable to find dynamic system library 'log'` |
| run a built binary | `wine`, or a Mac | not available, `which wine` returns nothing |

So a cross build proves that the Zig sources compile for a foreign target and that no
host-only header is reached. It proves nothing about the platform.

### 6.2 What a header parse proves, measured

`zig translate-c` fails on an Objective-C header and succeeds on a resolved COM C header and
on `jni.h` (`docs/16-native-platform-apis.md:1784-1786`). That proves the JNI declarations in
section 3.1 are the ones `jni.h` states, and nothing more: not that any symbol resolves at
load time, and not one line of behaviour. The test used a desktop JDK header, not an NDK
header (`docs/16-native-platform-apis.md:1741-1743`).

### 6.3 What cannot be reached at all

1. Objective-C message dispatch and the class-pair runtime, which is every row in section 2
   marked `impl`.
2. UIKit's accessibility server, VoiceOver, the nine notification deliveries at
   `ios/src/adapter.rs:370-380`, and `UIAccessibilityPostNotification` (`event.rs:57`).
3. The JNI boundary at run time: no `JNIEnv`, no local reference frame, no
   `attach_current_thread` (`inject.rs:422`), no `InMemoryDexClassLoader` (`:227-241`).
4. The Android UI thread, `View.post` (`inject.rs:128-134`) and
   `requestSendAccessibilityEvent` (`event.rs:63-69`).
5. Any timing, ordering or focus claim: the rules in 3.3 and at `ios/src/event.rs:164-204` are read off code, not observed.

### 6.4 Verdict

From this machine the port can make **no** honest claim about the behaviour of macOS, iOS or
Android. Not one sentence of section 2, 3 or 4 is runtime-testable here, and for iOS and
Android even the link step fails.

The one honest claim, which `docs/30-port-design.md` may rely on, is about the
**checked-out source and not about the platform**: the 63-symbol iOS inventory in section 2 is
complete with respect to `adapters/ios/src/` and the 56-symbol JNI inventory in section 3 with
respect to `adapters/android/`, at commit `466e24e2`.
