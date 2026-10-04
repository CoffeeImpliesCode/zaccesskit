//! The Objective-C runtime and UIKit binding layer the iOS adapter calls
//! through, for milestone M9.
//!
//! Upstream is `accesskit_ios` 0.2.1. The files it reads its platform surface
//! from are `AK/ios/src/util.rs:71-110`, `AK/ios/src/event.rs:76-104`,
//! `AK/ios/src/subclass.rs:71-317` and `AK/ios/src/adapter.rs:97-119`. This
//! module holds what those files read out of the two system images, and
//! nothing else. The adapter body, the node and the element filter belong to
//! `root.zig` and to later milestones.
//!
//! | Held | Count | Upstream |
//! |---|---:|---|
//! | Objective-C runtime entry points | 14 | `AK/ios/src/util.rs:71-110`, `subclass.rs:199-317` |
//! | required UIKit symbols | 8 | `AK/ios/src/adapter.rs:97-103`, `:277-291` |
//! | optional UIKit symbols | 4 | `AK/ios/src/util.rs:77-110`, `event.rs:88` |
//! | message sends | 19 | `AK/ios/src/*` |
//! | installed implementations | 6 | `AK/ios/src/subclass.rs:214-230`, `adapter.rs:245-275` |
//!
//! **Why 14 runtime entry points and not the four `docs/42` counts.** Map
//! section 1.3.4 counts four Objective-C runtime functions, and
//! `runtime.runtime_functions` holds those four. The census in the map counts
//! what the Rust source spells: `objc2`'s `declare_class!` macro registers a
//! class pair behind `objc_allocateClassPair`, `class_addMethod` and
//! `objc_registerClassPair`, so the source never names `objc_msgSend` for the
//! messages it sends. This module resolves the fourteen the port sends through,
//! so it counts what the requirement needs rather than what the source spells.
//! The two numbers measure different things, and a `comptime` check and a test
//! both hold that the four upstream spellings are all in this table.
//!
//! **The context is threaded everywhere the ABI allows it.** Every entry point in
//! `Platform` takes the bindings as its first parameter, which is the
//! `context` field. AGENTS.md section 3 requires `io` threaded explicitly and
//! never global, and Zig has no closure, so a context cannot be baked into a
//! function pointer. This module holds no global allocator, no global bindings
//! for the entry points, no clock and no environment.
//!
//! **The one file-scope `var`, and why the ABI forces it.** The six installed
//! implementations are the exception. The Objective-C ABI hands an
//! implementation `self` and `_cmd` and nothing else, so an implementation
//! cannot take a context parameter either. `installed` is the single
//! file-scope `var` in this file: it holds the bindings that installed the
//! current class pairs, and `platform` writes it while `release` clears it. An
//! implementation reads its owner through it, and the owner carries the
//! caller's adapter pointer and callback table. Nothing else in the module is
//! reachable without a parameter: no global allocator, no clock, no
//! environment. One `Platform` may be live at a time,
//! because a second `platform` call shadows the first here and in the class
//! pairs the Objective-C runtime holds process-wide.
//!
//! **The linkage route.** `AK/ios/src/util.rs:71-75` writes its own `dlsym`
//! declaration and defines `RTLD_DEFAULT` as `-2isize`. Map section 2.3 says a
//! Zig port deletes both and uses `std.DynLib`. Zig 0.16.0 `std.DynLib.open`
//! takes a library path and has no null-path form, so the caller hands in the
//! two image paths rather than this module naming them, which is what
//! `runtime.resolveInImage` already records for the weak constants.
//! `runtime.resolveInImage` cannot serve here because it closes the image
//! before it returns, and this module keeps both handles until `release`.
//!
//! **The data symbol route.** A constant is not a function symbol, so a lookup
//! returns the address of the storage rather than the value.
//! `AK/ios/src/util.rs:78-86` dereferences the toggle trait once and
//! `AK/ios/src/util.rs:88-95` dereferences an `NSString` constant once. This
//! module does the same: it resolves each constant as a pointer to the
//! pointer, then reads it once through that address. A constant whose address
//! does not resolve yields the `Fallback` that `runtime.weak_constants`
//! records for it, so `UIAccessibilityPriorityHigh` and
//! `UIAccessibilityPriorityLow` downgrade the announcement and the two
//! attribute keys post a plain string. The fourth fallback, `.no_trait`,
//! belongs to `UIAccessibilityTraitToggleButton`, and this module resolves no
//! trait, because no trait value is written anywhere in it.
//!
//! **The three notification tags.** The eight required UIKit symbols include
//! `UIAccessibilityScreenChangedNotification`,
//! `UIAccessibilityLayoutChangedNotification` and
//! `UIAccessibilityAnnouncementNotification`. `NotificationTags` carries all
//! three, each read from its data symbol, and this module writes no numeric
//! literal for any of them.
//!
//! **What `UIAccessibilityConvertFrameToScreenCoordinates` is for.** The module
//! resolves it because the port must reach the symbol and it is one of the eight
//! required. No `Platform` entry point calls it, because the adapter body
//! converts points itself through `view_convert_point`, and the sent-selector
//! table spells no selector for it because the module sends none.
//!
//! **Message sends, and why the table is larger than `selectors.zig`'s 12.**
//! `selectors.zig` counts the 12 selectors `AK/ios/src/*` calls on a
//! Foundation or a UIKit object. This table holds the 19 the port spells
//! itself, because the port sends `alloc` and `init` by name where `objc2`
//! spells them inside a macro, and because the port sends `class`, `new`,
//! `setObject:forKey:`, `newWithAttributes:`, `stringWithUTF8String:` and
//! `numberWithBool:` from code that carries the message in a named table rather
//! than in a macro. Three spellings from the frozen send list are absent
//! because the module sends none: `name` and `getMethodImplementation:` are
//! reached through `class_getName` and `class_getMethodImplementation`, and
//! `superclass` is an installed selector rather than a message. `dictionary`
//! is absent because `AK/ios/src/event.rs:78` builds the attributes dictionary
//! with `NSMutableDictionary::new()`, which is the `new` row.
//!
//! **The installed implementations.** The Objective-C ABI hands an
//! implementation only `self` and `_cmd`, so the six implementations
//! `AK/ios/src/subclass.rs:214-230` and `AK/ios/src/adapter.rs:245-275`
//! install live in this module. Each one reads its owner through
//! `objc_getAssociatedObject` and the key below, and each one calls back into
//! `root.zig` through `Callbacks`.
//!
//! **The owner key.** The key is one file-scope `const` byte, exactly as
//! `AK/ios/src/subclass.rs:29-33` uses `&ASSOCIATED_OBJECT_KEY`. AGENTS.md
//! section 3.3 draws its line at a file-scope `var`, and a `const` is not one:
//! the byte never changes, so it carries no state and needs no lock.
//!
//! **The loop bound.** Five tables carry the port's spellings: 14 runtime entry
//! points, 8 required UIKit symbols, 4 optional UIKit symbols, 19 message sends
//! and 6 installed implementations. Each has a named count constant and each is
//! an array, so every walk over one is bounded by that array's length. Each
//! duplicate check walks each row against the rows that follow it, so its bound
//! is that count squared: 196, 28, 6, 171 and 15. The two build functions walk
//! the installed table: 5 rows for the view subclass and 1 for the observer
//! class. The one loop whose bound is not a type-level constant walks
//! `resolved.owners` in `release`, and its length is the number of
//! `claim_object` calls that allocated an owner.
//!
//! **What is a fact and what is not.** No Apple SDK is installed on this host,
//! so `objc/runtime.h`, `objc/message.h`, `NSObject.h` and
//! `UIKit/UIAccessibilityConstants.h` were not read. The nine signature types
//! below come from `docs/29-apple-android-apis.md` rows 1 to 14 and from the
//! four types `runtime.zig` and `uikit.zig` already declare. The `objc_super`
//! layout, the six type encodings, the two default image paths and the `BOOL`
//! the installed `isAccessibilityElement` answers are **unverified**, and each
//! declaration that carries one says so.
//!
//! **The shortest sequence that uses the module.**
//! ```zig
//! const answer = try objc.platform(
//!     gpa,
//!     objc.default_objective_c_image_path,
//!     objc.default_uikit_image_path,
//!     callbacks,
//! );
//! defer objc.release(answer);
//! const is_running = answer.any_assistive_tech_running(answer.context);
//! ```
//! The caller releases the `Platform` with `release`, once, and that call frees
//! both images, the bindings allocation and every `Owner` `claim_object`
//! allocated. The caller owns the allocator and releases nothing else.

const std = @import("std");

const builtin = @import("builtin");

const foundation = @import("foundation.zig");
const runtime = @import("runtime.zig");
const selectors = @import("selectors.zig");
const uikit = @import("uikit.zig");

const testing = std.testing;

/// One method the port installs on a class it builds at run time.
///
/// The port builds two classes, at `AK/ios/src/subclass.rs:214-230` and
/// `AK/ios/src/adapter.rs:245-275`, and both take their rows from
/// `installed_methods`, so a caller never constructs one.
pub const InstalledMethod = struct {
    /// The exact selector spelling, as `selectors.zig` records it.
    name: [:0]const u8,
    /// The Objective-C type encoding of the installed implementation.
    ///
    /// `class_addMethod` hands this string to the runtime as the method's type
    /// encoding, and the runtime reports a mismatch when it builds the method.
    /// **Unverified**: no Apple SDK is installed on this host, so
    /// `objc/runtime.h` was not read, and no document under `docs/` records an
    /// encoding.
    types: [:0]const u8,
    /// The implementation, cast to the runtime's fixed shape.
    implementation: runtime.Imp,
};

/// The three `UIAccessibilityNotifications` tags the adapter posts.
///
/// Upstream reads them out of the UIKit image at `AK/ios/src/event.rs:92`,
/// `:135` and `:142`. Each is a data symbol, so the port resolves the symbol
/// and reads the value through its address, which is what
/// `AK/ios/src/util.rs:78-86` does for the toggle trait. No document under
/// `docs/` records a value, so the port never writes one itself.
pub const NotificationTags = struct {
    /// `UIAccessibilityScreenChangedNotification`.
    screen_changed: u64,
    /// `UIAccessibilityLayoutChangedNotification`.
    layout_changed: u64,
    /// `UIAccessibilityAnnouncementNotification`.
    announcement: u64,
};

/// What an installed implementation calls back into.
///
/// Every entry takes the pointer the caller passed to `claim_object` or to
/// `observer_new`, unchanged. `root.zig` casts it to the adapter type that owns
/// the object, so this module never names a type of the adapter's.
pub const Callbacks = struct {
    /// `AK/ios/src/subclass.rs:80-83`: the superclass of the class the view
    /// carried before the port installed its own.
    view_superclass: *const fn (adapter: ?*anyopaque) ?*runtime.ObjClass,

    /// `AK/ios/src/subclass.rs:87-92`.
    view_is_accessibility_element: *const fn (adapter: ?*anyopaque) bool,

    /// `AK/ios/src/subclass.rs:95-100`.
    view_accessibility_elements: *const fn (adapter: ?*anyopaque) ?*runtime.AnyObject,

    /// `AK/ios/src/subclass.rs:103-112`.
    view_accessibility_hit_test: *const fn (
        adapter: ?*anyopaque,
        point: foundation.CGPoint,
    ) ?*runtime.AnyObject,

    /// `AK/ios/src/subclass.rs:118`: the class the view carried before the port
    /// installed its own. The `didMoveToWindow` implementation asks for this
    /// first, because it forwards to that class's implementation before it runs
    /// the callback.
    view_previous_class: *const fn (adapter: ?*anyopaque) ?*runtime.ObjClass,

    /// `AK/ios/src/subclass.rs:130-135`: the adapter is active and the events it
    /// produced have been raised.
    view_did_move_to_window: *const fn (adapter: ?*anyopaque) void,

    /// `AK/ios/src/adapter.rs:266-272`.
    accessibility_status_changed: *const fn (adapter: ?*anyopaque) void,
};

/// What an installed implementation reads off the object it was sent to.
///
/// This is the port's `StatusObserver` and `AssociatedObject` ivars, at
/// `AK/ios/src/adapter.rs:239-243` and `AK/ios/src/subclass.rs:35-39`. Upstream
/// carries a weak reference to the adapter state in them and a strong one in
/// the associated object; the port carries the caller's pointer unchanged and
/// the callback table it was built with, so one allocation answers both.
///
const Owner = struct {
    /// The caller's pointer, as `claim_object` or `observer_new` received it.
    adapter: ?*anyopaque,
    /// The caller's callback table.
    callbacks: Callbacks,
};

/// `objc_msgSend`, as the fixed part plus the variadic tail.
///
/// `docs/29` records no signature for it, and `objc2` spells its sends through a
/// macro rather than through this symbol. **Unverified**: no Apple SDK is
/// installed on this host, so `objc/message.h` was not read.
const MsgSendFn = fn (
    ?*runtime.AnyObject,
    ?*runtime.Sel,
    ...
) callconv(.c) ?*runtime.AnyObject;

/// `objc_msgSendSuper2`, with the fixed part `objc/message.h` gives.
///
/// **Unverified**: no Apple SDK is installed on this host, so `objc/message.h`
/// was not read.
const MsgSendSuper2Fn = fn (
    *const anyopaque,
    ?*runtime.Sel,
    ...
) callconv(.c) ?*runtime.AnyObject;

/// `objc_getClass`.
const ObjCGetClassFn = fn ([*:0]const u8) callconv(.c) ?*runtime.ObjClass;

/// `objc_allocateClassPair`.
const ObjCAllocateClassPairFn = fn (
    ?*runtime.ObjClass,
    [*:0]const u8,
    usize,
) callconv(.c) ?*runtime.ObjClass;

/// `objc_registerClassPair`.
const ObjCRegisterClassPairFn = fn (?*runtime.ObjClass) callconv(.c) void;

/// `class_getName`.
const ClassGetNameFn = fn (?*runtime.ObjClass) callconv(.c) ?[*:0]const u8;

/// `class_getSuperclass`.
const ClassGetSuperclassFn = fn (?*runtime.ObjClass) callconv(.c) ?*runtime.ObjClass;

/// `class_getMethodImplementation`.
const ClassGetMethodImplementationFn = fn (
    ?*runtime.ObjClass,
    ?*runtime.Sel,
) callconv(.c) ?runtime.Imp;

/// `sel_registerName`.
const SelRegisterNameFn = fn ([*:0]const u8) callconv(.c) ?*runtime.Sel;

/// `objc_release`, which balances the reference `+alloc` produced.
///
/// **Unverified**: no Apple SDK is installed on this host, so `objc/runtime.h`
/// was not read. `docs/29` records no signature for it.
const ObjCReleaseFn = fn (?*runtime.AnyObject) callconv(.c) void;

/// `[view convertPoint:fromCoordinateSpace:]`, which returns a struct rather
/// than an object, so the port calls it through a second view of the same
/// address.
///
/// **Unverified**: no Apple SDK is installed on this host, so `objc/message.h`
/// was not read. The return type is `foundation.CGPoint`, which
/// `foundation.zig` declares from `CGGeometry.h` and also marks unverified.
const ConvertPointFn = fn (
    ?*runtime.AnyObject,
    ?*runtime.Sel,
    foundation.CGPoint,
    ?*runtime.AnyObject,
) callconv(.c) foundation.CGPoint;

/// `[view contentScaleFactor]`, which returns a scalar rather than an object.
const ContentScaleFactorFn = fn (
    ?*runtime.AnyObject,
    ?*runtime.Sel,
) callconv(.c) foundation.CGFloat;

/// `struct objc_super`, the first argument `objc_msgSendSuper2` takes.
///
/// **Unverified**: no Apple SDK is installed on this host, so `objc/message.h`
/// was not read. The field order is the one that header declares.
const ObjcSuper = extern struct {
    receiver: ?*runtime.AnyObject,
    super_class: ?*runtime.ObjClass,
};

/// The key every associated owner hangs under.
///
/// `AK/ios/src/subclass.rs:29-33` names one `static` byte and takes its
/// address, so the key is the address and not the value. The port takes the
/// address of a `const` byte, which no caller can write through.
const associated_object_key: u8 = 0;

/// The resolved symbols and the two open images.
///
/// One value owns the two `std.DynLib` handles, the `Owner` allocations
/// `claim_object` made and itself. `release` frees all three. A caller reaches
/// it as the `Platform.context` field and hands it back as the first argument
/// of every entry point.
const Bindings = struct {
    /// The allocator `platform` was given. Every `Owner` comes from it.
    gpa: std.mem.Allocator,
    /// The Objective-C runtime image, opened by `platform`.
    objective_c_image: std.DynLib,
    /// The UIKit image, opened by `platform`.
    uikit_image: std.DynLib,
    /// The callback table `platform` was given.
    callbacks: Callbacks,
    /// Every `Owner` `claim_object` allocated, in the order it allocated them.
    owners: std.ArrayList(*Owner),

    /// `objc_getClass`.
    get_class: *const ObjCGetClassFn,
    /// `objc_allocateClassPair`.
    allocate_class_pair: *const ObjCAllocateClassPairFn,
    /// `objc_registerClassPair`.
    register_class_pair: *const ObjCRegisterClassPairFn,
    /// `objc_msgSend`.
    msg_send: *const MsgSendFn,
    /// `objc_msgSendSuper2`.
    msg_send_super2: *const MsgSendSuper2Fn,
    /// `class_getName`.
    class_get_name: *const ClassGetNameFn,
    /// `class_getSuperclass`.
    class_get_superclass: *const ClassGetSuperclassFn,
    /// `class_getMethodImplementation`.
    class_get_method_implementation: *const ClassGetMethodImplementationFn,
    /// `class_addMethod`, typed by `runtime.ClassAddMethodFn`.
    class_add_method: *const runtime.ClassAddMethodFn,
    /// `objc_getAssociatedObject`, typed by `runtime.ObjCGetAssociatedObjectFn`.
    get_associated_object: *const runtime.ObjCGetAssociatedObjectFn,
    /// `objc_setAssociatedObject`, typed by `runtime.ObjCSetAssociatedObjectFn`.
    set_associated_object: *const runtime.ObjCSetAssociatedObjectFn,
    /// `object_setClass`, typed by `runtime.ObjectSetClassFn`.
    object_set_class: *const runtime.ObjectSetClassFn,
    /// `sel_registerName`.
    sel_register_name: *const SelRegisterNameFn,
    /// `objc_release`.
    objc_release: *const ObjCReleaseFn,

    /// `UIAccessibilityIsVoiceOverRunning`.
    is_voice_over_running: *const uikit.IsRunningFn,
    /// `UIAccessibilityIsSwitchControlRunning`.
    is_switch_control_running: *const uikit.IsRunningFn,
    /// `UIAccessibilityIsSpeakScreenEnabled`.
    is_speak_screen_enabled: *const uikit.IsRunningFn,
    /// `UIAccessibilityPostNotification`, typed by `uikit.PostNotificationFn`.
    post_notification: *const uikit.PostNotificationFn,
    /// `UIAccessibilityConvertFrameToScreenCoordinates`.
    ///
    /// Resolved because the port must reach the symbol and it is one of the eight
    /// required. No `Platform` entry point calls it, because the adapter body
    /// converts points itself through `view_convert_point`.
    convert_frame_to_screen: *const uikit.ConvertFrameToScreenCoordinatesFn,

    /// `UIAccessibilityScreenChangedNotification`, read through its address.
    screen_changed: u64,
    /// `UIAccessibilityLayoutChangedNotification`, read through its address.
    layout_changed: u64,
    /// `UIAccessibilityAnnouncementNotification`, read through its address.
    announcement: u64,

    /// `UIAccessibilityPriorityHigh`, or `null` when the image does not export
    /// it. The fallback is `runtime.Fallback.downgrade_announcement`.
    priority_high: ?*runtime.AnyObject,
    /// `UIAccessibilityPriorityLow`, or `null`. The fallback is
    /// `runtime.Fallback.downgrade_announcement`.
    priority_low: ?*runtime.AnyObject,
    /// `UIAccessibilitySpeechAttributeAnnouncementPriority`, or `null`. The
    /// fallback is `runtime.Fallback.plain_string_announcement`.
    announcement_priority_key: ?*runtime.AnyObject,
    /// `UIAccessibilitySpeechAttributeQueueAnnouncement`, or `null`. The
    /// fallback is `runtime.Fallback.plain_string_announcement`.
    queue_announcement_key: ?*runtime.AnyObject,
};

/// Every platform call the iOS adapter makes.
///
/// Every entry point takes the bindings as its first parameter, which is the
/// `context` field. A caller must not call one after `release`, because the
/// pointer it hands over is then freed.
pub const Platform = struct {
    /// The bindings, which a caller passes as the first argument of every entry
    /// point below. The field is here so a caller holds the pair together; it is
    /// not read by the entry points, which take it as a parameter.
    context: ?*anyopaque,

    /// The three tags above.
    notification_tags: NotificationTags,

    /// `AK/ios/src/adapter.rs:97-103`: VoiceOver, Switch Control or Speak
    /// Screen is running.
    any_assistive_tech_running: *const fn (ctx: ?*anyopaque) bool,

    /// `AK/ios/src/adapter.rs:277-291`: an instance of `class` that carries
    /// `adapter` as its owner.
    observer_new: *const fn (
        ctx: ?*anyopaque,
        class: *runtime.ObjClass,
        adapter: ?*anyopaque,
    ) ?*runtime.AnyObject,

    /// `AK/ios/src/adapter.rs:373`: `[[NSNotificationCenter defaultCenter]
    /// addObserver:selector:name:object:]`.
    add_status_observer: *const fn (
        ctx: ?*anyopaque,
        observer: *runtime.AnyObject,
        notification_name: [:0]const u8,
    ) void,

    /// `AK/ios/src/adapter.rs:511`: `[center removeObserver:]`, then the
    /// matching release for the `+alloc` `observer_new` sent.
    remove_status_observer: *const fn (
        ctx: ?*anyopaque,
        observer: *runtime.AnyObject,
    ) void,

    /// `objc_setAssociatedObject(object, key, owner, policy)`: associates an
    /// owner with `object`, allocating one. `AK/ios/src/subclass.rs:88-96` is
    /// the call this replaces.
    claim_object: *const fn (
        ctx: ?*anyopaque,
        object: *runtime.AnyObject,
        adapter: ?*anyopaque,
    ) void,

    /// `objc_setAssociatedObject(object, key, null, policy)`, which is what
    /// `AK/ios/src/subclass.rs:313-318` does in the subclassing drop.
    release_object: *const fn (
        ctx: ?*anyopaque,
        object: *runtime.AnyObject,
    ) void,

    /// Whether `object` already carries an owner. `AK/ios/src/subclass.rs:218-220`
    /// is the check this replaces.
    object_owner: *const fn (
        ctx: ?*anyopaque,
        object: *runtime.AnyObject,
    ) bool,

    /// `AK/ios/src/subclass.rs:131`: `[view window]`.
    view_window: *const fn (
        ctx: ?*anyopaque,
        view: *runtime.AnyObject,
    ) ?*runtime.AnyObject,

    /// `AK/ios/src/util.rs:36`: `[window screen]`.
    view_screen: *const fn (
        ctx: ?*anyopaque,
        view: *runtime.AnyObject,
    ) ?*runtime.AnyObject,

    /// `AK/ios/src/util.rs:37`: `[screen coordinateSpace]`.
    screen_coordinate_space: *const fn (
        ctx: ?*anyopaque,
        screen: *runtime.AnyObject,
    ) ?*runtime.AnyObject,

    /// `AK/ios/src/util.rs:38`: `[view convertPoint:fromCoordinateSpace:]`.
    view_convert_point: *const fn (
        ctx: ?*anyopaque,
        view: *runtime.AnyObject,
        point: foundation.CGPoint,
        space: *runtime.AnyObject,
    ) foundation.CGPoint,

    /// `AK/ios/src/util.rs:39`: `[view contentScaleFactor]`.
    view_content_scale_factor: *const fn (
        ctx: ?*anyopaque,
        view: *runtime.AnyObject,
    ) foundation.CGFloat,

    /// `AK/ios/src/subclass.rs:295-299`: `[window rootViewController]` and
    /// then `[- view]`.
    window_root_view: *const fn (
        ctx: ?*anyopaque,
        window: *runtime.AnyObject,
    ) ?*runtime.AnyObject,

    /// `AK/ios/src/subclass.rs:214`: `[view class]`.
    view_class: *const fn (
        ctx: ?*anyopaque,
        view: *runtime.AnyObject,
    ) ?*runtime.ObjClass,

    /// `AK/ios/src/subclass.rs:242`: `[class name]`.
    class_name: *const fn (
        ctx: ?*anyopaque,
        class: *runtime.ObjClass,
    ) ?[*:0]const u8,

    /// `AK/ios/src/subclass.rs:81`: `[class superclass]`.
    class_superclass: *const fn (
        ctx: ?*anyopaque,
        class: *runtime.ObjClass,
    ) ?*runtime.ObjClass,

    /// `objc_getClass(name)`.
    class_with_name: *const fn (
        ctx: ?*anyopaque,
        name: [:0]const u8,
    ) ?*runtime.ObjClass,

    /// Registers the class named `name` on `superclass` with the single
    /// `accessibilityStatusChanged:` implementation.
    ///
    /// `AK/ios/src/adapter.rs:245-275`. Returns `null` when the pair refuses the
    /// class, which is the same name already taken.
    build_observer_class: *const fn (
        ctx: ?*anyopaque,
        name: [:0]const u8,
        superclass: *runtime.ObjClass,
    ) ?*runtime.ObjClass,

    /// Registers the class named `name` on `superclass` with the five
    /// implementations `AK/ios/src/subclass.rs:214-230` installs.
    ///
    /// Returns `null` when the pair refuses the class, which is the same name
    /// already taken.
    build_view_subclass: *const fn (
        ctx: ?*anyopaque,
        name: [:0]const u8,
        superclass: *runtime.ObjClass,
    ) ?*runtime.ObjClass,

    /// `object_setClass`, at `AK/ios/src/subclass.rs:262`.
    set_view_class: *const fn (
        ctx: ?*anyopaque,
        view: *runtime.AnyObject,
        class: *runtime.ObjClass,
    ) void,

    /// `UIAccessibilityPostNotification(notification, argument)`.
    post_notification: *const fn (
        ctx: ?*anyopaque,
        notification: u64,
        argument: ?*runtime.AnyObject,
    ) void,

    /// `AK/ios/src/event.rs:76-104`: the announcement, with the two priorities
    /// and the key it resolves through `dlsym`.
    raise_announcement: *const fn (
        ctx: ?*anyopaque,
        text: []const u8,
        assertive: bool,
    ) void,

    /// `+[NSArray array]`: an empty array the caller does not own.
    empty_array: *const fn (ctx: ?*anyopaque) ?*runtime.AnyObject,

    /// Closes both images and frees the bindings, which is the only release a
    /// `Platform` has.
    ///
    /// The table carries it because every other platform call is here, and a
    /// caller that reached for `objc.release` instead would cast its `context`
    /// as the `Bindings` that built the table, so a table not built by
    /// `platform` cannot be released that way. `platform` installs the real
    /// release; a table built by a test installs its own.
    release: *const fn (ctx: ?*anyopaque) void,
};

/// How many rows `objc_entry_points` holds.
pub const objc_entry_point_count = 14;

/// The Objective-C runtime entry points the port resolves, with a count and a
/// `comptime` check that no spelling appears twice.
///
/// The four spellings `runtime.runtime_functions` holds are all in this table,
/// and a `comptime` check says so. The other ten are the ones `objc2`'s
/// `declare_class!` macro and `msg_send!` hide from the Rust source. See the
/// module doc for why the two counts differ.
pub const objc_entry_points = [objc_entry_point_count][:0]const u8{
    "class_addMethod",
    "class_getMethodImplementation",
    "class_getName",
    "class_getSuperclass",
    "objc_allocateClassPair",
    "objc_getAssociatedObject",
    "objc_getClass",
    "objc_msgSend",
    "objc_msgSendSuper2",
    "objc_release",
    "objc_registerClassPair",
    "objc_setAssociatedObject",
    "object_setClass",
    "sel_registerName",
};

/// How many rows `required_uikit_symbols` holds.
///
/// The count is 8 and not the 9 the frozen interface names, because the
/// enumeration that interface gives holds 8 rows: the three predicates, the
/// posting function, the conversion function and the three notification tags.
/// The table below holds all 8, and a test names each one.
pub const required_uikit_symbol_count = 8;

/// The UIKit symbols without which the port builds no platform.
///
/// The three predicates `AK/ios/src/adapter.rs:97-103` short-circuits on, the
/// one function it calls to post, the one function it resolves for the caller,
/// and the three notification tags it posts. A missing one is
/// `error.MissingSymbol`, never a half-built platform.
pub const required_uikit_symbols = [required_uikit_symbol_count][:0]const u8{
    "UIAccessibilityAnnouncementNotification",
    "UIAccessibilityConvertFrameToScreenCoordinates",
    "UIAccessibilityIsSpeakScreenEnabled",
    "UIAccessibilityIsSwitchControlRunning",
    "UIAccessibilityIsVoiceOverRunning",
    "UIAccessibilityLayoutChangedNotification",
    "UIAccessibilityPostNotification",
    "UIAccessibilityScreenChangedNotification",
};

/// How many rows `optional_uikit_symbols` holds.
pub const optional_uikit_symbol_count = 4;

/// One UIKit constant the port reads when the image exports it.
///
/// A missing one is not an error. Each row records the `runtime.Fallback` the
/// adapter applies when the address does not resolve, so a reader of
/// `runtime.weak_constants` sees which of its four rows this module uses.
pub const OptionalSymbol = struct {
    /// The exact spelling passed to the symbol lookup.
    name: [:0]const u8,
    /// What the adapter does when the image does not export `name`.
    fallback: runtime.Fallback,
    /// The upstream line the constant comes from, kept as text so a reader can
    /// find it without a second document.
    upstream_range: [:0]const u8,
};

/// The UIKit constants the port reads when the image exports them.
///
/// `AK/ios/src/util.rs:100-110` reads the two priorities and the announcement
/// priority key through `dlsym`, and `AK/ios/src/event.rs:88` links the queue
/// announcement key. The port resolves both keys rather than linking the
/// second, so an image that does not export it posts a plain string instead of
/// naming a key it cannot resolve.
pub const optional_uikit_symbols = [optional_uikit_symbol_count]OptionalSymbol{
    .{
        .name = "UIAccessibilityPriorityHigh",
        .fallback = .downgrade_announcement,
        .upstream_range = "AK/ios/src/util.rs:100-102",
    },
    .{
        .name = "UIAccessibilityPriorityLow",
        .fallback = .downgrade_announcement,
        .upstream_range = "AK/ios/src/util.rs:104-106",
    },
    .{
        .name = "UIAccessibilitySpeechAttributeAnnouncementPriority",
        .fallback = .plain_string_announcement,
        .upstream_range = "AK/ios/src/util.rs:108-110",
    },
    .{
        .name = "UIAccessibilitySpeechAttributeQueueAnnouncement",
        .fallback = .plain_string_announcement,
        .upstream_range = "AK/ios/src/event.rs:88",
    },
};

/// How many rows `sent_selectors` holds.
pub const sent_selector_count = 19;

/// Every message the port sends, in the order `AK/ios/src/*` sends them.
///
/// `selectors.zig` counts the 12 selectors upstream calls by name on a
/// Foundation or a UIKit object. This table is larger because the port spells
/// every send itself. See the module doc for the whole difference.
pub const sent_selectors = [sent_selector_count][:0]const u8{
    "defaultCenter",
    "addObserver:selector:name:object:",
    "removeObserver:",
    "alloc",
    "init",
    "window",
    "screen",
    "coordinateSpace",
    "convertPoint:fromCoordinateSpace:",
    "contentScaleFactor",
    "rootViewController",
    "view",
    "class",
    "new",
    "setObject:forKey:",
    "newWithAttributes:",
    "stringWithUTF8String:",
    "numberWithBool:",
    "array",
};

/// How many rows `installed_selectors` holds.
pub const installed_selector_count = 6;

/// The selectors the port installs, in the order `AK/ios/src/subclass.rs:214-230`
/// and `AK/ios/src/adapter.rs:245-275` install them.
///
/// The first five are the view subclass and the sixth is the observer class.
pub const installed_selectors = [installed_selector_count][:0]const u8{
    "superclass",
    "isAccessibilityElement",
    "accessibilityElements",
    "accessibilityHitTest:",
    "didMoveToWindow",
    "accessibilityStatusChanged:",
};

/// How many rows `installed_types` holds.
pub const installed_type_count = 6;

/// The Objective-C type encoding of each installed implementation.
///
/// **Unverified**: no Apple SDK is installed on this host, so `objc/runtime.h`
/// was not read, and no document under `docs/` records an encoding. A wrong
/// encoding is a defect the runtime reports on a device and no Linux compile
/// reports, so each row here needs a check on a host that has the SDK.
pub const installed_types = [installed_type_count][:0]const u8{
    "@:",
    "c@:",
    "@:",
    "v{CGPoint=dd}@:",
    "v@:",
    "v@:@",
};

/// How many implementations the view subclass carries.
pub const view_method_count = 5;

/// How many implementations the observer class carries.
pub const observer_method_count = 1;

/// The selector the `didMoveToWindow` implementation forwards.
///
/// It is the last row of the view subclass, so its index is derived from
/// `view_method_count` rather than written as a number.
const did_move_to_window_selector = installed_selectors[view_method_count - 1];

/// The selector an installed observer receives, the last row of the table.
const observer_selector = installed_selectors[installed_selector_count - observer_method_count];

/// The six implementations the port installs, paired with their encodings.
const installed_methods = [installed_selector_count]InstalledMethod{
    .{
        .name = installed_selectors[0],
        .types = installed_types[0],
        .implementation = @ptrCast(&superclassImplementation),
    },
    .{
        .name = installed_selectors[1],
        .types = installed_types[1],
        .implementation = @ptrCast(&isAccessibilityElementImplementation),
    },
    .{
        .name = installed_selectors[2],
        .types = installed_types[2],
        .implementation = @ptrCast(&accessibilityElementsImplementation),
    },
    .{
        .name = installed_selectors[3],
        .types = installed_types[3],
        .implementation = @ptrCast(&accessibilityHitTestImplementation),
    },
    .{
        .name = installed_selectors[4],
        .types = installed_types[4],
        .implementation = @ptrCast(&didMoveToWindowImplementation),
    },
    .{
        .name = installed_selectors[5],
        .types = installed_types[5],
        .implementation = @ptrCast(&accessibilityStatusChangedImplementation),
    },
};

/// The Objective-C runtime image on an iOS device, as a default for
/// `platform`.
///
/// **Unverified**: no Apple SDK and no iOS device exist on this host, so no
/// `dlopen` of this path has run here. The reader who has one changes this
/// constant, or passes its own path to `platform`. The other spelling the
/// runtime answers to is `/usr/lib/libSystem.dylib`, which exports the same
/// fourteen entry points.
pub const default_objective_c_image_path: []const u8 = "/usr/lib/libobjc.A.dylib";

/// The UIKit image on an iOS device, as a default for `platform`.
///
/// **Unverified**: no Apple SDK and no iOS device exist on this host, so no
/// `dlopen` of this path has run here. The reader who has one changes this
/// constant, or passes its own path to `platform`.
pub const default_uikit_image_path: []const u8 =
    "/System/Library/PrivateFrameworks/UIKit.framework/UIKit";

/// Why an image could not be opened or a symbol could not be resolved.
///
/// Both members leave nothing behind. `platform` closes every image it opened
/// before it returns the error, and no `Owner` exists yet, so a caller that
/// receives either tag owns nothing to release.
pub const ResolveError = error{
    /// The image could not be opened. Every cause `std.DynLib.open` reports
    /// arrives here, so the caller acts on one tag.
    ImageUnavailable,
    /// The image opened but does not export one of the required symbols. No
    /// half-built platform is returned.
    MissingSymbol,
};

comptime {
    @setEvalBranchQuota(200_000);
    // 14 rows, each against the rows that follow it.
    for (objc_entry_points, 0..) |a, i| {
        for (objc_entry_points[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a, b)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate runtime entry point at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a },
                ));
            }
        }
    }
    // 9 rows, and each must be an identifier `uikit.zig` already records.
    for (required_uikit_symbols, 0..) |a, i| {
        for (required_uikit_symbols[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a, b)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate required UIKit symbol at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a },
                ));
            }
        }
        if (uikit.find(a) == null) {
            @compileError(std.fmt.comptimePrint(
                "uikit.identifiers must hold {s}",
                .{a},
            ));
        }
    }
    // 4 rows.
    for (optional_uikit_symbols, 0..) |a, i| {
        for (optional_uikit_symbols[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a.name, b.name)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate optional UIKit symbol at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a.name },
                ));
            }
        }
        if (uikit.find(a.name) == null) {
            @compileError(std.fmt.comptimePrint(
                "uikit.identifiers must hold {s}",
                .{a.name},
            ));
        }
        // The three rows `runtime.weak_constants` also holds must carry the
        // same fallback there, or the two tables would disagree on what an
        // absent symbol means.
        if (runtime.weakConstant(a.name)) |weak| {
            if (weak.fallback != a.fallback) {
                @compileError(std.fmt.comptimePrint(
                    "{s} must carry the fallback runtime.weak_constants records",
                    .{a.name},
                ));
            }
        }
    }
    // 19 rows.
    for (sent_selectors, 0..) |a, i| {
        for (sent_selectors[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a, b)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate message send at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a },
                ));
            }
        }
    }
    // The ten spellings both selector tables share must be recorded as calls.
    for ([_][:0]const u8{
        "defaultCenter",
        "addObserver:selector:name:object:",
        "removeObserver:",
        "window",
        "coordinateSpace",
        "convertPoint:fromCoordinateSpace:",
        "contentScaleFactor",
        "rootViewController",
        "view",
    }) |shared| {
        if (selectors.find(.called, shared) == null) {
            @compileError(std.fmt.comptimePrint(
                "selectors.selectors must record {s} as a called selector",
                .{shared},
            ));
        }
    }
    // The four spellings the module does not send must not be in the sent
    // table, because the module sends none of them.
    for ([_][:0]const u8{
        "name",
        "superclass",
        "getMethodImplementation:",
        "dictionary",
    }) |absent| {
        for (sent_selectors) |row| {
            if (std.mem.eql(u8, row, absent)) {
                @compileError(std.fmt.comptimePrint(
                    "the module sends no {s} message",
                    .{absent},
                ));
            }
        }
    }
    // 6 rows.
    for (installed_selectors, 0..) |a, i| {
        for (installed_selectors[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a, b)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate installed selector at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a },
                ));
            }
        }
    }
    // The four upstream spellings must all be in the port's table.
    for (runtime.runtime_functions) |upstream| {
        var found = false;
        for (objc_entry_points) |port| {
            if (std.mem.eql(u8, upstream, port)) found = true;
        }
        if (!found) {
            @compileError(std.fmt.comptimePrint(
                "the port table must name {s}",
                .{upstream},
            ));
        }
    }
    // The two build functions must together cover the installed table.
    if (installed_selector_count != view_method_count + observer_method_count) {
        @compileError("the two build functions must cover every installed selector");
    }
    // The first five installed selectors are the host view selectors
    // `selectors.zig` records, in the same order.
    var host_view_seen: usize = 0;
    for (selectors.selectors) |selector| {
        if (selector.target != .host_view) continue;
        if (!std.mem.eql(u8, selector.name, installed_selectors[host_view_seen])) {
            @compileError(std.fmt.comptimePrint(
                "installed selector {d} must be the host view selector {s}",
                .{ host_view_seen, selector.name },
            ));
        }
        host_view_seen += 1;
    }
    if (host_view_seen != view_method_count) {
        @compileError("the view subclass installs exactly the host view selectors");
    }
    if (objc_entry_points.len != objc_entry_point_count) {
        @compileError("the array length is the count");
    }
    if (installed_methods.len != installed_selector_count) {
        @compileError("the installed table holds one row per installed selector");
    }
    if (installed_types.len != installed_type_count) {
        @compileError("the encoding table holds one row per installed selector");
    }
}

/// The key every associated owner hangs under, as the runtime takes it.
fn ownerKey() *const anyopaque {
    return &associated_object_key;
}

/// The bindings `ctx` names, or `null` when the caller passed `null`.
///
/// Every entry point answers its empty result for `null` rather than reading
/// through a null pointer, so a call that arrives after `release` degrades
/// instead of crashing.
fn bindings(ctx: ?*anyopaque) ?*Bindings {
    const pointer = ctx orelse return null;
    return @ptrCast(@alignCast(pointer));
}

/// The Objective-C class named `name`, or `null` when the runtime has none.
fn classNamed(ctx: ?*anyopaque, name: [:0]const u8) ?*runtime.ObjClass {
    const current = bindings(ctx) orelse return null;
    return current.get_class(name.ptr);
}

/// The owner associated with `object`, or `null` when it carries none.
fn ownerOf(current: *Bindings, object: ?*runtime.AnyObject) ?*Owner {
    const stored = current.get_associated_object(object, ownerKey()) orelse return null;
    return @ptrCast(@alignCast(stored));
}

/// Sends the message spelled `name` to `receiver` with no further argument.
fn send(
    current: *Bindings,
    receiver: ?*runtime.AnyObject,
    name: [:0]const u8,
) ?*runtime.AnyObject {
    const command = current.sel_register_name(name.ptr) orelse return null;
    return current.msg_send(receiver, command);
}

/// Sends the message spelled `name` to `receiver` with one C string argument,
/// as `+[NSString stringWithUTF8String:]` takes.
///
/// The C string reaches the variadic call through a `?*runtime.AnyObject`
/// because the port resolves `objc_msgSend` as a pointer and a variadic call
/// through a pointer takes each extra argument at its own width.
fn sendCString(
    current: *Bindings,
    receiver: ?*runtime.AnyObject,
    name: [:0]const u8,
    text: [*:0]const u8,
) ?*runtime.AnyObject {
    const command = current.sel_register_name(name.ptr) orelse return null;
    const argument: *runtime.AnyObject = @ptrFromInt(@intFromPtr(text));
    return current.msg_send(receiver, command, argument);
}

/// Sends the message spelled `name` to `receiver` with one object argument.
fn sendOne(
    current: *Bindings,
    receiver: ?*runtime.AnyObject,
    name: [:0]const u8,
    argument: ?*runtime.AnyObject,
) ?*runtime.AnyObject {
    const command = current.sel_register_name(name.ptr) orelse return null;
    return current.msg_send(receiver, command, argument);
}

/// Sends the message spelled `name` to `receiver` with two object arguments.
fn sendTwo(
    current: *Bindings,
    receiver: ?*runtime.AnyObject,
    name: [:0]const u8,
    first: ?*runtime.AnyObject,
    second: ?*runtime.AnyObject,
) ?*runtime.AnyObject {
    const command = current.sel_register_name(name.ptr) orelse return null;
    return current.msg_send(receiver, command, first, second);
}

/// Sends the message spelled `name` to `receiver` with two object arguments,
/// the second of which is the dictionary key.
fn sendOneKeyed(
    current: *Bindings,
    receiver: ?*runtime.AnyObject,
    name: [:0]const u8,
    object: ?*runtime.AnyObject,
    key: ?*runtime.AnyObject,
) ?*runtime.AnyObject {
    const command = current.sel_register_name(name.ptr) orelse return null;
    return current.msg_send(receiver, command, object, key);
}

/// Sends the message spelled `name` to `receiver` with one `BOOL` argument.
///
/// The `objc2` spelling is `NSNumber::new_bool(true)` at
/// `AK/ios/src/event.rs:85`, and the message it reaches is
/// `+[NSNumber numberWithBool:]`.
fn sendBool(
    current: *Bindings,
    receiver: ?*runtime.AnyObject,
    name: [:0]const u8,
    value: bool,
) ?*runtime.AnyObject {
    const command = current.sel_register_name(name.ptr) orelse return null;
    return current.msg_send(receiver, command, value);
}

/// Posts `notification` with `argument` through `UIAccessibilityPostNotification`.
///
/// `notification` is a `UIAccessibilityNotifications` value, which UIKit
/// declares over the platform `int`, and `uikit.Notifications` is `enum(c_int)`,
/// so the port truncates. **Unverified**: no Apple SDK is installed on this
/// host, so `UIKit/UIAccessibilityConstants.h` was not read.
fn postNotificationOf(
    current: *Bindings,
    notification: u64,
    argument: ?*runtime.AnyObject,
) void {
    const tag: uikit.Notifications = @enumFromInt(
        @as(c_int, @bitCast(@as(u32, @truncate(notification)))),
    );
    current.post_notification(tag, argument);
}

/// Whether VoiceOver, Switch Control or Speak Screen is running, as
/// `AK/ios/src/adapter.rs:97-103` asks.
///
/// The three predicates are read in the order the adapter short-circuits on
/// them.
fn anyAssistiveTechRunning(ctx: ?*anyopaque) bool {
    const current = bindings(ctx) orelse return false;
    return current.is_voice_over_running() or
        current.is_switch_control_running() or
        current.is_speak_screen_enabled();
}

/// An instance of `class` carrying `adapter` as its owner.
///
/// `AK/ios/src/adapter.rs:277-291` allocates the observer, sets its ivars and
/// sends `init`. The port sends `alloc` and then `init`, claims the owner, and
/// releases the allocated object only when `init` answered a different object,
/// because `+alloc` hands its reference to whatever `init` returns. The usual
/// path releases nothing, so the returned instance carries the reference `+alloc`
/// produced.
///
/// `remove_status_observer` is the matching release, so the caller must not
/// touch `observer` after it and must not release it a second time.
///
/// Returns `null` when `alloc` refuses, which leaves nothing owned, and when
/// `init` refuses, in which case the runtime has already released the object it
/// was sent to, so this call releases nothing more.
fn observerNew(
    ctx: ?*anyopaque,
    class: *runtime.ObjClass,
    adapter: ?*anyopaque,
) ?*runtime.AnyObject {
    const current = bindings(ctx) orelse return null;
    const allocated = send(current, @ptrCast(class), "alloc") orelse return null;
    const instance = send(current, allocated, "init") orelse return null;
    claimObject(ctx, instance, adapter);
    if (instance != allocated) current.objc_release(allocated);
    return instance;
}

/// Associates an owner with `object`, allocating one.
///
/// The owner carries `adapter` unchanged and the callback table `platform` was
/// given. When the allocator refuses, nothing is associated and the object
/// reads no owner, which is the state `AK/ios/src/subclass.rs:88-96` answers for
/// a view with no adapter. The allocation is recorded in the bindings and
/// `release` frees it, so `release_object` does not free it.
fn claimObject(ctx: ?*anyopaque, object: *runtime.AnyObject, adapter: ?*anyopaque) void {
    const current = bindings(ctx) orelse return;
    const owner = current.gpa.create(Owner) catch return;
    owner.* = .{ .adapter = adapter, .callbacks = current.callbacks };
    current.owners.append(current.gpa, owner) catch {
        current.gpa.destroy(owner);
        return;
    };
    current.set_associated_object(
        object,
        ownerKey(),
        @ptrCast(owner),
        runtime.association_policy_retain_nonatomic,
    );
}

/// Drops the owner associated with `object`, as
/// `AK/ios/src/subclass.rs:313-318` does in the subclassing drop.
///
/// The `Owner` allocation stays in the bindings and `release` frees it, because
/// the association the runtime drops owns nothing the port can free at that
/// moment. After this call the object reads no owner.
fn releaseObject(ctx: ?*anyopaque, object: *runtime.AnyObject) void {
    const current = bindings(ctx) orelse return;
    current.set_associated_object(
        object,
        ownerKey(),
        @as(?*runtime.AnyObject, null),
        runtime.association_policy_retain_nonatomic,
    );
}

/// Whether `object` already carries an owner.
fn objectOwner(ctx: ?*anyopaque, object: *runtime.AnyObject) bool {
    const current = bindings(ctx) orelse return false;
    return current.get_associated_object(object, ownerKey()) != null;
}

/// Registers `observer` for `notification_name`, as
/// `AK/ios/src/adapter.rs:371-379` does.
///
/// The name arrives as a `[:0]const u8`, so the port builds the `NSString`
/// through `+[NSString stringWithUTF8String:]` where upstream passes an already
/// built `NSNotificationName`. A refused message or class leaves the observer
/// unregistered for that name. This call neither retains nor releases the
/// observer; `remove_status_observer` does the matching release.
fn addStatusObserver(
    ctx: ?*anyopaque,
    observer: *runtime.AnyObject,
    notification_name: [:0]const u8,
) void {
    const current = bindings(ctx) orelse return;
    const center_class = classNamed(ctx, runtime.notification_centre_name) orelse return;
    const center = send(current, @ptrCast(center_class), "defaultCenter") orelse return;
    const string_class = classNamed(ctx, "NSString") orelse return;
    const name = sendCString(
        current,
        @ptrCast(string_class),
        "stringWithUTF8String:",
        notification_name.ptr,
    ) orelse return;
    const command = current.sel_register_name(observer_selector.ptr) orelse return;
    const add = current.sel_register_name("addObserver:selector:name:object:") orelse return;
    _ = current.msg_send(
        center,
        add,
        observer,
        command,
        name,
        @as(?*runtime.AnyObject, null),
    );
}

/// Removes `observer` from the notification centre and releases it.
///
/// This is the matching release for the `+alloc` `observer_new` sends, so the
/// caller must not touch `observer` after this call and must not release it a
/// second time. `AK/ios/src/adapter.rs:511` removes the observer and then drops
/// the `Retained<StatusObserver>`. A refused message leaves the observer
/// registered, so the caller must keep it alive.
fn removeStatusObserver(ctx: ?*anyopaque, observer: *runtime.AnyObject) void {
    const current = bindings(ctx) orelse return;
    const center_class = current.get_class(runtime.notification_centre_name.ptr) orelse return;
    const center_command = current.sel_register_name("defaultCenter") orelse return;
    const center = current.msg_send(@ptrCast(center_class), center_command) orelse return;
    const remove = current.sel_register_name("removeObserver:") orelse return;
    _ = current.msg_send(center, remove, observer);
    current.objc_release(observer);
}

/// `[view window]`, at `AK/ios/src/subclass.rs:131`.
fn viewWindow(ctx: ?*anyopaque, view: *runtime.AnyObject) ?*runtime.AnyObject {
    const current = bindings(ctx) orelse return null;
    return send(current, view, "window");
}

/// `[window screen]`, at `AK/ios/src/util.rs:36`.
fn viewScreen(ctx: ?*anyopaque, view: *runtime.AnyObject) ?*runtime.AnyObject {
    const current = bindings(ctx) orelse return null;
    return send(current, view, "screen");
}

/// `[screen coordinateSpace]`, at `AK/ios/src/util.rs:37`.
fn screenCoordinateSpace(ctx: ?*anyopaque, screen: *runtime.AnyObject) ?*runtime.AnyObject {
    const current = bindings(ctx) orelse return null;
    return send(current, screen, "coordinateSpace");
}

/// `[view convertPoint:fromCoordinateSpace:]`, at `AK/ios/src/util.rs:38`.
///
/// The message returns a `CGPoint`, so the port calls the resolved
/// `objc_msgSend` through a second view of the same address whose return type
/// is the struct. With a `null` context the answer is the zero point, because
/// no space was converted into any.
fn viewConvertPoint(
    ctx: ?*anyopaque,
    view: *runtime.AnyObject,
    point: foundation.CGPoint,
    space: *runtime.AnyObject,
) foundation.CGPoint {
    const zero = foundation.CGPoint{ .x = 0, .y = 0 };
    const current = bindings(ctx) orelse return zero;
    const command = current.sel_register_name("convertPoint:fromCoordinateSpace:") orelse
        return zero;
    const convert: *const ConvertPointFn = @ptrCast(current.msg_send);
    return convert(view, command, point, space);
}

/// `[view contentScaleFactor]`, at `AK/ios/src/util.rs:39`.
///
/// The message returns a scalar, so the port calls the resolved `objc_msgSend`
/// through a second view of the same address whose return type is the scalar.
/// With a `null` context the answer is `1`, the factor that leaves a point
/// unchanged.
fn viewContentScaleFactor(ctx: ?*anyopaque, view: *runtime.AnyObject) foundation.CGFloat {
    const current = bindings(ctx) orelse return 1;
    const command = current.sel_register_name("contentScaleFactor") orelse return 1;
    const scale: *const ContentScaleFactorFn = @ptrCast(current.msg_send);
    return scale(view, command);
}

/// `[window rootViewController]` and then `[- view]`, at
/// `AK/ios/src/subclass.rs:295-299`.
fn windowRootView(ctx: ?*anyopaque, window: *runtime.AnyObject) ?*runtime.AnyObject {
    const current = bindings(ctx) orelse return null;
    const controller = send(current, window, "rootViewController") orelse return null;
    return send(current, controller, "view");
}

/// `[view class]`, at `AK/ios/src/subclass.rs:214`.
fn viewClass(ctx: ?*anyopaque, view: *runtime.AnyObject) ?*runtime.ObjClass {
    const current = bindings(ctx) orelse return null;
    const object = send(current, view, "class") orelse return null;
    return @ptrCast(object);
}

/// `[class name]`, at `AK/ios/src/subclass.rs:242`.
///
/// The port calls `class_getName`, which the runtime exports and which answers
/// the same name without a message send. It answers `null` when the runtime
/// refuses the class.
fn className(ctx: ?*anyopaque, class: *runtime.ObjClass) ?[*:0]const u8 {
    const current = bindings(ctx) orelse return null;
    return current.class_get_name(class);
}

/// `[class superclass]`, at `AK/ios/src/subclass.rs:81`.
///
/// The port calls `class_getSuperclass`, which the runtime exports and which
/// answers the same class without a message send. The root class answers
/// `null`.
fn classSuperclass(ctx: ?*anyopaque, class: *runtime.ObjClass) ?*runtime.ObjClass {
    const current = bindings(ctx) orelse return null;
    return current.class_get_superclass(class);
}

/// `objc_getClass(name)`.
fn classWithName(ctx: ?*anyopaque, name: [:0]const u8) ?*runtime.ObjClass {
    return classNamed(ctx, name);
}

/// The class named `name` on `superclass` with the methods in `rows`.
///
/// `AK/ios/src/subclass.rs:199-256` allocates the pair, adds one method per row
/// and registers it. Returns `null` when the pair is refused, which is the same
/// name already taken, and when a method is refused. A refused method leaves an
/// allocated pair that was never registered, and the port resolves no
/// `objc_disposeClassPair`, so that pair stays allocated for the life of the
/// process. `AK/ios/src/subclass.rs:206` panics in that case and the port
/// returns `null` instead.
///
/// `rows` is a comptime-bounded slice of `installed_methods`.
fn buildClass(
    ctx: ?*anyopaque,
    name: [:0]const u8,
    superclass: *runtime.ObjClass,
    rows: []const InstalledMethod,
) ?*runtime.ObjClass {
    const current = bindings(ctx) orelse return null;
    const pair = current.allocate_class_pair(superclass, name.ptr, 0) orelse return null;
    for (rows) |row| {
        const command = current.sel_register_name(row.name.ptr) orelse return null;
        // `class_addMethod` takes the implementation through a mutable pointer
        // and does not write through it, so the row's value is copied into a
        // local the call can name.
        var implementation = row.implementation;
        if (!current.class_add_method(pair, command, &implementation, row.types.ptr)) {
            return null;
        }
    }
    current.register_class_pair(pair);
    return pair;
}

/// The class named `name` on `superclass` with the single
/// `accessibilityStatusChanged:` implementation, at
/// `AK/ios/src/adapter.rs:245-275`.
fn buildObserverClass(
    ctx: ?*anyopaque,
    name: [:0]const u8,
    superclass: *runtime.ObjClass,
) ?*runtime.ObjClass {
    const rows = installed_methods[installed_methods.len - observer_method_count ..];
    return buildClass(ctx, name, superclass, rows);
}

/// The class named `name` on `superclass` with the five implementations
/// `AK/ios/src/subclass.rs:214-230` installs.
fn buildViewSubclass(
    ctx: ?*anyopaque,
    name: [:0]const u8,
    superclass: *runtime.ObjClass,
) ?*runtime.ObjClass {
    const rows = installed_methods[0..view_method_count];
    return buildClass(ctx, name, superclass, rows);
}

/// `object_setClass`, at `AK/ios/src/subclass.rs:262`.
fn setViewClass(ctx: ?*anyopaque, view: *runtime.AnyObject, class: *runtime.ObjClass) void {
    const current = bindings(ctx) orelse return;
    _ = current.object_set_class(view, class);
}

/// `UIAccessibilityPostNotification(notification, argument)`.
fn postNotification(
    ctx: ?*anyopaque,
    notification: u64,
    argument: ?*runtime.AnyObject,
) void {
    const current = bindings(ctx) orelse return;
    postNotificationOf(current, notification, argument);
}

/// The empty array `AK/ios/src/subclass.rs:96-98` returns for a view with no
/// adapter.
fn emptyArray(ctx: ?*anyopaque) ?*runtime.AnyObject {
    const current = bindings(ctx) orelse return null;
    const array_class = current.get_class("NSArray") orelse return null;
    return send(current, @ptrCast(array_class), "array");
}

/// The attributed announcement `AK/ios/src/event.rs:76-104` builds, or `null`
/// when a class or a message is missing.
///
/// The port builds it only when the priority and both attribute keys resolved,
/// because upstream links the queue key and cannot observe its absence. The
/// attributes dictionary comes from `+[NSMutableDictionary new]`, which is the
/// call `AK/ios/src/event.rs:78` makes, and the port releases it after the post
/// rather than holding it.
fn attributedAnnouncement(
    current: *Bindings,
    text: *runtime.AnyObject,
    priority: *runtime.AnyObject,
    priority_key: *runtime.AnyObject,
    queue_key: *runtime.AnyObject,
) ?*runtime.AnyObject {
    const dictionary_class = current.get_class("NSMutableDictionary") orelse return null;
    const attributes = send(current, @ptrCast(dictionary_class), "new") orelse return null;
    defer current.objc_release(attributes);
    const number_class = current.get_class("NSNumber") orelse return null;
    const queued = sendBool(current, @ptrCast(number_class), "numberWithBool:", true) orelse
        return null;
    // Two entries, as `AK/ios/src/event.rs:83-88` writes them: the priority
    // under the announcement priority key, and true under the queue
    // announcement key.
    _ = sendOneKeyed(current, attributes, "setObject:forKey:", priority, priority_key);
    _ = sendOneKeyed(current, attributes, "setObject:forKey:", queued, queue_key);
    const attributed_class = current.get_class("NSAttributedString") orelse return null;
    return sendTwo(
        current,
        @ptrCast(attributed_class),
        "newWithAttributes:",
        text,
        attributes,
    );
}

/// `AK/ios/src/event.rs:76-104`: post the announcement under the announcement
/// tag, attributed when the priority and the keys resolved and plain otherwise.
///
/// `text` is not null-terminated, so the port copies it into an allocation it
/// frees before it returns, because `+[NSString stringWithUTF8String:]` reads a
/// C string. When that allocation is refused the announcement is not posted,
/// because the port has no other way to hand UIKit the text.
fn raiseAnnouncement(ctx: ?*anyopaque, text: []const u8, assertive: bool) void {
    const current = bindings(ctx) orelse return;
    const string_class = current.get_class("NSString") orelse return;
    const terminated = current.gpa.dupeZ(u8, text) catch return;
    defer current.gpa.free(terminated);
    const text_object = sendCString(
        current,
        @ptrCast(string_class),
        "stringWithUTF8String:",
        terminated.ptr,
    ) orelse return;
    const priority = if (assertive) current.priority_high else current.priority_low;
    const priority_key = current.announcement_priority_key;
    const queue_key = current.queue_announcement_key;
    const argument: ?*runtime.AnyObject = if (priority != null and
        priority_key != null and
        queue_key != null)
        attributedAnnouncement(current, text_object, priority.?, priority_key.?, queue_key.?)
    else
        null;
    postNotificationOf(current, current.announcement, argument orelse text_object);
}

/// `AK/ios/src/subclass.rs:80-83`: the superclass of the class the view carried
/// before the port installed its own. A view with no owner answers `null`.
fn superclassImplementation(
    this: ?*runtime.AnyObject,
    command: ?*runtime.Sel,
) ?*runtime.AnyObject {
    _ = command;
    const owner = installedOwner(this) orelse return null;
    const class = owner.callbacks.view_superclass(owner.adapter) orelse return null;
    return @ptrCast(class);
}

/// `AK/ios/src/subclass.rs:87-92`: a view with no adapter answers yes.
///
/// The runtime reads the answer out of the return register as a one-byte
/// `BOOL`, so the implementation returns a one-valued pointer for yes and
/// `null` for no. **Unverified**: no Apple SDK is installed on this host, so
/// `objc/objc.h` was not read.
fn isAccessibilityElementImplementation(
    this: ?*runtime.AnyObject,
    command: ?*runtime.Sel,
) ?*runtime.AnyObject {
    _ = command;
    const owner = installedOwner(this) orelse return @ptrFromInt(1);
    if (owner.callbacks.view_is_accessibility_element(owner.adapter)) {
        return @ptrFromInt(1);
    }
    return null;
}

/// `AK/ios/src/subclass.rs:95-100`: a view with no adapter answers an empty
/// array, which the caller does not own.
fn accessibilityElementsImplementation(
    this: ?*runtime.AnyObject,
    command: ?*runtime.Sel,
) ?*runtime.AnyObject {
    _ = command;
    const current = installedBindings() orelse return null;
    const owner = ownerOf(current, this) orelse return emptyArray(current);
    return owner.callbacks.view_accessibility_elements(owner.adapter);
}

/// `AK/ios/src/subclass.rs:103-112`: a view with no adapter answers nothing.
fn accessibilityHitTestImplementation(
    this: ?*runtime.AnyObject,
    command: ?*runtime.Sel,
    point: foundation.CGPoint,
) ?*runtime.AnyObject {
    _ = command;
    const owner = installedOwner(this) orelse return null;
    return owner.callbacks.view_accessibility_hit_test(owner.adapter, point);
}

/// `AK/ios/src/subclass.rs:116-135`: forward to the class the view carried,
/// then report the move.
///
/// The order is upstream's at `AK/ios/src/subclass.rs:120-133` and the reason is
/// stated there: the previous implementation runs before the adapter activates.
/// The port asks `class_getMethodImplementation` whether the previous class has
/// the method and sends `objc_msgSendSuper2` to that class when it does, because
/// the `objc2` macro upstream sends through is not available to the port. A view
/// with no owner returns at once, and so does a view with no window.
fn didMoveToWindowImplementation(
    this: ?*runtime.AnyObject,
    command: ?*runtime.Sel,
) ?*runtime.AnyObject {
    _ = command;
    const current = installedBindings() orelse return null;
    const owner = ownerOf(current, this) orelse return null;
    const previous = owner.callbacks.view_previous_class(owner.adapter) orelse return null;
    const moved = current.sel_register_name(did_move_to_window_selector.ptr) orelse return null;
    if (current.class_get_method_implementation(previous, moved) != null) {
        var super = ObjcSuper{ .receiver = this, .super_class = previous };
        _ = current.msg_send_super2(@ptrCast(&super), moved);
    }
    if (send(current, this, "window") == null) return null;
    owner.callbacks.view_did_move_to_window(owner.adapter);
    return null;
}

/// `AK/ios/src/adapter.rs:266-272`: the notification argument is ignored, which
/// is what upstream does at `AK/ios/src/subclass.rs:268`.
fn accessibilityStatusChangedImplementation(
    this: ?*runtime.AnyObject,
    command: ?*runtime.Sel,
    notification: ?*runtime.AnyObject,
) ?*runtime.AnyObject {
    _ = command;
    _ = notification;
    const owner = installedOwner(this) orelse return null;
    owner.callbacks.accessibility_status_changed(owner.adapter);
    return null;
}

/// The bindings the six installed implementations send through.
///
/// The Objective-C ABI hands an implementation `self` and `_cmd` and nothing
/// else, so there is no parameter to thread and Zig has no closure to bake one
/// into. This is the one place in the file where a file-scope `var` is the only
/// route, and the module doc says so. `platform` writes it after it resolves
/// every required symbol and `release` clears it, so an implementation reached
/// between those two calls finds the bindings that installed it. Every other
/// route in this module takes the context as a parameter.
///
/// One `Platform` may be live at a time, because a second `platform` call
/// shadows the first here and in the class pairs the runtime holds.
var installed: ?*Bindings = null;

/// The bindings `platform` installed, or `null` when none is live.
fn installedBindings() ?*Bindings {
    return installed;
}

/// The owner associated with `this`, or `null` when it carries none.
///
/// An installed implementation is reached through `self`, so it has no context
/// parameter. The owner is the only thing `self` names that points at the
/// caller's adapter, and reading it goes through the bindings.
fn installedOwner(this: ?*runtime.AnyObject) ?*Owner {
    const current = installedBindings() orelse return null;
    return ownerOf(current, this);
}

/// Resolves one required symbol in `image`, or answers `error.MissingSymbol`.
fn required(comptime T: type, image: *std.DynLib, name: [:0]const u8) ResolveError!T {
    return image.lookup(T, name) orelse error.MissingSymbol;
}

/// Reads one `NSString` constant through the address its lookup answered, or
/// answers `null` when the image does not export it.
///
/// This is the `AK/ios/src/util.rs:88-95` route: the lookup answers the address
/// of the storage, and the value is read once through that address.
fn readStringConstant(image: *std.DynLib, name: [:0]const u8) ?*runtime.AnyObject {
    const address = image.lookup(*const ?*runtime.AnyObject, name) orelse return null;
    return address.*;
}

/// Opens both images, resolves every required symbol and returns the platform.
///
/// The caller must release the answer with `release`, once, and that call frees
/// both images, the bindings allocation and every `Owner` `claim_object`
/// allocated. Nothing survives either error: every image opened before the
/// failure is closed on the way out, and no `Owner` exists yet. `null` answers a
/// refused allocation, which is the only outcome this function has that is
/// neither a success nor one of the two error tags.
///
/// `gpa` owns every later allocation and the caller owns it. `callbacks` is
/// copied into the bindings and is never released. Both image paths must stay
/// valid for the duration of the call only, because `std.DynLib.open` copies
/// what it needs and the handle it returns holds the image open.
///
/// The answer's `context` field is the pointer every entry point takes as its
/// first argument. One `Platform` may be live at a time, because the six
/// installed implementations read their bindings through the owner `self`
/// carries, so two live platforms would install implementations that answer
/// through whichever owner was allocated last.
pub fn platform(
    gpa: std.mem.Allocator,
    objective_c_image_path: []const u8,
    uikit_image_path: []const u8,
    callbacks: Callbacks,
) ResolveError!?Platform {
    var objective_c_image = std.DynLib.open(objective_c_image_path) catch
        return error.ImageUnavailable;
    errdefer objective_c_image.close();
    var uikit_image = std.DynLib.open(uikit_image_path) catch
        return error.ImageUnavailable;
    errdefer uikit_image.close();

    const resolved = gpa.create(Bindings) catch return null;
    errdefer gpa.destroy(resolved);

    resolved.* = .{
        .gpa = gpa,
        .objective_c_image = objective_c_image,
        .uikit_image = uikit_image,
        .callbacks = callbacks,
        .owners = .empty,
        .get_class = try required(*const ObjCGetClassFn, &objective_c_image, "objc_getClass"),
        .allocate_class_pair = try required(
            *const ObjCAllocateClassPairFn,
            &objective_c_image,
            "objc_allocateClassPair",
        ),
        .register_class_pair = try required(
            *const ObjCRegisterClassPairFn,
            &objective_c_image,
            "objc_registerClassPair",
        ),
        .msg_send = try required(*const MsgSendFn, &objective_c_image, "objc_msgSend"),
        .msg_send_super2 = try required(
            *const MsgSendSuper2Fn,
            &objective_c_image,
            "objc_msgSendSuper2",
        ),
        .class_get_name = try required(*const ClassGetNameFn, &objective_c_image, "class_getName"),
        .class_get_superclass = try required(
            *const ClassGetSuperclassFn,
            &objective_c_image,
            "class_getSuperclass",
        ),
        .class_get_method_implementation = try required(
            *const ClassGetMethodImplementationFn,
            &objective_c_image,
            "class_getMethodImplementation",
        ),
        .class_add_method = try required(
            *const runtime.ClassAddMethodFn,
            &objective_c_image,
            "class_addMethod",
        ),
        .get_associated_object = try required(
            *const runtime.ObjCGetAssociatedObjectFn,
            &objective_c_image,
            "objc_getAssociatedObject",
        ),
        .set_associated_object = try required(
            *const runtime.ObjCSetAssociatedObjectFn,
            &objective_c_image,
            "objc_setAssociatedObject",
        ),
        .object_set_class = try required(
            *const runtime.ObjectSetClassFn,
            &objective_c_image,
            "object_setClass",
        ),
        .sel_register_name = try required(
            *const SelRegisterNameFn,
            &objective_c_image,
            "sel_registerName",
        ),
        .objc_release = try required(*const ObjCReleaseFn, &objective_c_image, "objc_release"),
        .is_voice_over_running = try required(
            *const uikit.IsRunningFn,
            &uikit_image,
            "UIAccessibilityIsVoiceOverRunning",
        ),
        .is_switch_control_running = try required(
            *const uikit.IsRunningFn,
            &uikit_image,
            "UIAccessibilityIsSwitchControlRunning",
        ),
        .is_speak_screen_enabled = try required(
            *const uikit.IsRunningFn,
            &uikit_image,
            "UIAccessibilityIsSpeakScreenEnabled",
        ),
        .post_notification = try required(
            *const uikit.PostNotificationFn,
            &uikit_image,
            "UIAccessibilityPostNotification",
        ),
        .convert_frame_to_screen = try required(
            *const uikit.ConvertFrameToScreenCoordinatesFn,
            &uikit_image,
            "UIAccessibilityConvertFrameToScreenCoordinates",
        ),
        // Each tag arrives as the address of the storage, so the value is read
        // once through that address, which is what `AK/ios/src/util.rs:78-86`
        // does for the toggle trait.
        .screen_changed = (try required(
            *const u64,
            &uikit_image,
            "UIAccessibilityScreenChangedNotification",
        )).*,
        .layout_changed = (try required(
            *const u64,
            &uikit_image,
            "UIAccessibilityLayoutChangedNotification",
        )).*,
        .announcement = (try required(
            *const u64,
            &uikit_image,
            "UIAccessibilityAnnouncementNotification",
        )).*,
        .priority_high = readStringConstant(&uikit_image, optional_uikit_symbols[0].name),
        .priority_low = readStringConstant(&uikit_image, optional_uikit_symbols[1].name),
        .announcement_priority_key = readStringConstant(
            &uikit_image,
            optional_uikit_symbols[2].name,
        ),
        .queue_announcement_key = readStringConstant(
            &uikit_image,
            optional_uikit_symbols[3].name,
        ),
    };

    installed = resolved;
    return platformValue(resolved);
}

/// The `Platform` value over `resolved`.
///
/// Every entry point takes `resolved` as its first parameter, so the value holds
/// the same pointer twice: once in `context` and once inside each call.
fn platformValue(resolved: ?*Bindings) Platform {
    const context: ?*anyopaque = if (resolved) |value| value else null;
    return .{
        .context = context,
        .notification_tags = .{
            .screen_changed = if (resolved) |value| value.screen_changed else 0,
            .layout_changed = if (resolved) |value| value.layout_changed else 0,
            .announcement = if (resolved) |value| value.announcement else 0,
        },
        .any_assistive_tech_running = anyAssistiveTechRunning,
        .observer_new = observerNew,
        .add_status_observer = addStatusObserver,
        .remove_status_observer = removeStatusObserver,
        .claim_object = claimObject,
        .release_object = releaseObject,
        .object_owner = objectOwner,
        .view_window = viewWindow,
        .view_screen = viewScreen,
        .screen_coordinate_space = screenCoordinateSpace,
        .view_convert_point = viewConvertPoint,
        .view_content_scale_factor = viewContentScaleFactor,
        .window_root_view = windowRootView,
        .view_class = viewClass,
        .class_name = className,
        .class_superclass = classSuperclass,
        .class_with_name = classWithName,
        .build_observer_class = buildObserverClass,
        .build_view_subclass = buildViewSubclass,
        .set_view_class = setViewClass,
        .post_notification = postNotification,
        .raise_announcement = raiseAnnouncement,
        .empty_array = emptyArray,
        .release = release,
    };
}

/// Closes both images and frees the bindings, the `Owner` allocations and the
/// bindings allocation itself.
///
/// `platform` installs this as the `release` field of the table it returns, and
/// a caller reaches it through that field.
///
/// The bindings are freed, so a second call on the same `ctx` is a
/// use-after-free, and every other entry point of the table answers its empty
/// result for a `null` context afterwards. The caller must not free any
/// `Owner` itself. The allocator `platform` was given is not released here,
/// because the caller owns it. A `null` context owns nothing and this call does
/// nothing.
pub fn release(ctx: ?*anyopaque) void {
    const current = bindings(ctx) orelse return;
    // The bound is `current.owners.items.len`, which is the number of
    // `claim_object` calls that allocated an owner. The walk runs once.
    for (current.owners.items) |owner| current.gpa.destroy(owner);
    current.owners.deinit(current.gpa);
    current.objective_c_image.close();
    current.uikit_image.close();
    if (installed == current) installed = null;
    current.gpa.destroy(current);
}

// =============================================================================
// Tests
// =============================================================================

test "the table holds the 14 Objective-C entry points the port resolves" {
    try testing.expectEqual(@as(usize, 14), objc_entry_points.len);
    try testing.expectEqual(@as(usize, 14), objc_entry_point_count);
    for ([_][:0]const u8{
        "class_addMethod",
        "class_getMethodImplementation",
        "class_getName",
        "class_getSuperclass",
        "objc_allocateClassPair",
        "objc_getAssociatedObject",
        "objc_getClass",
        "objc_msgSend",
        "objc_msgSendSuper2",
        "objc_release",
        "objc_registerClassPair",
        "objc_setAssociatedObject",
        "object_setClass",
        "sel_registerName",
    }) |name| {
        try testing.expect(hasEntryPoint(name));
    }
}

test "no entry point spelling appears twice" {
    try testing.expectEqual(pairCount(objc_entry_point_count), comparedPairs(objc_entry_points));
}

test "the four upstream runtime spellings are all in the port table" {
    try testing.expectEqual(@as(usize, 4), runtime.runtime_functions.len);
    for (runtime.runtime_functions) |upstream| {
        try testing.expect(hasEntryPoint(upstream));
    }
}

test "the required UIKit table holds the eight symbols the port cannot do without" {
    try testing.expectEqual(required_uikit_symbol_count, required_uikit_symbols.len);
    try testing.expectEqual(@as(usize, 8), required_uikit_symbol_count);
    for ([_][:0]const u8{
        "UIAccessibilityIsVoiceOverRunning",
        "UIAccessibilityIsSwitchControlRunning",
        "UIAccessibilityIsSpeakScreenEnabled",
        "UIAccessibilityPostNotification",
        "UIAccessibilityConvertFrameToScreenCoordinates",
        "UIAccessibilityScreenChangedNotification",
        "UIAccessibilityLayoutChangedNotification",
        "UIAccessibilityAnnouncementNotification",
    }) |name| {
        try testing.expect(hasRequiredSymbol(name));
        try testing.expect(uikit.find(name) != null);
    }
}

test "the required table is three predicates, one post, one convert and three tags" {
    var predicates: usize = 0;
    var posting: usize = 0;
    var type_identifier: usize = 0;
    var posted: usize = 0;
    for (required_uikit_symbols) |name| {
        const identifier = uikit.find(name).?;
        switch (identifier.kind) {
            .predicate => predicates += 1,
            .posting_function => posting += 1,
            .type_identifier => type_identifier += 1,
            .posted_notification => posted += 1,
            else => {},
        }
    }
    try testing.expectEqual(@as(usize, 3), predicates);
    try testing.expectEqual(@as(usize, 1), posting);
    try testing.expectEqual(@as(usize, 1), type_identifier);
    try testing.expectEqual(@as(usize, 3), posted);
}

test "no required symbol spelling appears twice" {
    try testing.expectEqual(
        pairCount(required_uikit_symbol_count),
        comparedPairs(required_uikit_symbols),
    );
}

test "the three notification tags are resolved as data symbols, never as numbers" {
    for ([_][:0]const u8{
        "UIAccessibilityScreenChangedNotification",
        "UIAccessibilityLayoutChangedNotification",
        "UIAccessibilityAnnouncementNotification",
    }) |tag| {
        try testing.expect(hasRequiredSymbol(tag));
        try testing.expectEqual(uikit.Kind.posted_notification, uikit.find(tag).?.kind);
    }
}

test "the optional UIKit table records the fallbacks runtime.weak_constants holds" {
    try testing.expectEqual(@as(usize, 4), optional_uikit_symbols.len);
    try testing.expectEqualStrings(
        "UIAccessibilityPriorityHigh",
        optional_uikit_symbols[0].name,
    );
    try testing.expectEqual(
        runtime.Fallback.downgrade_announcement,
        optional_uikit_symbols[0].fallback,
    );
    try testing.expectEqualStrings("UIAccessibilityPriorityLow", optional_uikit_symbols[1].name);
    try testing.expectEqual(
        runtime.Fallback.downgrade_announcement,
        optional_uikit_symbols[1].fallback,
    );
    try testing.expectEqualStrings(
        "UIAccessibilitySpeechAttributeAnnouncementPriority",
        optional_uikit_symbols[2].name,
    );
    try testing.expectEqual(
        runtime.Fallback.plain_string_announcement,
        optional_uikit_symbols[2].fallback,
    );
    try testing.expectEqualStrings(
        "UIAccessibilitySpeechAttributeQueueAnnouncement",
        optional_uikit_symbols[3].name,
    );
    try testing.expectEqual(
        runtime.Fallback.plain_string_announcement,
        optional_uikit_symbols[3].fallback,
    );
    // The three rows `runtime.weak_constants` also holds must carry the same
    // fallback there.
    var shared: usize = 0;
    for (optional_uikit_symbols) |row| {
        if (runtime.weakConstant(row.name)) |weak| {
            try testing.expectEqual(weak.fallback, row.fallback);
            shared += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), shared);
}

test "the module resolves no trait, so the no_trait fallback is not one of its rows" {
    for (optional_uikit_symbols) |row| {
        try testing.expect(row.fallback != .no_trait);
    }
    // The fourth row of `runtime.weak_constants` is the toggle trait.
    try testing.expectEqual(runtime.Fallback.no_trait, runtime.weakConstant(
        "UIAccessibilityTraitToggleButton",
    ).?.fallback);
}

test "the sent selector table pins every spelling the port sends" {
    try testing.expectEqual(@as(usize, 19), sent_selectors.len);
    for ([_][:0]const u8{
        "defaultCenter",
        "addObserver:selector:name:object:",
        "removeObserver:",
        "alloc",
        "init",
        "window",
        "screen",
        "coordinateSpace",
        "convertPoint:fromCoordinateSpace:",
        "contentScaleFactor",
        "rootViewController",
        "view",
        "class",
        "new",
        "setObject:forKey:",
        "newWithAttributes:",
        "stringWithUTF8String:",
        "numberWithBool:",
        "array",
    }) |name| {
        try testing.expect(hasSentSelector(name));
    }
}

test "no sent selector spelling appears twice" {
    try testing.expectEqual(pairCount(sent_selector_count), comparedPairs(sent_selectors));
}

test "the nine spellings both selector tables share are calls in selectors.zig" {
    try testing.expectEqual(@as(usize, 36), selectors.selector_count);
    try testing.expectEqual(@as(usize, 12), selectors.countOf(.called));
    for ([_][:0]const u8{
        "defaultCenter",
        "addObserver:selector:name:object:",
        "removeObserver:",
        "window",
        "coordinateSpace",
        "convertPoint:fromCoordinateSpace:",
        "contentScaleFactor",
        "rootViewController",
        "view",
    }) |shared| {
        try testing.expect(selectors.find(.called, shared) != null);
        try testing.expect(hasSentSelector(shared));
    }
}

test "the module sends none of the four spellings it reaches another way" {
    for ([_][:0]const u8{
        "name",
        "superclass",
        "getMethodImplementation:",
        "dictionary",
    }) |absent| {
        try testing.expect(!hasSentSelector(absent));
    }
    // Two of them are reached through the runtime functions the table resolves,
    // and one is an installed selector.
    try testing.expect(hasEntryPoint("class_getName"));
    try testing.expect(hasEntryPoint("class_getMethodImplementation"));
    try testing.expect(hasInstalledSelector("superclass"));
}

test "the installed selector table pins every spelling the port installs" {
    try testing.expectEqual(@as(usize, 6), installed_selectors.len);
    for ([_][:0]const u8{
        "superclass",
        "isAccessibilityElement",
        "accessibilityElements",
        "accessibilityHitTest:",
        "didMoveToWindow",
        "accessibilityStatusChanged:",
    }) |name| {
        try testing.expect(hasInstalledSelector(name));
    }
}

test "no installed selector spelling appears twice" {
    try testing.expectEqual(
        pairCount(installed_selector_count),
        comparedPairs(installed_selectors),
    );
}

test "the encoding table pins every type encoding the port installs" {
    try testing.expectEqual(@as(usize, 6), installed_types.len);
    for ([_][:0]const u8{
        "@:",
        "c@:",
        "@:",
        "v{CGPoint=dd}@:",
        "v@:",
        "v@:@",
    }) |encoding| {
        var found = false;
        for (installed_types) |row| {
            if (std.mem.eql(u8, row, encoding)) found = true;
        }
        try testing.expect(found);
    }
}

test "each installed row carries its own encoding and its own implementation" {
    try testing.expectEqual(installed_selector_count, installed_methods.len);
    for (installed_methods, 0..) |row, i| {
        try testing.expectEqualStrings(installed_selectors[i], row.name);
        try testing.expectEqualStrings(installed_types[i], row.types);
    }
    var distinct: usize = 0;
    for (installed_methods, 0..) |a, i| {
        for (installed_methods[0..i]) |b| {
            if (a.implementation != b.implementation) distinct += 1;
        }
    }
    try testing.expectEqual(pairCount(installed_selector_count), distinct);
}

test "the two build functions cover the table between them" {
    try testing.expectEqual(@as(usize, 5), view_method_count);
    try testing.expectEqual(@as(usize, 1), observer_method_count);
    try testing.expectEqual(
        installed_selector_count,
        view_method_count + observer_method_count,
    );
    try testing.expectEqualStrings("didMoveToWindow", did_move_to_window_selector);
    try testing.expectEqualStrings("accessibilityStatusChanged:", observer_selector);
}

test "the five installed view selectors are the host view selectors selectors.zig records" {
    var checked: usize = 0;
    for (selectors.selectors) |selector| {
        if (selector.target != .host_view) continue;
        try testing.expectEqualStrings(selector.name, installed_selectors[checked]);
        checked += 1;
    }
    try testing.expectEqual(view_method_count, checked);
}

test "the two default image paths are the strings the module doc names" {
    try testing.expectEqualStrings("/usr/lib/libobjc.A.dylib", default_objective_c_image_path);
    try testing.expectEqualStrings(
        "/System/Library/PrivateFrameworks/UIKit.framework/UIKit",
        default_uikit_image_path,
    );
}

test "ResolveError has exactly the two members" {
    const members = @typeInfo(ResolveError).error_set orelse
        &[_]builtin.Type.Error{};
    try testing.expectEqual(@as(usize, 2), members.len);
    inline for (members, 0..) |member, i| {
        const expected = [_][:0]const u8{ "ImageUnavailable", "MissingSymbol" };
        try testing.expectEqualStrings(expected[i], member.name);
    }
}

test "NotificationTags carries the three fields in the frozen order" {
    try expectFieldNames(NotificationTags, &.{
        "screen_changed",
        "layout_changed",
        "announcement",
    });
}

test "Callbacks carries the seven fields in the frozen order" {
    try expectFieldNames(Callbacks, &.{
        "view_superclass",
        "view_is_accessibility_element",
        "view_accessibility_elements",
        "view_accessibility_hit_test",
        "view_previous_class",
        "view_did_move_to_window",
        "accessibility_status_changed",
    });
}

test "Platform carries the frozen field names in the frozen order" {
    try expectFieldNames(Platform, &.{
        "context",
        "notification_tags",
        "any_assistive_tech_running",
        "observer_new",
        "add_status_observer",
        "remove_status_observer",
        "claim_object",
        "release_object",
        "object_owner",
        "view_window",
        "view_screen",
        "screen_coordinate_space",
        "view_convert_point",
        "view_content_scale_factor",
        "window_root_view",
        "view_class",
        "class_name",
        "class_superclass",
        "class_with_name",
        "build_observer_class",
        "build_view_subclass",
        "set_view_class",
        "post_notification",
        "raise_announcement",
        "empty_array",
        "release",
    });
}

test "every Platform entry point takes the context as its first parameter" {
    var entry_points: usize = 0;
    inline for (@typeInfo(Platform).@"struct".fields) |field| {
        const info = @typeInfo(field.type);
        if (info != .pointer) continue;
        switch (@typeInfo(info.pointer.child)) {
            .@"fn" => |function| {
                entry_points += 1;
                try testing.expect(function.params.len >= 1);
                try testing.expectEqualStrings(
                    "?*anyopaque",
                    @typeName(function.params[0].type.?),
                );
            },
            else => {},
        }
    }
    // 24 entry points, and the release is one of them, so it reaches the
    // bindings the same way every other entry point does.
    // `context` and `notification_tags` are the other two fields, and neither
    // is a pointer to a function.
    try testing.expectEqual(@as(usize, 24), entry_points);
    try testing.expectEqual(@as(usize, 26), @typeInfo(Platform).@"struct".fields.len);
}

test "Owner carries the two fields the installed implementations read" {
    try expectFieldNames(Owner, &.{ "adapter", "callbacks" });
}

test "InstalledMethod carries the three fields the class builder reads" {
    try expectFieldNames(InstalledMethod, &.{
        "name",
        "types",
        "implementation",
    });
}

test "the objc_super layout is the one objc/message.h declares" {
    const sample = std.mem.zeroes(ObjcSuper);
    try testing.expectEqual(@sizeOf(?*runtime.AnyObject), @sizeOf(@TypeOf(sample.receiver)));
    try testing.expectEqual(@sizeOf(?*runtime.ObjClass), @sizeOf(@TypeOf(sample.super_class)));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ObjcSuper, "receiver"));
    try testing.expectEqual(@sizeOf(?*runtime.AnyObject), @offsetOf(ObjcSuper, "super_class"));
    try testing.expectEqual(@as(usize, 2 * @sizeOf(usize)), @sizeOf(ObjcSuper));
}

test "platform against a path that does not exist answers ImageUnavailable and leaks nothing" {
    try testing.expectError(
        error.ImageUnavailable,
        platform(
            testing.allocator,
            "/nonexistent/libobjc.A.dylib",
            "/nonexistent/UIKit",
            emptyCallbacks(),
        ),
    );
}

test "the table release answers for a platform with no bindings and changes nothing" {
    const table = platformValue(null);
    // The entry the table carries is the path a caller takes, and a `null`
    // context is the whole answer.
    try testing.expectEqual(@as(?*anyopaque, null), table.context);
    table.release(table.context);
    release(null);
}

test "every entry point answers its empty result for a null context" {
    const absent = null;
    try testing.expectEqual(false, anyAssistiveTechRunning(absent));
    try testing.expectEqual(@as(?*runtime.AnyObject, null), viewWindow(absent, unusedPointer()));
    try testing.expectEqual(@as(?*runtime.AnyObject, null), viewScreen(absent, unusedPointer()));
    try testing.expectEqual(
        @as(?*runtime.AnyObject, null),
        screenCoordinateSpace(absent, unusedPointer()),
    );
    try testing.expectEqual(
        @as(?*runtime.AnyObject, null),
        windowRootView(absent, unusedPointer()),
    );
    try testing.expectEqual(@as(?*runtime.ObjClass, null), viewClass(absent, unusedPointer()));
    try testing.expectEqual(@as(?*runtime.AnyObject, null), emptyArray(absent));
    try testing.expectEqual(@as(?*runtime.ObjClass, null), classWithName(absent, "UIView"));
    try testing.expectEqual(@as(?[*:0]const u8, null), className(absent, unusedClass()));
    try testing.expectEqual(@as(?*runtime.ObjClass, null), classSuperclass(absent, unusedClass()));
    try testing.expectEqual(
        foundation.CGPoint{ .x = 0, .y = 0 },
        viewConvertPoint(absent, unusedPointer(), .{ .x = 1, .y = 2 }, unusedPointer()),
    );
    try testing.expectEqual(
        @as(foundation.CGFloat, 1),
        viewContentScaleFactor(absent, unusedPointer()),
    );
    try testing.expect(!objectOwner(absent, unusedPointer()));
    try testing.expectEqual(
        @as(?*runtime.AnyObject, null),
        observerNew(absent, unusedClass(), null),
    );
    try testing.expectEqual(
        @as(?*runtime.ObjClass, null),
        buildViewSubclass(absent, "AK", unusedClass()),
    );
    try testing.expectEqual(
        @as(?*runtime.ObjClass, null),
        buildObserverClass(absent, "AK", unusedClass()),
    );
}

test "the void entry points do nothing for a null context" {
    const absent = null;
    const object = unusedPointer();
    claimObject(absent, object, null);
    releaseObject(absent, object);
    setViewClass(absent, object, unusedClass());
    addStatusObserver(absent, object, "AKNotification");
    removeStatusObserver(absent, object);
    postNotification(absent, 0, null);
    raiseAnnouncement(absent, "text", true);
}

test "every installed implementation answers the upstream empty answer with no owner" {
    // `self` carries no owner, so every one of the six answers what
    // `AK/ios/src/subclass.rs` answers for a view with no adapter, and none of
    // them reaches the runtime because none of them has bindings to reach.
    try testing.expectEqual(
        @as(?*runtime.AnyObject, null),
        superclassImplementation(unusedPointer(), null),
    );
    try testing.expectEqual(
        @as(?*runtime.AnyObject, @ptrFromInt(1)),
        isAccessibilityElementImplementation(unusedPointer(), null),
    );
    try testing.expectEqual(
        @as(?*runtime.AnyObject, null),
        accessibilityElementsImplementation(unusedPointer(), null),
    );
    try testing.expectEqual(
        @as(?*runtime.AnyObject, null),
        accessibilityHitTestImplementation(unusedPointer(), null, .{ .x = 0, .y = 0 }),
    );
    try testing.expectEqual(
        @as(?*runtime.AnyObject, null),
        didMoveToWindowImplementation(unusedPointer(), null),
    );
    try testing.expectEqual(
        @as(?*runtime.AnyObject, null),
        accessibilityStatusChangedImplementation(unusedPointer(), null, null),
    );
}

test "the owner key is a const byte reached through its address" {
    const first = ownerKey();
    const second = ownerKey();
    try testing.expectEqual(@intFromPtr(first), @intFromPtr(second));
    try testing.expectEqual(associated_object_key, 0);
    try testing.expectEqualStrings("NSNotificationCenter", runtime.notification_centre_name);
}

test "no platform is installed before a successful platform call" {
    // The one file-scope `var` holds nothing until `platform` has resolved every
    // required symbol, so an installed implementation reached before that
    // answers as upstream answers for a view with no adapter.
    try testing.expectEqual(@as(?*Bindings, null), installedBindings());
    try testing.expectEqual(@as(?*Owner, null), installedOwner(unusedPointer()));
}

/// A pointer the entry points can name in a null-context test. It is never
/// dereferenced, because every entry point returns before it reaches the
/// Objective-C runtime when the context is `null`.
fn unusedPointer() *runtime.AnyObject {
    return @ptrFromInt(1);
}

/// A class pointer the entry points can name in a null-context test.
fn unusedClass() *runtime.ObjClass {
    return @ptrFromInt(1);
}

/// The callbacks a test hands to `platform` when the call must fail before it
/// reads them.
fn emptyCallbacks() Callbacks {
    return .{
        .view_superclass = emptySuperclass,
        .view_is_accessibility_element = emptyBool,
        .view_accessibility_elements = emptyObject,
        .view_accessibility_hit_test = emptyHitTest,
        .view_previous_class = emptySuperclass,
        .view_did_move_to_window = emptyVoid,
        .accessibility_status_changed = emptyVoid,
    };
}

fn emptySuperclass(adapter: ?*anyopaque) ?*runtime.ObjClass {
    _ = adapter;
    return null;
}

fn emptyBool(adapter: ?*anyopaque) bool {
    _ = adapter;
    return false;
}

fn emptyObject(adapter: ?*anyopaque) ?*runtime.AnyObject {
    _ = adapter;
    return null;
}

fn emptyHitTest(adapter: ?*anyopaque, point: foundation.CGPoint) ?*runtime.AnyObject {
    _ = adapter;
    _ = point;
    return null;
}

fn emptyVoid(adapter: ?*anyopaque) void {
    _ = adapter;
}

/// How many row pairs a table of `count` rows holds.
fn pairCount(count: usize) usize {
    return count * (count - 1) / 2;
}

/// How many distinct row pairs `table` holds, each compared one at a time.
fn comparedPairs(table: anytype) usize {
    var compared: usize = 0;
    for (table, 0..) |a, i| {
        for (table[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a, b)) continue;
            compared += 1;
        }
    }
    return compared;
}

/// Whether the port table names `name`.
fn hasEntryPoint(name: []const u8) bool {
    for (objc_entry_points) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// Whether the required UIKit table names `name`.
fn hasRequiredSymbol(name: []const u8) bool {
    for (required_uikit_symbols) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// Whether the sent selector table names `name`.
fn hasSentSelector(name: []const u8) bool {
    for (sent_selectors) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// Whether the installed selector table names `name`.
fn hasInstalledSelector(name: []const u8) bool {
    for (installed_selectors) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// Checks that the fields of `T` are exactly `expected`, in order.
fn expectFieldNames(comptime T: type, comptime expected: []const [:0]const u8) !void {
    const fields = @typeInfo(T).@"struct".fields;
    try testing.expectEqual(expected.len, fields.len);
    inline for (fields, 0..) |field, i| {
        if (i < expected.len) try testing.expectEqualStrings(expected[i], field.name);
    }
}