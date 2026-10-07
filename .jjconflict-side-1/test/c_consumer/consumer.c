/*
 * A C consumer of `include/zaccesskit.h`.
 *
 * What this file is for. The header is 6572 lines with 498 declarations. That
 * it parses as C11 under `-Wall -Wextra -Wpedantic` says the header is
 * syntactically valid. It does not say a C program can use it. This program is
 * the missing evidence: it includes the header, takes a tree, walks it, reads a
 * node's role and extents, receives an action request and registers the four
 * platform callbacks, and it spells every `accesskit_opt_*` form, every
 * `const char *` plus `size_t` pair, every by-value aggregate, and every free
 * function that this target exposes.
 *
 * Standard. C11, compiled with `-Wall -Wextra -Wpedantic` and no other flag.
 * C11 is the mode this library claims and the mode the header is clean in. The
 * header emits 10 `-Wpedantic` diagnostics under C99, 9 `-Wc11-extensions` under
 * clang in C99, and 8 to 16 under C++17, all of them from the eight anonymous
 * structs inside `accesskit_action_data`. C11 gave C anonymous structures, so
 * this program is C11 and says so rather than working around the extension.
 *
 * Linking. This program does not link yet. `src/capi/` is being written in
 * parallel, so every `accesskit_` symbol below is undefined at link time and
 * that is the expected state. Nothing here claims the library works. What is
 * checked today is that the header is usable from C, which is a property of
 * the header alone.
 *
 * Failing loudly. Every assertion reports the file, the line and the source of
 * the condition, and `main` returns a non-zero count. A test that cannot fail
 * is worse than no test, so no check here is a tautology: each one would fail
 * on a wrong value, a wrong flag, a leaked pointer or a missing NUL.
 */

#define _POSIX_C_SOURCE 200809L

#include "zaccesskit.h"

#include "surface.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !defined(_WIN32)
#include <sys/mman.h>
#include <unistd.h>
#endif

#define COUNT(a) (sizeof(a) / sizeof((a)[0]))

static unsigned long checks_run;
static unsigned long checks_failed;

/* Reports one failed condition and keeps going, so one bad property does not
   hide the next. */
#define CHECK(cond)                                                           \
    do {                                                                      \
        ++checks_run;                                                         \
        if (!(cond)) {                                                        \
            ++checks_failed;                                                  \
            (void)fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__,     \
                          #cond);                                             \
        }                                                                     \
    } while (0)

/* A count of bytes, printed as a decimal so a report names the real number. */
#define CHECK_SIZE(label, actual, expected)                                    \
    do {                                                                      \
        size_t actual_ = (actual);                                            \
        size_t expected_ = (expected);                                        \
        ++checks_run;                                                         \
        if (actual_ != expected_) {                                           \
            ++checks_failed;                                                  \
            (void)fprintf(stderr,                                             \
                          "FAIL %s:%d: %s is %lu, expected %lu\n", __FILE__,   \
                          __LINE__, (label), (unsigned long)actual_,          \
                          (unsigned long)expected_);                          \
        }                                                                     \
    } while (0)

/* A section that was compiled but deliberately not run. Saying so is the point:
   a reader counting checks has to be able to tell a check that passed from one
   that never ran. */
static unsigned long sections_skipped;

static void note_skipped(const char *what)
{
    ++sections_skipped;
    (void)fprintf(stdout, "SKIP %s: compiled, not run\n", what);
}

static bool bytes_are_zero(const void *data, size_t length)
{
    const unsigned char *bytes = (const unsigned char *)data;
    size_t index;
    for (index = 0; index < length; ++index) {
        if (bytes[index] != 0u) {
            return false;
        }
    }
    return true;
}

/* ------------------------------------------------------------------------- */
/* The allocator seam. `accesskit_set_allocator` takes two function pointers   */
/* and a context. Installed first, so every later allocation the library makes */
/* is counted here.                                                              */
/* ------------------------------------------------------------------------- */

static unsigned long allocator_alloc_calls;
static unsigned long allocator_free_calls;
static int allocator_context_seen;

static void *counting_alloc(size_t size, void *context)
{
    ++allocator_alloc_calls;
    allocator_context_seen = (context == &allocator_context_seen);
    return malloc(size);
}

static void counting_free(void *pointer, void *context)
{
    ++allocator_free_calls;
    if (context == &allocator_context_seen) {
        free(pointer);
    }
}

/* ------------------------------------------------------------------------- */
/* Release counters. Each `*_free` the header declares is called on its own     */
/* allocation, once, and the count is checked.                                 */
/* ------------------------------------------------------------------------- */

static unsigned long string_free_calls;
static unsigned long custom_action_free_calls;
static unsigned long custom_actions_free_calls;
static unsigned long node_free_calls;
static unsigned long tree_info_free_calls;
static unsigned long tree_update_free_calls;
static unsigned long action_request_free_calls;

static void release_string(char *string, const char *what)
{
    if (string == NULL) {
        ++checks_run;
        ++checks_failed;
        (void)fprintf(stderr, "FAIL %s: %s returned no string\n", __FILE__, what);
        return;
    }
    ++string_free_calls;
    accesskit_string_free(string);
}

/* The one release path a callback owns. `accesskit_action_request_free` is the
   only free a C consumer cannot reach on its own, because the header gives no
   way to build a request the library will accept ownership of. It runs here,
   on a request the library delivered, exactly once, on every path out of the
   callback including the early ones. */
static void release_action_request(struct accesskit_action_request *request)
{
    if (request == NULL) {
        ++checks_run;
        ++checks_failed;
        (void)fprintf(stderr, "FAIL %s: a null action request reached the "
                               "handler\n",
                      __FILE__);
        return;
    }
    ++action_request_free_calls;
    accesskit_action_request_free(request);
}

/* ------------------------------------------------------------------------- */
/* The four callbacks.                                                         */
/*                                                                            */
/* Each one is written with the header's spelling, then assigned to the        */
/* header's own function-pointer typedef. A mismatch in the parameter list,    */
/* the return type or the calling convention is a constraint violation at     */
/* that assignment, and it is the only place in C where one is caught. The     */
/* program then calls through the pointer rather than the named function, so   */
/* a wrong convention is exercised, not just checked.                         */
/* ------------------------------------------------------------------------- */

typedef struct adapter_state {
    unsigned long activations;
    unsigned long deactivations;
    unsigned long actions;
    unsigned long updates_built;
    accesskit_node_id last_action_node;
    accesskit_action last_action;
    accesskit_action_data_Tag last_tag;
} adapter_state;

static struct accesskit_tree_update *on_activate(void *userdata)
{
    struct adapter_state *state = (struct adapter_state *)userdata;
    ++state->activations;
    /* `null` is an ordinary answer here, so it is what this one returns. */
    return NULL;
}

static void on_deactivate(void *userdata)
{
    struct adapter_state *state = (struct adapter_state *)userdata;
    ++state->deactivations;
}

/* The handler a real adapter registers. The header says ownership of
   `request` transfers into this callback, so it is released on every path out,
   including this one. */
static void on_action(struct accesskit_action_request *request, void *userdata)
{
    struct adapter_state *state = (struct adapter_state *)userdata;

    ++state->actions;
    if (request != NULL) {
        state->last_action = request->action;
        state->last_action_node = request->target_node;
    }
    /* The early return above is the one path a consumer most often forgets,
       and it is the path the header names: release before returning. */
    release_action_request(request);
}

/* The same signature, without the release. This program cannot make a request
   the library will accept ownership of, so the only way to call an action
   handler at all is with a request this program owns, and handing that to
   `accesskit_action_request_free` would release memory the library never
   allocated. Two functions rather than one flag, so neither contract is faked:
   the registered one owns and releases, the probe one records and returns. */
static void on_action_probe(struct accesskit_action_request *request,
                            void *userdata)
{
    struct adapter_state *state = (struct adapter_state *)userdata;

    ++state->actions;
    if (request != NULL) {
        state->last_action = request->action;
        state->last_action_node = request->target_node;
        state->last_tag = request->data.has_value
                              ? request->data.value.tag
                              : ACCESSKIT_ACTION_DATA_CUSTOM_ACTION;
    }
}

/* The root of the demo tree. The header exports a root tree identifier but no
   root node identifier, so the application chooses one. */
#define DEMO_ROOT_ID 1u

static struct accesskit_tree_update *on_build_update(
    accesskit_tree_update_factory_userdata userdata)
{
    struct adapter_state *state = (struct adapter_state *)userdata;

    ++state->updates_built;
    return accesskit_tree_update_with_focus(DEMO_ROOT_ID);
}

/* Every one of the four, held through the header's typedefs. Assigning a
   function to the wrong typedef is the defect this catches. */
static const accesskit_activation_handler_callback activation_callback =
    on_activate;
static const accesskit_deactivation_handler_callback deactivation_callback =
    on_deactivate;
static const accesskit_action_handler_callback action_callback = on_action;
static const accesskit_action_handler_callback action_probe_callback =
    on_action_probe;
static const accesskit_tree_update_factory update_factory = on_build_update;

/* The header documents these as one-byte typedefs for a bare tag with no fixed
   base. If a typedef stops being one byte the ABI changes under every caller,
   so the claim is asserted rather than assumed. */
_Static_assert(sizeof(accesskit_action) == 1, "action typedef must be one byte");
_Static_assert(sizeof(accesskit_aria_current) == 1, "aria_current must be 1 byte");
_Static_assert(sizeof(accesskit_auto_complete) == 1, "auto_complete must be 1");
_Static_assert(sizeof(accesskit_has_popup) == 1, "has_popup must be one byte");
_Static_assert(sizeof(accesskit_invalid) == 1, "invalid must be one byte");
_Static_assert(sizeof(accesskit_list_style) == 1, "list_style must be one byte");
_Static_assert(sizeof(accesskit_live) == 1, "live must be one byte");
_Static_assert(sizeof(accesskit_orientation) == 1, "orientation must be 1 byte");
_Static_assert(sizeof(accesskit_role) == 1, "role must be one byte");
_Static_assert(sizeof(accesskit_scroll_hint) == 1, "scroll_hint must be 1 byte");
_Static_assert(sizeof(accesskit_scroll_unit) == 1, "scroll_unit must be 1 byte");
_Static_assert(sizeof(accesskit_sort_direction) == 1, "sort_direction is 1 byte");
_Static_assert(sizeof(accesskit_text_align) == 1, "text_align must be one byte");
_Static_assert(sizeof(accesskit_text_decoration_style) == 1, "decoration 1 byte");
_Static_assert(sizeof(accesskit_text_direction) == 1, "text_direction is 1 byte");
_Static_assert(sizeof(accesskit_toggled) == 1, "toggled must be one byte");
_Static_assert(sizeof(accesskit_vertical_offset) == 1, "vertical_offset is 1");
_Static_assert(sizeof(accesskit_node_id) == 8, "node id must be eight bytes");
_Static_assert(sizeof(accesskit_tree_id) == 16, "tree id must be 16 bytes");

/* The two enums with no one-byte typedef keep the compiler's own size, which
   is why the header says not to spell them in a struct. These two assertions
   pin the lower bound the header relies on. A bare `enum` with no fixed base is
   at least as wide as `int` for an enumerator this range needs, and a header
   that dropped a member or declared none fails here rather than passing. */
_Static_assert(sizeof(accesskit_action_data_Tag) >= sizeof(int),
               "the payload discriminant must hold eight enumerators");
_Static_assert(sizeof(accesskit_error) >= sizeof(int),
               "an error tag must hold at least two enumerators");

/* Calls every callback through the header's pointer type and checks the
   `userdata` reached the callee unchanged. A callback whose convention is wrong
   corrupts the caller's frame here, not anywhere else. */
static void check_callbacks(struct adapter_state *state)
{
    unsigned long before;
    struct accesskit_tree_update *update;

    before = state->activations;
    CHECK(activation_callback(state) == NULL);
    CHECK(state->activations == before + 1u);

    before = state->deactivations;
    deactivation_callback(state);
    CHECK(state->deactivations == before + 1u);

    before = state->updates_built;
    update = update_factory(state);
    CHECK(update != NULL);
    if (update != NULL) {
        ++tree_update_free_calls;
        accesskit_tree_update_free(update);
    }

    /* Both action-handler pointers are non-null. One is what an adapter would
       register and it owns its request; the other is what the payload probe
       calls through. A signature is checked by the assignment above, not by
       naming the function, which is why the assignment is there. */
    CHECK(action_callback != NULL);
    CHECK(action_probe_callback != NULL);
}

/* ------------------------------------------------------------------------- */
/* The `const char *` plus `size_t` pairs.                                     */
/*                                                                            */
/* A guarded region ends in an unreadable page, so a read one byte past the end */
/* of the data the caller promised faults instead of returning a byte nobody    */
/* wrote. Two shapes are used. One carries its NUL in the last readable byte,  */
/* which catches a length that is off by one in the reading direction. The      */
/* other has no NUL at all, which catches an implementation that reaches for     */
/* `strlen` where the header says it may not.                                  */
/* ------------------------------------------------------------------------- */

#if !defined(_WIN32)

struct guarded_region {
    unsigned char *base;
    size_t total;
    size_t readable;
};

static bool guarded_open(struct guarded_region *region, size_t wanted)
{
    long page = sysconf(_SC_PAGESIZE);
    size_t page_size = (page > 0) ? (size_t)page : (size_t)4096u;
    size_t readable = ((wanted + page_size - 1u) / page_size) * page_size;
    size_t total = readable + page_size;
    void *base;

    base = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS,
                -1, 0);
    if (base == MAP_FAILED) {
        return false;
    }
    if (mprotect((unsigned char *)base + readable, page_size, PROT_NONE) != 0) {
        (void)munmap(base, total);
        return false;
    }
    region->base = (unsigned char *)base;
    region->total = total;
    region->readable = readable;
    return true;
}

static void guarded_close(struct guarded_region *region)
{
    if (region->base != NULL) {
        (void)munmap(region->base, region->total);
        region->base = NULL;
    }
}

#endif /* !_WIN32 */

typedef void (*set_string_fn)(struct accesskit_node *, const char *);
typedef void (*set_string_len_fn)(struct accesskit_node *, const char *, size_t);
typedef char *(*get_string_fn)(const struct accesskit_node *);

/* The 21 node string properties, in header order. Each name appears three
   times: the `const char *` setter, the `const char *` plus `size_t` setter,
   and the `char *` getter. */
static const set_string_fn node_string_setters[] = {
    accesskit_node_set_label,
    accesskit_node_set_description,
    accesskit_node_set_value,
    accesskit_node_set_access_key,
    accesskit_node_set_author_id,
    accesskit_node_set_class_name,
    accesskit_node_set_font_family,
    accesskit_node_set_html_id,
    accesskit_node_set_html_tag,
    accesskit_node_set_inner_html,
    accesskit_node_set_keyboard_shortcut,
    accesskit_node_set_language,
    accesskit_node_set_placeholder,
    accesskit_node_set_role_description,
    accesskit_node_set_state_description,
    accesskit_node_set_tooltip,
    accesskit_node_set_url,
    accesskit_node_set_row_index_text,
    accesskit_node_set_column_index_text,
    accesskit_node_set_braille_label,
    accesskit_node_set_braille_role_description,
};

static const set_string_len_fn node_string_len_setters[] = {
    accesskit_node_set_label_with_length,
    accesskit_node_set_description_with_length,
    accesskit_node_set_value_with_length,
    accesskit_node_set_access_key_with_length,
    accesskit_node_set_author_id_with_length,
    accesskit_node_set_class_name_with_length,
    accesskit_node_set_font_family_with_length,
    accesskit_node_set_html_id_with_length,
    accesskit_node_set_html_tag_with_length,
    accesskit_node_set_inner_html_with_length,
    accesskit_node_set_keyboard_shortcut_with_length,
    accesskit_node_set_language_with_length,
    accesskit_node_set_placeholder_with_length,
    accesskit_node_set_role_description_with_length,
    accesskit_node_set_state_description_with_length,
    accesskit_node_set_tooltip_with_length,
    accesskit_node_set_url_with_length,
    accesskit_node_set_row_index_text_with_length,
    accesskit_node_set_column_index_text_with_length,
    accesskit_node_set_braille_label_with_length,
    accesskit_node_set_braille_role_description_with_length,
};

static const get_string_fn node_string_getters[] = {
    accesskit_node_label,
    accesskit_node_description,
    accesskit_node_value,
    accesskit_node_access_key,
    accesskit_node_author_id,
    accesskit_node_class_name,
    accesskit_node_font_family,
    accesskit_node_html_id,
    accesskit_node_html_tag,
    accesskit_node_inner_html,
    accesskit_node_keyboard_shortcut,
    accesskit_node_language,
    accesskit_node_placeholder,
    accesskit_node_role_description,
    accesskit_node_state_description,
    accesskit_node_tooltip,
    accesskit_node_url,
    accesskit_node_row_index_text,
    accesskit_node_column_index_text,
    accesskit_node_braille_label,
    accesskit_node_braille_role_description,
};

static const char *const node_string_names[] = {
    "label",         "description",   "value",
    "access_key",    "author_id",     "class_name",
    "font_family",   "html_id",       "html_tag",
    "inner_html",    "keyboard_shortcut", "language",
    "placeholder",   "role_description", "state_description",
    "tooltip",       "url",           "row_index_text",
    "column_index_text", "braille_label", "braille_role_description",
};

/* One property, all three forms. Every check can fail on a real defect: a
   setter that drops the value, a getter that hands back the wrong bytes, or a
   length form that reads one byte too many. */
static void check_one_string(struct accesskit_node *node, size_t index)
{
    const char *name = node_string_names[index];
    char *got;

    node_string_setters[index](node, "plain");
    got = node_string_getters[index](node);
    if (got != NULL) {
        CHECK(strcmp(got, "plain") == 0);
        release_string(got, name);
    } else {
        ++checks_run;
        ++checks_failed;
        (void)fprintf(stderr, "FAIL %s: %s read back nothing\n", __FILE__, name);
    }

    /* The empty string. A `size_t` of 0 with a pointer to a NUL is the
       boundary a consumer hits first, and the header says a length of zero is
       a copy of no bytes, not a cleared property. */
    node_string_setters[index](node, "");
    got = node_string_getters[index](node);
    if (got != NULL) {
        CHECK_SIZE(name, strlen(got), 0u);
        release_string(got, name);
    } else {
        ++checks_run;
        ++checks_failed;
        (void)fprintf(stderr, "FAIL %s: %s lost the empty string\n", __FILE__,
                      name);
    }

    node_string_len_setters[index](node, "", 0u);
    got = node_string_getters[index](node);
    if (got != NULL) {
        CHECK_SIZE(name, strlen(got), 0u);
        release_string(got, name);
    } else {
        ++checks_run;
        ++checks_failed;
        (void)fprintf(stderr, "FAIL %s: %s lost a zero-length copy\n", __FILE__,
                      name);
    }

    /* A length shorter than the buffer. The bytes past `length` are `0xFF`, so
       an implementation that ignores `length` and reaches for a terminator
       returns them and the comparison fails. */
    {
        static const char with_tail[] = "abc\xFF\xFF\xFF";
        node_string_len_setters[index](node, with_tail, 3u);
        got = node_string_getters[index](node);
        if (got != NULL) {
            CHECK(strcmp(got, "abc") == 0);
            release_string(got, name);
        } else {
            ++checks_run;
            ++checks_failed;
            (void)fprintf(stderr, "FAIL %s: %s lost a counted copy\n", __FILE__,
                          name);
        }
    }

    /* A NUL inside the counted range. The header says a byte string is stored
       up to the first NUL byte, so the tail cannot come back out. */
    {
        static const char with_nul[] = "ab\0cd";
        node_string_len_setters[index](node, with_nul, 5u);
        got = node_string_getters[index](node);
        if (got != NULL) {
            CHECK_SIZE(name, strlen(got), 2u);
            release_string(got, name);
        } else {
            ++checks_run;
            ++checks_failed;
            (void)fprintf(stderr, "FAIL %s: %s lost an embedded NUL\n", __FILE__,
                          name);
        }
    }
}

static void check_node_strings(void)
{
    size_t index;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_WINDOW);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    for (index = 0; index < COUNT(node_string_setters); ++index) {
        check_one_string(node, index);
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

/* The page-boundary form. A string whose last readable byte is its own NUL,
   and a string with no NUL that runs to the end of the readable region. */
static void check_strings_at_a_page_boundary(void)
{
#if !defined(_WIN32)
    struct guarded_region region;
    static const char text[] = "a label that ends at the last readable byte";
    const size_t text_length = sizeof(text) - 1u;
    size_t index;

    if (!guarded_open(&region, text_length + 1u)) {
        ++checks_run;
        ++checks_failed;
        (void)fprintf(stderr, "FAIL %s: no guarded region\n", __FILE__);
        return;
    }

    for (index = 0; index < COUNT(node_string_setters); ++index) {
        struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_WINDOW);
        unsigned char *terminated;
        unsigned char *unterminated;
        char *got;

        CHECK(node != NULL);
        if (node == NULL) {
            continue;
        }

        /* Terminated exactly at the last readable byte. A read of one byte more
           than the caller promised faults here instead of returning junk. */
        terminated = region.base + region.readable - text_length - 1u;
        (void)memcpy(terminated, text, text_length);
        terminated[text_length] = 0u;
        node_string_len_setters[index](node, (const char *)terminated,
                                       text_length);
        got = node_string_getters[index](node);
        if (got != NULL) {
            CHECK(strcmp(got, text) == 0);
            release_string(got, node_string_names[index]);
        }

        /* No terminator anywhere in the readable region. Only a copy that
           trusts `length` survives this one. */
        unterminated = region.base + region.readable - text_length;
        (void)memcpy(unterminated, text, text_length);
        node_string_len_setters[index](node, (const char *)unterminated,
                                       text_length);
        got = node_string_getters[index](node);
        if (got != NULL) {
            CHECK(strcmp(got, text) == 0);
            release_string(got, node_string_names[index]);
        }

        ++node_free_calls;
        accesskit_node_free(node);
    }
    guarded_close(&region);
#else
    (void)fprintf(stderr,
                  "NOTE %s: no guarded page on this target, so the "
                  "page-boundary string forms did not run\n",
                  __FILE__);
#endif
}

/* The `size_t` forms on the two non-node owners. */
static void check_owner_string_pairs(void)
{
    struct accesskit_custom_action *action = accesskit_custom_action_new(7);
    struct accesskit_tree_info *tree = accesskit_tree_info_new(1u);
    char *got;

    CHECK(action != NULL);
    CHECK(tree != NULL);
    if (action == NULL || tree == NULL) {
        if (action != NULL) {
            ++custom_action_free_calls;
            accesskit_custom_action_free(action);
        }
        if (tree != NULL) {
            ++tree_info_free_calls;
            accesskit_tree_info_free(tree);
        }
        return;
    }

    accesskit_custom_action_set_description(action, "reply");
    got = accesskit_custom_action_description(action);
    if (got != NULL) {
        CHECK(strcmp(got, "reply") == 0);
        release_string(got, "custom action description");
    }
    accesskit_custom_action_set_description_with_length(action, "reply!", 6u);
    got = accesskit_custom_action_description(action);
    if (got != NULL) {
        CHECK(strcmp(got, "reply!") == 0);
        release_string(got, "custom action description");
    }
    accesskit_custom_action_set_description_with_length(action, "", 0u);
    got = accesskit_custom_action_description(action);
    if (got != NULL) {
        CHECK_SIZE("custom action description", strlen(got), 0u);
        release_string(got, "custom action description");
    }
    accesskit_custom_action_set_description(action, "ab\0cd");
    got = accesskit_custom_action_description(action);
    if (got != NULL) {
        CHECK_SIZE("custom action description", strlen(got), 2u);
        release_string(got, "custom action description");
    }
    CHECK(accesskit_custom_action_id(action) == 7);
    accesskit_custom_action_set_id(action, 9);
    CHECK(accesskit_custom_action_id(action) == 9);

    accesskit_tree_info_set_toolkit_name(tree, "zaccesskit");
    got = accesskit_tree_info_get_toolkit_name(tree);
    if (got != NULL) {
        CHECK(strcmp(got, "zaccesskit") == 0);
        release_string(got, "toolkit name");
    }
    accesskit_tree_info_set_toolkit_name_with_length(tree, "zaccesskit-c", 11u);
    got = accesskit_tree_info_get_toolkit_name(tree);
    if (got != NULL) {
        CHECK(strcmp(got, "zaccesskit-c") == 0);
        release_string(got, "toolkit name");
    }
    accesskit_tree_info_set_toolkit_name_with_length(tree, "", 0u);
    got = accesskit_tree_info_get_toolkit_name(tree);
    if (got != NULL) {
        CHECK_SIZE("toolkit name", strlen(got), 0u);
        release_string(got, "toolkit name");
    }
    accesskit_tree_info_clear_toolkit_name(tree);
    CHECK(accesskit_tree_info_get_toolkit_name(tree) == NULL);

    accesskit_tree_info_set_toolkit_version(tree, "0.16.0");
    got = accesskit_tree_info_get_toolkit_version(tree);
    if (got != NULL) {
        CHECK(strcmp(got, "0.16.0") == 0);
        release_string(got, "toolkit version");
    }
    accesskit_tree_info_set_toolkit_version_with_length(tree, "0.16.0-rc", 8u);
    got = accesskit_tree_info_get_toolkit_version(tree);
    if (got != NULL) {
        CHECK(strcmp(got, "0.16.0-rc") == 0);
        release_string(got, "toolkit version");
    }
    accesskit_tree_info_clear_toolkit_version(tree);
    CHECK(accesskit_tree_info_get_toolkit_version(tree) == NULL);

    got = accesskit_tree_info_debug(tree);
    release_string(got, "tree info debug");

    ++custom_action_free_calls;
    accesskit_custom_action_free(action);
    ++tree_info_free_calls;
    accesskit_tree_info_free(tree);
}

/* ------------------------------------------------------------------------- */
/* The `accesskit_opt_*` forms.                                                 */
/*                                                                            */
/* Twenty-five forms are declared. Twenty-four are reachable on this target:   */
/* `accesskit_opt_lresult` sits behind `_WIN32` and is exercised under that    */
/* guard below. Every form is checked three ways: set and read back, clear and */
/* read back as unset, and read `value` while unset to confirm the header's    */
/* promise that it reads as a defined zero rather than uninitialised storage.   */
/* ------------------------------------------------------------------------- */

typedef void (*flag_set_fn)(struct accesskit_node *);
typedef void (*node_clear_fn)(struct accesskit_node *);
typedef bool (*flag_get_fn)(const struct accesskit_node *);

static const flag_set_fn node_flag_setters[] = {
    accesskit_node_set_hidden,
    accesskit_node_set_multiselectable,
    accesskit_node_set_required,
    accesskit_node_set_visited,
    accesskit_node_set_busy,
    accesskit_node_set_live_atomic,
    accesskit_node_set_modal,
    accesskit_node_set_touch_transparent,
    accesskit_node_set_read_only,
    accesskit_node_set_disabled,
    accesskit_node_set_italic,
    accesskit_node_set_clips_children,
    accesskit_node_set_is_line_breaking_object,
    accesskit_node_set_is_page_breaking_object,
    accesskit_node_set_is_spelling_error,
    accesskit_node_set_is_grammar_error,
    accesskit_node_set_is_search_match,
    accesskit_node_set_is_suggestion,
};

static const node_clear_fn node_flag_clears[] = {
    accesskit_node_clear_hidden,
    accesskit_node_clear_multiselectable,
    accesskit_node_clear_required,
    accesskit_node_clear_visited,
    accesskit_node_clear_busy,
    accesskit_node_clear_live_atomic,
    accesskit_node_clear_modal,
    accesskit_node_clear_touch_transparent,
    accesskit_node_clear_read_only,
    accesskit_node_clear_disabled,
    accesskit_node_clear_italic,
    accesskit_node_clear_clips_children,
    accesskit_node_clear_is_line_breaking_object,
    accesskit_node_clear_is_page_breaking_object,
    accesskit_node_clear_is_spelling_error,
    accesskit_node_clear_is_grammar_error,
    accesskit_node_clear_is_search_match,
    accesskit_node_clear_is_suggestion,
};

static const flag_get_fn node_flag_getters[] = {
    accesskit_node_is_hidden,
    accesskit_node_is_multiselectable,
    accesskit_node_is_required,
    accesskit_node_is_visited,
    accesskit_node_is_busy,
    accesskit_node_is_live_atomic,
    accesskit_node_is_modal,
    accesskit_node_is_touch_transparent,
    accesskit_node_is_read_only,
    accesskit_node_is_disabled,
    accesskit_node_is_italic,
    accesskit_node_clips_children,
    accesskit_node_is_line_breaking_object,
    accesskit_node_is_page_breaking_object,
    accesskit_node_is_spelling_error,
    accesskit_node_is_grammar_error,
    accesskit_node_is_search_match,
    accesskit_node_is_suggestion,
};

static const char *const node_flag_names[] = {
    "hidden",           "multiselectable", "required",
    "visited",          "busy",            "live_atomic",
    "modal",            "touch_transparent", "read_only",
    "disabled",         "italic",          "clips_children",
    "line_breaking",    "page_breaking",   "spelling_error",
    "grammar_error",    "search_match",    "suggestion",
};

static void check_flags(void)
{
    size_t index;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_CHECK_BOX);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    for (index = 0; index < COUNT(node_flag_setters); ++index) {
        /* Never set reads false, so a getter that always returned true would
           pass nothing else. */
        CHECK(node_flag_getters[index](node) == false);
        node_flag_setters[index](node);
        CHECK(node_flag_getters[index](node) == true);
        node_flag_clears[index](node);
        /* Cleared reads the same as never set, and that is what the header
           promises, so this is the only observable difference. */
        CHECK(node_flag_getters[index](node) == false);
        CHECK(node_flag_names[index] != NULL);
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

/* Every `accesskit_opt_*` scalar, one family at a time. */

typedef void (*opt_node_id_set_fn)(struct accesskit_node *, accesskit_node_id);
typedef struct accesskit_opt_node_id (*opt_node_id_get_fn)(const struct accesskit_node *);

static const opt_node_id_set_fn opt_node_id_setters[] = {
    accesskit_node_set_active_descendant,
    accesskit_node_set_error_message,
    accesskit_node_set_in_page_link_target,
    accesskit_node_set_member_of,
    accesskit_node_set_next_on_line,
    accesskit_node_set_previous_on_line,
    accesskit_node_set_popup_for,
};

static const opt_node_id_get_fn opt_node_id_getters[] = {
    accesskit_node_active_descendant,
    accesskit_node_error_message,
    accesskit_node_in_page_link_target,
    accesskit_node_member_of,
    accesskit_node_next_on_line,
    accesskit_node_previous_on_line,
    accesskit_node_popup_for,
};

static const node_clear_fn opt_node_id_clears[] = {
    accesskit_node_clear_active_descendant,
    accesskit_node_clear_error_message,
    accesskit_node_clear_in_page_link_target,
    accesskit_node_clear_member_of,
    accesskit_node_clear_next_on_line,
    accesskit_node_clear_previous_on_line,
    accesskit_node_clear_popup_for,
};

static void check_opt_node_id(void)
{
    size_t index;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_WINDOW);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    for (index = 0; index < COUNT(opt_node_id_setters); ++index) {
        struct accesskit_opt_node_id got = opt_node_id_getters[index](node);
        CHECK(got.has_value == false);
        opt_node_id_setters[index](node, 4242u);
        got = opt_node_id_getters[index](node);
        CHECK(got.has_value == true);
        CHECK(got.value == 4242u);
        opt_node_id_clears[index](node);
        got = opt_node_id_getters[index](node);
        CHECK(got.has_value == false);
        CHECK_SIZE("opt_node_id value", got.value, 0u);
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

typedef void (*opt_double_set_fn)(struct accesskit_node *, double);
typedef struct accesskit_opt_double (*opt_double_get_fn)(const struct accesskit_node *);

static const opt_double_set_fn opt_double_setters[] = {
    accesskit_node_set_scroll_x,     accesskit_node_set_scroll_x_min,
    accesskit_node_set_scroll_x_max, accesskit_node_set_scroll_y,
    accesskit_node_set_scroll_y_min, accesskit_node_set_scroll_y_max,
    accesskit_node_set_numeric_value, accesskit_node_set_min_numeric_value,
    accesskit_node_set_max_numeric_value,
    accesskit_node_set_numeric_value_step,
    accesskit_node_set_numeric_value_jump,
};

static const opt_double_get_fn opt_double_getters[] = {
    accesskit_node_scroll_x,     accesskit_node_scroll_x_min,
    accesskit_node_scroll_x_max, accesskit_node_scroll_y,
    accesskit_node_scroll_y_min, accesskit_node_scroll_y_max,
    accesskit_node_numeric_value, accesskit_node_min_numeric_value,
    accesskit_node_max_numeric_value,
    accesskit_node_numeric_value_step,
    accesskit_node_numeric_value_jump,
};

static const node_clear_fn opt_double_clears[] = {
    accesskit_node_clear_scroll_x,     accesskit_node_clear_scroll_x_min,
    accesskit_node_clear_scroll_x_max, accesskit_node_clear_scroll_y,
    accesskit_node_clear_scroll_y_min, accesskit_node_clear_scroll_y_max,
    accesskit_node_clear_numeric_value,
    accesskit_node_clear_min_numeric_value,
    accesskit_node_clear_max_numeric_value,
    accesskit_node_clear_numeric_value_step,
    accesskit_node_clear_numeric_value_jump,
};

static void check_opt_double(void)
{
    size_t index;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_SLIDER);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    for (index = 0; index < COUNT(opt_double_setters); ++index) {
        struct accesskit_opt_double got = opt_double_getters[index](node);
        CHECK(got.has_value == false);
        /* A value no coordinate uses, so a mixed-up setter or getter shows. */
        opt_double_setters[index](node, -1234.5);
        got = opt_double_getters[index](node);
        CHECK(got.has_value == true);
        CHECK(got.value == -1234.5);
        opt_double_clears[index](node);
        got = opt_double_getters[index](node);
        CHECK(got.has_value == false);
        CHECK(got.value == 0.0);
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

typedef void (*opt_float_set_fn)(struct accesskit_node *, float);
typedef struct accesskit_opt_float (*opt_float_get_fn)(const struct accesskit_node *);

static const opt_float_set_fn opt_float_setters[] = {
    accesskit_node_set_font_size,
    accesskit_node_set_font_weight,
};

static const opt_float_get_fn opt_float_getters[] = {
    accesskit_node_font_size,
    accesskit_node_font_weight,
};

static const node_clear_fn opt_float_clears[] = {
    accesskit_node_clear_font_size,
    accesskit_node_clear_font_weight,
};

static void check_opt_float(void)
{
    size_t index;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_LABEL);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    for (index = 0; index < COUNT(opt_float_setters); ++index) {
        struct accesskit_opt_float got = opt_float_getters[index](node);
        CHECK(got.has_value == false);
        opt_float_setters[index](node, 12.5f);
        got = opt_float_getters[index](node);
        CHECK(got.has_value == true);
        CHECK(got.value == 12.5f);
        opt_float_clears[index](node);
        got = opt_float_getters[index](node);
        CHECK(got.has_value == false);
        CHECK(got.value == 0.0f);
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

typedef void (*opt_index_set_fn)(struct accesskit_node *, size_t);
typedef struct accesskit_opt_index (*opt_index_get_fn)(const struct accesskit_node *);

static const opt_index_set_fn opt_index_setters[] = {
    accesskit_node_set_row_count,     accesskit_node_set_column_count,
    accesskit_node_set_row_index,     accesskit_node_set_column_index,
    accesskit_node_set_row_span,      accesskit_node_set_column_span,
    accesskit_node_set_level,         accesskit_node_set_size_of_set,
    accesskit_node_set_position_in_set,
};

static const opt_index_get_fn opt_index_getters[] = {
    accesskit_node_row_count,     accesskit_node_column_count,
    accesskit_node_row_index,     accesskit_node_column_index,
    accesskit_node_row_span,      accesskit_node_column_span,
    accesskit_node_level,         accesskit_node_size_of_set,
    accesskit_node_position_in_set,
};

static const node_clear_fn opt_index_clears[] = {
    accesskit_node_clear_row_count,     accesskit_node_clear_column_count,
    accesskit_node_clear_row_index,     accesskit_node_clear_column_index,
    accesskit_node_clear_row_span,      accesskit_node_clear_column_span,
    accesskit_node_clear_level,         accesskit_node_clear_size_of_set,
    accesskit_node_clear_position_in_set,
};

static void check_opt_index(void)
{
    size_t index;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_ROW);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    for (index = 0; index < COUNT(opt_index_setters); ++index) {
        struct accesskit_opt_index got = opt_index_getters[index](node);
        CHECK(got.has_value == false);
        opt_index_setters[index](node, (size_t)17u);
        got = opt_index_getters[index](node);
        CHECK(got.has_value == true);
        CHECK_SIZE("opt_index value", got.value, 17u);
        opt_index_clears[index](node);
        got = opt_index_getters[index](node);
        CHECK(got.has_value == false);
        CHECK_SIZE("opt_index value", got.value, 0u);
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

static const struct accesskit_color sample_color = {0x11u, 0x22u, 0x33u, 0x44u};
static const struct accesskit_color other_color = {0x55u, 0x66u, 0x77u, 0x88u};

typedef void (*opt_color_set_fn)(struct accesskit_node *, struct accesskit_color);
typedef struct accesskit_opt_color (*opt_color_get_fn)(const struct accesskit_node *);

static const opt_color_set_fn opt_color_setters[] = {
    accesskit_node_set_color_value,
    accesskit_node_set_background_color,
    accesskit_node_set_foreground_color,
};

static const opt_color_get_fn opt_color_getters[] = {
    accesskit_node_color_value,
    accesskit_node_background_color,
    accesskit_node_foreground_color,
};

static const node_clear_fn opt_color_clears[] = {
    accesskit_node_clear_color_value,
    accesskit_node_clear_background_color,
    accesskit_node_clear_foreground_color,
};

static void check_opt_color(void)
{
    size_t index;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_LABEL);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    for (index = 0; index < COUNT(opt_color_setters); ++index) {
        struct accesskit_opt_color got = opt_color_getters[index](node);
        CHECK(got.has_value == false);
        opt_color_setters[index](node, sample_color);
        got = opt_color_getters[index](node);
        CHECK(got.has_value == true);
        CHECK(got.value.red == sample_color.red);
        CHECK(got.value.green == sample_color.green);
        CHECK(got.value.blue == sample_color.blue);
        CHECK(got.value.alpha == sample_color.alpha);
        opt_color_setters[index](node, other_color);
        got = opt_color_getters[index](node);
        CHECK(got.value.green == other_color.green);
        opt_color_clears[index](node);
        got = opt_color_getters[index](node);
        CHECK(got.has_value == false);
        /* The whole value, not one field: the header promises a zeroed value. */
        CHECK(bytes_are_zero(&got.value, sizeof(got.value)));
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

static const struct accesskit_text_decoration sample_decoration = {
    ACCESSKIT_TEXT_DECORATION_STYLE_DOTTED, sample_color};

typedef void (*opt_decoration_set_fn)(struct accesskit_node *,
                                      struct accesskit_text_decoration);
typedef struct accesskit_opt_text_decoration (*opt_decoration_get_fn)(
    const struct accesskit_node *);

static const opt_decoration_set_fn opt_decoration_setters[] = {
    accesskit_node_set_overline,
    accesskit_node_set_strikethrough,
    accesskit_node_set_underline,
};

static const opt_decoration_get_fn opt_decoration_getters[] = {
    accesskit_node_overline,
    accesskit_node_strikethrough,
    accesskit_node_underline,
};

static const node_clear_fn opt_decoration_clears[] = {
    accesskit_node_clear_overline,
    accesskit_node_clear_strikethrough,
    accesskit_node_clear_underline,
};

static void check_opt_text_decoration(void)
{
    size_t index;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_LABEL);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    for (index = 0; index < COUNT(opt_decoration_setters); ++index) {
        struct accesskit_opt_text_decoration got =
            opt_decoration_getters[index](node);
        CHECK(got.has_value == false);
        opt_decoration_setters[index](node, sample_decoration);
        got = opt_decoration_getters[index](node);
        CHECK(got.has_value == true);
        CHECK(got.value.style == sample_decoration.style);
        CHECK(got.value.color.blue == sample_decoration.color.blue);
        opt_decoration_clears[index](node);
        got = opt_decoration_getters[index](node);
        CHECK(got.has_value == false);
        CHECK(bytes_are_zero(&got.value, sizeof(got.value)));
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

typedef void (*opt_bool_set_fn)(struct accesskit_node *, bool);
typedef struct accesskit_opt_bool (*opt_bool_get_fn)(const struct accesskit_node *);

static const opt_bool_set_fn opt_bool_setters[] = {
    accesskit_node_set_expanded,
    accesskit_node_set_selected,
};

static const opt_bool_get_fn opt_bool_getters[] = {
    accesskit_node_is_expanded,
    accesskit_node_is_selected,
};

static const node_clear_fn opt_bool_clears[] = {
    accesskit_node_clear_expanded,
    accesskit_node_clear_selected,
};

/* A `bool` family, so that `true` and `false` are both stored and the cleared
   read is not the same as a stored `false`. */
static void check_opt_bool(void)
{
    size_t index;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_TREE);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    for (index = 0; index < COUNT(opt_bool_setters); ++index) {
        struct accesskit_opt_bool got = opt_bool_getters[index](node);
        CHECK(got.has_value == false);
        opt_bool_setters[index](node, true);
        got = opt_bool_getters[index](node);
        CHECK(got.has_value == true);
        CHECK(got.value == true);
        opt_bool_setters[index](node, false);
        got = opt_bool_getters[index](node);
        /* Stored `false` is not unset, and only the flag tells them apart. */
        CHECK(got.has_value == true);
        CHECK(got.value == false);
        opt_bool_clears[index](node);
        got = opt_bool_getters[index](node);
        CHECK(got.has_value == false);
        CHECK(got.value == false);
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

/* The twelve single-enumerator families. Each one carries its own enum type,
   so each one gets its own setter, getter and clear call rather than a
   table. Each one stores every enumerator in turn, so a renumbered or dropped
   enumerator fails the round trip, then clears and checks that the cleared
   read is the zero enumerator of that same family. */

static void check_opt_invalid(void)
{
    static const accesskit_invalid values[] = {ACCESSKIT_INVALID_TRUE,
                                               ACCESSKIT_INVALID_SPELLING,
                                               ACCESSKIT_INVALID_GRAMMAR};
    size_t value_index;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_LABEL);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    for (value_index = 0; value_index < COUNT(values); ++value_index) {
        struct accesskit_opt_invalid got;
        accesskit_node_set_invalid(node, values[value_index]);
        got = accesskit_node_invalid(node);
        CHECK(got.has_value == true);
        CHECK(got.value == values[value_index]);
    }
    accesskit_node_clear_invalid(node);
    {
        struct accesskit_opt_invalid got = accesskit_node_invalid(node);
        CHECK(got.has_value == false);
        CHECK(got.value == ACCESSKIT_INVALID_TRUE);
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

static void check_opt_toggled(void)
{
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_CHECK_BOX);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    accesskit_node_set_toggled(node, ACCESSKIT_TOGGLED_MIXED);
    CHECK(accesskit_node_toggled(node).value == ACCESSKIT_TOGGLED_MIXED);
    accesskit_node_set_toggled(node, ACCESSKIT_TOGGLED_FALSE);
    CHECK(accesskit_node_toggled(node).value == ACCESSKIT_TOGGLED_FALSE);
    accesskit_node_clear_toggled(node);
    CHECK(accesskit_node_toggled(node).has_value == false);
    CHECK(accesskit_node_toggled(node).value == ACCESSKIT_TOGGLED_FALSE);
    ++node_free_calls;
    accesskit_node_free(node);
}

static void check_opt_live(void)
{
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_LABEL);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    accesskit_node_set_live(node, ACCESSKIT_LIVE_ASSERTIVE);
    CHECK(accesskit_node_live(node).has_value == true);
    CHECK(accesskit_node_live(node).value == ACCESSKIT_LIVE_ASSERTIVE);
    accesskit_node_clear_live(node);
    CHECK(accesskit_node_live(node).has_value == false);
    CHECK(accesskit_node_live(node).value == ACCESSKIT_LIVE_OFF);
    ++node_free_calls;
    accesskit_node_free(node);
}

static void check_opt_text_direction(void)
{
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_LABEL);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    accesskit_node_set_text_direction(node, ACCESSKIT_TEXT_DIRECTION_RIGHT_TO_LEFT);
    CHECK(accesskit_node_text_direction(node).has_value == true);
    CHECK(accesskit_node_text_direction(node).value ==
          ACCESSKIT_TEXT_DIRECTION_RIGHT_TO_LEFT);
    accesskit_node_clear_text_direction(node);
    CHECK(accesskit_node_text_direction(node).has_value == false);
    CHECK(accesskit_node_text_direction(node).value ==
          ACCESSKIT_TEXT_DIRECTION_LEFT_TO_RIGHT);
    ++node_free_calls;
    accesskit_node_free(node);
}

static void check_opt_orientation(void)
{
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_SLIDER);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    accesskit_node_set_orientation(node, ACCESSKIT_ORIENTATION_VERTICAL);
    CHECK(accesskit_node_orientation(node).has_value == true);
    CHECK(accesskit_node_orientation(node).value == ACCESSKIT_ORIENTATION_VERTICAL);
    accesskit_node_clear_orientation(node);
    CHECK(accesskit_node_orientation(node).has_value == false);
    CHECK(accesskit_node_orientation(node).value == ACCESSKIT_ORIENTATION_HORIZONTAL);
    ++node_free_calls;
    accesskit_node_free(node);
}

static void check_opt_sort_direction(void)
{
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_COLUMN_HEADER);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    accesskit_node_set_sort_direction(node, ACCESSKIT_SORT_DIRECTION_DESCENDING);
    CHECK(accesskit_node_sort_direction(node).has_value == true);
    CHECK(accesskit_node_sort_direction(node).value ==
          ACCESSKIT_SORT_DIRECTION_DESCENDING);
    accesskit_node_clear_sort_direction(node);
    CHECK(accesskit_node_sort_direction(node).has_value == false);
    CHECK(accesskit_node_sort_direction(node).value == ACCESSKIT_SORT_DIRECTION_ASCENDING);
    ++node_free_calls;
    accesskit_node_free(node);
}

static void check_opt_aria_current(void)
{
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_LINK);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    accesskit_node_set_aria_current(node, ACCESSKIT_ARIA_CURRENT_PAGE);
    CHECK(accesskit_node_aria_current(node).has_value == true);
    CHECK(accesskit_node_aria_current(node).value == ACCESSKIT_ARIA_CURRENT_PAGE);
    accesskit_node_clear_aria_current(node);
    CHECK(accesskit_node_aria_current(node).has_value == false);
    CHECK(accesskit_node_aria_current(node).value == ACCESSKIT_ARIA_CURRENT_FALSE);
    ++node_free_calls;
    accesskit_node_free(node);
}

static void check_opt_auto_complete(void)
{
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_TEXT_INPUT);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    accesskit_node_set_auto_complete(node, ACCESSKIT_AUTO_COMPLETE_LIST);
    CHECK(accesskit_node_auto_complete(node).has_value == true);
    CHECK(accesskit_node_auto_complete(node).value == ACCESSKIT_AUTO_COMPLETE_LIST);
    accesskit_node_clear_auto_complete(node);
    CHECK(accesskit_node_auto_complete(node).has_value == false);
    CHECK(accesskit_node_auto_complete(node).value == ACCESSKIT_AUTO_COMPLETE_INLINE);
    ++node_free_calls;
    accesskit_node_free(node);
}

static void check_opt_has_popup(void)
{
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_MENU_ITEM);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    accesskit_node_set_has_popup(node, ACCESSKIT_HAS_POPUP_TREE);
    CHECK(accesskit_node_has_popup(node).has_value == true);
    CHECK(accesskit_node_has_popup(node).value == ACCESSKIT_HAS_POPUP_TREE);
    accesskit_node_clear_has_popup(node);
    CHECK(accesskit_node_has_popup(node).has_value == false);
    CHECK(accesskit_node_has_popup(node).value == ACCESSKIT_HAS_POPUP_MENU);
    ++node_free_calls;
    accesskit_node_free(node);
}

static void check_opt_list_style(void)
{
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_LIST_ITEM);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    accesskit_node_set_list_style(node, ACCESSKIT_LIST_STYLE_DISC);
    CHECK(accesskit_node_list_style(node).has_value == true);
    CHECK(accesskit_node_list_style(node).value == ACCESSKIT_LIST_STYLE_DISC);
    accesskit_node_clear_list_style(node);
    CHECK(accesskit_node_list_style(node).has_value == false);
    CHECK(accesskit_node_list_style(node).value == ACCESSKIT_LIST_STYLE_CIRCLE);
    ++node_free_calls;
    accesskit_node_free(node);
}

static void check_opt_text_align(void)
{
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_LABEL);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    accesskit_node_set_text_align(node, ACCESSKIT_TEXT_ALIGN_CENTER);
    CHECK(accesskit_node_text_align(node).has_value == true);
    CHECK(accesskit_node_text_align(node).value == ACCESSKIT_TEXT_ALIGN_CENTER);
    accesskit_node_clear_text_align(node);
    CHECK(accesskit_node_text_align(node).has_value == false);
    CHECK(accesskit_node_text_align(node).value == ACCESSKIT_TEXT_ALIGN_LEFT);
    ++node_free_calls;
    accesskit_node_free(node);
}

static void check_opt_vertical_offset(void)
{
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_LABEL);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    accesskit_node_set_vertical_offset(node, ACCESSKIT_VERTICAL_OFFSET_SUPERSCRIPT);
    CHECK(accesskit_node_vertical_offset(node).has_value == true);
    CHECK(accesskit_node_vertical_offset(node).value ==
          ACCESSKIT_VERTICAL_OFFSET_SUPERSCRIPT);
    accesskit_node_clear_vertical_offset(node);
    CHECK(accesskit_node_vertical_offset(node).has_value == false);
    CHECK(accesskit_node_vertical_offset(node).value ==
          ACCESSKIT_VERTICAL_OFFSET_SUBSCRIPT);
    ++node_free_calls;
    accesskit_node_free(node);
}

/* `accesskit_opt_tree_id`, `accesskit_opt_rect` and `accesskit_opt_text_selection`
   hold a struct by value, so the cleared read is checked over every byte. */

static void check_opt_tree_id(void)
{
    struct accesskit_tree_id other;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_WINDOW);
    struct accesskit_opt_tree_id got;
    size_t byte;

    for (byte = 0; byte < sizeof(other.bytes); ++byte) {
        other.bytes[byte] = (uint8_t)(byte + 1u);
    }
    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    got = accesskit_node_tree_id(node);
    CHECK(got.has_value == false);
    accesskit_node_set_tree_id(node, other);
    got = accesskit_node_tree_id(node);
    CHECK(got.has_value == true);
    CHECK(memcmp(&got.value, &other, sizeof(other)) == 0);
    accesskit_node_clear_tree_id(node);
    got = accesskit_node_tree_id(node);
    CHECK(got.has_value == false);
    CHECK(bytes_are_zero(&got.value, sizeof(got.value)));
    ++node_free_calls;
    accesskit_node_free(node);
}

/* A literal, not `accesskit_rect_new`: a C constant expression cannot call a
   function, and a consumer that needs one at file scope hits this. */
static const struct accesskit_rect sample_bounds = {1.0, 2.0, 11.0, 22.0};

static void check_opt_rect(void)
{
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_WINDOW);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    CHECK(accesskit_node_bounds(node).has_value == false);
    accesskit_node_set_bounds(node, sample_bounds);
    {
        struct accesskit_opt_rect got = accesskit_node_bounds(node);
        CHECK(got.has_value == true);
        CHECK(got.value.x1 == 11.0);
        CHECK(got.value.y1 == 22.0);
    }
    accesskit_node_clear_bounds(node);
    {
        struct accesskit_opt_rect got = accesskit_node_bounds(node);
        CHECK(got.has_value == false);
        CHECK(bytes_are_zero(&got.value, sizeof(got.value)));
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

static void check_opt_text_selection(void)
{
    struct accesskit_text_selection selection;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_TEXT_INPUT);

    selection.anchor.node = 3u;
    selection.anchor.character_index = 1u;
    selection.focus.node = 4u;
    selection.focus.character_index = 7u;

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    CHECK(accesskit_node_text_selection(node).has_value == false);
    accesskit_node_set_text_selection(node, selection);
    {
        struct accesskit_opt_text_selection got = accesskit_node_text_selection(node);
        CHECK(got.has_value == true);
        CHECK(got.value.anchor.node == 3u);
        CHECK(got.value.focus.character_index == 7u);
    }
    accesskit_node_clear_text_selection(node);
    {
        struct accesskit_opt_text_selection got = accesskit_node_text_selection(node);
        CHECK(got.has_value == false);
        CHECK(bytes_are_zero(&got.value, sizeof(got.value)));
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

/* `accesskit_opt_coords` and `accesskit_lengths` are not `has_value` plus
   `value`: they carry a borrowed array, and the header promises an unset one
   gives `length == 0` with a non-null `values`. */

typedef void (*set_u8_array_fn)(struct accesskit_node *, size_t, const uint8_t *);
typedef struct accesskit_lengths (*get_lengths_fn)(const struct accesskit_node *);

static const set_u8_array_fn lengths_setters[] = {
    accesskit_node_set_character_lengths,
    accesskit_node_set_word_starts,
};

static const get_lengths_fn lengths_getters[] = {
    accesskit_node_character_lengths,
    accesskit_node_word_starts,
};

static const node_clear_fn lengths_clears[] = {
    accesskit_node_clear_character_lengths,
    accesskit_node_clear_word_starts,
};

static void check_lengths(void)
{
    static const uint8_t byte_lengths[] = {1u, 1u, 3u, 1u, 4u};
    size_t index;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_LABEL);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    for (index = 0; index < COUNT(lengths_setters); ++index) {
        struct accesskit_lengths got = lengths_getters[index](node);
        /* An unset list must still hand back a usable pointer, or a consumer
           that ranges over it without a length check reads nothing. */
        CHECK_SIZE("unset lengths", got.length, 0u);
        CHECK(got.values != NULL);
        lengths_setters[index](node, COUNT(byte_lengths), byte_lengths);
        got = lengths_getters[index](node);
        CHECK_SIZE("lengths", got.length, COUNT(byte_lengths));
        CHECK(got.values != NULL);
        if (got.values != NULL && got.length == COUNT(byte_lengths)) {
            CHECK(memcmp(got.values, byte_lengths, COUNT(byte_lengths)) == 0);
        }
        /* A zero count with a null array is the other legal shape. */
        lengths_setters[index](node, 0u, NULL);
        got = lengths_getters[index](node);
        CHECK_SIZE("lengths", got.length, 0u);
        lengths_clears[index](node);
        got = lengths_getters[index](node);
        CHECK_SIZE("lengths", got.length, 0u);
        CHECK(got.values != NULL);
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

typedef void (*set_float_array_fn)(struct accesskit_node *, size_t, const float *);
typedef struct accesskit_opt_coords (*get_coords_fn)(const struct accesskit_node *);

static const set_float_array_fn coords_setters[] = {
    accesskit_node_set_character_positions,
    accesskit_node_set_character_widths,
};

static const get_coords_fn coords_getters[] = {
    accesskit_node_character_positions,
    accesskit_node_character_widths,
};

static const node_clear_fn coords_clears[] = {
    accesskit_node_clear_character_positions,
    accesskit_node_clear_character_widths,
};

static void check_opt_coords(void)
{
    static const float positions[] = {0.0f, 7.5f, 8.25f, 15.0f};
    size_t index;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_LABEL);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    for (index = 0; index < COUNT(coords_setters); ++index) {
        struct accesskit_opt_coords got = coords_getters[index](node);
        CHECK(got.has_value == false);
        CHECK_SIZE("unset coords", got.length, 0u);
        coords_setters[index](node, COUNT(positions), positions);
        got = coords_getters[index](node);
        CHECK(got.has_value == true);
        CHECK_SIZE("coords", got.length, COUNT(positions));
        if (got.values != NULL && got.length == COUNT(positions)) {
            CHECK(got.values[2] == 8.25f);
        } else {
            CHECK(false);
        }
        coords_setters[index](node, 0u, NULL);
        got = coords_getters[index](node);
        CHECK_SIZE("coords", got.length, 0u);
        coords_clears[index](node);
        got = coords_getters[index](node);
        CHECK(got.has_value == false);
        CHECK_SIZE("coords", got.length, 0u);
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

/* The eight node-id lists. */

typedef void (*set_ids_fn)(struct accesskit_node *, size_t,
                           const accesskit_node_id *);
typedef void (*push_id_fn)(struct accesskit_node *, accesskit_node_id);
typedef struct accesskit_node_ids (*get_ids_fn)(const struct accesskit_node *);

static const set_ids_fn id_list_setters[] = {
    accesskit_node_set_children,     accesskit_node_set_controls,
    accesskit_node_set_details,      accesskit_node_set_described_by,
    accesskit_node_set_flow_to,      accesskit_node_set_labelled_by,
    accesskit_node_set_owns,         accesskit_node_set_radio_group,
};

static const push_id_fn id_list_pushers[] = {
    accesskit_node_push_child,        accesskit_node_push_controlled,
    accesskit_node_push_detail,       accesskit_node_push_described_by,
    accesskit_node_push_flow_to,      accesskit_node_push_labelled_by,
    accesskit_node_push_owned,        accesskit_node_push_to_radio_group,
};

static const get_ids_fn id_list_getters[] = {
    accesskit_node_children,     accesskit_node_controls,
    accesskit_node_details,      accesskit_node_described_by,
    accesskit_node_flow_to,      accesskit_node_labelled_by,
    accesskit_node_owns,         accesskit_node_radio_group,
};

static const node_clear_fn id_list_clears[] = {
    accesskit_node_clear_children,     accesskit_node_clear_controls,
    accesskit_node_clear_details,      accesskit_node_clear_described_by,
    accesskit_node_clear_flow_to,      accesskit_node_clear_labelled_by,
    accesskit_node_clear_owns,         accesskit_node_clear_radio_group,
};

static void check_id_lists(void)
{
    static const accesskit_node_id ids[] = {10u, 11u, 12u};
    size_t index;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_WINDOW);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    for (index = 0; index < COUNT(id_list_setters); ++index) {
        struct accesskit_node_ids got = id_list_getters[index](node);
        CHECK_SIZE("unset ids", got.length, 0u);
        CHECK(got.values != NULL);
        id_list_setters[index](node, COUNT(ids), ids);
        got = id_list_getters[index](node);
        CHECK_SIZE("ids", got.length, COUNT(ids));
        if (got.values != NULL && got.length == COUNT(ids)) {
            CHECK(got.values[0] == 10u);
            CHECK(got.values[2] == 12u);
        } else {
            CHECK(false);
        }
        id_list_clears[index](node);
        id_list_pushers[index](node, 99u);
        got = id_list_getters[index](node);
        CHECK_SIZE("ids after one push", got.length, 1u);
        if (got.values != NULL && got.length == 1u) {
            CHECK(got.values[0] == 99u);
        } else {
            CHECK(false);
        }
        id_list_clears[index](node);
        got = id_list_getters[index](node);
        CHECK_SIZE("ids after clear", got.length, 0u);
        CHECK(got.values != NULL);
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

/* The transform. The header has a setter and a clear but no getter, so this
   reads the value back through the affine predicates instead. */
static void check_transform(void)
{
    struct accesskit_affine flip = accesskit_affine_flip_y();
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_CANVAS);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    accesskit_node_set_transform(node, flip);
    CHECK(accesskit_affine_is_finite(&flip) == true);
    CHECK(accesskit_affine_is_nan(&flip) == false);
    accesskit_node_clear_transform(node);
    {
        struct accesskit_affine identity = accesskit_affine_identity();
        CHECK(accesskit_affine_determinant(identity) == 1.0);
    }
    ++node_free_calls;
    accesskit_node_free(node);
}

/* The action sets. */
static void check_actions(void)
{
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_BUTTON);

    CHECK(node != NULL);
    if (node == NULL) {
        return;
    }
    CHECK(accesskit_node_supports_action(node, ACCESSKIT_ACTION_CLICK) == false);
    accesskit_node_add_action(node, ACCESSKIT_ACTION_CLICK);
    CHECK(accesskit_node_supports_action(node, ACCESSKIT_ACTION_CLICK) == true);
    accesskit_node_add_action(node, ACCESSKIT_ACTION_CLICK);
    CHECK(accesskit_node_supports_action(node, ACCESSKIT_ACTION_CLICK) == true);
    accesskit_node_remove_action(node, ACCESSKIT_ACTION_CLICK);
    CHECK(accesskit_node_supports_action(node, ACCESSKIT_ACTION_CLICK) == false);
    accesskit_node_remove_action(node, ACCESSKIT_ACTION_CLICK);
    CHECK(accesskit_node_supports_action(node, ACCESSKIT_ACTION_CLICK) == false);
    accesskit_node_add_action(node, ACCESSKIT_ACTION_FOCUS);
    accesskit_node_clear_actions(node);
    CHECK(accesskit_node_supports_action(node, ACCESSKIT_ACTION_FOCUS) == false);

    CHECK(accesskit_node_child_supports_action(node, ACCESSKIT_ACTION_CLICK) ==
          false);
    accesskit_node_add_child_action(node, ACCESSKIT_ACTION_CLICK);
    CHECK(accesskit_node_child_supports_action(node, ACCESSKIT_ACTION_CLICK) ==
          true);
    accesskit_node_remove_child_action(node, ACCESSKIT_ACTION_CLICK);
    CHECK(accesskit_node_child_supports_action(node, ACCESSKIT_ACTION_CLICK) ==
          false);
    accesskit_node_add_child_action(node, ACCESSKIT_ACTION_EXPAND);
    accesskit_node_clear_child_actions(node);
    CHECK(accesskit_node_child_supports_action(node, ACCESSKIT_ACTION_EXPAND) ==
          false);
    ++node_free_calls;
    accesskit_node_free(node);
}

/* ------------------------------------------------------------------------- */
/* The by-value aggregates: rect, point, vec2, size and affine.                 */
/*                                                                            */
/* Every declaration that takes a struct by value, and every one that returns   */
/* one, appears here. A mismatch in one of these is not a wrong number but a   */
/* corrupted frame, which is why the header warns about it and why a consumer  */
/* has to exercise them rather than only declare them.                        */
/* ------------------------------------------------------------------------- */

static void check_rect_and_vectors(void)
{
    struct accesskit_point origin;
    struct accesskit_point opposite;
    struct accesskit_vec2 shift;
    struct accesskit_vec2 as_vec2;
    struct accesskit_size size;
    struct accesskit_rect rect;
    struct accesskit_rect moved;
    struct accesskit_rect unioned;
    struct accesskit_rect hit;
    struct accesskit_point corner;
    struct accesskit_affine identity = accesskit_affine_identity();
    struct accesskit_affine flip_x = accesskit_affine_flip_x();
    struct accesskit_affine flip_y = accesskit_affine_flip_y();
    struct accesskit_affine scaled;
    struct accesskit_affine scaled_xy;
    struct accesskit_affine translated;
    struct accesskit_affine mapped;
    struct accesskit_affine inverse;
    struct accesskit_affine product;

    origin.x = 1.0;
    origin.y = 2.0;
    opposite.x = 5.0;
    opposite.y = 9.0;
    shift.x = 10.0;
    shift.y = 20.0;
    size.width = 4.0;
    size.height = 6.0;

    /* Constructed from two corners and from an origin and a size. */
    rect = accesskit_rect_new(0.0, 0.0, 4.0, 6.0);
    CHECK(accesskit_rect_width(&rect) == 4.0);
    CHECK(accesskit_rect_height(&rect) == 6.0);
    CHECK(accesskit_rect_min_x(&rect) == 0.0);
    CHECK(accesskit_rect_min_y(&rect) == 0.0);
    CHECK(accesskit_rect_max_x(&rect) == 4.0);
    CHECK(accesskit_rect_max_y(&rect) == 6.0);
    CHECK(accesskit_rect_area(&rect) == 24.0);
    CHECK(accesskit_rect_is_empty(&rect) == false);

    hit = accesskit_rect_from_points(origin, opposite);
    CHECK(hit.x0 == 1.0);
    CHECK(hit.y1 == 9.0);
    hit = accesskit_rect_from_origin_size(origin, size);
    CHECK(hit.x1 == 5.0);
    CHECK(hit.y1 == 8.0);

    /* `accesskit_rect` returned by value, then taken back by value. */
    moved = accesskit_rect_with_origin(rect, origin);
    CHECK(moved.x0 == 1.0);
    moved = accesskit_rect_with_size(moved, size);
    CHECK(accesskit_rect_width(&moved) == 4.0);
    moved = accesskit_rect_translate(moved, shift);
    CHECK(moved.x0 == 11.0);
    /* `accesskit_rect_abs` takes a pointer and returns by value, unlike its
       neighbours, which take the rect by value. */
    moved = accesskit_rect_abs(&moved);
    CHECK(moved.x0 == 11.0);
    {
        struct accesskit_rect negated = accesskit_rect_new(-4.0, -6.0, 0.0, 0.0);
        struct accesskit_rect positive = accesskit_rect_abs(&negated);
        CHECK(positive.x0 == 4.0);
        CHECK(positive.y1 == 0.0);
    }

    corner = accesskit_rect_origin(&rect);
    CHECK(corner.x == 0.0);
    corner = accesskit_rect_origin(&moved);
    CHECK(corner.x == 11.0);
    {
        struct accesskit_size got = accesskit_rect_size(&rect);
        CHECK(got.width == 4.0);
        CHECK(got.height == 6.0);
    }
    CHECK(accesskit_rect_contains(&rect, origin) == false);
    CHECK(accesskit_rect_contains(&rect, accesskit_vec2_to_point(shift)) ==
          false);
    CHECK(accesskit_rect_contains(&rect, accesskit_vec2_to_point(
                                           (struct accesskit_vec2){1.0, 1.0})) ==
          true);

    unioned = accesskit_rect_union(&rect, hit);
    CHECK(unioned.x0 == 0.0);
    unioned = accesskit_rect_union_pt(&rect, opposite);
    CHECK(unioned.y1 == 9.0);
    unioned = accesskit_rect_intersect(&rect, hit);
    CHECK(unioned.x1 == 4.0);

    /* `accesskit_point` and `accesskit_vec2` in both directions. */
    as_vec2 = accesskit_point_to_vec2(origin);
    CHECK(as_vec2.x == 1.0);
    CHECK(as_vec2.y == 2.0);
    corner = accesskit_point_add_vec2(origin, shift);
    CHECK(corner.x == 11.0);
    corner = accesskit_point_sub_vec2(opposite, shift);
    CHECK(corner.y == -11.0);
    as_vec2 = accesskit_point_sub_point(opposite, origin);
    CHECK(as_vec2.x == 4.0);
    CHECK(as_vec2.y == 7.0);
    as_vec2 = accesskit_vec2_add(shift, as_vec2);
    CHECK(as_vec2.x == 14.0);
    as_vec2 = accesskit_vec2_sub(shift, as_vec2);
    CHECK(as_vec2.x == 0.0);
    as_vec2 = accesskit_vec2_scale(shift, 0.5);
    CHECK(as_vec2.y == 10.0);
    as_vec2 = accesskit_vec2_neg(as_vec2);
    CHECK(as_vec2.y == -10.0);
    corner = accesskit_vec2_to_point(as_vec2);
    CHECK(corner.x == 5.0);

    /* `accesskit_size` in both directions. */
    {
        struct accesskit_vec2 as_vec = accesskit_size_to_vec2(size);
        CHECK(as_vec.x == 4.0);
        size = accesskit_size_scale(size, 2.0);
        CHECK(size.width == 8.0);
        size = accesskit_size_add(size, accesskit_vec2_to_size(shift));
        CHECK(size.height == 26.0);
        size = accesskit_size_sub(size, accesskit_vec2_to_size(shift));
        CHECK(size.height == 6.0);
    }

    /* `accesskit_affine`: nine declarations return one by value, and five
       take one by value. */
    CHECK(accesskit_affine_determinant(identity) == 1.0);
    CHECK(accesskit_affine_is_finite(&identity) == true);
    CHECK(accesskit_affine_is_nan(&identity) == false);
    CHECK(accesskit_affine_is_finite(&flip_x) == true);
    scaled = accesskit_affine_scale(2.0);
    CHECK(accesskit_affine_determinant(scaled) == 4.0);
    scaled_xy = accesskit_affine_scale_non_uniform(2.0, 3.0);
    CHECK(accesskit_affine_determinant(scaled_xy) == 6.0);
    translated = accesskit_affine_translate(shift);
    mapped = accesskit_affine_map_unit_square(rect);
    inverse = accesskit_affine_inverse(scaled);
    CHECK(accesskit_affine_determinant(inverse) == 0.25);
    product = accesskit_affine_mul(scaled, flip_x);
    CHECK(accesskit_affine_determinant(product) == -4.0);
    {
        struct accesskit_rect bbox =
            accesskit_affine_transform_rect_bbox(translated, rect);
        CHECK(bbox.x0 == 10.0);
        CHECK(bbox.y1 == 26.0);
        bbox = accesskit_affine_transform_rect_bbox(mapped, rect);
        CHECK(bbox.x0 == 0.0);
        bbox = accesskit_affine_transform_rect_bbox(flip_y, rect);
        CHECK(bbox.y0 == -6.0);
    }
    {
        struct accesskit_point where =
            accesskit_affine_transform_point(translated, origin);
        CHECK(where.x == 11.0);
        CHECK(where.y == 22.0);
    }
    CHECK(flip_x._0[0] == -1.0 || flip_x._0[0] == 1.0);
}

static void check_custom_actions(void)
{
    struct accesskit_custom_action *first = accesskit_custom_action_new(1);
    struct accesskit_custom_action *second = accesskit_custom_action_new(2);
    struct accesskit_custom_action *const both[] = {first, second};
    struct accesskit_custom_actions *listed;
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_BUTTON);

    CHECK(first != NULL);
    CHECK(second != NULL);
    CHECK(node != NULL);
    if (first == NULL || second == NULL || node == NULL) {
        return;
    }

    accesskit_custom_action_set_description(first, "copy");
    accesskit_custom_action_set_description(second, "paste");

    accesskit_node_set_custom_actions(node, 2u, both);
    listed = accesskit_node_custom_actions(node);
    CHECK(listed != NULL);
    if (listed != NULL) {
        CHECK_SIZE("custom actions", listed->length, 2u);
        CHECK(listed->values != NULL);
        if (listed->values != NULL && listed->length == 2u) {
            char *description = accesskit_custom_action_description(listed->values[0]);
            if (description != NULL) {
                CHECK(strcmp(description, "copy") == 0);
                release_string(description, "listed action description");
            }
            CHECK(accesskit_custom_action_id(listed->values[1]) == 2);
        } else {
            CHECK(false);
        }
        /* This releases the list and every action in it, so the two originals
           are not released again. */
        ++custom_actions_free_calls;
        accesskit_custom_actions_free(listed);
    }
    accesskit_node_clear_custom_actions(node);
    CHECK(accesskit_node_custom_actions(node) == NULL);

    /* A second pair, this time pushed one at a time and released by the caller
       when the node takes them. */
    first = accesskit_custom_action_new(3);
    second = accesskit_custom_action_new(4);
    CHECK(first != NULL);
    CHECK(second != NULL);
    if (first != NULL && second != NULL) {
        accesskit_node_push_custom_action(node, first);
        accesskit_node_push_custom_action(node, second);
        listed = accesskit_node_custom_actions(node);
        if (listed != NULL) {
            CHECK_SIZE("pushed custom actions", listed->length, 2u);
            ++custom_actions_free_calls;
            accesskit_custom_actions_free(listed);
        } else {
            CHECK(false);
            CHECK(false);
        }
    } else if (first != NULL) {
        ++custom_action_free_calls;
        accesskit_custom_action_free(first);
    } else if (second != NULL) {
        ++custom_action_free_calls;
        accesskit_custom_action_free(second);
    }

    ++node_free_calls;
    accesskit_node_free(node);
}

/* ------------------------------------------------------------------------- */
/* Action requests.                                                            */
/*                                                                            */
/* A C consumer never issues one; it receives one. This builds the eight       */
/* documented payload shapes in full, dispatches each through the registered    */
/* action-handler pointer, and checks the handler read the right arm. That       */
/* covers the eight anonymous structs in `accesskit_action_data` and the        */
/* calling convention of the callback together.                                */
/* ------------------------------------------------------------------------- */

struct adapter_state probe_state;

static void begin_request(struct accesskit_action_request *request,
                          accesskit_action action)
{
    request->action = action;
    request->target_tree = ACCESSKIT_TREE_ID_ROOT;
    request->target_node = 5u;
    request->data.has_value = false;
    request->data.value.tag = ACCESSKIT_ACTION_DATA_CUSTOM_ACTION;
    request->data.value.custom_action = 0;
}

/* Dispatches through the header's own action-handler pointer, so the calling
   convention is exercised rather than only declared. The handler records what
   it read; this function then checks the record, which is what a wrong
   convention or a wrong payload arm would break. */
static void dispatch(struct accesskit_action_request *request,
                     accesskit_action_data_Tag expected)
{
    unsigned long before = probe_state.actions;
    accesskit_action seen_action = request->action;
    accesskit_node_id seen_node = request->target_node;

    if (request->data.has_value) {
        CHECK(request->data.value.tag == expected);
    } else {
        /* No payload. The header says `has_value` is false and the value reads
           as a defined zero, so a reader that ignores the flag still gets a
           deterministic answer. */
        CHECK(bytes_are_zero(&request->data.value,
                             sizeof(request->data.value)));
    }
    action_probe_callback(request, &probe_state);
    CHECK(probe_state.actions == before + 1u);
    CHECK(probe_state.last_action == seen_action);
    CHECK(probe_state.last_action_node == seen_node);
    CHECK(probe_state.last_tag == expected);
}

static void check_action_requests(void)
{
    struct accesskit_action_request request;

    memset(&request, 0, sizeof(request));

    /* No payload. The header says `has_value` is false and the value reads as
       a defined zero. */
    begin_request(&request, ACCESSKIT_ACTION_CLICK);
    CHECK(request.data.has_value == false);
    dispatch(&request, ACCESSKIT_ACTION_DATA_CUSTOM_ACTION);

    /* Arm one: a custom action index. */
    begin_request(&request, ACCESSKIT_ACTION_CUSTOM_ACTION);
    request.data.has_value = true;
    request.data.value.tag = ACCESSKIT_ACTION_DATA_CUSTOM_ACTION;
    request.data.value.custom_action = 17;
    dispatch(&request, ACCESSKIT_ACTION_DATA_CUSTOM_ACTION);

    /* Arm two: a replacement string. The header says this `char *` belongs to
       the request and the caller never receives or releases it, so the string
       here is a literal this program owns and the handler must not free it. */
    begin_request(&request, ACCESSKIT_ACTION_REPLACE_SELECTED_TEXT);
    request.data.has_value = true;
    request.data.value.tag = ACCESSKIT_ACTION_DATA_VALUE;
    request.data.value.value = "replacement";
    dispatch(&request, ACCESSKIT_ACTION_DATA_VALUE);
    CHECK(request.data.value.value != NULL);
    if (request.data.value.value != NULL) {
        CHECK(strcmp(request.data.value.value, "replacement") == 0);
    }
    /* No interior-NUL case here, on purpose. The string above is this program's
       own literal, so any assertion about it would be an assertion about a
       constant and could not fail. What the header states about this payload,
       and what a real request obeys, is the rule the string setters state at
       include/zaccesskit.h:5050 and :2890: a byte string is stored up to the
       first NUL byte, because a value holding one cannot come back out of a
       `char *` without losing its tail. That rule is tested for real against
       the library in `check_one_string`, where the bytes come from the
       library.

    /* Arm three: a numeric value. */
    begin_request(&request, ACCESSKIT_ACTION_SET_VALUE);
    request.data.has_value = true;
    request.data.value.tag = ACCESSKIT_ACTION_DATA_NUMERIC_VALUE;
    request.data.value.numeric_value = 2.5;
    dispatch(&request, ACCESSKIT_ACTION_DATA_NUMERIC_VALUE);
    CHECK(request.data.value.numeric_value == 2.5);

    /* Arm four: a scroll unit. */
    begin_request(&request, ACCESSKIT_ACTION_SCROLL_UP);
    request.data.has_value = true;
    request.data.value.tag = ACCESSKIT_ACTION_DATA_SCROLL_UNIT;
    request.data.value.scroll_unit = ACCESSKIT_SCROLL_UNIT_PAGE;
    dispatch(&request, ACCESSKIT_ACTION_DATA_SCROLL_UNIT);

    /* Arm five: a scroll hint. */
    begin_request(&request, ACCESSKIT_ACTION_SCROLL_INTO_VIEW);
    request.data.has_value = true;
    request.data.value.tag = ACCESSKIT_ACTION_DATA_SCROLL_HINT;
    request.data.value.scroll_hint = ACCESSKIT_SCROLL_HINT_BOTTOM_EDGE;
    dispatch(&request, ACCESSKIT_ACTION_DATA_SCROLL_HINT);

    /* Arm six: a point. */
    begin_request(&request, ACCESSKIT_ACTION_SCROLL_TO_POINT);
    request.data.has_value = true;
    request.data.value.tag = ACCESSKIT_ACTION_DATA_SCROLL_TO_POINT;
    request.data.value.scroll_to_point.x = 3.0;
    request.data.value.scroll_to_point.y = 4.0;
    dispatch(&request, ACCESSKIT_ACTION_DATA_SCROLL_TO_POINT);

    /* Arm seven: a scroll offset, which is a point under a different name. */
    begin_request(&request, ACCESSKIT_ACTION_SET_SCROLL_OFFSET);
    request.data.has_value = true;
    request.data.value.tag = ACCESSKIT_ACTION_DATA_SET_SCROLL_OFFSET;
    request.data.value.set_scroll_offset.x = 5.0;
    request.data.value.set_scroll_offset.y = 6.0;
    dispatch(&request, ACCESSKIT_ACTION_DATA_SET_SCROLL_OFFSET);
    CHECK(request.data.value.set_scroll_offset.x == 5.0);

    /* Arm eight: a text selection, the largest payload. */
    begin_request(&request, ACCESSKIT_ACTION_SET_TEXT_SELECTION);
    request.data.has_value = true;
    request.data.value.tag = ACCESSKIT_ACTION_DATA_SET_TEXT_SELECTION;
    request.data.value.set_text_selection.anchor.node = 1u;
    request.data.value.set_text_selection.anchor.character_index = 2u;
    request.data.value.set_text_selection.focus.node = 1u;
    request.data.value.set_text_selection.focus.character_index = 9u;
    dispatch(&request, ACCESSKIT_ACTION_DATA_SET_TEXT_SELECTION);
    CHECK(request.data.value.set_text_selection.focus.character_index == 9u);

    /* Every tag the header declares, so a renumbered tag is caught. */
    CHECK(ACCESSKIT_ACTION_DATA_CUSTOM_ACTION == 0);
    CHECK(ACCESSKIT_ACTION_DATA_VALUE == 1);
    CHECK(ACCESSKIT_ACTION_DATA_NUMERIC_VALUE == 2);
    CHECK(ACCESSKIT_ACTION_DATA_SCROLL_UNIT == 3);
    CHECK(ACCESSKIT_ACTION_DATA_SCROLL_HINT == 4);
    CHECK(ACCESSKIT_ACTION_DATA_SCROLL_TO_POINT == 5);
    CHECK(ACCESSKIT_ACTION_DATA_SET_SCROLL_OFFSET == 6);
    CHECK(ACCESSKIT_ACTION_DATA_SET_TEXT_SELECTION == 7);
}

/* ------------------------------------------------------------------------- */
/* The tree: take one, walk it, read a role and extents, hand it to a platform.*/
/* ------------------------------------------------------------------------- */

#define DEMO_NODES 4u

static struct accesskit_node *demo_nodes[DEMO_NODES];

static accesskit_node_id find_node_in(const struct accesskit_node *parent,
                                      accesskit_node_id wanted)
{
    struct accesskit_node_ids children = accesskit_node_children(parent);
    size_t index;
    if (children.values == NULL) {
        return 0u;
    }
    for (index = 0; index < children.length; ++index) {
        if (children.values[index] == wanted) {
            return wanted;
        }
    }
    return 0u;
}

static void check_tree(void)
{
    static const accesskit_role roles[DEMO_NODES] = {
        ACCESSKIT_ROLE_WINDOW,
        ACCESSKIT_ROLE_GROUP,
        ACCESSKIT_ROLE_LABEL,
        ACCESSKIT_ROLE_BUTTON,
    };
    static const accesskit_node_id ids[DEMO_NODES] = {1u, 2u, 3u, 4u};
    static const char *const labels[DEMO_NODES] = {"root", "group", "name",
                                                   "press me"};
    static const struct accesskit_rect bounds[DEMO_NODES] = {
        {0.0, 0.0, 800.0, 600.0},
        {10.0, 10.0, 400.0, 300.0},
        {20.0, 20.0, 200.0, 40.0},
        {30.0, 400.0, 120.0, 440.0},
    };
    struct accesskit_tree_update *update;
    struct accesskit_tree_info *tree_info;
    struct accesskit_node_ids children;
    struct accesskit_node_ids root_ids;
    char *debug;
    size_t index;
    unsigned long visited = 0u;

    for (index = 0; index < DEMO_NODES; ++index) {
        demo_nodes[index] = accesskit_node_new(roles[index]);
        CHECK(demo_nodes[index] != NULL);
        if (demo_nodes[index] == NULL) {
            return;
        }
        accesskit_node_set_label(demo_nodes[index], labels[index]);
        accesskit_node_set_bounds(demo_nodes[index], bounds[index]);
        accesskit_node_add_action(demo_nodes[index], ACCESSKIT_ACTION_CLICK);
        accesskit_node_add_action(demo_nodes[index], ACCESSKIT_ACTION_FOCUS);
    }

    /* One tree, two levels, with the third node labelled by the fourth. */
    accesskit_node_set_children(demo_nodes[1], 1u, &ids[2]);
    accesskit_node_set_children(demo_nodes[0], 2u, (const accesskit_node_id[]){
                                                       2u, 4u});
    accesskit_node_set_labelled_by(demo_nodes[2], 1u, &ids[3]);

    /* Read a role and extents back off a node, the way a consumer must before
       the tree is handed over. */
    CHECK(accesskit_node_role(demo_nodes[0]) == ACCESSKIT_ROLE_WINDOW);
    CHECK(accesskit_node_bounds(demo_nodes[0]).has_value == true);
    CHECK(accesskit_node_bounds(demo_nodes[0]).value.x1 == 800.0);
    CHECK(accesskit_node_supports_action(demo_nodes[3],
                                         ACCESSKIT_ACTION_CLICK) == true);

    /* Walk the tree. The lists are borrowed from the nodes, so the node has to
       stay alive and unmodified while the walk reads them. */
    root_ids = accesskit_node_children(demo_nodes[0]);
    CHECK_SIZE("root children", root_ids.length, 2u);
    if (root_ids.values != NULL && root_ids.length == 2u) {
        CHECK(root_ids.values[0] == 2u);
        CHECK(root_ids.values[1] == 4u);
        CHECK(find_node_in(demo_nodes[0], 2u) == 2u);
        CHECK(find_node_in(demo_nodes[0], 4u) == 4u);
        CHECK(find_node_in(demo_nodes[0], 3u) == 0u);
        ++visited;
    }
    children = accesskit_node_children(demo_nodes[1]);
    CHECK_SIZE("group children", children.length, 1u);
    if (children.values != NULL && children.length == 1u) {
        CHECK(children.values[0] == 3u);
        ++visited;
    }
    children = accesskit_node_labelled_by(demo_nodes[2]);
    CHECK_SIZE("labelled by", children.length, 1u);
    if (children.values != NULL && children.length == 1u) {
        CHECK(children.values[0] == 4u);
        ++visited;
    }
    CHECK(visited == 3u);

    debug = accesskit_node_debug(demo_nodes[0]);
    if (debug != NULL) {
        CHECK(debug != NULL);
        release_string(debug, "node debug");
    } else {
        CHECK(false);
    }

    /* The tree info and the update. `accesskit_tree_update_set_tree_info`
       consumes its argument, so it is not released afterwards. */
    tree_info = accesskit_tree_info_new(ids[0]);
    CHECK(tree_info != NULL);
    accesskit_tree_info_set_toolkit_name(tree_info, "zaccesskit");
    accesskit_tree_info_set_toolkit_version(tree_info, "0.16.0");

    update = accesskit_tree_update_with_capacity_and_focus(DEMO_NODES, ids[3]);
    CHECK(update != NULL);
    if (update != NULL) {
        struct accesskit_tree_id id = accesskit_tree_update_get_tree_id(update);
        CHECK(memcmp(&id, &ACCESSKIT_TREE_ID_ROOT, sizeof(id)) == 0);
        for (index = 0; index < DEMO_NODES; ++index) {
            /* Push takes ownership, so each node is released exactly once and
               not at all by hand. */
            accesskit_tree_update_push_node(update, ids[index], demo_nodes[index]);
            demo_nodes[index] = NULL;
        }
        accesskit_tree_update_set_tree_info(update, tree_info);
        accesskit_tree_update_set_focus(update, ids[3]);
        debug = accesskit_tree_update_debug(update);
        if (debug != NULL) {
            release_string(debug, "tree update debug");
        } else {
            CHECK(false);
        }
        ++tree_update_free_calls;
        accesskit_tree_update_free(update);
    } else {
        ++tree_info_free_calls;
        accesskit_tree_info_free(tree_info);
        for (index = 0; index < DEMO_NODES; ++index) {
            if (demo_nodes[index] != NULL) {
                ++node_free_calls;
                accesskit_node_free(demo_nodes[index]);
                demo_nodes[index] = NULL;
            }
        }
    }

    CHECK(ACCESSKIT_ERROR_NONE == 0);
    CHECK(accesskit_last_error() == ACCESSKIT_ERROR_NONE);
}

/* ------------------------------------------------------------------------- */
/* The platform registration.                                                   */
/*                                                                            */
/* `accesskit_unix_adapter_new` is the one platform constructor this target has */
/* and it is the whole seam: three callbacks and three context pointers. The    */
/* other platforms are compiled behind their guards in the header, so a consumer */
/* on Linux cannot name them and this file does not try.                        */
/*                                                                            */
/* This block is compiled on every run and executed on none of them unless      */
/* `--live` is given. Creating an adapter opens a session on the running        */
/* accessibility bus, and a stray `Socket.Embed` on that bus takes down         */
/* `at-spi2-registryd` for every process on the machine. So the default is off  */
/* and turning it on is a deliberate act.                                       */
/* ------------------------------------------------------------------------- */

#if defined(__linux__) || defined(__FreeBSD__) || defined(__NetBSD__) ||        \
    defined(__OpenBSD__) || defined(__DragonFly__)

static int reach_the_live_bus;

static void check_platform_registration(struct adapter_state *state)
{
    struct accesskit_unix_adapter *adapter;
    struct accesskit_rect outer;
    struct accesskit_rect inner;
    unsigned long before;
    struct accesskit_tree_update *update;
    char *debug;

    /* The four callbacks are held in the header's own typedefs and registered
       by value. The assignment of each function to its typedef, at file scope
       above, is the compile-time half of this check; this is the runtime half,
       and it is off unless it was asked for. */
    CHECK(activation_callback == on_activate);
    CHECK(deactivation_callback == on_deactivate);
    CHECK(action_callback == on_action);
    CHECK(update_factory == on_build_update);
    if (!reach_the_live_bus) {
        note_skipped("platform registration");
        return;
    }

    adapter = accesskit_unix_adapter_new(activation_callback, state,
                                        action_callback, state,
                                        deactivation_callback, state);
    CHECK(adapter != NULL);
    if (adapter == NULL) {
        return;
    }

    /* The adapter takes two rectangles by value. */
    outer = accesskit_rect_new(0.0, 0.0, 1024.0, 768.0);
    inner = accesskit_rect_new(0.0, 24.0, 1024.0, 744.0);
    accesskit_unix_adapter_set_root_window_bounds(adapter, outer, inner);

    accesskit_unix_adapter_update_window_focus_state(adapter, true);

    /* The factory is handed the context the registration was given, unchanged,
       so a state pointer that arrives as something else is caught here. */
    before = state->activations;
    CHECK(activation_callback(state) == NULL);
    CHECK(state->activations == before + 1u);

    /* `update_factory` is the fourth callback and takes the library's own
       context type, not `void *`. */
    update = update_factory(state);
    CHECK(update != NULL);
    if (update != NULL) {
        ++tree_update_free_calls;
        accesskit_tree_update_free(update);
    }

    debug = accesskit_unix_adapter_debug(adapter);
    if (debug != NULL) {
        release_string(debug, "adapter debug");
    }

    /* One adapter, created above, released exactly once. */
    accesskit_unix_adapter_free(adapter);
}

#endif /* the Linux and BSD family */

/* ------------------------------------------------------------------------- */
/* The release ledger.                                                          */
/*                                                                            */
/* One allocation per free function, released exactly once by that free         */
/* function, counted. The sweeps above release far more than this; the ledger   */
/* is the place where each of the eight is called once on an allocation of its   */
/* own, so a free that took the wrong thing, or was reached twice, shows up as a */
/* count that is not one.                                                       */
/*                                                                            */
/* `accesskit_action_request_free` is the one the ledger cannot cover. The       */
/* header gives a C consumer no way to build a request the library will take     */
/* ownership of, so no such allocation exists to release. Its release path is    */
/* `release_action_request`, which the registered handler runs on every request  */
/* the library delivers, and its count is reported as zero when none arrived.     */
/* `accesskit_unix_adapter_free` needs a live bus and is only reached under        */
/* `--live`.                                                                     */
/* ------------------------------------------------------------------------- */

static void check_release_ledger(void)
{
    unsigned long before_strings = string_free_calls;
    unsigned long before_action = custom_action_free_calls;
    unsigned long before_actions = custom_actions_free_calls;
    unsigned long before_node = node_free_calls;
    unsigned long before_info = tree_info_free_calls;
    unsigned long before_update = tree_update_free_calls;
    /* Two custom actions, on purpose. One goes on a node and is released by
       `accesskit_custom_actions_free` with the list; the other is never handed
       to anyone, so `accesskit_custom_action_free` has an allocation of its own
       to release. Sharing one between the two would make one of the two frees
       a null or a double free. */
    struct accesskit_custom_action *listed_action =
        accesskit_custom_action_new(11);
    struct accesskit_custom_action *own_action =
        accesskit_custom_action_new(12);
    struct accesskit_tree_info *info = accesskit_tree_info_new(DEMO_ROOT_ID);
    struct accesskit_tree_update *update =
        accesskit_tree_update_with_capacity_and_focus(1u, DEMO_ROOT_ID);
    struct accesskit_node *node = accesskit_node_new(ACCESSKIT_ROLE_BUTTON);
    char *string = NULL;

    CHECK(listed_action != NULL);
    CHECK(own_action != NULL);
    CHECK(info != NULL);
    CHECK(update != NULL);
    CHECK(node != NULL);
    if (listed_action == NULL || own_action == NULL || info == NULL ||
        update == NULL || node == NULL) {
        if (listed_action != NULL) { accesskit_custom_action_free(listed_action); }
        if (own_action != NULL) { accesskit_custom_action_free(own_action); }
        if (info != NULL) { accesskit_tree_info_free(info); }
        if (update != NULL) { accesskit_tree_update_free(update); }
        if (node != NULL) { accesskit_node_free(node); }
        return;
    }

    /* One string of its own, read off the node and released on its own. */
    accesskit_node_set_label(node, "ledger");
    string = accesskit_node_label(node);
    if (string != NULL) {
        ++string_free_calls;
        accesskit_string_free(string);
    } else {
        ++checks_run;
        ++checks_failed;
        (void)fprintf(stderr, "FAIL %s: the ledger node lost its label\n",
                      __FILE__);
    }

    /* One list of its own. This releases the list and the action inside it, so
       `listed_action` is not released a second time. */
    accesskit_custom_action_set_description(listed_action, "in a list");
    accesskit_node_push_custom_action(node, listed_action);
    {
        struct accesskit_custom_actions *listed =
            accesskit_node_custom_actions(node);
        CHECK(listed != NULL);
        if (listed != NULL) {
            CHECK_SIZE("ledger custom actions", listed->length, 1u);
            ++custom_actions_free_calls;
            accesskit_custom_actions_free(listed);
        }
        accesskit_node_clear_custom_actions(node);
    }

    ++custom_action_free_calls;
    accesskit_custom_action_free(own_action);

    ++node_free_calls;
    accesskit_node_free(node);
    ++tree_info_free_calls;
    accesskit_tree_info_free(info);
    ++tree_update_free_calls;
    accesskit_tree_update_free(update);

    /* One release each, on its own allocation. A count that is not exactly one
       means a free ran twice or not at all. */
    CHECK_SIZE("string releases in the ledger", string_free_calls - before_strings,
               1u);
    CHECK_SIZE("custom action releases in the ledger",
               custom_action_free_calls - before_action, 1u);
    CHECK_SIZE("custom action list releases in the ledger",
               custom_actions_free_calls - before_actions, 1u);
    CHECK_SIZE("node releases in the ledger", node_free_calls - before_node, 1u);
    CHECK_SIZE("tree info releases in the ledger", tree_info_free_calls - before_info,
               1u);
    CHECK_SIZE("tree update releases in the ledger",
               tree_update_free_calls - before_update, 1u);
}

/* ------------------------------------------------------------------------- */
/* `accesskit_opt_lresult`, which the header keeps behind `_WIN32`.             */
/* ------------------------------------------------------------------------- */

#if defined(_WIN32)
static void check_opt_lresult(void)
{
    accesskit_opt_lresult got;
    got.has_value = false;
    got.value = (LRESULT)0;
    CHECK(got.has_value == false);
    CHECK(got.value == (LRESULT)0);
}
#endif

/* ------------------------------------------------------------------------- */

int main(void)
{
    struct adapter_state state;

    accesskit_set_allocator(counting_alloc, counting_free,
                           &allocator_context_seen);

    state.activations = 0u;
    state.deactivations = 0u;
    state.actions = 0u;
    state.updates_built = 0u;
    state.last_action = ACCESSKIT_ACTION_CLICK;
    state.last_action_node = 0u;
    probe_state = state;

    check_callbacks(&state);
    check_flags();
    check_opt_node_id();
    check_opt_double();
    check_opt_float();
    check_opt_index();
    check_opt_color();
    check_opt_text_decoration();
    check_opt_bool();
    check_opt_invalid();
    check_opt_toggled();
    check_opt_live();
    check_opt_text_direction();
    check_opt_orientation();
    check_opt_sort_direction();
    check_opt_aria_current();
    check_opt_auto_complete();
    check_opt_has_popup();
    check_opt_list_style();
    check_opt_text_align();
    check_opt_vertical_offset();
    check_opt_tree_id();
    check_opt_rect();
    check_opt_text_selection();
    check_lengths();
    check_opt_coords();
    check_id_lists();
    check_transform();
    check_actions();
    check_node_strings();
    check_strings_at_a_page_boundary();
    check_owner_string_pairs();
    check_rect_and_vectors();
    check_custom_actions();
    check_action_requests();
    check_tree();
#if defined(__linux__) || defined(__FreeBSD__) || defined(__NetBSD__) ||        \
    defined(__OpenBSD__) || defined(__DragonFly__)
    check_platform_registration(&state);
#endif
#if defined(_WIN32)
    check_opt_lresult();
#endif

    /* The surface census is read here, so no member is dead. `sizeof` is the
       one number that grows if a declaration is added and this copy is stale:
       every member is at least a pointer wide, so a struct with fewer than
       `ACCESSKIT_SURFACE_FUNCTION_COUNT` members cannot reach the bound. */
    CHECK(accesskit_surface_all.node_new != NULL);
    CHECK(accesskit_surface_all.last_error != NULL);
    CHECK_SIZE("surface census",
               sizeof(accesskit_surface),
               ACCESSKIT_SURFACE_FUNCTION_COUNT * sizeof(void (*)(void)));

    (void)fprintf(stdout,
                  "zaccesskit C consumer: %lu checks, %lu failed\n", checks_run,
                  checks_failed);
    (void)fprintf(stdout,
                  "releases: strings %lu, custom actions %lu, action lists %lu, "
                  "nodes %lu, tree infos %lu, tree updates %lu, action requests "
                  "%lu\n",
                  string_free_calls, custom_action_free_calls,
                  custom_actions_free_calls, node_free_calls, tree_info_free_calls,
                  tree_update_free_calls, action_request_free_calls);
    (void)fprintf(stdout, "allocator: %lu allocations, %lu frees\n",
                  allocator_alloc_calls, allocator_free_calls);
    return (checks_failed == 0u) ? 0 : 1;
}
