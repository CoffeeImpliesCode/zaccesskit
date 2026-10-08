/* Rung 4: AppKit's SDK headers contain unconditional Objective-C interfaces,
 * NSString handles and generic NSDictionary types that translate-C cannot express.
 * This file lets the Objective-C compiler type-check precisely two C calls and
 * fourteen borrowed NSString constant getters against the selected SDK. All
 * runtime C APIs remain generated bindings; no provider behavior, allocation
 * or state lives here. NSAttributedStringKey and NSAccessibilityFontAttributeKey
 * are NSString typedefs, not representable SDK C declarations for translate-C.
 * SDK source: AppKit/NSAccessibility.h and AppKit/NSAccessibilityConstants.h.
 * Primary API: https://developer.apple.com/documentation/appkit/nsaccessibility
 * Apple SDK declaration snapshot (eleven text globals at lines 130-189):
 * https://api.github.com/repos/phracker/MacOSX-SDKs/git/blobs/d46725739a34f180d2d7913e0ca96a50c783a72d
 */
#include "foundation.h"
#import <AppKit/NSAccessibility.h>
#include <stddef.h>

/* Reached SDK checks for the portable Zig records and scalar message ABI. */
_Static_assert(sizeof(NSUInteger) == sizeof(size_t), "NSUInteger pointer-width ABI");
_Static_assert(sizeof(NSStringEncoding) == sizeof(size_t), "NSStringEncoding ABI");
_Static_assert(NSUTF8StringEncoding == 4, "UTF-8 NSString encoding ABI");
_Static_assert(sizeof(BOOL) == 1, "BOOL scalar ABI");
_Static_assert(sizeof(NSRange) == 2 * sizeof(size_t), "NSRange size ABI");
_Static_assert(_Alignof(NSRange) == _Alignof(size_t), "NSRange alignment ABI");
_Static_assert(offsetof(NSRange, location) == 0, "NSRange location ABI");
_Static_assert(offsetof(NSRange, length) == sizeof(size_t), "NSRange length ABI");
_Static_assert(__builtin_types_compatible_p(NSPoint, CGPoint), "NSPoint CGPoint ABI");
_Static_assert(__builtin_types_compatible_p(NSSize, CGSize), "NSSize CGSize ABI");
_Static_assert(__builtin_types_compatible_p(NSRect, CGRect), "NSRect CGRect ABI");
_Static_assert(NSAccessibilityPriorityLow == 10, "low announcement priority ABI");
_Static_assert(NSAccessibilityPriorityMedium == 50, "medium announcement priority ABI");
_Static_assert(NSAccessibilityPriorityHigh == 90, "high announcement priority ABI");

void zaccesskit_macos_post_notification(void *element, void *notification) {
    NSAccessibilityPostNotification((id)element, (NSString *)notification);
}

void zaccesskit_macos_post_notification_with_user_info(
    void *element, void *notification, void *user_info) {
    NSAccessibilityPostNotificationWithUserInfo(
        (id)element, (NSString *)notification, (NSDictionary *)user_info);
}

void *zaccesskit_macos_announcement_key(void) {
    NSString *key = NSAccessibilityAnnouncementKey;
    return (void *)key;
}

void *zaccesskit_macos_priority_key(void) {
    NSString *key = NSAccessibilityPriorityKey;
    return (void *)key;
}

void *zaccesskit_macos_announcement_requested_notification(void) {
    NSString *name = NSAccessibilityAnnouncementRequestedNotification;
    return (void *)name;
}

const void *zaccesskit_macos_ax_background_color(void) {
    NSString *key = NSAccessibilityBackgroundColorTextAttribute;
    return (const void *)key;
}

const void *zaccesskit_macos_ax_foreground_color(void) {
    NSString *key = NSAccessibilityForegroundColorTextAttribute;
    return (const void *)key;
}

const void *zaccesskit_macos_ax_font(void) {
    NSString *key = NSAccessibilityFontTextAttribute;
    return (const void *)key;
}

const void *zaccesskit_macos_ax_font_family(void) {
    NSString *key = NSAccessibilityFontFamilyKey;
    return (const void *)key;
}

const void *zaccesskit_macos_ax_font_size(void) {
    NSString *key = NSAccessibilityFontSizeKey;
    return (const void *)key;
}

const void *zaccesskit_macos_ax_underline(void) {
    NSString *key = NSAccessibilityUnderlineTextAttribute;
    return (const void *)key;
}

const void *zaccesskit_macos_ax_underline_color(void) {
    NSString *key = NSAccessibilityUnderlineColorTextAttribute;
    return (const void *)key;
}

const void *zaccesskit_macos_ax_strikethrough(void) {
    NSString *key = NSAccessibilityStrikethroughTextAttribute;
    return (const void *)key;
}

const void *zaccesskit_macos_ax_strikethrough_color(void) {
    NSString *key = NSAccessibilityStrikethroughColorTextAttribute;
    return (const void *)key;
}

const void *zaccesskit_macos_ax_language(void) {
    NSString *key = NSAccessibilityLanguageTextAttribute;
    return (const void *)key;
}

const void *zaccesskit_macos_ax_text_alignment(void) {
    NSString *key = NSAccessibilityTextAlignmentAttribute;
    return (const void *)key;
}
