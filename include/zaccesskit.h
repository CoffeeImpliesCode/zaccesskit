/**
 * Copyright 2023 The AccessKit Authors. All rights reserved.
 * Licensed under the Apache License, Version 2.0 (found in the LICENSE-APACHE
 * file) or the MIT license (found in the LICENSE-MIT file), at your option.
 *
 * Portions of this header derive from Chromium. See the Chromium attribution
 * below and LICENSE.chromium.
 *
 * This file is the whole C surface of `zaccesskit`, a pure Zig port of
 * AccessKit. It is hand written, it is the contract, and the Zig declarations
 * in this repository are checked against it.
 *
 * Licence, by material. AccessKit-authored declarations are under
 * `MIT OR Apache-2.0`, at your option, as LICENSE-APACHE and LICENSE-MIT state.
 * The role list and the role descriptions come from Chromium and are under the
 * BSD-style licence in LICENSE.chromium, which is
 *
 *     Copyright 2015 The Chromium Authors. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the conditions in LICENSE.chromium
 * are met. That licence is a separate obligation and the choice above does not
 * cover it. Each licence text travels with this header in the root of the
 * distribution that contains it: LICENSE-APACHE, LICENSE-MIT,
 * LICENSE.chromium, and NOTICE.md for the per-file inventory. A binary
 * distribution carries the same four files.
 *
 * Change notice, which Apache-2.0 clause 4(b) requires. This file was
 * changed. It is a port of the AccessKit C header and not a copy of it.
 *
 * What this port changed. Three upstream comments were wrong or missing, and
 * each correction is stated at the declaration: the macOS focus forwarder does
 * not take ownership of its class name, the twelve getters that return a
 * `{ length, values }` pair borrow `values` from the node, and
 * `accesskit_tree_update_set_tree_info` consumes its argument. The port also
 * adds `accesskit_set_allocator`, `accesskit_last_error` and the
 * `accesskit_error` enum, and it states the null-pointer result of every
 * geometry function that takes a pointer.
 *
 * Nothing here uses the name Google Inc. or Google LLC, or the name of any
 * contributor, to endorse or promote this software.
 */

#ifndef ZACCESSKIT_H
#define ZACCESSKIT_H

#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#ifdef _WIN32
#include <windows.h>
#endif /* _WIN32 */
#ifdef __ANDROID__
#include <jni.h>
#endif /* __ANDROID__ */
#ifdef __APPLE__
#include <TargetConditionals.h>
/* An older SDK leaves some of these undefined, so the value tests below
   would read them as undefined identifiers. Define each to 0 first. */
#ifndef TARGET_OS_OSX
#define TARGET_OS_OSX 0
#endif /* TARGET_OS_OSX */
#ifndef TARGET_OS_IOS
#define TARGET_OS_IOS 0
#endif /* TARGET_OS_IOS */
#ifndef TARGET_OS_TV
#define TARGET_OS_TV 0
#endif /* TARGET_OS_TV */
#ifndef TARGET_OS_WATCH
#define TARGET_OS_WATCH 0
#endif /* TARGET_OS_WATCH */
#ifndef TARGET_OS_VISION
#define TARGET_OS_VISION 0
#endif /* TARGET_OS_VISION */
#ifndef TARGET_OS_MACCATALYST
#define TARGET_OS_MACCATALYST 0
#endif /* TARGET_OS_MACCATALYST */
#if TARGET_OS_OSX
#define ACCESSKIT_MACOS
#endif /* TARGET_OS_OSX */
#if TARGET_OS_IOS || TARGET_OS_MACCATALYST
#define ACCESSKIT_IOS
#endif /* TARGET_OS_IOS || TARGET_OS_MACCATALYST */
#if TARGET_OS_TV
#define ACCESSKIT_TVOS
#endif /* TARGET_OS_TV */
#if TARGET_OS_WATCH
#define ACCESSKIT_WATCHOS
#endif /* TARGET_OS_WATCH */
#if TARGET_OS_VISION
#define ACCESSKIT_VISIONOS
#endif /* TARGET_OS_VISION */
#endif /* __APPLE__ */

/*
 * This header declares no platform registration mechanism. The library links
 * the platform adapters it ships, and a C caller cannot supply one. A caller
 * that needs a platform this library does not ship must build its own tree and
 * use the Zig surface instead.
 *
 * Every handle here is owned by the caller until a `push` or a `set` transfers
 * it, a `*_free` releases it, or it is handed to a callback. The tables in
 * section 3 of `docs/31-c-abi-design.md` name which is which for every
 * function.
 *
 * Every `void` function either cannot fail or takes its failure as a
 * precondition on the arguments. There is no status code and no exception
 * channel, and this library does not check preconditions at run time.
 *
 * Several hundred functions take or return a struct by value, and nine return
 * a 48-byte `accesskit_affine`. That is a property of the calling convention,
 * not only of the layout: such a value is classified, then passed in registers
 * or on the stack, and a caller built against a different classification
 * corrupts its own stack rather than receiving a wrong number. A consumer that
 * compiles this header with a C compiler and links the library built by the
 * same Zig toolchain version has a matching convention by construction. A
 * consumer that hand-writes the prototypes does not.
 *
 * `accesskit_last_error()` reports the failure tag from the most recent call
 * on the calling thread. Every function clears the tag on entry and sets it on
 * the failing path, so read it immediately after the call that failed. A
 * `null` or `false` return with `ACCESSKIT_ERROR_NONE` means the property was
 * absent, not that an allocation failed.
 */

/**
 * `zaccesskit` is the AccessKit accessibility toolkit as a C library. An
 * application builds a tree of `accesskit_node` values, hands the tree to a
 * platform adapter, and receives action requests back from the platform.
 *
 * This header, one shared library and the `accesskit_` symbol prefix are the
 * supported route for a C consumer. There is no vtable, no registration
 * object and no plugin table. A Zig consumer has a second supported route,
 * the `zaccesskit` module, and it is not reachable from C.
 *
 * Shortest sequence: call `accesskit_set_allocator` only if the library must
 * not use the C allocator; build one `accesskit_tree_update`; push nodes into
 * it; hand it to the platform's `*_update_if_active`; answer the callbacks the
 * adapter makes; raise the queued-events handle that call returns.
 *
 * What the caller releases: every `accesskit_node`, `accesskit_tree_info`,
 * `accesskit_tree_update` and `accesskit_custom_action` the caller still owns,
 * with the matching `*_free`; every `char *` a getter returned, with
 * `accesskit_string_free`; and every `accesskit_action_request` a callback
 * received, with `accesskit_action_request_free` before that callback returns.
 * Library memory is never released with `free`.
 *
 * ABI claim: C11, against a library built by Zig 0.16.0. Parsed as C11 with
 * `-Wall -Wextra -Wpedantic`, this header is clean. Parsed as C99 with the same
 * flags it gives 10 `-Wpedantic` diagnostics with gcc and 9
 * `-Wc11-extensions` with clang. Parsed as C++17 it gives 8 with g++ and 16 with
 * clang++ under `-Wgnu-anonymous-struct`. Every one of those diagnostics comes
 * from `accesskit_action_data`, whose payload union uses the anonymous struct
 * extension eight times. Both compilers accept the extension as a warning, and
 * C11 is the mode this library targets. The counts were measured with gcc 15.3.0
 * and clang 19.1.7; another compiler may report a different number without the
 * header being wrong. The conformance section at the end of this file states the
 * layout the two agree on.
 *
 * A setter that could not copy its value changes nothing, records
 * `ACCESSKIT_ERROR_OUT_OF_MEMORY` in `accesskit_last_error`, and returns. Read
 * the slot after any call whose return value you cannot check. Upstream aborts
 * the process on an allocation failure instead, because its setters have
 * nowhere to report one; this port reports it rather than aborting.
 *
 * A queued-events handle borrows its adapter. The adapter must outlive every
 * handle that came from it: raise the events, or free them, before you free the
 * adapter. Freeing the adapter first and then raising leaves the raise reading
 * storage the adapter owned. This applies to every `*_queued_events_raise` in
 * this header, and to no other handle here: a tree info, a tree update and a
 * node each own everything they point at.
 */

/*
 * Types. The declaration order is the port's own; the layout is the
 * pinned header's. Nothing here is optional to read: a field's unit and
 * the meaning of each `null` are part of the contract.
 */

/* Scalar identifiers. */

/**
 * The identifier of one node, unique inside its tree.
 *
 * It is copied by value in every signature that uses it, so no release is
 * owed and no copy must be freed.
 */
typedef uint64_t accesskit_node_id;

/**
 * The context pointer a tree update factory receives, passed through
 * unchanged.
 *
 * It is a distinct name for a `void *` so that a factory and its caller
 * cannot swap it with an activation handler's context by accident.
 * `accesskit_tree_update_factory` requires it to stay valid until the adapter
 * is released.
 */
typedef void *accesskit_tree_update_factory_userdata;

/* Enumerations. Each is a bare tag with no fixed base, and a one-byte
   typedef for C. */

/**
 * An action a platform may ask an application to perform on a node.
 *
 * `sizeof(enum accesskit_action)` is 4 and `sizeof(accesskit_action)` is 1 on
 * the measured target. A struct that spells the bare name therefore has a
 * different layout from this header.
 *
 * Spell the type `accesskit_action`, never `enum accesskit_action`. The bare
 * enum has no fixed base and no fixed size, while the typedef is one byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_action
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_ACTION_CLICK,
  ACCESSKIT_ACTION_FOCUS,
  ACCESSKIT_ACTION_BLUR,
  ACCESSKIT_ACTION_COLLAPSE,
  ACCESSKIT_ACTION_EXPAND,
  /**
   * Requires `request->data` to name `ACCESSKIT_ACTION_DATA_CUSTOM_ACTION`.
   */
  ACCESSKIT_ACTION_CUSTOM_ACTION,
  ACCESSKIT_ACTION_DECREMENT,
  ACCESSKIT_ACTION_INCREMENT,
  ACCESSKIT_ACTION_HIDE_TOOLTIP,
  ACCESSKIT_ACTION_SHOW_TOOLTIP,
  /**
   * Requires `request->data` to name `ACCESSKIT_ACTION_DATA_VALUE`.
   */
  ACCESSKIT_ACTION_REPLACE_SELECTED_TEXT,
  ACCESSKIT_ACTION_SCROLL_DOWN,
  ACCESSKIT_ACTION_SCROLL_LEFT,
  ACCESSKIT_ACTION_SCROLL_RIGHT,
  ACCESSKIT_ACTION_SCROLL_UP,
  /**
   * Requires `request->data` to name `ACCESSKIT_ACTION_DATA_SCROLL_UNIT`. An
   * `ACCESSKIT_ACTION_DATA_SCROLL_HINT` payload is optional and says where in
   * the container the node should land.
   */
  ACCESSKIT_ACTION_SCROLL_INTO_VIEW,
  /**
   * Requires `request->data` to name `ACCESSKIT_ACTION_DATA_SCROLL_TO_POINT`.
   */
  ACCESSKIT_ACTION_SCROLL_TO_POINT,
  /**
   * Requires `request->data` to name `ACCESSKIT_ACTION_DATA_SET_SCROLL_OFFSET`.
   */
  ACCESSKIT_ACTION_SET_SCROLL_OFFSET,
  /**
   * Requires `request->data` to name
   * `ACCESSKIT_ACTION_DATA_SET_TEXT_SELECTION`.
   */
  ACCESSKIT_ACTION_SET_TEXT_SELECTION,
  ACCESSKIT_ACTION_SET_SEQUENTIAL_FOCUS_NAVIGATION_STARTING_POINT,
  /**
   * Requires `request->data` to name `ACCESSKIT_ACTION_DATA_VALUE` or
   * `ACCESSKIT_ACTION_DATA_NUMERIC_VALUE`.
   */
  ACCESSKIT_ACTION_SET_VALUE,
  ACCESSKIT_ACTION_SHOW_CONTEXT_MENU,
};
#ifndef __cplusplus
typedef uint8_t accesskit_action;
#endif  // __cplusplus

/**
 * The value of an ARIA `aria-current` attribute.
 *
 * Spell the type `accesskit_aria_current`, never `enum
 * accesskit_aria_current`. The bare enum has no fixed base and no fixed size,
 * while the typedef is one byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_aria_current
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_ARIA_CURRENT_FALSE,
  ACCESSKIT_ARIA_CURRENT_TRUE,
  ACCESSKIT_ARIA_CURRENT_PAGE,
  ACCESSKIT_ARIA_CURRENT_STEP,
  ACCESSKIT_ARIA_CURRENT_LOCATION,
  ACCESSKIT_ARIA_CURRENT_DATE,
  ACCESSKIT_ARIA_CURRENT_TIME,
};
#ifndef __cplusplus
typedef uint8_t accesskit_aria_current;
#endif  // __cplusplus

/**
 * How a text input offers the values it holds.
 *
 * Spell the type `accesskit_auto_complete`, never `enum
 * accesskit_auto_complete`. The bare enum has no fixed base and no fixed
 * size, while the typedef is one byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_auto_complete
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_AUTO_COMPLETE_INLINE,
  ACCESSKIT_AUTO_COMPLETE_LIST,
  ACCESSKIT_AUTO_COMPLETE_BOTH,
};
#ifndef __cplusplus
typedef uint8_t accesskit_auto_complete;
#endif  // __cplusplus

/**
 * The kind of popup a control opens.
 *
 * Spell the type `accesskit_has_popup`, never `enum accesskit_has_popup`. The
 * bare enum has no fixed base and no fixed size, while the typedef is one
 * byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_has_popup
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_HAS_POPUP_MENU,
  ACCESSKIT_HAS_POPUP_LISTBOX,
  ACCESSKIT_HAS_POPUP_TREE,
  ACCESSKIT_HAS_POPUP_GRID,
  ACCESSKIT_HAS_POPUP_DIALOG,
};
#ifndef __cplusplus
typedef uint8_t accesskit_has_popup;
#endif  // __cplusplus

/**
 * Whether a form control holds input the platform rejects, or whether a DOM
 * element carries `aria-invalid`.
 *
 * Spell the type `accesskit_invalid`, never `enum accesskit_invalid`. The
 * bare enum has no fixed base and no fixed size, while the typedef is one
 * byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_invalid
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_INVALID_TRUE,
  ACCESSKIT_INVALID_GRAMMAR,
  ACCESSKIT_INVALID_SPELLING,
};
#ifndef __cplusplus
typedef uint8_t accesskit_invalid;
#endif  // __cplusplus

/**
 * The marker a list draws beside each of its items.
 *
 * Spell the type `accesskit_list_style`, never `enum accesskit_list_style`.
 * The bare enum has no fixed base and no fixed size, while the typedef is one
 * byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_list_style
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_LIST_STYLE_CIRCLE,
  ACCESSKIT_LIST_STYLE_DISC,
  ACCESSKIT_LIST_STYLE_IMAGE,
  ACCESSKIT_LIST_STYLE_NUMERIC,
  ACCESSKIT_LIST_STYLE_SQUARE,
  /**
   * An ordering the language defines, such as alphabetical, roman or CJK
   * ideographic.
   */
  ACCESSKIT_LIST_STYLE_OTHER,
};
#ifndef __cplusplus
typedef uint8_t accesskit_list_style;
#endif  // __cplusplus

/**
 * How loudly a live region announces a change.
 *
 * Spell the type `accesskit_live`, never `enum accesskit_live`. The bare enum
 * has no fixed base and no fixed size, while the typedef is one byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_live
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_LIVE_OFF,
  ACCESSKIT_LIVE_POLITE,
  ACCESSKIT_LIVE_ASSERTIVE,
};
#ifndef __cplusplus
typedef uint8_t accesskit_live;
#endif  // __cplusplus

/**
 * The axis a control lays its items out on.
 *
 * Spell the type `accesskit_orientation`, never `enum accesskit_orientation`.
 * The bare enum has no fixed base and no fixed size, while the typedef is one
 * byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_orientation
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  /**
   * Most toolbars and separators.
   */
  ACCESSKIT_ORIENTATION_HORIZONTAL,
  /**
   * Menus and combo boxes.
   */
  ACCESSKIT_ORIENTATION_VERTICAL,
};
#ifndef __cplusplus
typedef uint8_t accesskit_orientation;
#endif  // __cplusplus

/**
 * The role of an accessibility node.
 *
 * Most of these roles come from the ARIA specification. Read the current ARIA
 * draft for correct use of each one.
 *
 * The list comes largely from Chromium. Unlike Chromium's alphabetized list,
 * this one is ordered roughly by expected usage frequency, with
 * `ACCESSKIT_ROLE_UNKNOWN` excepted, because a serialisation that writes the
 * enumerator number as a variable-length integer is shorter when the common
 * values are the small ones.
 *
 * Spell the type `accesskit_role`, never `enum accesskit_role`. The bare enum
 * has no fixed base and no fixed size, while the typedef is one byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_role
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_ROLE_UNKNOWN,
  ACCESSKIT_ROLE_TEXT_RUN,
  ACCESSKIT_ROLE_CELL,
  ACCESSKIT_ROLE_LABEL,
  ACCESSKIT_ROLE_IMAGE,
  ACCESSKIT_ROLE_LINK,
  ACCESSKIT_ROLE_ROW,
  ACCESSKIT_ROLE_LIST_ITEM,
  /**
   * The bullet, number or other marker that belongs to a list item.
   */
  ACCESSKIT_ROLE_LIST_MARKER,
  ACCESSKIT_ROLE_TREE_ITEM,
  ACCESSKIT_ROLE_LIST_BOX_OPTION,
  ACCESSKIT_ROLE_MENU_ITEM,
  ACCESSKIT_ROLE_MENU_LIST_OPTION,
  ACCESSKIT_ROLE_PARAGRAPH,
  /**
   * A container that an assistive technology should skip and that a platform
   * tree should filter out. The ARIA `none` and `presentation` roles, and an
   * HTML `div` that carries no role, are all this role.
   */
  ACCESSKIT_ROLE_GENERIC_CONTAINER,
  ACCESSKIT_ROLE_CHECK_BOX,
  ACCESSKIT_ROLE_RADIO_BUTTON,
  ACCESSKIT_ROLE_TEXT_INPUT,
  ACCESSKIT_ROLE_BUTTON,
  ACCESSKIT_ROLE_DEFAULT_BUTTON,
  ACCESSKIT_ROLE_PANE,
  ACCESSKIT_ROLE_ROW_HEADER,
  ACCESSKIT_ROLE_COLUMN_HEADER,
  ACCESSKIT_ROLE_ROW_GROUP,
  ACCESSKIT_ROLE_LIST,
  ACCESSKIT_ROLE_TABLE,
  ACCESSKIT_ROLE_LAYOUT_TABLE_CELL,
  ACCESSKIT_ROLE_LAYOUT_TABLE_ROW,
  ACCESSKIT_ROLE_LAYOUT_TABLE,
  ACCESSKIT_ROLE_SWITCH,
  ACCESSKIT_ROLE_MENU,
  ACCESSKIT_ROLE_MULTILINE_TEXT_INPUT,
  ACCESSKIT_ROLE_SEARCH_INPUT,
  ACCESSKIT_ROLE_DATE_INPUT,
  ACCESSKIT_ROLE_DATE_TIME_INPUT,
  ACCESSKIT_ROLE_WEEK_INPUT,
  ACCESSKIT_ROLE_MONTH_INPUT,
  ACCESSKIT_ROLE_TIME_INPUT,
  ACCESSKIT_ROLE_EMAIL_INPUT,
  ACCESSKIT_ROLE_NUMBER_INPUT,
  ACCESSKIT_ROLE_PASSWORD_INPUT,
  ACCESSKIT_ROLE_PHONE_NUMBER_INPUT,
  ACCESSKIT_ROLE_URL_INPUT,
  ACCESSKIT_ROLE_ABBR,
  ACCESSKIT_ROLE_ALERT,
  ACCESSKIT_ROLE_ALERT_DIALOG,
  ACCESSKIT_ROLE_APPLICATION,
  ACCESSKIT_ROLE_ARTICLE,
  ACCESSKIT_ROLE_AUDIO,
  ACCESSKIT_ROLE_BANNER,
  ACCESSKIT_ROLE_BLOCKQUOTE,
  ACCESSKIT_ROLE_CANVAS,
  ACCESSKIT_ROLE_CAPTION,
  ACCESSKIT_ROLE_CARET,
  ACCESSKIT_ROLE_CODE,
  ACCESSKIT_ROLE_COLOR_WELL,
  ACCESSKIT_ROLE_COMBO_BOX,
  ACCESSKIT_ROLE_EDITABLE_COMBO_BOX,
  ACCESSKIT_ROLE_COMPLEMENTARY,
  ACCESSKIT_ROLE_COMMENT,
  ACCESSKIT_ROLE_CONTENT_DELETION,
  ACCESSKIT_ROLE_CONTENT_INSERTION,
  ACCESSKIT_ROLE_CONTENT_INFO,
  ACCESSKIT_ROLE_DEFINITION,
  ACCESSKIT_ROLE_DESCRIPTION_LIST,
  ACCESSKIT_ROLE_DETAILS,
  ACCESSKIT_ROLE_DIALOG,
  ACCESSKIT_ROLE_DISCLOSURE_TRIANGLE,
  ACCESSKIT_ROLE_DOCUMENT,
  ACCESSKIT_ROLE_EMBEDDED_OBJECT,
  ACCESSKIT_ROLE_EMPHASIS,
  ACCESSKIT_ROLE_FEED,
  ACCESSKIT_ROLE_FIGURE_CAPTION,
  ACCESSKIT_ROLE_FIGURE,
  ACCESSKIT_ROLE_FOOTER,
  ACCESSKIT_ROLE_FORM,
  ACCESSKIT_ROLE_GRID,
  ACCESSKIT_ROLE_GRID_CELL,
  ACCESSKIT_ROLE_GROUP,
  ACCESSKIT_ROLE_HEADER,
  ACCESSKIT_ROLE_HEADING,
  ACCESSKIT_ROLE_IFRAME,
  ACCESSKIT_ROLE_IFRAME_PRESENTATIONAL,
  ACCESSKIT_ROLE_IME_CANDIDATE,
  ACCESSKIT_ROLE_KEYBOARD,
  ACCESSKIT_ROLE_LEGEND,
  ACCESSKIT_ROLE_LINE_BREAK,
  ACCESSKIT_ROLE_LIST_BOX,
  ACCESSKIT_ROLE_LOG,
  ACCESSKIT_ROLE_MAIN,
  ACCESSKIT_ROLE_MARK,
  ACCESSKIT_ROLE_MARQUEE,
  ACCESSKIT_ROLE_MATH,
  ACCESSKIT_ROLE_MENU_BAR,
  ACCESSKIT_ROLE_MENU_ITEM_CHECK_BOX,
  ACCESSKIT_ROLE_MENU_ITEM_RADIO,
  ACCESSKIT_ROLE_MENU_LIST_POPUP,
  ACCESSKIT_ROLE_METER,
  ACCESSKIT_ROLE_NAVIGATION,
  ACCESSKIT_ROLE_NOTE,
  ACCESSKIT_ROLE_PLUGIN_OBJECT,
  ACCESSKIT_ROLE_PROGRESS_INDICATOR,
  ACCESSKIT_ROLE_RADIO_GROUP,
  ACCESSKIT_ROLE_REGION,
  ACCESSKIT_ROLE_ROOT_WEB_AREA,
  ACCESSKIT_ROLE_RUBY,
  ACCESSKIT_ROLE_RUBY_ANNOTATION,
  ACCESSKIT_ROLE_SCROLL_BAR,
  ACCESSKIT_ROLE_SCROLL_VIEW,
  ACCESSKIT_ROLE_SEARCH,
  ACCESSKIT_ROLE_SECTION,
  ACCESSKIT_ROLE_SECTION_FOOTER,
  ACCESSKIT_ROLE_SECTION_HEADER,
  ACCESSKIT_ROLE_SLIDER,
  ACCESSKIT_ROLE_SPIN_BUTTON,
  ACCESSKIT_ROLE_SPLITTER,
  ACCESSKIT_ROLE_STATUS,
  ACCESSKIT_ROLE_STRONG,
  ACCESSKIT_ROLE_SUGGESTION,
  ACCESSKIT_ROLE_SVG_ROOT,
  ACCESSKIT_ROLE_TAB,
  ACCESSKIT_ROLE_TAB_LIST,
  ACCESSKIT_ROLE_TAB_PANEL,
  ACCESSKIT_ROLE_TERM,
  ACCESSKIT_ROLE_TIME,
  ACCESSKIT_ROLE_TIMER,
  ACCESSKIT_ROLE_TITLE_BAR,
  ACCESSKIT_ROLE_TOOLBAR,
  ACCESSKIT_ROLE_TOOLTIP,
  ACCESSKIT_ROLE_TREE,
  ACCESSKIT_ROLE_TREE_GRID,
  ACCESSKIT_ROLE_VIDEO,
  ACCESSKIT_ROLE_WEB_VIEW,
  ACCESSKIT_ROLE_WINDOW,
  ACCESSKIT_ROLE_PDF_ACTIONABLE_HIGHLIGHT,
  ACCESSKIT_ROLE_PDF_ROOT,
  ACCESSKIT_ROLE_GRAPHICS_DOCUMENT,
  ACCESSKIT_ROLE_GRAPHICS_OBJECT,
  ACCESSKIT_ROLE_GRAPHICS_SYMBOL,
  ACCESSKIT_ROLE_DOC_ABSTRACT,
  ACCESSKIT_ROLE_DOC_ACKNOWLEDGEMENTS,
  ACCESSKIT_ROLE_DOC_AFTERWORD,
  ACCESSKIT_ROLE_DOC_APPENDIX,
  ACCESSKIT_ROLE_DOC_BACK_LINK,
  ACCESSKIT_ROLE_DOC_BIBLIO_ENTRY,
  ACCESSKIT_ROLE_DOC_BIBLIOGRAPHY,
  ACCESSKIT_ROLE_DOC_BIBLIO_REF,
  ACCESSKIT_ROLE_DOC_CHAPTER,
  ACCESSKIT_ROLE_DOC_COLOPHON,
  ACCESSKIT_ROLE_DOC_CONCLUSION,
  ACCESSKIT_ROLE_DOC_COVER,
  ACCESSKIT_ROLE_DOC_CREDIT,
  ACCESSKIT_ROLE_DOC_CREDITS,
  ACCESSKIT_ROLE_DOC_DEDICATION,
  ACCESSKIT_ROLE_DOC_ENDNOTE,
  ACCESSKIT_ROLE_DOC_ENDNOTES,
  ACCESSKIT_ROLE_DOC_EPIGRAPH,
  ACCESSKIT_ROLE_DOC_EPILOGUE,
  ACCESSKIT_ROLE_DOC_ERRATA,
  ACCESSKIT_ROLE_DOC_EXAMPLE,
  ACCESSKIT_ROLE_DOC_FOOTNOTE,
  ACCESSKIT_ROLE_DOC_FOREWORD,
  ACCESSKIT_ROLE_DOC_GLOSSARY,
  ACCESSKIT_ROLE_DOC_GLOSS_REF,
  ACCESSKIT_ROLE_DOC_INDEX,
  ACCESSKIT_ROLE_DOC_INTRODUCTION,
  ACCESSKIT_ROLE_DOC_NOTE_REF,
  ACCESSKIT_ROLE_DOC_NOTICE,
  ACCESSKIT_ROLE_DOC_PAGE_BREAK,
  ACCESSKIT_ROLE_DOC_PAGE_FOOTER,
  ACCESSKIT_ROLE_DOC_PAGE_HEADER,
  ACCESSKIT_ROLE_DOC_PAGE_LIST,
  ACCESSKIT_ROLE_DOC_PART,
  ACCESSKIT_ROLE_DOC_PREFACE,
  ACCESSKIT_ROLE_DOC_PROLOGUE,
  ACCESSKIT_ROLE_DOC_PULLQUOTE,
  ACCESSKIT_ROLE_DOC_QNA,
  ACCESSKIT_ROLE_DOC_SUBTITLE,
  ACCESSKIT_ROLE_DOC_TIP,
  ACCESSKIT_ROLE_DOC_TOC,
  /**
   * Behaves like an ARIA grid. Chromium's `TableView` and its subclasses use
   * it, so that they expose correctly on certain platforms.
   */
  ACCESSKIT_ROLE_LIST_GRID,
  /**
   * A multi-line document that asks an assistive technology for behaviour
   * specific to a VT-100-style terminal.
   */
  ACCESSKIT_ROLE_TERMINAL,
};
#ifndef __cplusplus
typedef uint8_t accesskit_role;
#endif  // __cplusplus

/**
 * Where a node scrolled into view sits against the edges of its scroll
 * container.
 *
 * Spell the type `accesskit_scroll_hint`, never `enum accesskit_scroll_hint`.
 * The bare enum has no fixed base and no fixed size, while the typedef is one
 * byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_scroll_hint
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_SCROLL_HINT_TOP_LEFT,
  ACCESSKIT_SCROLL_HINT_BOTTOM_RIGHT,
  ACCESSKIT_SCROLL_HINT_TOP_EDGE,
  ACCESSKIT_SCROLL_HINT_BOTTOM_EDGE,
  ACCESSKIT_SCROLL_HINT_LEFT_EDGE,
  ACCESSKIT_SCROLL_HINT_RIGHT_EDGE,
};
#ifndef __cplusplus
typedef uint8_t accesskit_scroll_hint;
#endif  // __cplusplus

/**
 * How far one scroll action moves.
 *
 * Spell the type `accesskit_scroll_unit`, never `enum accesskit_scroll_unit`.
 * The bare enum has no fixed base and no fixed size, while the typedef is one
 * byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_scroll_unit
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_SCROLL_UNIT_ITEM,
  ACCESSKIT_SCROLL_UNIT_PAGE,
};
#ifndef __cplusplus
typedef uint8_t accesskit_scroll_unit;
#endif  // __cplusplus

/**
 * The direction a sorted set runs in.
 *
 * Spell the type `accesskit_sort_direction`, never `enum
 * accesskit_sort_direction`. The bare enum has no fixed base and no fixed
 * size, while the typedef is one byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_sort_direction
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_SORT_DIRECTION_ASCENDING,
  ACCESSKIT_SORT_DIRECTION_DESCENDING,
  ACCESSKIT_SORT_DIRECTION_OTHER,
};
#ifndef __cplusplus
typedef uint8_t accesskit_sort_direction;
#endif  // __cplusplus

/**
 * The horizontal alignment of a block of text.
 *
 * Spell the type `accesskit_text_align`, never `enum accesskit_text_align`.
 * The bare enum has no fixed base and no fixed size, while the typedef is one
 * byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_text_align
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_TEXT_ALIGN_LEFT,
  ACCESSKIT_TEXT_ALIGN_RIGHT,
  ACCESSKIT_TEXT_ALIGN_CENTER,
  ACCESSKIT_TEXT_ALIGN_JUSTIFY,
};
#ifndef __cplusplus
typedef uint8_t accesskit_text_align;
#endif  // __cplusplus

/**
 * The stroke pattern of a text decoration.
 *
 * Spell the type `accesskit_text_decoration_style`, never `enum
 * accesskit_text_decoration_style`. The bare enum has no fixed base and no
 * fixed size, while the typedef is one byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_text_decoration_style
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_TEXT_DECORATION_STYLE_SOLID,
  ACCESSKIT_TEXT_DECORATION_STYLE_DOTTED,
  ACCESSKIT_TEXT_DECORATION_STYLE_DASHED,
  ACCESSKIT_TEXT_DECORATION_STYLE_DOUBLE,
  ACCESSKIT_TEXT_DECORATION_STYLE_WAVY,
};
#ifndef __cplusplus
typedef uint8_t accesskit_text_decoration_style;
#endif  // __cplusplus

/**
 * The direction text advances in.
 *
 * Spell the type `accesskit_text_direction`, never `enum
 * accesskit_text_direction`. The bare enum has no fixed base and no fixed
 * size, while the typedef is one byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_text_direction
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_TEXT_DIRECTION_LEFT_TO_RIGHT,
  ACCESSKIT_TEXT_DIRECTION_RIGHT_TO_LEFT,
  ACCESSKIT_TEXT_DIRECTION_TOP_TO_BOTTOM,
  ACCESSKIT_TEXT_DIRECTION_BOTTOM_TO_TOP,
};
#ifndef __cplusplus
typedef uint8_t accesskit_text_direction;
#endif  // __cplusplus

/**
 * The state of a toggle: off, on, or mixed.
 *
 * Spell the type `accesskit_toggled`, never `enum accesskit_toggled`. The
 * bare enum has no fixed base and no fixed size, while the typedef is one
 * byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_toggled
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_TOGGLED_FALSE,
  ACCESSKIT_TOGGLED_TRUE,
  ACCESSKIT_TOGGLED_MIXED,
};
#ifndef __cplusplus
typedef uint8_t accesskit_toggled;
#endif  // __cplusplus

/**
 * Whether a run of text sits below or above the baseline.
 *
 * Spell the type `accesskit_vertical_offset`, never `enum
 * accesskit_vertical_offset`. The bare enum has no fixed base and no fixed
 * size, while the typedef is one byte.
 *
 * The first enumerator is 0 and the values are contiguous. The enumerator
 * number is the number a serialised schema carries, so reordering or
 * renumbering this list changes the wire format.
 */
enum accesskit_vertical_offset
#ifdef __cplusplus
    : uint8_t
#endif  // __cplusplus
{
  ACCESSKIT_VERTICAL_OFFSET_SUBSCRIPT,
  ACCESSKIT_VERTICAL_OFFSET_SUPERSCRIPT,
};
#ifndef __cplusplus
typedef uint8_t accesskit_vertical_offset;
#endif  // __cplusplus

/* Forward declarations. A C caller can hold these pointers and reaches
   their contents only through the functions below. */

/**
 * A platform handle this header only names. It has no C layout, and the
 * caller reaches it only through the `android_*` functions below.
 */
#if defined(__ANDROID__)
typedef struct accesskit_android_adapter accesskit_android_adapter;
#endif /* __ANDROID__ */

/**
 * A platform handle this header only names. It has no C layout, and the
 * caller reaches it only through the `android_*` functions below.
 */
#if defined(__ANDROID__)
typedef struct
    accesskit_android_injecting_adapter accesskit_android_injecting_adapter;
#endif /* __ANDROID__ */

/**
 * A platform handle this header only names. It has no C layout, and the
 * caller reaches it only through the `android_*` functions below.
 */
#if defined(__ANDROID__)
typedef struct
    accesskit_android_platform_action accesskit_android_platform_action;
#endif /* __ANDROID__ */

/**
 * A platform handle this header only names. It has no C layout, and the
 * caller reaches it only through the `android_*` functions below.
 */
#if defined(__ANDROID__)
typedef struct
    accesskit_android_queued_events accesskit_android_queued_events;
#endif /* __ANDROID__ */

/**
 * One named action a node offers beyond the standard set.
 *
 * `accesskit_custom_action_new` returns one. The caller owns it until
 * `accesskit_node_push_custom_action` takes it, and releases it with
 * `accesskit_custom_action_free`.
 */
typedef struct accesskit_custom_action accesskit_custom_action;

/**
 * A platform handle this header only names. It has no C layout, and the
 * caller reaches it only through the `ios_*` functions below.
 */
#if (defined(ACCESSKIT_IOS) || defined(ACCESSKIT_TVOS) || \
     defined(ACCESSKIT_VISIONOS) || defined(ACCESSKIT_WATCHOS))
typedef struct accesskit_ios_adapter accesskit_ios_adapter;
#endif /* the iOS, tvOS, visionOS and watchOS family */

/**
 * A platform handle this header only names. It has no C layout, and the
 * caller reaches it only through the `ios_*` functions below.
 */
#if (defined(ACCESSKIT_IOS) || defined(ACCESSKIT_TVOS) || \
     defined(ACCESSKIT_VISIONOS) || defined(ACCESSKIT_WATCHOS))
typedef struct accesskit_ios_queued_events accesskit_ios_queued_events;
#endif /* the iOS, tvOS, visionOS and watchOS family */

/**
 * A platform handle this header only names. It has no C layout, and the
 * caller reaches it only through the `ios_*` functions below.
 */
#if (defined(ACCESSKIT_IOS) || defined(ACCESSKIT_TVOS) || \
     defined(ACCESSKIT_VISIONOS) || defined(ACCESSKIT_WATCHOS))
typedef struct
    accesskit_ios_subclassing_adapter accesskit_ios_subclassing_adapter;
#endif /* the iOS, tvOS, visionOS and watchOS family */

/**
 * A platform handle this header only names. It has no C layout, and the
 * caller reaches it only through the `macos_*` functions below.
 */
#if defined(ACCESSKIT_MACOS)
typedef struct accesskit_macos_adapter accesskit_macos_adapter;
#endif /* ACCESSKIT_MACOS */

/**
 * A platform handle this header only names. It has no C layout, and the
 * caller reaches it only through the `macos_*` functions below.
 */
#if defined(ACCESSKIT_MACOS)
typedef struct accesskit_macos_queued_events accesskit_macos_queued_events;
#endif /* ACCESSKIT_MACOS */

/**
 * A platform handle this header only names. It has no C layout, and the
 * caller reaches it only through the `macos_*` functions below.
 */
#if defined(ACCESSKIT_MACOS)
typedef struct
    accesskit_macos_subclassing_adapter accesskit_macos_subclassing_adapter;
#endif /* ACCESSKIT_MACOS */

/**
 * One node of an accessibility tree. A C caller holds a pointer to it and
 * reaches its properties through the `accesskit_node_*` functions below; it
 * cannot read the layout, because there is none.
 *
 * `accesskit_node_new` returns one. The caller owns it until a
 * `accesskit_tree_update_push_node` takes it, and releases it with
 * `accesskit_node_free`.
 */
typedef struct accesskit_node accesskit_node;

/**
 * The metadata that describes one tree to a platform: its root node and its
 * toolkit name and version.
 *
 * `accesskit_tree_info_new` returns one. The caller owns it until
 * `accesskit_tree_update_set_tree_info` consumes it, and releases it with
 * `accesskit_tree_info_free`.
 */
typedef struct accesskit_tree_info accesskit_tree_info;

/**
 * One update to a tree: a set of nodes, an optional tree info and a focus.
 *
 * The two `accesskit_tree_update_with_*` functions return one. The caller
 * owns it, and releases it with `accesskit_tree_update_free`, unless a
 * factory or an activation handler hands ownership to the library instead.
 */
typedef struct accesskit_tree_update accesskit_tree_update;

/**
 * A platform handle this header only names. It has no C layout, and the
 * caller reaches it only through the `unix_*` functions below.
 */
#if (defined(__linux__) || defined(__DragonFly__) || \
     defined(__FreeBSD__) || defined(__NetBSD__) || \
     defined(__OpenBSD__))
typedef struct accesskit_unix_adapter accesskit_unix_adapter;
#endif /* the Linux and BSD family */

/**
 * A platform handle this header only names. It has no C layout, and the
 * caller reaches it only through the `windows_*` functions below.
 */
#if defined(_WIN32)
typedef struct accesskit_windows_adapter accesskit_windows_adapter;
#endif /* _WIN32 */

/**
 * A platform handle this header only names. It has no C layout, and the
 * caller reaches it only through the `windows_*` functions below.
 */
#if defined(_WIN32)
typedef struct
    accesskit_windows_queued_events accesskit_windows_queued_events;
#endif /* _WIN32 */

/**
 * A platform handle this header only names. It has no C layout, and the
 * caller reaches it only through the `windows_*` functions below.
 */
#if defined(_WIN32)
typedef struct
    accesskit_windows_subclassing_adapter accesskit_windows_subclassing_adapter;
#endif /* _WIN32 */

/* Structs. The optionals share one shape: a flag and a payload. */

/**
 * A list of node identifiers, returned by value.
 */
typedef struct accesskit_node_ids {
  /**
   * An element count, not a byte count.
   */
  size_t length;
  /**
   * Borrows the array this node owns. The node must stay alive and this list
   * unmodified for as long as the caller reads it, and the caller never
   * releases it.
   */
  const accesskit_node_id *values;
} accesskit_node_ids;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_node_id {
  bool has_value;
  accesskit_node_id value;
} accesskit_opt_node_id;

/**
 * A 128-bit identifier for a tree. `ACCESSKIT_TREE_ID_ROOT` is the all-zero
 * identifier.
 */
typedef struct accesskit_tree_id {
  uint8_t bytes[16];
} accesskit_tree_id;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_tree_id {
  bool has_value;
  struct accesskit_tree_id value;
} accesskit_opt_tree_id;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_double {
  bool has_value;
  double value;
} accesskit_opt_double;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_float {
  bool has_value;
  float value;
} accesskit_opt_float;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_index {
  bool has_value;
  /**
   * A count, not an index into any table this header defines.
   */
  size_t value;
} accesskit_opt_index;

/**
 * One RGBA colour. Each component is an integer in `0..=255`, and an alpha of
 * 255 is fully opaque.
 */
typedef struct accesskit_color {
  uint8_t red;
  uint8_t green;
  uint8_t blue;
  uint8_t alpha;
} accesskit_color;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_color {
  bool has_value;
  struct accesskit_color value;
} accesskit_opt_color;

/**
 * A line drawn through or around text, such as an underline.
 */
typedef struct accesskit_text_decoration {
  /**
   * `ACCESSKIT_TEXT_DECORATION_STYLE_SOLID` is the default when the property is
   * absent.
   */
  accesskit_text_decoration_style style;
  /**
   * Meaningful only when `style` says the decoration paints.
   */
  struct accesskit_color color;
} accesskit_text_decoration;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_text_decoration {
  bool has_value;
  struct accesskit_text_decoration value;
} accesskit_opt_text_decoration;

/**
 * A list of per-character byte lengths, returned by value.
 */
typedef struct accesskit_lengths {
  /**
   * An element count, not a byte count.
   */
  size_t length;
  /**
   * UTF-8 encoded character lengths in bytes, one per character, in text order.
   * Borrows the array this node owns: the node must stay alive and this list
   * unmodified while the caller reads it, and the caller never releases it.
   */
  const uint8_t *values;
} accesskit_lengths;

/**
 * Character positions or widths in logical pixels from the start of the text,
 * one per character, in text order. A character is a UTF-8 character, as in
 * `accesskit_text_position.character_index`.
 *
 * `has_value` is false when the property is unset. `length` is an element
 * count, not a byte count. `values` borrows the array this node owns: the
 * node must stay alive and this list unmodified while the caller reads it,
 * and the caller never releases it.
 *
 * A copy of this struct is independent of the node it came from.
 */
typedef struct accesskit_opt_coords {
  bool has_value;
  size_t length;
  const float *values;
} accesskit_opt_coords;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_bool {
  bool has_value;
  bool value;
} accesskit_opt_bool;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_invalid {
  bool has_value;
  accesskit_invalid value;
} accesskit_opt_invalid;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_toggled {
  bool has_value;
  accesskit_toggled value;
} accesskit_opt_toggled;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_live {
  bool has_value;
  accesskit_live value;
} accesskit_opt_live;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_text_direction {
  bool has_value;
  accesskit_text_direction value;
} accesskit_opt_text_direction;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_orientation {
  bool has_value;
  accesskit_orientation value;
} accesskit_opt_orientation;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_sort_direction {
  bool has_value;
  accesskit_sort_direction value;
} accesskit_opt_sort_direction;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_aria_current {
  bool has_value;
  accesskit_aria_current value;
} accesskit_opt_aria_current;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_auto_complete {
  bool has_value;
  accesskit_auto_complete value;
} accesskit_opt_auto_complete;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_has_popup {
  bool has_value;
  accesskit_has_popup value;
} accesskit_opt_has_popup;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_list_style {
  bool has_value;
  accesskit_list_style value;
} accesskit_opt_list_style;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_text_align {
  bool has_value;
  accesskit_text_align value;
} accesskit_opt_text_align;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_vertical_offset {
  bool has_value;
  accesskit_vertical_offset value;
} accesskit_opt_vertical_offset;

/**
 * A 2D affine transform.
 *
 * Logical, device-independent pixels. The y axis grows downwards, so `y0` is
 * the top edge and `y1` the bottom edge. `accesskit_affine._0` is row-major
 * with an implicit last row of `0 0 1`.
 *
 * The field is named `_0` because the value is a six-element tuple and C has
 * no tuple type.
 */
typedef struct accesskit_affine {
  double _0[6];
} accesskit_affine;

/**
 * An axis-aligned rectangle, given by two corners.
 *
 * Logical, device-independent pixels. The y axis grows downwards, so `y0` is
 * the top edge and `y1` the bottom edge. `accesskit_affine._0` is row-major
 * with an implicit last row of `0 0 1`.
 */
typedef struct accesskit_rect {
  double x0;
  double y0;
  double x1;
  double y1;
} accesskit_rect;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_rect {
  bool has_value;
  struct accesskit_rect value;
} accesskit_opt_rect;

/**
 * One end of a text selection: a node and a character offset into that node's
 * text.
 */
typedef struct accesskit_text_position {
  accesskit_node_id node;
  /**
   * A count of UTF-8 characters, not bytes and not UTF-16 code units.
   */
  size_t character_index;
} accesskit_text_position;

/**
 * A range of text in one node. An anchor at or after the focus is a backwards
 * selection, and the platform preserves it as given.
 */
typedef struct accesskit_text_selection {
  struct accesskit_text_position anchor;
  struct accesskit_text_position focus;
} accesskit_text_selection;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_text_selection {
  bool has_value;
  struct accesskit_text_selection value;
} accesskit_opt_text_selection;

/**
 * A list of custom actions, returned by value.
 */
typedef struct accesskit_custom_actions {
  /**
   * An element count, not a byte count.
   */
  size_t length;
  /**
   * Points at `length` actions. A value returned by
   * `accesskit_node_custom_actions` owns the array and every action in it, and
   * `accesskit_custom_actions_free` releases all of them. An array passed to
   * `accesskit_node_set_custom_actions` is only borrowed.
   */
  struct accesskit_custom_action **values;
} accesskit_custom_actions;

/**
 * A point in two dimensions.
 *
 * Logical, device-independent pixels. The y axis grows downwards, so `y0` is
 * the top edge and `y1` the bottom edge. `accesskit_affine._0` is row-major
 * with an implicit last row of `0 0 1`.
 */
typedef struct accesskit_point {
  double x;
  double y;
} accesskit_point;

/**
 * A displacement or an extent in two dimensions.
 *
 * Logical, device-independent pixels. The y axis grows downwards, so `y0` is
 * the top edge and `y1` the bottom edge. `accesskit_affine._0` is row-major
 * with an implicit last row of `0 0 1`.
 */
typedef struct accesskit_vec2 {
  double x;
  double y;
} accesskit_vec2;

/**
 * A width and a height in two dimensions.
 *
 * Logical, device-independent pixels. The y axis grows downwards, so `y0` is
 * the top edge and `y1` the bottom edge. `accesskit_affine._0` is row-major
 * with an implicit last row of `0 0 1`.
 */
typedef struct accesskit_size {
  double width;
  double height;
} accesskit_size;

#if defined(_WIN32)
/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_lresult {
  bool has_value;
  /**
   * A `LRESULT`, the value Windows returns from a window procedure. The type
   * comes from `windows.h`, which this header includes under `_WIN32`.
   */
  LRESULT value;
} accesskit_opt_lresult;
#endif /* _WIN32 */

/* The action payload, its discriminant and the request it arrives in. */

/**
 * The discriminant of `accesskit_action_data`. It names the one member of the
 * union that is meaningful.
 *
 * This enum has no `uint8_t` alias and no fixed base, so its size is the C
 * compiler's choice. Do not spell this type in a struct; use
 * `accesskit_action_data`.
 */
typedef enum accesskit_action_data_Tag {
  ACCESSKIT_ACTION_DATA_CUSTOM_ACTION,
  ACCESSKIT_ACTION_DATA_VALUE,
  ACCESSKIT_ACTION_DATA_NUMERIC_VALUE,
  ACCESSKIT_ACTION_DATA_SCROLL_UNIT,
  /**
   * Optional. Names the preferred position of the target node against the
   * scroll container's viewport.
   */
  ACCESSKIT_ACTION_DATA_SCROLL_HINT,
  ACCESSKIT_ACTION_DATA_SCROLL_TO_POINT,
  ACCESSKIT_ACTION_DATA_SET_SCROLL_OFFSET,
  ACCESSKIT_ACTION_DATA_SET_TEXT_SELECTION,
} accesskit_action_data_Tag;

/**
 * The payload of one action request.
 *
 * Read `tag` first. Every other member is a union, so at most one member is
 * meaningful at a time and reading a member the tag does not name is
 * undefined behaviour. The `value` member is a `char *` owned by the
 * enclosing `accesskit_action_request`; the caller never receives or releases
 * it separately.
 *
 * Every payload is a fixed-size C type. A variable-length payload crosses
 * this boundary as a pointer, and `value` is the only pointer among the
 * eight.
 */
typedef struct accesskit_action_data {
  accesskit_action_data_Tag tag;
  union {
    struct {
      int32_t custom_action;
    };
    struct {
      char *value;
    };
    struct {
      double numeric_value;
    };
    struct {
      accesskit_scroll_unit scroll_unit;
    };
    struct {
      accesskit_scroll_hint scroll_hint;
    };
    struct {
      struct accesskit_point scroll_to_point;
    };
    struct {
      struct accesskit_point set_scroll_offset;
    };
    struct {
      struct accesskit_text_selection set_text_selection;
    };
  };
} accesskit_action_data;

/**
 * An optional value. `has_value` is false when the property is unset; read
 * `value` only when it is true. The port writes a zero value into `value` in
 * the false case, so a reader who ignores the flag reads a defined zero
 * rather than uninitialised storage. That is a diagnostic aid, not a
 * contract.
 *
 * A copy of this struct is independent of the node it came from. Copying one
 * needs no release, and no operation invalidates the other copy.
 */
typedef struct accesskit_opt_action_data {
  bool has_value;
  /**
   * When it carries an `ACCESSKIT_ACTION_DATA_VALUE` payload, the `char *`
   * inside belongs to the enclosing `accesskit_action_request` and the caller
   * never receives or releases it separately.
   */
  struct accesskit_action_data value;
} accesskit_opt_action_data;

/**
 * One action the platform asks an application to perform, with the node it
 * applies to and, for some actions, a payload.
 */
typedef struct accesskit_action_request {
  /**
   * The action the platform asks for.
   */
  accesskit_action action;
  /**
   * The tree the action applies to.
   */
  struct accesskit_tree_id target_tree;
  /**
   * The node the action applies to.
   */
  accesskit_node_id target_node;
  /**
   * The payload. `has_value` is false when the action needs no payload. When it
   * is true, read `tag` before any other member.
   */
  struct accesskit_opt_action_data data;
} accesskit_action_request;

/* The four callbacks. Each is the whole seam between the library and
   the adapter author. */

/**
 * Builds one tree update for a platform adapter.
 *
 * Must not return `null`; returning `null` terminates the process. Ownership
 * of a returned update transfers to the library, which releases it after
 * delivery. The library calls this on its own thread, not the thread that
 * installed it, so it must not assume anything about that thread. `userdata`
 * must stay valid until the adapter is released.
 */
typedef struct accesskit_tree_update *
    (*accesskit_tree_update_factory)(accesskit_tree_update_factory_userdata);

/**
 * Returns the tree for a platform that has just activated accessibility, or
 * `null` when it has none.
 *
 * A `null` return is an ordinary answer, not a failure, and the library keeps
 * nothing. Ownership of a non-null result transfers to the library, which
 * releases it. This matches `accesskit_tree_update_factory` except that
 * `null` is allowed, and the two are documented the same way on purpose.
 * `userdata` must stay valid until the adapter is released.
 */
typedef struct accesskit_tree_update *
    (*accesskit_activation_handler_callback)(void *userdata);

/**
 * Called when the platform asks the application to perform `request`.
 *
 * Ownership of `request` transfers to this callback. Release it with
 * `accesskit_action_request_free` before returning, on every path out of the
 * callback. Forgetting it leaks the request and, when
 * `request->data.has_value` is true and `request->data.value.tag` is
 * `ACCESSKIT_ACTION_DATA_VALUE`, the string it holds.
 *
 * The library calls this on the platform's own thread. It says so for Linux,
 * iOS, tvOS and the Windows subclassing adapter, and says nothing for macOS,
 * Android and the plain Windows adapter. `userdata` must stay valid until the
 * adapter is released.
 */
typedef void
    (*accesskit_action_handler_callback)(
        struct accesskit_action_request *request, void *userdata);

/**
 * Called when the platform deactivates accessibility.
 *
 * It runs on the same thread as the activation handler for the same adapter.
 * `userdata` is passed through unchanged and must stay valid until the
 * adapter is released.
 */
typedef void (*accesskit_deactivation_handler_callback)(void *userdata);

/* The diagnostic channel. */

/**
 * The tag `accesskit_last_error` reports. `ACCESSKIT_ERROR_NONE` means the
 * call that just returned did not fail.
 *
 * The only failure a C caller can observe is an allocation failure, so the
 * tag has one failing member. A `null` or `false` return carrying
 * `ACCESSKIT_ERROR_NONE` is an ordinary answer: the property was unset, or
 * the predicate said no.
 */
typedef enum accesskit_error {
  ACCESSKIT_ERROR_NONE,
  ACCESSKIT_ERROR_OUT_OF_MEMORY,
} accesskit_error;

/* Functions. 496 of them, plus two this port adds. The declarations
   behind a platform guard are absent on every other target. */

#ifdef __cplusplus
extern "C" {
#endif /* __cplusplus */

/**
 * The tree identifier every update starts from: sixteen zero bytes.
 *
 * The value is read-only to a C caller.
 */
extern const struct accesskit_tree_id ACCESSKIT_TREE_ID_ROOT;

/**
 * Returns the node's role.
 *
 * A node always has one: `accesskit_node_new` takes it and no function clears
 * it.
 */
accesskit_role accesskit_node_role(const struct accesskit_node *node);

/**
 * Sets the node's role.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_set_role(struct accesskit_node *node,
                             accesskit_role value);

/**
 * Reports whether `action` is in the set this node supports.
 *
 * A `false` result is the answer, never a failure, so `accesskit_last_error`
 * stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_supports_action(const struct accesskit_node *node,
                                    accesskit_action action);

/**
 * Adds `action` to the set this node supports.
 *
 * An action the set already holds leaves the set unchanged. Returns nothing
 * and cannot fail.
 */
void accesskit_node_add_action(struct accesskit_node *node,
                               accesskit_action action);

/**
 * Removes `action` from the set this node supports.
 *
 * An action the set does not hold leaves the set unchanged. Returns nothing
 * and cannot fail.
 */
void accesskit_node_remove_action(struct accesskit_node *node,
                                  accesskit_action action);

/**
 * Empties the set of actions this node supports.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_actions(struct accesskit_node *node);

/**
 * Reports whether `action` is in the set this node's direct children support
 * in the filtered tree.
 *
 * A `false` result is the answer, never a failure.
 */
bool accesskit_node_child_supports_action(const struct accesskit_node *node,
                                          accesskit_action action);

/**
 * Adds `action` to the set this node's direct children support in the
 * filtered tree.
 *
 * An action the set already holds leaves the set unchanged. Returns nothing
 * and cannot fail.
 */
void accesskit_node_add_child_action(struct accesskit_node *node,
                                     accesskit_action action);

/**
 * Removes `action` from the set this node's direct children support in the
 * filtered tree.
 *
 * An action the set does not hold leaves the set unchanged. Returns nothing
 * and cannot fail.
 */
void accesskit_node_remove_child_action(struct accesskit_node *node,
                                        accesskit_action action);

/**
 * Empties the set of actions this node's direct children support in the
 * filtered tree.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_child_actions(struct accesskit_node *node);

/**
 * Reports the `hidden` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_is_hidden(const struct accesskit_node *node);

/**
 * Sets the `hidden` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_hidden(struct accesskit_node *node);

/**
 * Clears the `hidden` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_hidden(struct accesskit_node *node);

/**
 * Reports the `multiselectable` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_is_multiselectable(const struct accesskit_node *node);

/**
 * Sets the `multiselectable` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_multiselectable(struct accesskit_node *node);

/**
 * Clears the `multiselectable` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_multiselectable(struct accesskit_node *node);

/**
 * Reports the `required` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_is_required(const struct accesskit_node *node);

/**
 * Sets the `required` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_required(struct accesskit_node *node);

/**
 * Clears the `required` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_required(struct accesskit_node *node);

/**
 * Reports the `visited` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_is_visited(const struct accesskit_node *node);

/**
 * Sets the `visited` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_visited(struct accesskit_node *node);

/**
 * Clears the `visited` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_visited(struct accesskit_node *node);

/**
 * Reports the `busy` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_is_busy(const struct accesskit_node *node);

/**
 * Sets the `busy` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_busy(struct accesskit_node *node);

/**
 * Clears the `busy` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_busy(struct accesskit_node *node);

/**
 * Reports the `live_atomic` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_is_live_atomic(const struct accesskit_node *node);

/**
 * Sets the `live_atomic` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_live_atomic(struct accesskit_node *node);

/**
 * Clears the `live_atomic` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_live_atomic(struct accesskit_node *node);

/**
 * Reports the `modal` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_is_modal(const struct accesskit_node *node);

/**
 * Sets the `modal` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_modal(struct accesskit_node *node);

/**
 * Clears the `modal` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_modal(struct accesskit_node *node);

/**
 * Reports the `touch_transparent` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_is_touch_transparent(const struct accesskit_node *node);

/**
 * Sets the `touch_transparent` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_touch_transparent(struct accesskit_node *node);

/**
 * Clears the `touch_transparent` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_touch_transparent(struct accesskit_node *node);

/**
 * Reports the `read_only` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_is_read_only(const struct accesskit_node *node);

/**
 * Sets the `read_only` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_read_only(struct accesskit_node *node);

/**
 * Clears the `read_only` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_read_only(struct accesskit_node *node);

/**
 * Reports the `disabled` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_is_disabled(const struct accesskit_node *node);

/**
 * Sets the `disabled` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_disabled(struct accesskit_node *node);

/**
 * Clears the `disabled` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_disabled(struct accesskit_node *node);

/**
 * Reports the `italic` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_is_italic(const struct accesskit_node *node);

/**
 * Sets the `italic` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_italic(struct accesskit_node *node);

/**
 * Clears the `italic` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_italic(struct accesskit_node *node);

/**
 * Reports the `clips_children` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_clips_children(const struct accesskit_node *node);

/**
 * Sets the `clips_children` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_clips_children(struct accesskit_node *node);

/**
 * Clears the `clips_children` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_clips_children(struct accesskit_node *node);

/**
 * Reports the `is_line_breaking_object` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool
accesskit_node_is_line_breaking_object(const struct accesskit_node *node);

/**
 * Sets the `is_line_breaking_object` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_is_line_breaking_object(struct accesskit_node *node);

/**
 * Clears the `is_line_breaking_object` property, so the getter reports the
 * property as unset.
 *
 * Returns nothing and cannot fail.
 */
void
accesskit_node_clear_is_line_breaking_object(struct accesskit_node *node);

/**
 * Reports the `is_page_breaking_object` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool
accesskit_node_is_page_breaking_object(const struct accesskit_node *node);

/**
 * Sets the `is_page_breaking_object` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_is_page_breaking_object(struct accesskit_node *node);

/**
 * Clears the `is_page_breaking_object` property, so the getter reports the
 * property as unset.
 *
 * Returns nothing and cannot fail.
 */
void
accesskit_node_clear_is_page_breaking_object(struct accesskit_node *node);

/**
 * Reports the `is_spelling_error` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_is_spelling_error(const struct accesskit_node *node);

/**
 * Sets the `is_spelling_error` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_is_spelling_error(struct accesskit_node *node);

/**
 * Clears the `is_spelling_error` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_is_spelling_error(struct accesskit_node *node);

/**
 * Reports the `is_grammar_error` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_is_grammar_error(const struct accesskit_node *node);

/**
 * Sets the `is_grammar_error` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_is_grammar_error(struct accesskit_node *node);

/**
 * Clears the `is_grammar_error` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_is_grammar_error(struct accesskit_node *node);

/**
 * Reports the `is_search_match` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_is_search_match(const struct accesskit_node *node);

/**
 * Sets the `is_search_match` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_is_search_match(struct accesskit_node *node);

/**
 * Clears the `is_search_match` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_is_search_match(struct accesskit_node *node);

/**
 * Reports the `is_suggestion` property.
 *
 * A `false` result is the answer and never a failure, so
 * `accesskit_last_error` stays `ACCESSKIT_ERROR_NONE`.
 */
bool accesskit_node_is_suggestion(const struct accesskit_node *node);

/**
 * Sets the `is_suggestion` property to `true`.
 *
 * A property that has never been set reads the same as one that was set and
 * then cleared. Returns nothing and cannot fail.
 */
void accesskit_node_set_is_suggestion(struct accesskit_node *node);

/**
 * Clears the `is_suggestion` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_is_suggestion(struct accesskit_node *node);

/**
 * Returns the `children` property as a list of node identifiers.
 *
 * `values` points into storage this node owns: the node must stay alive and
 * its `children` list unmodified for as long as the caller reads `values`.
 * There is no function to release `values`, because the caller does not own
 * it. An unset property gives `length == 0` with a non-null `values`.
 */
struct accesskit_node_ids
accesskit_node_children(const struct accesskit_node *node);

/**
 * Copies `length` identifiers from `values` into the node's `children`.
 * Nothing is retained.
 *
 * `values` may be `null` when `length` is 0 and must not be `null` otherwise.
 * The caller keeps ownership of the array. On success `children` is exactly
 * the copied values. There is no failure path, so nothing partial can
 * survive.
 */
void accesskit_node_set_children(struct accesskit_node *node, size_t length,
                                 const accesskit_node_id *values);

/**
 * Appends `item` to the node's `children`.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_push_child(struct accesskit_node *node,
                               accesskit_node_id item);

/**
 * Clears the `children` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_children(struct accesskit_node *node);

/**
 * Returns the `controls` property as a list of node identifiers.
 *
 * `values` points into storage this node owns: the node must stay alive and
 * its `controls` list unmodified for as long as the caller reads `values`.
 * There is no function to release `values`, because the caller does not own
 * it. An unset property gives `length == 0` with a non-null `values`.
 */
struct accesskit_node_ids
accesskit_node_controls(const struct accesskit_node *node);

/**
 * Copies `length` identifiers from `values` into the node's `controls`.
 * Nothing is retained.
 *
 * `values` may be `null` when `length` is 0 and must not be `null` otherwise.
 * The caller keeps ownership of the array. On success `controls` is exactly
 * the copied values. There is no failure path, so nothing partial can
 * survive.
 */
void accesskit_node_set_controls(struct accesskit_node *node, size_t length,
                                 const accesskit_node_id *values);

/**
 * Appends `item` to the node's `controls`.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_push_controlled(struct accesskit_node *node,
                                    accesskit_node_id item);

/**
 * Clears the `controls` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_controls(struct accesskit_node *node);

/**
 * Returns the `details` property as a list of node identifiers.
 *
 * `values` points into storage this node owns: the node must stay alive and
 * its `details` list unmodified for as long as the caller reads `values`.
 * There is no function to release `values`, because the caller does not own
 * it. An unset property gives `length == 0` with a non-null `values`.
 */
struct accesskit_node_ids
accesskit_node_details(const struct accesskit_node *node);

/**
 * Copies `length` identifiers from `values` into the node's `details`.
 * Nothing is retained.
 *
 * `values` may be `null` when `length` is 0 and must not be `null` otherwise.
 * The caller keeps ownership of the array. On success `details` is exactly
 * the copied values. There is no failure path, so nothing partial can
 * survive.
 */
void accesskit_node_set_details(struct accesskit_node *node, size_t length,
                                const accesskit_node_id *values);

/**
 * Appends `item` to the node's `details`.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_push_detail(struct accesskit_node *node,
                                accesskit_node_id item);

/**
 * Clears the `details` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_details(struct accesskit_node *node);

/**
 * Returns the `described_by` property as a list of node identifiers.
 *
 * `values` points into storage this node owns: the node must stay alive and
 * its `described_by` list unmodified for as long as the caller reads
 * `values`. There is no function to release `values`, because the caller does
 * not own it. An unset property gives `length == 0` with a non-null `values`.
 */
struct accesskit_node_ids
accesskit_node_described_by(const struct accesskit_node *node);

/**
 * Copies `length` identifiers from `values` into the node's `described_by`.
 * Nothing is retained.
 *
 * `values` may be `null` when `length` is 0 and must not be `null` otherwise.
 * The caller keeps ownership of the array. On success `described_by` is
 * exactly the copied values. There is no failure path, so nothing partial can
 * survive.
 */
void accesskit_node_set_described_by(struct accesskit_node *node,
                                     size_t length,
                                     const accesskit_node_id *values);

/**
 * Appends `item` to the node's `described_by`.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_push_described_by(struct accesskit_node *node,
                                      accesskit_node_id item);

/**
 * Clears the `described_by` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_described_by(struct accesskit_node *node);

/**
 * Returns the `flow_to` property as a list of node identifiers.
 *
 * `values` points into storage this node owns: the node must stay alive and
 * its `flow_to` list unmodified for as long as the caller reads `values`.
 * There is no function to release `values`, because the caller does not own
 * it. An unset property gives `length == 0` with a non-null `values`.
 */
struct accesskit_node_ids
accesskit_node_flow_to(const struct accesskit_node *node);

/**
 * Copies `length` identifiers from `values` into the node's `flow_to`.
 * Nothing is retained.
 *
 * `values` may be `null` when `length` is 0 and must not be `null` otherwise.
 * The caller keeps ownership of the array. On success `flow_to` is exactly
 * the copied values. There is no failure path, so nothing partial can
 * survive.
 */
void accesskit_node_set_flow_to(struct accesskit_node *node, size_t length,
                                const accesskit_node_id *values);

/**
 * Appends `item` to the node's `flow_to`.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_push_flow_to(struct accesskit_node *node,
                                 accesskit_node_id item);

/**
 * Clears the `flow_to` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_flow_to(struct accesskit_node *node);

/**
 * Returns the `labelled_by` property as a list of node identifiers.
 *
 * `values` points into storage this node owns: the node must stay alive and
 * its `labelled_by` list unmodified for as long as the caller reads `values`.
 * There is no function to release `values`, because the caller does not own
 * it. An unset property gives `length == 0` with a non-null `values`.
 */
struct accesskit_node_ids
accesskit_node_labelled_by(const struct accesskit_node *node);

/**
 * Copies `length` identifiers from `values` into the node's `labelled_by`.
 * Nothing is retained.
 *
 * `values` may be `null` when `length` is 0 and must not be `null` otherwise.
 * The caller keeps ownership of the array. On success `labelled_by` is
 * exactly the copied values. There is no failure path, so nothing partial can
 * survive.
 */
void accesskit_node_set_labelled_by(struct accesskit_node *node,
                                    size_t length,
                                    const accesskit_node_id *values);

/**
 * Appends `item` to the node's `labelled_by`.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_push_labelled_by(struct accesskit_node *node,
                                     accesskit_node_id item);

/**
 * Clears the `labelled_by` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_labelled_by(struct accesskit_node *node);

/**
 * Returns the `owns` property as a list of node identifiers.
 *
 * `values` points into storage this node owns: the node must stay alive and
 * its `owns` list unmodified for as long as the caller reads `values`. There
 * is no function to release `values`, because the caller does not own it. An
 * unset property gives `length == 0` with a non-null `values`.
 */
struct accesskit_node_ids
accesskit_node_owns(const struct accesskit_node *node);

/**
 * Copies `length` identifiers from `values` into the node's `owns`. Nothing
 * is retained.
 *
 * `values` may be `null` when `length` is 0 and must not be `null` otherwise.
 * The caller keeps ownership of the array. On success `owns` is exactly the
 * copied values. There is no failure path, so nothing partial can survive.
 */
void accesskit_node_set_owns(struct accesskit_node *node, size_t length,
                             const accesskit_node_id *values);

/**
 * Appends `item` to the node's `owns`.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_push_owned(struct accesskit_node *node,
                               accesskit_node_id item);

/**
 * Clears the `owns` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_owns(struct accesskit_node *node);

/**
 * Returns the `radio_group` property as a list of node identifiers.
 *
 * `values` points into storage this node owns: the node must stay alive and
 * its `radio_group` list unmodified for as long as the caller reads `values`.
 * There is no function to release `values`, because the caller does not own
 * it. An unset property gives `length == 0` with a non-null `values`.
 */
struct accesskit_node_ids
accesskit_node_radio_group(const struct accesskit_node *node);

/**
 * Copies `length` identifiers from `values` into the node's `radio_group`.
 * Nothing is retained.
 *
 * `values` may be `null` when `length` is 0 and must not be `null` otherwise.
 * The caller keeps ownership of the array. On success `radio_group` is
 * exactly the copied values. There is no failure path, so nothing partial can
 * survive.
 */
void accesskit_node_set_radio_group(struct accesskit_node *node,
                                    size_t length,
                                    const accesskit_node_id *values);

/**
 * Appends `item` to the node's `radio_group`.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_push_to_radio_group(struct accesskit_node *node,
                                        accesskit_node_id item);

/**
 * Clears the `radio_group` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_radio_group(struct accesskit_node *node);

/**
 * Returns the `active_descendant` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_node_id
accesskit_node_active_descendant(const struct accesskit_node *node);

/**
 * Sets the `active_descendant` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_active_descendant(struct accesskit_node *node,
                                          accesskit_node_id value);

/**
 * Clears the `active_descendant` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_active_descendant(struct accesskit_node *node);

/**
 * Returns the `error_message` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_node_id
accesskit_node_error_message(const struct accesskit_node *node);

/**
 * Sets the `error_message` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_error_message(struct accesskit_node *node,
                                      accesskit_node_id value);

/**
 * Clears the `error_message` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_error_message(struct accesskit_node *node);

/**
 * Returns the `in_page_link_target` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_node_id
accesskit_node_in_page_link_target(const struct accesskit_node *node);

/**
 * Sets the `in_page_link_target` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_in_page_link_target(struct accesskit_node *node,
                                            accesskit_node_id value);

/**
 * Clears the `in_page_link_target` property, so the getter reports the
 * property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_in_page_link_target(struct accesskit_node *node);

/**
 * Returns the `member_of` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_node_id
accesskit_node_member_of(const struct accesskit_node *node);

/**
 * Sets the `member_of` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_member_of(struct accesskit_node *node,
                                  accesskit_node_id value);

/**
 * Clears the `member_of` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_member_of(struct accesskit_node *node);

/**
 * Returns the `next_on_line` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_node_id
accesskit_node_next_on_line(const struct accesskit_node *node);

/**
 * Sets the `next_on_line` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_next_on_line(struct accesskit_node *node,
                                     accesskit_node_id value);

/**
 * Clears the `next_on_line` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_next_on_line(struct accesskit_node *node);

/**
 * Returns the `previous_on_line` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_node_id
accesskit_node_previous_on_line(const struct accesskit_node *node);

/**
 * Sets the `previous_on_line` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_previous_on_line(struct accesskit_node *node,
                                         accesskit_node_id value);

/**
 * Clears the `previous_on_line` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_previous_on_line(struct accesskit_node *node);

/**
 * Returns the `popup_for` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_node_id
accesskit_node_popup_for(const struct accesskit_node *node);

/**
 * Sets the `popup_for` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_popup_for(struct accesskit_node *node,
                                  accesskit_node_id value);

/**
 * Clears the `popup_for` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_popup_for(struct accesskit_node *node);

/**
 * Returns the `tree_id` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_tree_id
accesskit_node_tree_id(const struct accesskit_node *node);

/**
 * Sets the `tree_id` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_tree_id(struct accesskit_node *node,
                                struct accesskit_tree_id value);

/**
 * Clears the `tree_id` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_tree_id(struct accesskit_node *node);

/**
 * Releases a string this library returned, exactly once.
 *
 * Call it only on a `char *` a getter in this header returned. Never pass a
 * string to `free`, and never release a string this library did not return.
 * Passing `null` terminates the process, and a second call on the same
 * pointer is a double free.
 */
void accesskit_string_free(char *string);

/**
 * Returns a copy of the `label` property, or `null` when the property is
 * unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_label(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `label`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_label(struct accesskit_node *node, const char *value);

/**
 * Copies `length` bytes from `value` into the node's `label`. `value` need
 * not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void accesskit_node_set_label_with_length(struct accesskit_node *node,
                                          const char *value, size_t length);

/**
 * Clears the `label` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_label(struct accesskit_node *node);

/**
 * Returns a copy of the `description` property, or `null` when the property
 * is unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_description(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `description`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_description(struct accesskit_node *node,
                                    const char *value);

/**
 * Copies `length` bytes from `value` into the node's `description`. `value`
 * need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void accesskit_node_set_description_with_length(struct accesskit_node *node,
                                                const char *value,
                                                size_t length);

/**
 * Clears the `description` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_description(struct accesskit_node *node);

/**
 * Returns a copy of the `value` property, or `null` when the property is
 * unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_value(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `value`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_value(struct accesskit_node *node, const char *value);

/**
 * Copies `length` bytes from `value` into the node's `value`. `value` need
 * not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void accesskit_node_set_value_with_length(struct accesskit_node *node,
                                          const char *value, size_t length);

/**
 * Clears the `value` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_value(struct accesskit_node *node);

/**
 * Returns a copy of the `access_key` property, or `null` when the property is
 * unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_access_key(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `access_key`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_access_key(struct accesskit_node *node,
                                   const char *value);

/**
 * Copies `length` bytes from `value` into the node's `access_key`. `value`
 * need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void accesskit_node_set_access_key_with_length(struct accesskit_node *node,
                                               const char *value,
                                               size_t length);

/**
 * Clears the `access_key` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_access_key(struct accesskit_node *node);

/**
 * Returns a copy of the `author_id` property, or `null` when the property is
 * unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_author_id(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `author_id`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_author_id(struct accesskit_node *node,
                                  const char *value);

/**
 * Copies `length` bytes from `value` into the node's `author_id`. `value`
 * need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void accesskit_node_set_author_id_with_length(struct accesskit_node *node,
                                              const char *value,
                                              size_t length);

/**
 * Clears the `author_id` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_author_id(struct accesskit_node *node);

/**
 * Returns a copy of the `class_name` property, or `null` when the property is
 * unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_class_name(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `class_name`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_class_name(struct accesskit_node *node,
                                   const char *value);

/**
 * Copies `length` bytes from `value` into the node's `class_name`. `value`
 * need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void accesskit_node_set_class_name_with_length(struct accesskit_node *node,
                                               const char *value,
                                               size_t length);

/**
 * Clears the `class_name` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_class_name(struct accesskit_node *node);

/**
 * Returns a copy of the `font_family` property, or `null` when the property
 * is unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_font_family(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `font_family`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_font_family(struct accesskit_node *node,
                                    const char *value);

/**
 * Copies `length` bytes from `value` into the node's `font_family`. `value`
 * need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void accesskit_node_set_font_family_with_length(struct accesskit_node *node,
                                                const char *value,
                                                size_t length);

/**
 * Clears the `font_family` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_font_family(struct accesskit_node *node);

/**
 * Returns a copy of the `html_id` property, or `null` when the property is
 * unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_html_id(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `html_id`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_html_id(struct accesskit_node *node,
                                const char *value);

/**
 * Copies `length` bytes from `value` into the node's `html_id`. `value` need
 * not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void accesskit_node_set_html_id_with_length(struct accesskit_node *node,
                                            const char *value, size_t length);

/**
 * Clears the `html_id` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_html_id(struct accesskit_node *node);

/**
 * Returns a copy of the `html_tag` property, or `null` when the property is
 * unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_html_tag(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `html_tag`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_html_tag(struct accesskit_node *node,
                                 const char *value);

/**
 * Copies `length` bytes from `value` into the node's `html_tag`. `value` need
 * not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void accesskit_node_set_html_tag_with_length(struct accesskit_node *node,
                                             const char *value,
                                             size_t length);

/**
 * Clears the `html_tag` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_html_tag(struct accesskit_node *node);

/**
 * Returns a copy of the `inner_html` property, or `null` when the property is
 * unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_inner_html(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `inner_html`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_inner_html(struct accesskit_node *node,
                                   const char *value);

/**
 * Copies `length` bytes from `value` into the node's `inner_html`. `value`
 * need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void accesskit_node_set_inner_html_with_length(struct accesskit_node *node,
                                               const char *value,
                                               size_t length);

/**
 * Clears the `inner_html` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_inner_html(struct accesskit_node *node);

/**
 * Returns a copy of the `keyboard_shortcut` property, or `null` when the
 * property is unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_keyboard_shortcut(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's
 * `keyboard_shortcut`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_keyboard_shortcut(struct accesskit_node *node,
                                          const char *value);

/**
 * Copies `length` bytes from `value` into the node's `keyboard_shortcut`.
 * `value` need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void
accesskit_node_set_keyboard_shortcut_with_length(struct accesskit_node *node,
    const char *value, size_t length);

/**
 * Clears the `keyboard_shortcut` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_keyboard_shortcut(struct accesskit_node *node);

/**
 * Returns a copy of the `language` property, or `null` when the property is
 * unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_language(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `language`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_language(struct accesskit_node *node,
                                 const char *value);

/**
 * Copies `length` bytes from `value` into the node's `language`. `value` need
 * not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void accesskit_node_set_language_with_length(struct accesskit_node *node,
                                             const char *value,
                                             size_t length);

/**
 * Clears the `language` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_language(struct accesskit_node *node);

/**
 * Returns a copy of the `placeholder` property, or `null` when the property
 * is unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_placeholder(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `placeholder`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_placeholder(struct accesskit_node *node,
                                    const char *value);

/**
 * Copies `length` bytes from `value` into the node's `placeholder`. `value`
 * need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void accesskit_node_set_placeholder_with_length(struct accesskit_node *node,
                                                const char *value,
                                                size_t length);

/**
 * Clears the `placeholder` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_placeholder(struct accesskit_node *node);

/**
 * Returns a copy of the `role_description` property, or `null` when the
 * property is unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_role_description(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's
 * `role_description`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_role_description(struct accesskit_node *node,
                                         const char *value);

/**
 * Copies `length` bytes from `value` into the node's `role_description`.
 * `value` need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void
accesskit_node_set_role_description_with_length(struct accesskit_node *node,
    const char *value, size_t length);

/**
 * Clears the `role_description` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_role_description(struct accesskit_node *node);

/**
 * Returns a copy of the `state_description` property, or `null` when the
 * property is unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_state_description(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's
 * `state_description`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_state_description(struct accesskit_node *node,
                                          const char *value);

/**
 * Copies `length` bytes from `value` into the node's `state_description`.
 * `value` need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void
accesskit_node_set_state_description_with_length(struct accesskit_node *node,
    const char *value, size_t length);

/**
 * Clears the `state_description` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_state_description(struct accesskit_node *node);

/**
 * Returns a copy of the `tooltip` property, or `null` when the property is
 * unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_tooltip(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `tooltip`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_tooltip(struct accesskit_node *node,
                                const char *value);

/**
 * Copies `length` bytes from `value` into the node's `tooltip`. `value` need
 * not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void accesskit_node_set_tooltip_with_length(struct accesskit_node *node,
                                            const char *value, size_t length);

/**
 * Clears the `tooltip` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_tooltip(struct accesskit_node *node);

/**
 * Returns a copy of the `url` property, or `null` when the property is unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_url(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `url`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_url(struct accesskit_node *node, const char *value);

/**
 * Copies `length` bytes from `value` into the node's `url`. `value` need not
 * be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void accesskit_node_set_url_with_length(struct accesskit_node *node,
                                        const char *value, size_t length);

/**
 * Clears the `url` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_url(struct accesskit_node *node);

/**
 * Returns a copy of the `row_index_text` property, or `null` when the
 * property is unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_row_index_text(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `row_index_text`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_row_index_text(struct accesskit_node *node,
                                       const char *value);

/**
 * Copies `length` bytes from `value` into the node's `row_index_text`.
 * `value` need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void
accesskit_node_set_row_index_text_with_length(struct accesskit_node *node,
    const char *value, size_t length);

/**
 * Clears the `row_index_text` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_row_index_text(struct accesskit_node *node);

/**
 * Returns a copy of the `column_index_text` property, or `null` when the
 * property is unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_column_index_text(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's
 * `column_index_text`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_column_index_text(struct accesskit_node *node,
                                          const char *value);

/**
 * Copies `length` bytes from `value` into the node's `column_index_text`.
 * `value` need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void
accesskit_node_set_column_index_text_with_length(struct accesskit_node *node,
    const char *value, size_t length);

/**
 * Clears the `column_index_text` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_column_index_text(struct accesskit_node *node);

/**
 * Returns a copy of the `braille_label` property, or `null` when the property
 * is unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char * accesskit_node_braille_label(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's `braille_label`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_braille_label(struct accesskit_node *node,
                                      const char *value);

/**
 * Copies `length` bytes from `value` into the node's `braille_label`. `value`
 * need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void accesskit_node_set_braille_label_with_length(struct accesskit_node *node,
                                                  const char *value,
                                                  size_t length);

/**
 * Clears the `braille_label` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_braille_label(struct accesskit_node *node);

/**
 * Returns a copy of the `braille_role_description` property, or `null` when
 * the property is unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char *
accesskit_node_braille_role_description(const struct accesskit_node *node);

/**
 * Copies the NUL-terminated string `value` into the node's
 * `braille_role_description`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_node_set_braille_role_description(struct accesskit_node *node,
                                                 const char *value);

/**
 * Copies `length` bytes from `value` into the node's
 * `braille_role_description`. `value` need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void
accesskit_node_set_braille_role_description_with_length(
    struct accesskit_node *node,
    const char *value,
    size_t length);

/**
 * Clears the `braille_role_description` property, so the getter reports the
 * property as unset.
 *
 * Returns nothing and cannot fail.
 */
void
accesskit_node_clear_braille_role_description(struct accesskit_node *node);

/**
 * Returns the `scroll_x` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_double
accesskit_node_scroll_x(const struct accesskit_node *node);

/**
 * Sets the `scroll_x` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_scroll_x(struct accesskit_node *node, double value);

/**
 * Clears the `scroll_x` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_scroll_x(struct accesskit_node *node);

/**
 * Returns the `scroll_x_min` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_double
accesskit_node_scroll_x_min(const struct accesskit_node *node);

/**
 * Sets the `scroll_x_min` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_scroll_x_min(struct accesskit_node *node,
                                     double value);

/**
 * Clears the `scroll_x_min` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_scroll_x_min(struct accesskit_node *node);

/**
 * Returns the `scroll_x_max` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_double
accesskit_node_scroll_x_max(const struct accesskit_node *node);

/**
 * Sets the `scroll_x_max` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_scroll_x_max(struct accesskit_node *node,
                                     double value);

/**
 * Clears the `scroll_x_max` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_scroll_x_max(struct accesskit_node *node);

/**
 * Returns the `scroll_y` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_double
accesskit_node_scroll_y(const struct accesskit_node *node);

/**
 * Sets the `scroll_y` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_scroll_y(struct accesskit_node *node, double value);

/**
 * Clears the `scroll_y` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_scroll_y(struct accesskit_node *node);

/**
 * Returns the `scroll_y_min` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_double
accesskit_node_scroll_y_min(const struct accesskit_node *node);

/**
 * Sets the `scroll_y_min` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_scroll_y_min(struct accesskit_node *node,
                                     double value);

/**
 * Clears the `scroll_y_min` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_scroll_y_min(struct accesskit_node *node);

/**
 * Returns the `scroll_y_max` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_double
accesskit_node_scroll_y_max(const struct accesskit_node *node);

/**
 * Sets the `scroll_y_max` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_scroll_y_max(struct accesskit_node *node,
                                     double value);

/**
 * Clears the `scroll_y_max` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_scroll_y_max(struct accesskit_node *node);

/**
 * Returns the `numeric_value` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_double
accesskit_node_numeric_value(const struct accesskit_node *node);

/**
 * Sets the `numeric_value` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_numeric_value(struct accesskit_node *node,
                                      double value);

/**
 * Clears the `numeric_value` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_numeric_value(struct accesskit_node *node);

/**
 * Returns the `min_numeric_value` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_double
accesskit_node_min_numeric_value(const struct accesskit_node *node);

/**
 * Sets the `min_numeric_value` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_min_numeric_value(struct accesskit_node *node,
                                          double value);

/**
 * Clears the `min_numeric_value` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_min_numeric_value(struct accesskit_node *node);

/**
 * Returns the `max_numeric_value` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_double
accesskit_node_max_numeric_value(const struct accesskit_node *node);

/**
 * Sets the `max_numeric_value` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_max_numeric_value(struct accesskit_node *node,
                                          double value);

/**
 * Clears the `max_numeric_value` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_max_numeric_value(struct accesskit_node *node);

/**
 * Returns the `numeric_value_step` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_double
accesskit_node_numeric_value_step(const struct accesskit_node *node);

/**
 * Sets the `numeric_value_step` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_numeric_value_step(struct accesskit_node *node,
                                           double value);

/**
 * Clears the `numeric_value_step` property, so the getter reports the
 * property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_numeric_value_step(struct accesskit_node *node);

/**
 * Returns the `numeric_value_jump` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_double
accesskit_node_numeric_value_jump(const struct accesskit_node *node);

/**
 * Sets the `numeric_value_jump` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_numeric_value_jump(struct accesskit_node *node,
                                           double value);

/**
 * Clears the `numeric_value_jump` property, so the getter reports the
 * property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_numeric_value_jump(struct accesskit_node *node);

/**
 * Returns the `font_size` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_float
accesskit_node_font_size(const struct accesskit_node *node);

/**
 * Sets the `font_size` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_font_size(struct accesskit_node *node, float value);

/**
 * Clears the `font_size` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_font_size(struct accesskit_node *node);

/**
 * Returns the `font_weight` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_float
accesskit_node_font_weight(const struct accesskit_node *node);

/**
 * Sets the `font_weight` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_font_weight(struct accesskit_node *node, float value);

/**
 * Clears the `font_weight` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_font_weight(struct accesskit_node *node);

/**
 * Returns the `row_count` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_index
accesskit_node_row_count(const struct accesskit_node *node);

/**
 * Sets the `row_count` property.
 *
 * A count, not an index into any table this header defines. Returns nothing
 * and cannot fail.
 */
void accesskit_node_set_row_count(struct accesskit_node *node, size_t value);

/**
 * Clears the `row_count` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_row_count(struct accesskit_node *node);

/**
 * Returns the `column_count` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_index
accesskit_node_column_count(const struct accesskit_node *node);

/**
 * Sets the `column_count` property.
 *
 * A count, not an index into any table this header defines. Returns nothing
 * and cannot fail.
 */
void accesskit_node_set_column_count(struct accesskit_node *node,
                                     size_t value);

/**
 * Clears the `column_count` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_column_count(struct accesskit_node *node);

/**
 * Returns the `row_index` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_index
accesskit_node_row_index(const struct accesskit_node *node);

/**
 * Sets the `row_index` property.
 *
 * A count, not an index into any table this header defines. Returns nothing
 * and cannot fail.
 */
void accesskit_node_set_row_index(struct accesskit_node *node, size_t value);

/**
 * Clears the `row_index` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_row_index(struct accesskit_node *node);

/**
 * Returns the `column_index` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_index
accesskit_node_column_index(const struct accesskit_node *node);

/**
 * Sets the `column_index` property.
 *
 * A count, not an index into any table this header defines. Returns nothing
 * and cannot fail.
 */
void accesskit_node_set_column_index(struct accesskit_node *node,
                                     size_t value);

/**
 * Clears the `column_index` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_column_index(struct accesskit_node *node);

/**
 * Returns the `row_span` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_index
accesskit_node_row_span(const struct accesskit_node *node);

/**
 * Sets the `row_span` property.
 *
 * A count, not an index into any table this header defines. Returns nothing
 * and cannot fail.
 */
void accesskit_node_set_row_span(struct accesskit_node *node, size_t value);

/**
 * Clears the `row_span` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_row_span(struct accesskit_node *node);

/**
 * Returns the `column_span` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_index
accesskit_node_column_span(const struct accesskit_node *node);

/**
 * Sets the `column_span` property.
 *
 * A count, not an index into any table this header defines. Returns nothing
 * and cannot fail.
 */
void accesskit_node_set_column_span(struct accesskit_node *node,
                                    size_t value);

/**
 * Clears the `column_span` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_column_span(struct accesskit_node *node);

/**
 * Returns the `level` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_index
accesskit_node_level(const struct accesskit_node *node);

/**
 * Sets the `level` property.
 *
 * A count, not an index into any table this header defines. Returns nothing
 * and cannot fail.
 */
void accesskit_node_set_level(struct accesskit_node *node, size_t value);

/**
 * Clears the `level` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_level(struct accesskit_node *node);

/**
 * Returns the `size_of_set` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_index
accesskit_node_size_of_set(const struct accesskit_node *node);

/**
 * Sets the `size_of_set` property.
 *
 * A count, not an index into any table this header defines. Returns nothing
 * and cannot fail.
 */
void accesskit_node_set_size_of_set(struct accesskit_node *node,
                                    size_t value);

/**
 * Clears the `size_of_set` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_size_of_set(struct accesskit_node *node);

/**
 * Returns the `position_in_set` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_index
accesskit_node_position_in_set(const struct accesskit_node *node);

/**
 * Sets the `position_in_set` property.
 *
 * A count, not an index into any table this header defines. Returns nothing
 * and cannot fail.
 */
void accesskit_node_set_position_in_set(struct accesskit_node *node,
                                        size_t value);

/**
 * Clears the `position_in_set` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_position_in_set(struct accesskit_node *node);

/**
 * Returns the `color_value` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_color
accesskit_node_color_value(const struct accesskit_node *node);

/**
 * Sets the `color_value` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_color_value(struct accesskit_node *node,
                                    struct accesskit_color value);

/**
 * Clears the `color_value` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_color_value(struct accesskit_node *node);

/**
 * Returns the `background_color` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_color
accesskit_node_background_color(const struct accesskit_node *node);

/**
 * Sets the `background_color` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_background_color(struct accesskit_node *node,
                                         struct accesskit_color value);

/**
 * Clears the `background_color` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_background_color(struct accesskit_node *node);

/**
 * Returns the `foreground_color` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_color
accesskit_node_foreground_color(const struct accesskit_node *node);

/**
 * Sets the `foreground_color` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_foreground_color(struct accesskit_node *node,
                                         struct accesskit_color value);

/**
 * Clears the `foreground_color` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_foreground_color(struct accesskit_node *node);

/**
 * Returns the `overline` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_text_decoration
accesskit_node_overline(const struct accesskit_node *node);

/**
 * Sets the `overline` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_overline(struct accesskit_node *node,
                                 struct accesskit_text_decoration value);

/**
 * Clears the `overline` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_overline(struct accesskit_node *node);

/**
 * Returns the `strikethrough` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_text_decoration
accesskit_node_strikethrough(const struct accesskit_node *node);

/**
 * Sets the `strikethrough` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_strikethrough(struct accesskit_node *node,
                                      struct accesskit_text_decoration value);

/**
 * Clears the `strikethrough` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_strikethrough(struct accesskit_node *node);

/**
 * Returns the `underline` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_text_decoration
accesskit_node_underline(const struct accesskit_node *node);

/**
 * Sets the `underline` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_underline(struct accesskit_node *node,
                                  struct accesskit_text_decoration value);

/**
 * Clears the `underline` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_underline(struct accesskit_node *node);

/**
 * Returns the `character_lengths` property as a list of per-character byte
 * lengths.
 *
 * `values` points into storage this node owns: the node must stay alive and
 * its `character_lengths` list unmodified while the caller reads `values`.
 * There is no function to release `values`, because the caller does not own
 * it. An unset property gives `length == 0` with a non-null `values`.
 */
struct accesskit_lengths
accesskit_node_character_lengths(const struct accesskit_node *node);

/**
 * Copies `length` bytes from `values` into the node's `character_lengths`.
 * Nothing is retained.
 *
 * `values` may be `null` when `length` is 0 and must not be `null` otherwise.
 * The caller keeps ownership of the array. On success `character_lengths` is
 * exactly the copied values. There is no failure path, so nothing partial can
 * survive.
 */
void accesskit_node_set_character_lengths(struct accesskit_node *node,
                                          size_t length,
                                          const uint8_t *values);

/**
 * Clears the `character_lengths` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_character_lengths(struct accesskit_node *node);

/**
 * Returns the `word_starts` property as a list of per-character byte lengths.
 *
 * `values` points into storage this node owns: the node must stay alive and
 * its `word_starts` list unmodified while the caller reads `values`. There is
 * no function to release `values`, because the caller does not own it. An
 * unset property gives `length == 0` with a non-null `values`.
 */
struct accesskit_lengths
accesskit_node_word_starts(const struct accesskit_node *node);

/**
 * Copies `length` bytes from `values` into the node's `word_starts`. Nothing
 * is retained.
 *
 * `values` may be `null` when `length` is 0 and must not be `null` otherwise.
 * The caller keeps ownership of the array. On success `word_starts` is
 * exactly the copied values. There is no failure path, so nothing partial can
 * survive.
 */
void accesskit_node_set_word_starts(struct accesskit_node *node,
                                    size_t length, const uint8_t *values);

/**
 * Clears the `word_starts` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_word_starts(struct accesskit_node *node);

/**
 * Returns the `character_positions` property as a list of per-character
 * positions or widths.
 *
 * `has_value` is false when the property is unset. `values` points into
 * storage this node owns: the node must stay alive and its
 * `character_positions` list unmodified while the caller reads `values`.
 * There is no function to release `values`, because the caller does not own
 * it.
 */
struct accesskit_opt_coords
accesskit_node_character_positions(const struct accesskit_node *node);

/**
 * Copies `length` measurements from `values` into the node's
 * `character_positions`. Nothing is retained.
 *
 * `values` may be `null` when `length` is 0 and must not be `null` otherwise.
 * The caller keeps ownership of the array. On success `character_positions`
 * is exactly the copied values. There is no failure path, so nothing partial
 * can survive.
 */
void accesskit_node_set_character_positions(struct accesskit_node *node,
                                            size_t length,
                                            const float *values);

/**
 * Clears the `character_positions` property, so the getter reports the
 * property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_character_positions(struct accesskit_node *node);

/**
 * Returns the `character_widths` property as a list of per-character
 * positions or widths.
 *
 * `has_value` is false when the property is unset. `values` points into
 * storage this node owns: the node must stay alive and its `character_widths`
 * list unmodified while the caller reads `values`. There is no function to
 * release `values`, because the caller does not own it.
 */
struct accesskit_opt_coords
accesskit_node_character_widths(const struct accesskit_node *node);

/**
 * Copies `length` measurements from `values` into the node's
 * `character_widths`. Nothing is retained.
 *
 * `values` may be `null` when `length` is 0 and must not be `null` otherwise.
 * The caller keeps ownership of the array. On success `character_widths` is
 * exactly the copied values. There is no failure path, so nothing partial can
 * survive.
 */
void accesskit_node_set_character_widths(struct accesskit_node *node,
                                         size_t length, const float *values);

/**
 * Clears the `character_widths` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_character_widths(struct accesskit_node *node);

/**
 * Returns the `expanded` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_bool
accesskit_node_is_expanded(const struct accesskit_node *node);

/**
 * Sets the `expanded` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_expanded(struct accesskit_node *node, bool value);

/**
 * Clears the `expanded` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_expanded(struct accesskit_node *node);

/**
 * Returns the `selected` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_bool
accesskit_node_is_selected(const struct accesskit_node *node);

/**
 * Sets the `selected` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_selected(struct accesskit_node *node, bool value);

/**
 * Clears the `selected` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_selected(struct accesskit_node *node);

/**
 * Returns the `invalid` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_invalid
accesskit_node_invalid(const struct accesskit_node *node);

/**
 * Sets the `invalid` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_invalid(struct accesskit_node *node,
                                accesskit_invalid value);

/**
 * Clears the `invalid` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_invalid(struct accesskit_node *node);

/**
 * Returns the `toggled` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_toggled
accesskit_node_toggled(const struct accesskit_node *node);

/**
 * Sets the `toggled` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_toggled(struct accesskit_node *node,
                                accesskit_toggled value);

/**
 * Clears the `toggled` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_toggled(struct accesskit_node *node);

/**
 * Returns the `live` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_live
accesskit_node_live(const struct accesskit_node *node);

/**
 * Sets the `live` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_live(struct accesskit_node *node,
                             accesskit_live value);

/**
 * Clears the `live` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_live(struct accesskit_node *node);

/**
 * Returns the `text_direction` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_text_direction
accesskit_node_text_direction(const struct accesskit_node *node);

/**
 * Sets the `text_direction` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_text_direction(struct accesskit_node *node,
                                       accesskit_text_direction value);

/**
 * Clears the `text_direction` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_text_direction(struct accesskit_node *node);

/**
 * Returns the `orientation` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_orientation
accesskit_node_orientation(const struct accesskit_node *node);

/**
 * Sets the `orientation` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_orientation(struct accesskit_node *node,
                                    accesskit_orientation value);

/**
 * Clears the `orientation` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_orientation(struct accesskit_node *node);

/**
 * Returns the `sort_direction` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_sort_direction
accesskit_node_sort_direction(const struct accesskit_node *node);

/**
 * Sets the `sort_direction` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_sort_direction(struct accesskit_node *node,
                                       accesskit_sort_direction value);

/**
 * Clears the `sort_direction` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_sort_direction(struct accesskit_node *node);

/**
 * Returns the `aria_current` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_aria_current
accesskit_node_aria_current(const struct accesskit_node *node);

/**
 * Sets the `aria_current` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_aria_current(struct accesskit_node *node,
                                     accesskit_aria_current value);

/**
 * Clears the `aria_current` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_aria_current(struct accesskit_node *node);

/**
 * Returns the `auto_complete` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_auto_complete
accesskit_node_auto_complete(const struct accesskit_node *node);

/**
 * Sets the `auto_complete` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_auto_complete(struct accesskit_node *node,
                                      accesskit_auto_complete value);

/**
 * Clears the `auto_complete` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_auto_complete(struct accesskit_node *node);

/**
 * Returns the `has_popup` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_has_popup
accesskit_node_has_popup(const struct accesskit_node *node);

/**
 * Sets the `has_popup` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_has_popup(struct accesskit_node *node,
                                  accesskit_has_popup value);

/**
 * Clears the `has_popup` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_has_popup(struct accesskit_node *node);

/**
 * Returns the `list_style` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_list_style
accesskit_node_list_style(const struct accesskit_node *node);

/**
 * Sets the `list_style` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_list_style(struct accesskit_node *node,
                                   accesskit_list_style value);

/**
 * Clears the `list_style` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_list_style(struct accesskit_node *node);

/**
 * Returns the `text_align` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_text_align
accesskit_node_text_align(const struct accesskit_node *node);

/**
 * Sets the `text_align` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_text_align(struct accesskit_node *node,
                                   accesskit_text_align value);

/**
 * Clears the `text_align` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_text_align(struct accesskit_node *node);

/**
 * Returns the `vertical_offset` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_vertical_offset
accesskit_node_vertical_offset(const struct accesskit_node *node);

/**
 * Sets the `vertical_offset` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_vertical_offset(struct accesskit_node *node,
                                        accesskit_vertical_offset value);

/**
 * Clears the `vertical_offset` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_vertical_offset(struct accesskit_node *node);

/**
 * Returns the `transform` property.
 *
 * Returns `NULL` when the property is unset. There is no `has_value` field on
 * this function: it returns a bare pointer, and the pointer is the whole
 * answer. A caller that receives a non-`NULL` pointer owns a copy and needs no
 * release; the transform borrows nothing from the node.
 */
const struct accesskit_affine *
accesskit_node_transform(const struct accesskit_node *node);

/**
 * Sets the `transform` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_transform(struct accesskit_node *node,
                                  struct accesskit_affine value);

/**
 * Clears the `transform` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_transform(struct accesskit_node *node);

/**
 * Returns the `bounds` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_rect
accesskit_node_bounds(const struct accesskit_node *node);

/**
 * Sets the `bounds` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_bounds(struct accesskit_node *node,
                               struct accesskit_rect value);

/**
 * Clears the `bounds` property, so the getter reports the property as unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_bounds(struct accesskit_node *node);

/**
 * Returns the `text_selection` property.
 *
 * `has_value` is false when the property is unset. A copy of the result
 * borrows nothing and needs no release.
 */
struct accesskit_opt_text_selection
accesskit_node_text_selection(const struct accesskit_node *node);

/**
 * Sets the `text_selection` property to `value`.
 *
 * Nothing is retained and nothing is borrowed. Returns nothing and cannot
 * fail.
 */
void accesskit_node_set_text_selection(struct accesskit_node *node,
                                       struct accesskit_text_selection value);

/**
 * Clears the `text_selection` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_text_selection(struct accesskit_node *node);

/**
 * Returns a new custom action with `id` set, or `null` when the allocation
 * failed.
 *
 * The caller owns the action and releases it with
 * `accesskit_custom_action_free`, once, unless ownership passes to
 * `accesskit_node_push_custom_action`. Call `accesskit_last_error` after a
 * `null` return. Nothing is allocated on the failure path.
 */
struct accesskit_custom_action * accesskit_custom_action_new(int32_t id);

/**
 * Releases the object and everything it owns, exactly once.
 *
 * The allocator that created it is not released. The object is unusable after
 * this call, and a second call on the same pointer is a double free. Passing
 * `null` terminates the process.
 */
void accesskit_custom_action_free(struct accesskit_custom_action *action);

/**
 * Returns the custom action's identifier.
 */
int32_t
accesskit_custom_action_id(const struct accesskit_custom_action *action);

/**
 * Sets the custom action's identifier.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_custom_action_set_id(struct accesskit_custom_action *action,
                                    int32_t id);

/**
 * Returns a copy of the `description` property, or `null` when the property
 * is unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char *
accesskit_custom_action_description(
    const struct accesskit_custom_action *action);

/**
 * Copies the NUL-terminated string `value` into the node's `description`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void
accesskit_custom_action_set_description(
    struct accesskit_custom_action *action,
    const char *description);

/**
 * Copies `length` bytes from `value` into the node's `description`. `value`
 * need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void
accesskit_custom_action_set_description_with_length(
    struct accesskit_custom_action *action,
    const char *description,
    size_t length);

/**
 * Releases the list, every action in it and the outer struct, exactly once.
 *
 * Every action in the list is released with it, so the caller must not
 * release one itself after this call. Passing `null` terminates the process.
 */
void accesskit_custom_actions_free(struct accesskit_custom_actions *value);

/**
 * Returns a deep copy of the node's custom actions, or `null` when the
 * allocation failed.
 *
 * An empty list has `length == 0`, never a `null` result. Release the result
 * with `accesskit_custom_actions_free`, once. Nothing in the returned value
 * borrows from the node, so the node may be released first.
 */
struct accesskit_custom_actions *
accesskit_node_custom_actions(const struct accesskit_node *node);

/**
 * Copies every action in the array into the node.
 *
 * Takes ownership of nothing. The caller keeps the array and every action in
 * it, releases each action with `accesskit_custom_action_free`, and releases
 * the array itself afterwards. There is no failure path.
 */
void
accesskit_node_set_custom_actions(struct accesskit_node *node, size_t length,
    struct accesskit_custom_action *const *values);

/**
 * Appends `action` to the node's custom action list. Takes ownership of
 * `action`.
 *
 * The caller must not release `action` after this call and must not pass it
 * again. There is no failure path, so the list is never left half-appended.
 */
void
accesskit_node_push_custom_action(struct accesskit_node *node,
    struct accesskit_custom_action *action);

/**
 * Clears the `custom_actions` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_node_clear_custom_actions(struct accesskit_node *node);

/**
 * Returns a new node with `role` set, or `null` when the allocation failed.
 *
 * The caller owns the node and releases it with `accesskit_node_free`, once,
 * unless ownership passes to `accesskit_tree_update_push_node`. Call
 * `accesskit_last_error` after a `null` return. Nothing is allocated on the
 * failure path.
 */
struct accesskit_node * accesskit_node_new(accesskit_role role);

/**
 * Releases the node and every string it owns, exactly once.
 *
 * The allocator that created it is not released. The node is unusable after
 * this call, and a second call on the same pointer is a double free. Passing
 * `null` terminates the process.
 */
void accesskit_node_free(struct accesskit_node *node);

/**
 * Returns a text rendering of the object, or `null` when the text could not
 * be built.
 *
 * Release the result with `accesskit_string_free`, once. The text borrows
 * nothing from the object once the call returns, so the object may be
 * released first.
 */
char * accesskit_node_debug(const struct accesskit_node *node);

/**
 * Returns a new tree info whose root is `root`, or `null` when the allocation
 * failed.
 *
 * The caller owns it and releases it with `accesskit_tree_info_free`, once,
 * unless ownership passes to `accesskit_tree_update_set_tree_info`. Call
 * `accesskit_last_error` after a `null` return. Nothing is allocated on the
 * failure path.
 */
struct accesskit_tree_info * accesskit_tree_info_new(accesskit_node_id root);

/**
 * Releases the tree info and every string it owns, exactly once.
 *
 * Passing `null` terminates the process, and a second call on the same
 * pointer is a double free.
 */
void accesskit_tree_info_free(struct accesskit_tree_info *tree);

/**
 * Returns a copy of the `toolkit_name` property, or `null` when the property
 * is unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char *
accesskit_tree_info_get_toolkit_name(const struct accesskit_tree_info *tree);

/**
 * Copies the NUL-terminated string `value` into the node's `toolkit_name`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_tree_info_set_toolkit_name(struct accesskit_tree_info *tree,
                                          const char *toolkit_name);

/**
 * Copies `length` bytes from `value` into the node's `toolkit_name`. `value`
 * need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void
accesskit_tree_info_set_toolkit_name_with_length(
    struct accesskit_tree_info *tree,
    const char *toolkit_name,
    size_t length);

/**
 * Clears the `toolkit_name` property, so the getter reports the property as
 * unset.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_tree_info_clear_toolkit_name(struct accesskit_tree_info *tree);

/**
 * Returns a copy of the `toolkit_version` property, or `null` when the
 * property is unset.
 *
 * Release the result with `accesskit_string_free`, once. Never pass it to
 * `free`, and never release a string this library did not return. A `null`
 * return covers two cases, the property being unset and the copy not fitting
 * in memory; `accesskit_last_error` tells them apart. Nothing survives the
 * second case.
 */
char *
accesskit_tree_info_get_toolkit_version(
    const struct accesskit_tree_info *tree);

/**
 * Copies the NUL-terminated string `value` into the node's `toolkit_version`.
 *
 * Nothing is retained. The caller keeps ownership of the buffer. There is no
 * failure path.
 */
void accesskit_tree_info_set_toolkit_version(struct accesskit_tree_info *tree,
                                             const char *toolkit_version);

/**
 * Copies `length` bytes from `value` into the node's `toolkit_version`.
 * `value` need not be NUL-terminated.
 *
 * Nothing is retained. A byte string is stored up to the first NUL byte,
 * because a value holding one cannot come back out of a `char *` getter
 * without losing its tail. The caller keeps the buffer. There is no failure
 * path.
 */
void
accesskit_tree_info_set_toolkit_version_with_length(
    struct accesskit_tree_info *tree,
    const char *toolkit_version,
    size_t length);

/**
 * Clears the `toolkit_version` property, so the getter reports the property
 * as unset.
 *
 * Returns nothing and cannot fail.
 */
void
accesskit_tree_info_clear_toolkit_version(struct accesskit_tree_info *tree);

/**
 * Returns a text rendering of the object, or `null` when the text could not
 * be built.
 *
 * Release the result with `accesskit_string_free`, once. The text borrows
 * nothing from the object once the call returns, so the object may be
 * released first.
 */
char * accesskit_tree_info_debug(const struct accesskit_tree_info *tree);

/**
 * Builds one tree update whose focus is `focus`, or `null` when the
 * allocation failed.
 *
 * The caller owns the update and releases it with
 * `accesskit_tree_update_free`, once, unless a tree update factory or an
 * activation handler takes ownership instead. Call `accesskit_last_error`
 * after a `null` return. Nothing is allocated on the failure path.
 */
struct accesskit_tree_update *
accesskit_tree_update_with_focus(accesskit_node_id focus);

/**
 * Builds one tree update whose focus is `focus` and which reserves room for
 * `capacity` nodes, or `null` when the allocation failed.
 *
 * `capacity` is a reservation and not a limit; the update grows past it. The
 * caller owns the update and releases it with `accesskit_tree_update_free`,
 * once, unless a tree update factory or an activation handler takes ownership
 * instead. Call `accesskit_last_error` after a `null` return.
 */
struct accesskit_tree_update *
accesskit_tree_update_with_capacity_and_focus(size_t capacity,
    accesskit_node_id focus);

/**
 * Releases the update, its tree info and every node still held by it, exactly
 * once.
 *
 * A node pushed into the update is released here, so the caller must not
 * release one itself. Passing `null` terminates the process, and a second
 * call on the same pointer is a double free.
 */
void accesskit_tree_update_free(struct accesskit_tree_update *update);

/**
 * Stores `node` under `id` in the update and takes ownership of it.
 *
 * The caller must not release `node` after this call and must not pass it
 * again; `accesskit_tree_update_free` releases it. On success the update
 * holds exactly the node passed. Returns nothing and cannot fail.
 */
void accesskit_tree_update_push_node(struct accesskit_tree_update *update,
                                     accesskit_node_id id,
                                     struct accesskit_node *node);

/**
 * Attaches `tree` to the update. Takes ownership of `tree`.
 *
 * The caller must not release `tree` after this call and must not pass it
 * again. A second call with the same pointer is a use-after-free, because the
 * first call consumed it. Passing `null` stores no tree info, the same state
 * as `accesskit_tree_update_clear_tree_info`; this one does not abort on
 * `null`.
 */
void accesskit_tree_update_set_tree_info(struct accesskit_tree_update *update,
                                         struct accesskit_tree_info *tree);

/**
 * Removes any tree info from the update.
 *
 * The tree info already set is released with the update. Both calls are valid
 * in either order, and the first tree info goes with the update.
 */
void
accesskit_tree_update_clear_tree_info(struct accesskit_tree_update *update);

/**
 * Sets the node the update focuses.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_tree_update_set_focus(struct accesskit_tree_update *update,
                                     accesskit_node_id focus);

/**
 * Returns the update's tree identifier.
 *
 * The value is copied by value, so no release is owed.
 */
struct accesskit_tree_id
accesskit_tree_update_get_tree_id(const struct accesskit_tree_update *update);

/**
 * Sets the update's tree identifier.
 *
 * Returns nothing and cannot fail.
 */
void accesskit_tree_update_set_tree_id(struct accesskit_tree_update *update,
                                       struct accesskit_tree_id tree_id);

/**
 * Returns a text rendering of the object, or `null` when the text could not
 * be built.
 *
 * Release the result with `accesskit_string_free`, once. The text borrows
 * nothing from the object once the call returns, so the object may be
 * released first.
 */
char *
accesskit_tree_update_debug(const struct accesskit_tree_update *tree_update);

/**
 * Releases the request and everything it owns, exactly once.
 *
 * When `request->data.has_value` is true and `request->data.value.tag` is
 * `ACCESSKIT_ACTION_DATA_VALUE`, this releases the `char *` at
 * `request->data.value.value` as well. Do not release that string separately.
 * Passing `null` terminates the process, and a second call on the same
 * pointer is a double free.
 */
void accesskit_action_request_free(struct accesskit_action_request *request);

/**
 * Returns the transform that leaves every point where it is.
 */
struct accesskit_affine accesskit_affine_identity(void);

/**
 * Returns the transform that mirrors across the x axis.
 */
struct accesskit_affine accesskit_affine_flip_y(void);

/**
 * Returns the transform that mirrors across the y axis.
 */
struct accesskit_affine accesskit_affine_flip_x(void);

/**
 * Returns the transform that scales every distance by `s`.
 */
struct accesskit_affine accesskit_affine_scale(double s);

/**
 * Returns the transform that scales the x axis by `s_x` and the y axis by
 * `s_y`.
 */
struct accesskit_affine accesskit_affine_scale_non_uniform(double s_x,
                                                           double s_y);

/**
 * Returns the transform that moves every point by `p`.
 */
struct accesskit_affine accesskit_affine_translate(struct accesskit_vec2 p);

/**
 * Returns the transform that maps the unit square onto `rect`.
 */
struct accesskit_affine
accesskit_affine_map_unit_square(struct accesskit_rect rect);

/**
 * Returns the determinant of `affine`, the factor by which it scales area.
 */
double accesskit_affine_determinant(struct accesskit_affine affine);

/**
 * Returns the transform that undoes `affine`.
 *
 * A singular `affine` has no inverse. The result then holds values that are
 * not finite, which `accesskit_affine_is_finite` reports.
 */
struct accesskit_affine
accesskit_affine_inverse(struct accesskit_affine affine);

/**
 * Returns the smallest rectangle containing `rect` after `affine` has been
 * applied to it.
 */
struct accesskit_rect
accesskit_affine_transform_rect_bbox(struct accesskit_affine affine,
    struct accesskit_rect rect);

/**
 * Reports whether every coefficient of `affine` is a finite number.
 *
 * Passing `null` returns `false` rather than reading the pointer.
 */
bool accesskit_affine_is_finite(const struct accesskit_affine *affine);

/**
 * Reports whether any coefficient of `affine` is a NaN.
 *
 * Passing `null` returns `false` rather than reading the pointer.
 */
bool accesskit_affine_is_nan(const struct accesskit_affine *affine);

/**
 * Returns the transform that applies `a` and then `b`.
 *
 * Both arguments and the result are 48-byte aggregates. On the x86-64 System
 * V convention the result travels through a hidden pointer, so a caller built
 * against a different convention corrupts its own stack.
 */
struct accesskit_affine accesskit_affine_mul(struct accesskit_affine a,
                                             struct accesskit_affine b);

/**
 * Returns `point` after `affine` has been applied to it.
 */
struct accesskit_point
accesskit_affine_transform_point(struct accesskit_affine affine,
    struct accesskit_point point);

/**
 * Returns the point read as a vector, so `x` and `y` keep their values.
 */
struct accesskit_vec2 accesskit_point_to_vec2(struct accesskit_point point);

/**
 * Returns `point` moved by `vec`.
 */
struct accesskit_point accesskit_point_add_vec2(struct accesskit_point point,
                                                struct accesskit_vec2 vec);

/**
 * Returns `point` moved back by `vec`.
 */
struct accesskit_point accesskit_point_sub_vec2(struct accesskit_point point,
                                                struct accesskit_vec2 vec);

/**
 * Returns the vector from `b` to `a`.
 */
struct accesskit_vec2 accesskit_point_sub_point(struct accesskit_point a,
                                                struct accesskit_point b);

/**
 * Returns the rectangle with the two given corners.
 */
struct accesskit_rect accesskit_rect_new(double x0, double y0, double x1,
                                         double y1);

/**
 * Returns the smallest rectangle with `p0` and `p1` as corners.
 */
struct accesskit_rect accesskit_rect_from_points(struct accesskit_point p0,
                                                 struct accesskit_point p1);

/**
 * Returns the rectangle with `origin` as its top-left corner and `size` as
 * its extent.
 */
struct accesskit_rect
accesskit_rect_from_origin_size(struct accesskit_point origin,
    struct accesskit_size size);

/**
 * Returns `rect` moved so that `origin` is its top-left corner, with its size
 * unchanged.
 */
struct accesskit_rect
accesskit_rect_with_origin(struct accesskit_rect rect,
    struct accesskit_point origin);

/**
 * Returns `rect` resized to `size` about its top-left corner.
 */
struct accesskit_rect accesskit_rect_with_size(struct accesskit_rect rect,
                                               struct accesskit_size size);

/**
 * Returns the width of `rect`, in logical pixels.
 *
 * Passing `null` returns `0` rather than reading the pointer.
 */
double accesskit_rect_width(const struct accesskit_rect *rect);

/**
 * Returns the height of `rect`, in logical pixels.
 *
 * Passing `null` returns `0` rather than reading the pointer.
 */
double accesskit_rect_height(const struct accesskit_rect *rect);

/**
 * Returns the left edge of `rect`, in logical pixels.
 *
 * Passing `null` returns `0` rather than reading the pointer.
 */
double accesskit_rect_min_x(const struct accesskit_rect *rect);

/**
 * Returns the right edge of `rect`, in logical pixels.
 *
 * Passing `null` returns `0` rather than reading the pointer.
 */
double accesskit_rect_max_x(const struct accesskit_rect *rect);

/**
 * Returns the top edge of `rect`, in logical pixels.
 *
 * Passing `null` returns `0` rather than reading the pointer.
 */
double accesskit_rect_min_y(const struct accesskit_rect *rect);

/**
 * Returns the bottom edge of `rect`, in logical pixels.
 *
 * Passing `null` returns `0` rather than reading the pointer.
 */
double accesskit_rect_max_y(const struct accesskit_rect *rect);

/**
 * Returns the top-left corner of `rect`, as a point.
 *
 * Passing `null` returns the point at the origin.
 */
struct accesskit_point
accesskit_rect_origin(const struct accesskit_rect *rect);

/**
 * Returns the width and height of `rect`, as a size.
 *
 * Passing `null` returns the zero size.
 */
struct accesskit_size accesskit_rect_size(const struct accesskit_rect *rect);

/**
 * Returns `rect` with every negative edge moved to the other side, so the
 * result has no negative width or height.
 *
 * Passing `null` returns the zero rectangle rather than reading the pointer.
 */
struct accesskit_rect accesskit_rect_abs(const struct accesskit_rect *rect);

/**
 * Returns the area of `rect`, in squared logical pixels.
 *
 * Passing `null` returns `0` rather than reading the pointer.
 */
double accesskit_rect_area(const struct accesskit_rect *rect);

/**
 * Reports whether `rect` encloses no area.
 *
 * Passing `null` returns `true`, because the zero rectangle encloses no area.
 */
bool accesskit_rect_is_empty(const struct accesskit_rect *rect);

/**
 * Reports whether `point` lies inside `rect`.
 *
 * Passing `null` returns `false` rather than reading the pointer.
 */
bool accesskit_rect_contains(const struct accesskit_rect *rect,
                             struct accesskit_point point);

/**
 * Returns the smallest rectangle holding both `rect` and `other`.
 *
 * Passing `null` returns the zero rectangle rather than reading the pointer.
 */
struct accesskit_rect accesskit_rect_union(const struct accesskit_rect *rect,
                                           struct accesskit_rect other);

/**
 * Returns the smallest rectangle holding `rect` and `pt`.
 *
 * Passing `null` returns the zero rectangle rather than reading the pointer.
 */
struct accesskit_rect
accesskit_rect_union_pt(const struct accesskit_rect *rect,
    struct accesskit_point pt);

/**
 * Returns the overlap of `rect` and `other`, or the zero rectangle where they
 * do not overlap.
 *
 * Passing `null` returns the zero rectangle rather than reading the pointer.
 */
struct accesskit_rect
accesskit_rect_intersect(const struct accesskit_rect *rect,
    struct accesskit_rect other);

/**
 * Returns `rect` moved by `translation`.
 */
struct accesskit_rect
accesskit_rect_translate(struct accesskit_rect rect,
    struct accesskit_vec2 translation);

/**
 * Returns the size read as a vector, with the width as `x` and the height as
 * `y`.
 */
struct accesskit_vec2 accesskit_size_to_vec2(struct accesskit_size size);

/**
 * Returns `size` with both dimensions multiplied by `scalar`.
 */
struct accesskit_size accesskit_size_scale(struct accesskit_size size,
                                           double scalar);

/**
 * Returns the size that adds `a` to `b` dimension by dimension.
 */
struct accesskit_size accesskit_size_add(struct accesskit_size a,
                                         struct accesskit_size b);

/**
 * Returns the size that subtracts `b` from `a` dimension by dimension.
 */
struct accesskit_size accesskit_size_sub(struct accesskit_size a,
                                         struct accesskit_size b);

/**
 * Returns the vector read as a point.
 */
struct accesskit_point accesskit_vec2_to_point(struct accesskit_vec2 vec2);

/**
 * Returns the vector read as a size.
 */
struct accesskit_size accesskit_vec2_to_size(struct accesskit_vec2 vec2);

/**
 * Returns the vector that adds `a` to `b`.
 */
struct accesskit_vec2 accesskit_vec2_add(struct accesskit_vec2 a,
                                         struct accesskit_vec2 b);

/**
 * Returns the vector that subtracts `b` from `a`.
 */
struct accesskit_vec2 accesskit_vec2_sub(struct accesskit_vec2 a,
                                         struct accesskit_vec2 b);

/**
 * Returns `vec` multiplied by `scalar`.
 */
struct accesskit_vec2 accesskit_vec2_scale(struct accesskit_vec2 vec,
                                           double scalar);

/**
 * Returns `vec` with both components negated.
 */
struct accesskit_vec2 accesskit_vec2_neg(struct accesskit_vec2 vec);


#if defined(__ANDROID__)
/**
 * Builds a platform action from the Java object an Android action callback
 * supplied.
 *
 * The returned action is owned by the caller and is released with
 * `accesskit_android_platform_action_free`. The `arguments` object belongs to
 * the Java call and is not retained.
 */
struct accesskit_android_platform_action *
accesskit_android_platform_action_from_java(JNIEnv *env, jint action,
    jobject arguments);

/**
 * Releases a platform action and everything it owns, exactly once.
 *
 * The node it names is not released. Passing `null` terminates the process.
 */
void
accesskit_android_platform_action_free(
    struct accesskit_android_platform_action *action);

/**
 * Raises the queued events on the platform and releases the handle.
 *
 * Memory is also freed when calling this function, and this call is the only
 * way to release it. The handle is unusable afterward, and a second call on
 * the same pointer is a use-after-free. Passing `null` terminates the
 * process.
 */
void
accesskit_android_queued_events_raise(
    struct accesskit_android_queued_events *events,
    JNIEnv *env,
    jobject host);

/**
 * Returns an Android adapter, or `null` when the allocation failed.
 *
 * The caller owns it and releases it with `accesskit_android_adapter_free`.
 * Call `accesskit_last_error` after a `null` return. The activation and
 * action handlers are passed in on the calls that need them, not here.
 */
struct accesskit_android_adapter * accesskit_android_adapter_new(void);

/**
 * Releases the adapter and every tree it holds, exactly once.
 *
 * A tree update already handed to the adapter was released by the library.
 * Passing `null` terminates the process.
 */
void
accesskit_android_adapter_free(struct accesskit_android_adapter *adapter);

/**
 * Asks `update_factory` for a tree and hands it to the adapter. The library
 * calls the factory on its own thread and releases the update after delivery.
 *
 * Returns the events the answer produced, or `null` when the adapter is not
 * active. Build nothing and do not raise events on the `null` path. The
 * caller owns a non-null result and must pass it to the matching
 * `*_queued_events_raise`, which also releases it.
 */
struct accesskit_android_queued_events *
accesskit_android_adapter_update_if_active(
    struct accesskit_android_adapter *adapter,
    accesskit_tree_update_factory update_factory,
    void *update_factory_userdata);

/**
 * Returns the Android `AccessibilityNodeInfo` for `virtual_view_id`, or
 * `null` when there is no such node.
 *
 * Ownership of the reference does not transfer; it is a JNI local reference
 * owned by the call this was made from.
 */
jobject
accesskit_android_adapter_create_accessibility_node_info(
    struct accesskit_android_adapter *adapter,
    accesskit_activation_handler_callback activation_handler,
    void *activation_handler_userdata,
    JNIEnv *env,
    jobject host,
    jint virtual_view_id);

/**
 * Returns the Android `AccessibilityNodeInfo` the focus belongs to, or `null`
 * when the tree has no focus.
 *
 * Ownership of the reference does not transfer; it is a JNI local reference
 * owned by the call this was made from.
 */
jobject
accesskit_android_adapter_find_focus(
    struct accesskit_android_adapter *adapter,
    accesskit_activation_handler_callback activation_handler,
    void *activation_handler_userdata,
    JNIEnv *env,
    jobject host,
    jint focus_type);

/**
 * Hands `action` to the application through `action_handler` and returns the
 * events the answer produced.
 *
 * Returns `null` when the adapter is not active. The caller owns the result
 * and must pass it to `accesskit_android_queued_events_raise`, which also
 * releases it.
 */
struct accesskit_android_queued_events *
accesskit_android_adapter_perform_action(
    struct accesskit_android_adapter *adapter,
    accesskit_action_handler_callback action_handler,
    void *action_handler_userdata,
    jint virtual_view_id,
    const struct accesskit_android_platform_action *action);

/**
 * Delivers a hover at the logical pixel `(x, y)` to the application through
 * `activation_handler` and returns the events the answer produced.
 *
 * Returns `null` when the adapter is not active. The caller owns the result
 * and must pass it to `accesskit_android_queued_events_raise`.
 */
struct accesskit_android_queued_events *
accesskit_android_adapter_on_hover_event(
    struct accesskit_android_adapter *adapter,
    accesskit_activation_handler_callback activation_handler,
    void *activation_handler_userdata,
    jint action,
    jfloat x,
    jfloat y);

/**
 * Returns an injecting Android adapter bound to `host`, or `null` when the
 * allocation failed.
 *
 * `host` and both handler userdata pointers must stay valid until the adapter
 * is released. The caller owns the adapter and releases it with
 * `accesskit_android_injecting_adapter_free`.
 */
struct accesskit_android_injecting_adapter *
accesskit_android_injecting_adapter_new(JNIEnv *env, jobject host,
    accesskit_activation_handler_callback activation_handler,
    void *activation_handler_userdata,
    accesskit_action_handler_callback action_handler,
    void *action_handler_userdata);

/**
 * Releases the adapter and every tree it holds, exactly once.
 *
 * Passing `null` terminates the process.
 */
void
accesskit_android_injecting_adapter_free(
    struct accesskit_android_injecting_adapter *adapter);

/**
 * Asks `update_factory` for a tree and hands it to the adapter. The library
 * calls the factory on its own thread and releases the update after delivery.
 *
 * Returns the events the answer produced, or `null` when the adapter is not
 * active. Build nothing and do not raise events on the `null` path. The
 * caller owns a non-null result and must pass it to the matching
 * `*_queued_events_raise`, which also releases it.
 */
void
accesskit_android_injecting_adapter_update_if_active(
    struct accesskit_android_injecting_adapter *adapter,
    accesskit_tree_update_factory update_factory,
    void *update_factory_userdata);

#endif /* __ANDROID__ */

#if (defined(ACCESSKIT_IOS) || defined(ACCESSKIT_TVOS) || \
     defined(ACCESSKIT_VISIONOS) || defined(ACCESSKIT_WATCHOS))
/**
 * Raises the queued events on the platform and releases the handle.
 *
 * Memory is also freed when calling this function, and this call is the only
 * way to release it. The handle is unusable afterward, and a second call on
 * the same pointer is a use-after-free. Passing `null` terminates the
 * process.
 */
void
accesskit_ios_queued_events_raise(struct accesskit_ios_queued_events *events);

/**
 * Returns an iOS-family adapter for `view`, or `null` when the allocation
 * failed.
 *
 * `view` and every handler pointer must stay valid until the adapter is
 * released. The library calls each handler on the main thread. The caller
 * owns the adapter and releases it with `accesskit_ios_adapter_free`.
 */
struct accesskit_ios_adapter *
accesskit_ios_adapter_new(void *view,
    accesskit_activation_handler_callback activation_handler,
    void *activation_handler_userdata,
    accesskit_action_handler_callback action_handler,
    void *action_handler_userdata,
    accesskit_deactivation_handler_callback deactivation_handler,
    void *deactivation_handler_userdata);

/**
 * Releases the adapter and every tree it holds, exactly once.
 *
 * Passing `null` terminates the process.
 */
void accesskit_ios_adapter_free(struct accesskit_ios_adapter *adapter);

/**
 * Asks `update_factory` for a tree and hands it to the adapter. The library
 * calls the factory on its own thread and releases the update after delivery.
 *
 * Returns the events the answer produced, or `null` when the adapter is not
 * active. Build nothing and do not raise events on the `null` path. The
 * caller owns a non-null result and must pass it to the matching
 * `*_queued_events_raise`, which also releases it.
 */
struct accesskit_ios_queued_events *
accesskit_ios_adapter_update_if_active(struct accesskit_ios_adapter *adapter,
    accesskit_tree_update_factory update_factory,
    void *update_factory_userdata);

/**
 * Tells the adapter that `view` appeared and returns the events the answer
 * produced.
 *
 * Returns `null` when the adapter is not active. The caller owns the result
 * and must pass it to `accesskit_ios_queued_events_raise`.
 */
struct accesskit_ios_queued_events *
accesskit_ios_adapter_view_did_appear(struct accesskit_ios_adapter *adapter);

/**
 * Reports whether the adapter's view is an accessibility element itself.
 */
bool
accesskit_ios_adapter_is_accessibility_element(
    struct accesskit_ios_adapter *adapter);

/**
 * Returns a pointer to the platform object this call names, or `null` when
 * there is no such object.
 *
 * Ownership of the pointer does not transfer. The object belongs to the
 * platform view, its lifetime is the platform's own, and this library does
 * not extend it. Reading it after the platform releases the object follows
 * the platform's rule, not this header's.
 */
void *
accesskit_ios_adapter_accessibility_elements(
    struct accesskit_ios_adapter *adapter);

/**
 * Returns a pointer to the platform object this call names, or `null` when
 * there is no such object.
 *
 * Ownership of the pointer does not transfer. The object belongs to the
 * platform view, its lifetime is the platform's own, and this library does
 * not extend it. Reading it after the platform releases the object follows
 * the platform's rule, not this header's.
 */
void * accesskit_ios_adapter_hit_test(struct accesskit_ios_adapter *adapter,
                                      double x, double y);

/**
 * Returns a text rendering of the object, or `null` when the text could not
 * be built.
 *
 * Release the result with `accesskit_string_free`, once. The text borrows
 * nothing from the object once the call returns, so the object may be
 * released first.
 */
char *
accesskit_ios_adapter_debug(const struct accesskit_ios_adapter *adapter);

/**
 * Returns an iOS-family subclassing adapter for `view`, or `null` when the
 * allocation failed.
 *
 * `view` and every handler pointer must stay valid until the adapter is
 * released. The library calls each handler on the main thread. The caller
 * owns the adapter and releases it with
 * `accesskit_ios_subclassing_adapter_free`.
 */
struct accesskit_ios_subclassing_adapter *
accesskit_ios_subclassing_adapter_new(void *view,
    accesskit_activation_handler_callback activation_handler,
    void *activation_handler_userdata,
    accesskit_action_handler_callback action_handler,
    void *action_handler_userdata,
    accesskit_deactivation_handler_callback deactivation_handler,
    void *deactivation_handler_userdata);

/**
 * Returns a subclassing adapter for `window`, or `null` when the allocation
 * failed.
 *
 * The conditions are the ones `accesskit_ios_subclassing_adapter_new` states.
 */
struct accesskit_ios_subclassing_adapter *
accesskit_ios_subclassing_adapter_for_window(void *window,
    accesskit_activation_handler_callback activation_handler,
    void *activation_handler_userdata,
    accesskit_action_handler_callback action_handler,
    void *action_handler_userdata,
    accesskit_deactivation_handler_callback deactivation_handler,
    void *deactivation_handler_userdata);

/**
 * Releases the adapter and every tree it holds, exactly once.
 *
 * Passing `null` terminates the process.
 */
void
accesskit_ios_subclassing_adapter_free(
    struct accesskit_ios_subclassing_adapter *adapter);

/**
 * Asks `update_factory` for a tree and hands it to the adapter. The library
 * calls the factory on its own thread and releases the update after delivery.
 *
 * Returns the events the answer produced, or `null` when the adapter is not
 * active. Build nothing and do not raise events on the `null` path. The
 * caller owns a non-null result and must pass it to the matching
 * `*_queued_events_raise`, which also releases it.
 */
struct accesskit_ios_queued_events *
accesskit_ios_subclassing_adapter_update_if_active(
    struct accesskit_ios_subclassing_adapter *adapter,
    accesskit_tree_update_factory update_factory,
    void *update_factory_userdata);

#endif /* the iOS, tvOS, visionOS and watchOS family */

#if defined(ACCESSKIT_MACOS)
/**
 * Raises the queued events on the platform and releases the handle.
 *
 * Memory is also freed when calling this function, and this call is the only
 * way to release it. The handle is unusable afterward, and a second call on
 * the same pointer is a use-after-free. Passing `null` terminates the
 * process.
 */
void
accesskit_macos_queued_events_raise(
    struct accesskit_macos_queued_events *events);

/**
 * Returns a macOS adapter for `view`, or `null` when the allocation failed.
 *
 * `view` and `action_handler_userdata` must stay valid until the adapter is
 * released. The caller owns the adapter and releases it with
 * `accesskit_macos_adapter_free`.
 */
struct accesskit_macos_adapter *
accesskit_macos_adapter_new(void *view, bool is_view_focused,
    accesskit_action_handler_callback action_handler,
    void *action_handler_userdata);

/**
 * Releases the adapter and every tree it holds, exactly once.
 *
 * Passing `null` terminates the process.
 */
void accesskit_macos_adapter_free(struct accesskit_macos_adapter *adapter);

/**
 * Asks `update_factory` for a tree and hands it to the adapter. The library
 * calls the factory on its own thread and releases the update after delivery.
 *
 * Returns the events the answer produced, or `null` when the adapter is not
 * active. Build nothing and do not raise events on the `null` path. The
 * caller owns a non-null result and must pass it to the matching
 * `*_queued_events_raise`, which also releases it.
 */
struct accesskit_macos_queued_events *
accesskit_macos_adapter_update_if_active(
    struct accesskit_macos_adapter *adapter,
    accesskit_tree_update_factory update_factory,
    void *update_factory_userdata);

/**
 * Tells the adapter whether `view` holds focus and returns the events the
 * answer produced.
 *
 * Returns `null` when the adapter is not active. The caller owns the result
 * and must pass it to `accesskit_macos_queued_events_raise`.
 */
struct accesskit_macos_queued_events *
accesskit_macos_adapter_update_view_focus_state(
    struct accesskit_macos_adapter *adapter,
    bool is_focused);

/**
 * Returns a pointer to the platform object this call names, or `null` when
 * there is no such object.
 *
 * Ownership of the pointer does not transfer. The object belongs to the
 * platform view, its lifetime is the platform's own, and this library does
 * not extend it. Reading it after the platform releases the object follows
 * the platform's rule, not this header's.
 */
void *
accesskit_macos_adapter_view_children(struct accesskit_macos_adapter *adapter,
    accesskit_activation_handler_callback activation_handler,
    void *activation_handler_userdata);

/**
 * Returns a pointer to the platform object this call names, or `null` when
 * there is no such object.
 *
 * Ownership of the pointer does not transfer. The object belongs to the
 * platform view, its lifetime is the platform's own, and this library does
 * not extend it. Reading it after the platform releases the object follows
 * the platform's rule, not this header's.
 */
void *
accesskit_macos_adapter_focus(struct accesskit_macos_adapter *adapter,
    accesskit_activation_handler_callback activation_handler,
    void *activation_handler_userdata);

/**
 * Returns a pointer to the platform object this call names, or `null` when
 * there is no such object.
 *
 * Ownership of the pointer does not transfer. The object belongs to the
 * platform view, its lifetime is the platform's own, and this library does
 * not extend it. Reading it after the platform releases the object follows
 * the platform's rule, not this header's.
 */
void *
accesskit_macos_adapter_hit_test(struct accesskit_macos_adapter *adapter,
    double x, double y,
    accesskit_activation_handler_callback activation_handler,
    void *activation_handler_userdata);

/**
 * Returns a text rendering of the object, or `null` when the text could not
 * be built.
 *
 * Release the result with `accesskit_string_free`, once. The text borrows
 * nothing from the object once the call returns, so the object may be
 * released first.
 */
char *
accesskit_macos_adapter_debug(const struct accesskit_macos_adapter *adapter);

/**
 * Returns a macOS subclassing adapter for `view`, or `null` when the
 * allocation failed.
 *
 * `view` and every handler pointer must stay valid until the adapter is
 * released. The caller owns the adapter and releases it with
 * `accesskit_macos_subclassing_adapter_free`.
 */
struct accesskit_macos_subclassing_adapter *
accesskit_macos_subclassing_adapter_new(void *view,
    accesskit_activation_handler_callback activation_handler,
    void *activation_handler_userdata,
    accesskit_action_handler_callback action_handler,
    void *action_handler_userdata);

/**
 * Returns a subclassing adapter for `window`, or `null` when the allocation
 * failed.
 *
 * The conditions are the ones `accesskit_macos_subclassing_adapter_new`
 * states.
 */
struct accesskit_macos_subclassing_adapter *
accesskit_macos_subclassing_adapter_for_window(void *window,
    accesskit_activation_handler_callback activation_handler,
    void *activation_handler_userdata,
    accesskit_action_handler_callback action_handler,
    void *action_handler_userdata);

/**
 * Releases the adapter and every tree it holds, exactly once.
 *
 * Passing `null` terminates the process.
 */
void
accesskit_macos_subclassing_adapter_free(
    struct accesskit_macos_subclassing_adapter *adapter);

/**
 * Asks `update_factory` for a tree and hands it to the adapter. The library
 * calls the factory on its own thread and releases the update after delivery.
 *
 * Returns the events the answer produced, or `null` when the adapter is not
 * active. Build nothing and do not raise events on the `null` path. The
 * caller owns a non-null result and must pass it to the matching
 * `*_queued_events_raise`, which also releases it.
 */
struct accesskit_macos_queued_events *
accesskit_macos_subclassing_adapter_update_if_active(
    struct accesskit_macos_subclassing_adapter *adapter,
    accesskit_tree_update_factory update_factory,
    void *update_factory_userdata);

/**
 * Tells the adapter whether `view` holds focus and returns the events the
 * answer produced.
 *
 * Returns `null` when the adapter is not active. The caller owns the result
 * and must pass it to `accesskit_macos_queued_events_raise`.
 */
struct accesskit_macos_queued_events *
accesskit_macos_subclassing_adapter_update_view_focus_state(
    struct accesskit_macos_subclassing_adapter *adapter,
    bool is_focused);

/**
 * Adds a focus forwarder to the `NSWindow` subclass named by the
 * NUL-terminated `class_name`.
 *
 * This function reads `class_name` and keeps its own copy. The caller keeps
 * ownership of the buffer and must not release it after this call. Calling
 * this twice for one class name has no additional effect.
 *
 * The change cannot be undone, so the library must stay loaded for the life
 * of the process. Link it statically into the main executable.
 */
void
accesskit_macos_add_focus_forwarder_to_window_class(const char *class_name);

/**
 * Adds a focus forwarder to the `NSWindow` subclass named by `class_name`,
 * which is `length` bytes and is not NUL-terminated.
 *
 * This function reads `class_name` and keeps its own copy. The caller keeps
 * ownership of the buffer and must not release it after this call. Calling
 * this twice for one class name has no additional effect.
 *
 * The change cannot be undone, so the library must stay loaded for the life
 * of the process. Link it statically into the main executable.
 */
void
accesskit_macos_add_focus_forwarder_to_window_class_with_length(
    const char *class_name,
    size_t length);

#endif /* ACCESSKIT_MACOS */

#if (defined(__linux__) || defined(__DragonFly__) || \
     defined(__FreeBSD__) || defined(__NetBSD__) || \
     defined(__OpenBSD__))
/**
 * Returns a Unix adapter, or `null` when the allocation failed.
 *
 * Every handler runs on a thread of the library's own, never on the thread
 * that calls this, and every handler pointer must stay valid until the
 * adapter is released. The caller owns the adapter and releases it with
 * `accesskit_unix_adapter_free`.
 */
struct accesskit_unix_adapter *
accesskit_unix_adapter_new(
    accesskit_activation_handler_callback activation_handler,
    void *activation_handler_userdata,
    accesskit_action_handler_callback action_handler,
    void *action_handler_userdata,
    accesskit_deactivation_handler_callback deactivation_handler,
    void *deactivation_handler_userdata);

/**
 * Releases the adapter and every tree it holds, exactly once.
 *
 * Passing `null` terminates the process.
 */
void accesskit_unix_adapter_free(struct accesskit_unix_adapter *adapter);

/**
 * Sets the outer bounds of the root window to `outer` and its inner bounds to
 * `inner`, in logical pixels relative to the screen origin.
 *
 * Returns nothing and cannot fail.
 */
void
accesskit_unix_adapter_set_root_window_bounds(
    struct accesskit_unix_adapter *adapter,
    struct accesskit_rect outer,
    struct accesskit_rect inner);

/**
 * Asks `update_factory` for a tree and hands it to the adapter. The library
 * calls the factory on its own thread and releases the update after delivery.
 *
 * Returns the events the answer produced, or `null` when the adapter is not
 * active. Build nothing and do not raise events on the `null` path. The
 * caller owns a non-null result and must pass it to the matching
 * `*_queued_events_raise`, which also releases it.
 */
void
accesskit_unix_adapter_update_if_active(
    struct accesskit_unix_adapter *adapter,
    accesskit_tree_update_factory update_factory,
    void *update_factory_userdata);

/**
 * Tells the adapter whether the window holds focus.
 *
 * Returns nothing and cannot fail.
 */
void
accesskit_unix_adapter_update_window_focus_state(
    struct accesskit_unix_adapter *adapter,
    bool is_focused);

/**
 * Returns a text rendering of the object, or `null` when the text could not
 * be built.
 *
 * Release the result with `accesskit_string_free`, once. The text borrows
 * nothing from the object once the call returns, so the object may be
 * released first.
 */
char *
accesskit_unix_adapter_debug(const struct accesskit_unix_adapter *adapter);

#endif /* the Linux and BSD family */

#if defined(_WIN32)
/**
 * Raises the queued events on the platform and releases the handle.
 *
 * Memory is also freed when calling this function, and this call is the only
 * way to release it. The handle is unusable afterward, and a second call on
 * the same pointer is a use-after-free. Passing `null` terminates the
 * process.
 */
void
accesskit_windows_queued_events_raise(
    struct accesskit_windows_queued_events *events);

/**
 * Returns a Windows adapter for `hwnd`, or `null` when the allocation failed.
 *
 * `action_handler_userdata` must stay valid until the adapter is released.
 * The caller owns the adapter and releases it with
 * `accesskit_windows_adapter_free`.
 */
struct accesskit_windows_adapter *
accesskit_windows_adapter_new(HWND hwnd, bool is_window_focused,
    accesskit_action_handler_callback action_handler,
    void *action_handler_userdata);

/**
 * Releases the adapter and every tree it holds, exactly once.
 *
 * Passing `null` terminates the process.
 */
void
accesskit_windows_adapter_free(struct accesskit_windows_adapter *adapter);

/**
 * Asks `update_factory` for a tree and hands it to the adapter. The library
 * calls the factory on its own thread and releases the update after delivery.
 *
 * Returns the events the answer produced, or `null` when the adapter is not
 * active. Build nothing and do not raise events on the `null` path. The
 * caller owns a non-null result and must pass it to the matching
 * `*_queued_events_raise`, which also releases it.
 */
struct accesskit_windows_queued_events *
accesskit_windows_adapter_update_if_active(
    struct accesskit_windows_adapter *adapter,
    accesskit_tree_update_factory update_factory,
    void *update_factory_userdata);

/**
 * Tells the adapter whether `hwnd` holds focus and returns the events the
 * answer produced.
 *
 * Returns `null` when the adapter is not active. The caller owns the result
 * and must pass it to `accesskit_windows_queued_events_raise`.
 */
struct accesskit_windows_queued_events *
accesskit_windows_adapter_update_window_focus_state(
    struct accesskit_windows_adapter *adapter,
    bool is_focused);

/**
 * Answers a `WM_GETOBJECT` message from a window procedure.
 *
 * The window procedure passes the message's `wparam` and `lparam` unchanged.
 * `has_value` is false when this adapter is not the one that owns the window,
 * and the window procedure then returns `false` from `DefWindowProc`. When
 * `has_value` is true the value is the `LRESULT` to return. The library calls
 * `activation_handler` on its own thread, and any tree update it returns is
 * released by the library.
 */
struct accesskit_opt_lresult
accesskit_windows_adapter_handle_wm_getobject(
    struct accesskit_windows_adapter *adapter,
    WPARAM wparam,
    LPARAM lparam,
    accesskit_activation_handler_callback activation_handler,
    void *activation_handler_userdata);

/**
 * Returns a text rendering of the object, or `null` when the text could not
 * be built.
 *
 * Release the result with `accesskit_string_free`, once. The text borrows
 * nothing from the object once the call returns, so the object may be
 * released first.
 */
char *
accesskit_windows_adapter_debug(
    const struct accesskit_windows_adapter *adapter);

/**
 * Returns a Windows subclassing adapter for `hwnd`, or `null` when the
 * allocation failed.
 *
 * Every handler pointer must stay valid until the adapter is released. The
 * caller owns the adapter and releases it with
 * `accesskit_windows_subclassing_adapter_free`.
 */
struct accesskit_windows_subclassing_adapter *
accesskit_windows_subclassing_adapter_new(HWND hwnd,
    accesskit_activation_handler_callback activation_handler,
    void *activation_handler_userdata,
    accesskit_action_handler_callback action_handler,
    void *action_handler_userdata);

/**
 * Releases the adapter and every tree it holds, exactly once.
 *
 * Passing `null` terminates the process.
 */
void
accesskit_windows_subclassing_adapter_free(
    struct accesskit_windows_subclassing_adapter *adapter);

/**
 * Asks `update_factory` for a tree and hands it to the adapter. The library
 * calls the factory on its own thread and releases the update after delivery.
 *
 * Returns the events the answer produced, or `null` when the adapter is not
 * active. Build nothing and do not raise events on the `null` path. The
 * caller owns a non-null result and must pass it to the matching
 * `*_queued_events_raise`, which also releases it.
 */
struct accesskit_windows_queued_events *
accesskit_windows_subclassing_adapter_update_if_active(
    struct accesskit_windows_subclassing_adapter *adapter,
    accesskit_tree_update_factory update_factory,
    void *update_factory_userdata);

#endif /* _WIN32 */

/* The two functions this port adds. Both are optional: a consumer that
   calls neither sees upstream's behaviour exactly. */

/**
 * Installs the allocator every exported function in this library uses. Call
 * it once, before any other function in this header.
 *
 * `alloc` and `free` must stay valid until the process exits. This library
 * calls them from whatever thread made the allocation, so both must be
 * thread-safe. Passing `null` for either restores the default C allocator.
 * Passing `null` for `context` passes `null` back to both functions on every
 * call.
 *
 * Installing an allocator after the first call has no effect on allocations
 * already made, and none of those is released through the new pair.
 */
void accesskit_set_allocator(
    void *(*alloc)(size_t size, void *context),
    void (*free)(void *ptr, void *context), void *context);

/**
 * Returns the failure tag of the most recent call on the calling thread.
 *
 * Every function clears the tag on entry and sets it on the failing path, so
 * the tag is valid only until the next call on this thread. Read it
 * immediately after the call that failed and before making another call.
 * `ACCESSKIT_ERROR_NONE` means that call did not fail.
 */
accesskit_error accesskit_last_error(void);

#ifdef __cplusplus
}  // extern "C"
#endif /* __cplusplus */

/*
 * Conformance.
 *
 * The sizes and alignments below were measured on x86-64 Linux by compiling
 * this header with the system C compiler and printing `sizeof`, `_Alignof` and
 * `offsetof`. They are the numbers the library must agree with. A consumer
 * that checks them with `_Static_assert` proves the two sides agree; a
 * consumer that does not check them assumes it.
 *
 * These numbers are a property of the layout only. The passing convention for
 * an aggregate is a property of the calling convention, and a caller compiled
 * with a different classification corrupts its own stack without any size
 * disagreeing. Compile this header and link the library; do not hand-write
 * the prototypes.

 * The laid-out aggregates. The last column is the offset of the
 * payload, which is `value` on an optional, `values` on a list, and
 * `-` where the type has no payload field.
 *
 *   type                         size  align  payload
 *   --------------------------- ----- ------  -------
 *   accesskit_node_ids             16      8  8
 *   accesskit_opt_node_id          16      8  8
 *   accesskit_tree_id              16      1  -
 *   accesskit_opt_tree_id          17      1  1
 *   accesskit_opt_double           16      8  8
 *   accesskit_opt_float             8      4  4
 *   accesskit_opt_index            16      8  8
 *   accesskit_color                 4      1  -
 *   accesskit_opt_color             5      1  1
 *   accesskit_text_decoration       5      1  -
 *   accesskit_opt_text_decoration     6      1  1
 *   accesskit_lengths              16      8  8
 *   accesskit_opt_coords           24      8  16
 *   accesskit_opt_bool              2      1  1
 *   accesskit_opt_invalid           2      1  1
 *   accesskit_opt_toggled           2      1  1
 *   accesskit_opt_live              2      1  1
 *   accesskit_opt_text_direction     2      1  1
 *   accesskit_opt_orientation       2      1  1
 *   accesskit_opt_sort_direction     2      1  1
 *   accesskit_opt_aria_current      2      1  1
 *   accesskit_opt_auto_complete     2      1  1
 *   accesskit_opt_has_popup         2      1  1
 *   accesskit_opt_list_style        2      1  1
 *   accesskit_opt_text_align        2      1  1
 *   accesskit_opt_vertical_offset     2      1  1
 *   accesskit_affine               48      8  -
 *   accesskit_rect                 32      8  -
 *   accesskit_opt_rect             40      8  8
 *   accesskit_text_position        16      8  -
 *   accesskit_text_selection       32      8  16
 *   accesskit_opt_text_selection    40      8  8
 *   accesskit_custom_actions       16      8  8
 *   accesskit_point                16      8  -
 *   accesskit_vec2                 16      8  -
 *   accesskit_size                 16      8  -
 *   accesskit_opt_action_data      48      8  8
 *   accesskit_action_request       80      8  1
 *   accesskit_action_data          40      8  8
 *
 * `accesskit_opt_lresult` is absent from the table because it exists
 * only under `_WIN32`. `accesskit_action_data`'s payload is an
 * anonymous union, so no `offsetof` names it; its offset was measured
 * from the address of a member read through the union.
 *
 * Two of these numbers decide the layout and are worth naming.
 * `accesskit_affine` is 48 bytes, past the return budget of the
 * x86-64 System V convention, so it travels through a hidden pointer.
 * `accesskit_action_data_Tag` is a C enum with no fixed base and
 * measures 4 bytes here; a target that measures it differently needs
 * the conformance test, not this table.
 *
 * What a reader can run to confirm this header.
 *
 * 1. `cc -std=c11 -fsyntax-only -I<include-dir> -xc include/zaccesskit.h`
 *    proves the file is C11 and parses. It proves nothing about the library
 *    and nothing about a link.
 *
 * 2. A C fixture with `_Static_assert` on every size, alignment and offset in
 *    the table above proves the C compiler's own answers agree with this
 *    header. It proves nothing about how an argument is passed.
 *
 * 3. A C fixture linked against the shipped shared library that calls one
 *    function of each shape proves the calling conventions agree, and that
 *    the symbols resolve. It proves nothing about the logic behind a call.
 *
 * Checks 2 and 3 cannot run yet: this repository has no C artefact. They are
 * the checks the port owes, not checks it has run.
 */

#endif /* ZACCESSKIT_H */
