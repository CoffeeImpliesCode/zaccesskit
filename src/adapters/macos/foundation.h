#ifndef ZACCESSKIT_MACOS_FOUNDATION_H
#define ZACCESSKIT_MACOS_FOUNDATION_H

/* Borrowed Objective-C opaque handles; the caller owns all input lifetimes. */
void zaccesskit_macos_post_notification(void *element, void *notification);
void zaccesskit_macos_post_notification_with_user_info(
    void *element, void *notification, void *user_info);
/* These getters borrow process-lifetime NSString constants from AppKit. */
void *zaccesskit_macos_announcement_key(void);
void *zaccesskit_macos_priority_key(void);
void *zaccesskit_macos_announcement_requested_notification(void);

/* Borrowed immutable SDK NSString constants for accessibility attributed text. */
const void *zaccesskit_macos_ax_background_color(void);
const void *zaccesskit_macos_ax_foreground_color(void);
const void *zaccesskit_macos_ax_font(void);
const void *zaccesskit_macos_ax_font_family(void);
const void *zaccesskit_macos_ax_font_size(void);
const void *zaccesskit_macos_ax_underline(void);
const void *zaccesskit_macos_ax_underline_color(void);
const void *zaccesskit_macos_ax_strikethrough(void);
const void *zaccesskit_macos_ax_strikethrough_color(void);
const void *zaccesskit_macos_ax_language(void);
const void *zaccesskit_macos_ax_text_alignment(void);

#endif
