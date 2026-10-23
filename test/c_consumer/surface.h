/* The whole C surface, spelled by a consumer, on the target being compiled.
 *
 * The number of members below, so a stale copy of this file cannot pass
 * silently: `consumer.c` checks `sizeof(accesskit_surface)` against it.
 */
#define ACCESSKIT_SURFACE_FUNCTION_COUNT 446
/*
 * One function-pointer member per declaration that `zaccesskit.h` makes visible
 * on this target. A member's declared type is written out by hand and its
 * initialiser is the function itself, so a declaration that cannot be spelled
 * as a callable pointer, or whose types do not agree with the hand-written
 * pointer, is a compile error here and nowhere else.
 *
 * This file is generated from `include/zaccesskit.h`. Regenerate it when the
 * header gains or loses a declaration; `check.sh` reports the count it found so
 * a stale copy cannot pass silently.
 *
 * It is compiled as C11 with `-Wall -Wextra -Wpedantic`. It is not application
 * code and nothing calls through these pointers: this is a declaration census.
 */
#ifndef ZACCESSKIT_TEST_C_CONSUMER_SURFACE_H
#define ZACCESSKIT_TEST_C_CONSUMER_SURFACE_H

/* Every declaration this target sees, as function-pointer members. */
typedef struct accesskit_surface {
    accesskit_role (*node_role)(const struct accesskit_node *node);
    void (*node_set_role)(struct accesskit_node *node, accesskit_role value);
    bool (*node_supports_action)(const struct accesskit_node *node, accesskit_action action);
    void (*node_add_action)(struct accesskit_node *node, accesskit_action action);
    void (*node_remove_action)(struct accesskit_node *node, accesskit_action action);
    void (*node_clear_actions)(struct accesskit_node *node);
    bool (*node_child_supports_action)(const struct accesskit_node *node, accesskit_action action);
    void (*node_add_child_action)(struct accesskit_node *node, accesskit_action action);
    void (*node_remove_child_action)(struct accesskit_node *node, accesskit_action action);
    void (*node_clear_child_actions)(struct accesskit_node *node);
    bool (*node_is_hidden)(const struct accesskit_node *node);
    void (*node_set_hidden)(struct accesskit_node *node);
    void (*node_clear_hidden)(struct accesskit_node *node);
    bool (*node_is_multiselectable)(const struct accesskit_node *node);
    void (*node_set_multiselectable)(struct accesskit_node *node);
    void (*node_clear_multiselectable)(struct accesskit_node *node);
    bool (*node_is_required)(const struct accesskit_node *node);
    void (*node_set_required)(struct accesskit_node *node);
    void (*node_clear_required)(struct accesskit_node *node);
    bool (*node_is_visited)(const struct accesskit_node *node);
    void (*node_set_visited)(struct accesskit_node *node);
    void (*node_clear_visited)(struct accesskit_node *node);
    bool (*node_is_busy)(const struct accesskit_node *node);
    void (*node_set_busy)(struct accesskit_node *node);
    void (*node_clear_busy)(struct accesskit_node *node);
    bool (*node_is_live_atomic)(const struct accesskit_node *node);
    void (*node_set_live_atomic)(struct accesskit_node *node);
    void (*node_clear_live_atomic)(struct accesskit_node *node);
    bool (*node_is_modal)(const struct accesskit_node *node);
    void (*node_set_modal)(struct accesskit_node *node);
    void (*node_clear_modal)(struct accesskit_node *node);
    bool (*node_is_touch_transparent)(const struct accesskit_node *node);
    void (*node_set_touch_transparent)(struct accesskit_node *node);
    void (*node_clear_touch_transparent)(struct accesskit_node *node);
    bool (*node_is_read_only)(const struct accesskit_node *node);
    void (*node_set_read_only)(struct accesskit_node *node);
    void (*node_clear_read_only)(struct accesskit_node *node);
    bool (*node_is_disabled)(const struct accesskit_node *node);
    void (*node_set_disabled)(struct accesskit_node *node);
    void (*node_clear_disabled)(struct accesskit_node *node);
    bool (*node_is_italic)(const struct accesskit_node *node);
    void (*node_set_italic)(struct accesskit_node *node);
    void (*node_clear_italic)(struct accesskit_node *node);
    bool (*node_clips_children)(const struct accesskit_node *node);
    void (*node_set_clips_children)(struct accesskit_node *node);
    void (*node_clear_clips_children)(struct accesskit_node *node);
    bool (*node_is_line_breaking_object)(const struct accesskit_node *node);
    void (*node_set_is_line_breaking_object)(struct accesskit_node *node);
    void (*node_clear_is_line_breaking_object)(struct accesskit_node *node);
    bool (*node_is_page_breaking_object)(const struct accesskit_node *node);
    void (*node_set_is_page_breaking_object)(struct accesskit_node *node);
    void (*node_clear_is_page_breaking_object)(struct accesskit_node *node);
    bool (*node_is_spelling_error)(const struct accesskit_node *node);
    void (*node_set_is_spelling_error)(struct accesskit_node *node);
    void (*node_clear_is_spelling_error)(struct accesskit_node *node);
    bool (*node_is_grammar_error)(const struct accesskit_node *node);
    void (*node_set_is_grammar_error)(struct accesskit_node *node);
    void (*node_clear_is_grammar_error)(struct accesskit_node *node);
    bool (*node_is_search_match)(const struct accesskit_node *node);
    void (*node_set_is_search_match)(struct accesskit_node *node);
    void (*node_clear_is_search_match)(struct accesskit_node *node);
    bool (*node_is_suggestion)(const struct accesskit_node *node);
    void (*node_set_is_suggestion)(struct accesskit_node *node);
    void (*node_clear_is_suggestion)(struct accesskit_node *node);
    struct accesskit_node_ids (*node_children)(const struct accesskit_node *node);
    void (*node_set_children)(struct accesskit_node *node, size_t length, const accesskit_node_id *values);
    void (*node_push_child)(struct accesskit_node *node, accesskit_node_id item);
    void (*node_clear_children)(struct accesskit_node *node);
    struct accesskit_node_ids (*node_controls)(const struct accesskit_node *node);
    void (*node_set_controls)(struct accesskit_node *node, size_t length, const accesskit_node_id *values);
    void (*node_push_controlled)(struct accesskit_node *node, accesskit_node_id item);
    void (*node_clear_controls)(struct accesskit_node *node);
    struct accesskit_node_ids (*node_details)(const struct accesskit_node *node);
    void (*node_set_details)(struct accesskit_node *node, size_t length, const accesskit_node_id *values);
    void (*node_push_detail)(struct accesskit_node *node, accesskit_node_id item);
    void (*node_clear_details)(struct accesskit_node *node);
    struct accesskit_node_ids (*node_described_by)(const struct accesskit_node *node);
    void (*node_set_described_by)(struct accesskit_node *node, size_t length, const accesskit_node_id *values);
    void (*node_push_described_by)(struct accesskit_node *node, accesskit_node_id item);
    void (*node_clear_described_by)(struct accesskit_node *node);
    struct accesskit_node_ids (*node_flow_to)(const struct accesskit_node *node);
    void (*node_set_flow_to)(struct accesskit_node *node, size_t length, const accesskit_node_id *values);
    void (*node_push_flow_to)(struct accesskit_node *node, accesskit_node_id item);
    void (*node_clear_flow_to)(struct accesskit_node *node);
    struct accesskit_node_ids (*node_labelled_by)(const struct accesskit_node *node);
    void (*node_set_labelled_by)(struct accesskit_node *node, size_t length, const accesskit_node_id *values);
    void (*node_push_labelled_by)(struct accesskit_node *node, accesskit_node_id item);
    void (*node_clear_labelled_by)(struct accesskit_node *node);
    struct accesskit_node_ids (*node_owns)(const struct accesskit_node *node);
    void (*node_set_owns)(struct accesskit_node *node, size_t length, const accesskit_node_id *values);
    void (*node_push_owned)(struct accesskit_node *node, accesskit_node_id item);
    void (*node_clear_owns)(struct accesskit_node *node);
    struct accesskit_node_ids (*node_radio_group)(const struct accesskit_node *node);
    void (*node_set_radio_group)(struct accesskit_node *node, size_t length, const accesskit_node_id *values);
    void (*node_push_to_radio_group)(struct accesskit_node *node, accesskit_node_id item);
    void (*node_clear_radio_group)(struct accesskit_node *node);
    struct accesskit_opt_node_id (*node_active_descendant)(const struct accesskit_node *node);
    void (*node_set_active_descendant)(struct accesskit_node *node, accesskit_node_id value);
    void (*node_clear_active_descendant)(struct accesskit_node *node);
    struct accesskit_opt_node_id (*node_error_message)(const struct accesskit_node *node);
    void (*node_set_error_message)(struct accesskit_node *node, accesskit_node_id value);
    void (*node_clear_error_message)(struct accesskit_node *node);
    struct accesskit_opt_node_id (*node_in_page_link_target)(const struct accesskit_node *node);
    void (*node_set_in_page_link_target)(struct accesskit_node *node, accesskit_node_id value);
    void (*node_clear_in_page_link_target)(struct accesskit_node *node);
    struct accesskit_opt_node_id (*node_member_of)(const struct accesskit_node *node);
    void (*node_set_member_of)(struct accesskit_node *node, accesskit_node_id value);
    void (*node_clear_member_of)(struct accesskit_node *node);
    struct accesskit_opt_node_id (*node_next_on_line)(const struct accesskit_node *node);
    void (*node_set_next_on_line)(struct accesskit_node *node, accesskit_node_id value);
    void (*node_clear_next_on_line)(struct accesskit_node *node);
    struct accesskit_opt_node_id (*node_previous_on_line)(const struct accesskit_node *node);
    void (*node_set_previous_on_line)(struct accesskit_node *node, accesskit_node_id value);
    void (*node_clear_previous_on_line)(struct accesskit_node *node);
    struct accesskit_opt_node_id (*node_popup_for)(const struct accesskit_node *node);
    void (*node_set_popup_for)(struct accesskit_node *node, accesskit_node_id value);
    void (*node_clear_popup_for)(struct accesskit_node *node);
    struct accesskit_opt_tree_id (*node_tree_id)(const struct accesskit_node *node);
    void (*node_set_tree_id)(struct accesskit_node *node, struct accesskit_tree_id value);
    void (*node_clear_tree_id)(struct accesskit_node *node);
    void (*string_free)(char *string);
    char * (*node_label)(const struct accesskit_node *node);
    void (*node_set_label)(struct accesskit_node *node, const char *value);
    void (*node_set_label_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_label)(struct accesskit_node *node);
    char * (*node_description)(const struct accesskit_node *node);
    void (*node_set_description)(struct accesskit_node *node, const char *value);
    void (*node_set_description_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_description)(struct accesskit_node *node);
    char * (*node_value)(const struct accesskit_node *node);
    void (*node_set_value)(struct accesskit_node *node, const char *value);
    void (*node_set_value_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_value)(struct accesskit_node *node);
    char * (*node_access_key)(const struct accesskit_node *node);
    void (*node_set_access_key)(struct accesskit_node *node, const char *value);
    void (*node_set_access_key_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_access_key)(struct accesskit_node *node);
    char * (*node_author_id)(const struct accesskit_node *node);
    void (*node_set_author_id)(struct accesskit_node *node, const char *value);
    void (*node_set_author_id_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_author_id)(struct accesskit_node *node);
    char * (*node_class_name)(const struct accesskit_node *node);
    void (*node_set_class_name)(struct accesskit_node *node, const char *value);
    void (*node_set_class_name_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_class_name)(struct accesskit_node *node);
    char * (*node_font_family)(const struct accesskit_node *node);
    void (*node_set_font_family)(struct accesskit_node *node, const char *value);
    void (*node_set_font_family_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_font_family)(struct accesskit_node *node);
    char * (*node_html_id)(const struct accesskit_node *node);
    void (*node_set_html_id)(struct accesskit_node *node, const char *value);
    void (*node_set_html_id_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_html_id)(struct accesskit_node *node);
    char * (*node_html_tag)(const struct accesskit_node *node);
    void (*node_set_html_tag)(struct accesskit_node *node, const char *value);
    void (*node_set_html_tag_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_html_tag)(struct accesskit_node *node);
    char * (*node_inner_html)(const struct accesskit_node *node);
    void (*node_set_inner_html)(struct accesskit_node *node, const char *value);
    void (*node_set_inner_html_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_inner_html)(struct accesskit_node *node);
    char * (*node_keyboard_shortcut)(const struct accesskit_node *node);
    void (*node_set_keyboard_shortcut)(struct accesskit_node *node, const char *value);
    void (*node_set_keyboard_shortcut_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_keyboard_shortcut)(struct accesskit_node *node);
    char * (*node_language)(const struct accesskit_node *node);
    void (*node_set_language)(struct accesskit_node *node, const char *value);
    void (*node_set_language_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_language)(struct accesskit_node *node);
    char * (*node_placeholder)(const struct accesskit_node *node);
    void (*node_set_placeholder)(struct accesskit_node *node, const char *value);
    void (*node_set_placeholder_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_placeholder)(struct accesskit_node *node);
    char * (*node_role_description)(const struct accesskit_node *node);
    void (*node_set_role_description)(struct accesskit_node *node, const char *value);
    void (*node_set_role_description_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_role_description)(struct accesskit_node *node);
    char * (*node_state_description)(const struct accesskit_node *node);
    void (*node_set_state_description)(struct accesskit_node *node, const char *value);
    void (*node_set_state_description_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_state_description)(struct accesskit_node *node);
    char * (*node_tooltip)(const struct accesskit_node *node);
    void (*node_set_tooltip)(struct accesskit_node *node, const char *value);
    void (*node_set_tooltip_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_tooltip)(struct accesskit_node *node);
    char * (*node_url)(const struct accesskit_node *node);
    void (*node_set_url)(struct accesskit_node *node, const char *value);
    void (*node_set_url_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_url)(struct accesskit_node *node);
    char * (*node_row_index_text)(const struct accesskit_node *node);
    void (*node_set_row_index_text)(struct accesskit_node *node, const char *value);
    void (*node_set_row_index_text_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_row_index_text)(struct accesskit_node *node);
    char * (*node_column_index_text)(const struct accesskit_node *node);
    void (*node_set_column_index_text)(struct accesskit_node *node, const char *value);
    void (*node_set_column_index_text_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_column_index_text)(struct accesskit_node *node);
    char * (*node_braille_label)(const struct accesskit_node *node);
    void (*node_set_braille_label)(struct accesskit_node *node, const char *value);
    void (*node_set_braille_label_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_braille_label)(struct accesskit_node *node);
    char * (*node_braille_role_description)(const struct accesskit_node *node);
    void (*node_set_braille_role_description)(struct accesskit_node *node, const char *value);
    void (*node_set_braille_role_description_with_length)(struct accesskit_node *node, const char *value, size_t length);
    void (*node_clear_braille_role_description)(struct accesskit_node *node);
    struct accesskit_opt_double (*node_scroll_x)(const struct accesskit_node *node);
    void (*node_set_scroll_x)(struct accesskit_node *node, double value);
    void (*node_clear_scroll_x)(struct accesskit_node *node);
    struct accesskit_opt_double (*node_scroll_x_min)(const struct accesskit_node *node);
    void (*node_set_scroll_x_min)(struct accesskit_node *node, double value);
    void (*node_clear_scroll_x_min)(struct accesskit_node *node);
    struct accesskit_opt_double (*node_scroll_x_max)(const struct accesskit_node *node);
    void (*node_set_scroll_x_max)(struct accesskit_node *node, double value);
    void (*node_clear_scroll_x_max)(struct accesskit_node *node);
    struct accesskit_opt_double (*node_scroll_y)(const struct accesskit_node *node);
    void (*node_set_scroll_y)(struct accesskit_node *node, double value);
    void (*node_clear_scroll_y)(struct accesskit_node *node);
    struct accesskit_opt_double (*node_scroll_y_min)(const struct accesskit_node *node);
    void (*node_set_scroll_y_min)(struct accesskit_node *node, double value);
    void (*node_clear_scroll_y_min)(struct accesskit_node *node);
    struct accesskit_opt_double (*node_scroll_y_max)(const struct accesskit_node *node);
    void (*node_set_scroll_y_max)(struct accesskit_node *node, double value);
    void (*node_clear_scroll_y_max)(struct accesskit_node *node);
    struct accesskit_opt_double (*node_numeric_value)(const struct accesskit_node *node);
    void (*node_set_numeric_value)(struct accesskit_node *node, double value);
    void (*node_clear_numeric_value)(struct accesskit_node *node);
    struct accesskit_opt_double (*node_min_numeric_value)(const struct accesskit_node *node);
    void (*node_set_min_numeric_value)(struct accesskit_node *node, double value);
    void (*node_clear_min_numeric_value)(struct accesskit_node *node);
    struct accesskit_opt_double (*node_max_numeric_value)(const struct accesskit_node *node);
    void (*node_set_max_numeric_value)(struct accesskit_node *node, double value);
    void (*node_clear_max_numeric_value)(struct accesskit_node *node);
    struct accesskit_opt_double (*node_numeric_value_step)(const struct accesskit_node *node);
    void (*node_set_numeric_value_step)(struct accesskit_node *node, double value);
    void (*node_clear_numeric_value_step)(struct accesskit_node *node);
    struct accesskit_opt_double (*node_numeric_value_jump)(const struct accesskit_node *node);
    void (*node_set_numeric_value_jump)(struct accesskit_node *node, double value);
    void (*node_clear_numeric_value_jump)(struct accesskit_node *node);
    struct accesskit_opt_float (*node_font_size)(const struct accesskit_node *node);
    void (*node_set_font_size)(struct accesskit_node *node, float value);
    void (*node_clear_font_size)(struct accesskit_node *node);
    struct accesskit_opt_float (*node_font_weight)(const struct accesskit_node *node);
    void (*node_set_font_weight)(struct accesskit_node *node, float value);
    void (*node_clear_font_weight)(struct accesskit_node *node);
    struct accesskit_opt_index (*node_row_count)(const struct accesskit_node *node);
    void (*node_set_row_count)(struct accesskit_node *node, size_t value);
    void (*node_clear_row_count)(struct accesskit_node *node);
    struct accesskit_opt_index (*node_column_count)(const struct accesskit_node *node);
    void (*node_set_column_count)(struct accesskit_node *node, size_t value);
    void (*node_clear_column_count)(struct accesskit_node *node);
    struct accesskit_opt_index (*node_row_index)(const struct accesskit_node *node);
    void (*node_set_row_index)(struct accesskit_node *node, size_t value);
    void (*node_clear_row_index)(struct accesskit_node *node);
    struct accesskit_opt_index (*node_column_index)(const struct accesskit_node *node);
    void (*node_set_column_index)(struct accesskit_node *node, size_t value);
    void (*node_clear_column_index)(struct accesskit_node *node);
    struct accesskit_opt_index (*node_row_span)(const struct accesskit_node *node);
    void (*node_set_row_span)(struct accesskit_node *node, size_t value);
    void (*node_clear_row_span)(struct accesskit_node *node);
    struct accesskit_opt_index (*node_column_span)(const struct accesskit_node *node);
    void (*node_set_column_span)(struct accesskit_node *node, size_t value);
    void (*node_clear_column_span)(struct accesskit_node *node);
    struct accesskit_opt_index (*node_level)(const struct accesskit_node *node);
    void (*node_set_level)(struct accesskit_node *node, size_t value);
    void (*node_clear_level)(struct accesskit_node *node);
    struct accesskit_opt_index (*node_size_of_set)(const struct accesskit_node *node);
    void (*node_set_size_of_set)(struct accesskit_node *node, size_t value);
    void (*node_clear_size_of_set)(struct accesskit_node *node);
    struct accesskit_opt_index (*node_position_in_set)(const struct accesskit_node *node);
    void (*node_set_position_in_set)(struct accesskit_node *node, size_t value);
    void (*node_clear_position_in_set)(struct accesskit_node *node);
    struct accesskit_opt_color (*node_color_value)(const struct accesskit_node *node);
    void (*node_set_color_value)(struct accesskit_node *node, struct accesskit_color value);
    void (*node_clear_color_value)(struct accesskit_node *node);
    struct accesskit_opt_color (*node_background_color)(const struct accesskit_node *node);
    void (*node_set_background_color)(struct accesskit_node *node, struct accesskit_color value);
    void (*node_clear_background_color)(struct accesskit_node *node);
    struct accesskit_opt_color (*node_foreground_color)(const struct accesskit_node *node);
    void (*node_set_foreground_color)(struct accesskit_node *node, struct accesskit_color value);
    void (*node_clear_foreground_color)(struct accesskit_node *node);
    struct accesskit_opt_text_decoration (*node_overline)(const struct accesskit_node *node);
    void (*node_set_overline)(struct accesskit_node *node, struct accesskit_text_decoration value);
    void (*node_clear_overline)(struct accesskit_node *node);
    struct accesskit_opt_text_decoration (*node_strikethrough)(const struct accesskit_node *node);
    void (*node_set_strikethrough)(struct accesskit_node *node, struct accesskit_text_decoration value);
    void (*node_clear_strikethrough)(struct accesskit_node *node);
    struct accesskit_opt_text_decoration (*node_underline)(const struct accesskit_node *node);
    void (*node_set_underline)(struct accesskit_node *node, struct accesskit_text_decoration value);
    void (*node_clear_underline)(struct accesskit_node *node);
    struct accesskit_lengths (*node_character_lengths)(const struct accesskit_node *node);
    void (*node_set_character_lengths)(struct accesskit_node *node, size_t length, const uint8_t *values);
    void (*node_clear_character_lengths)(struct accesskit_node *node);
    struct accesskit_lengths (*node_word_starts)(const struct accesskit_node *node);
    void (*node_set_word_starts)(struct accesskit_node *node, size_t length, const uint8_t *values);
    void (*node_clear_word_starts)(struct accesskit_node *node);
    struct accesskit_opt_coords (*node_character_positions)(const struct accesskit_node *node);
    void (*node_set_character_positions)(struct accesskit_node *node, size_t length, const float *values);
    void (*node_clear_character_positions)(struct accesskit_node *node);
    struct accesskit_opt_coords (*node_character_widths)(const struct accesskit_node *node);
    void (*node_set_character_widths)(struct accesskit_node *node, size_t length, const float *values);
    void (*node_clear_character_widths)(struct accesskit_node *node);
    struct accesskit_opt_bool (*node_is_expanded)(const struct accesskit_node *node);
    void (*node_set_expanded)(struct accesskit_node *node, bool value);
    void (*node_clear_expanded)(struct accesskit_node *node);
    struct accesskit_opt_bool (*node_is_selected)(const struct accesskit_node *node);
    void (*node_set_selected)(struct accesskit_node *node, bool value);
    void (*node_clear_selected)(struct accesskit_node *node);
    struct accesskit_opt_invalid (*node_invalid)(const struct accesskit_node *node);
    void (*node_set_invalid)(struct accesskit_node *node, accesskit_invalid value);
    void (*node_clear_invalid)(struct accesskit_node *node);
    struct accesskit_opt_toggled (*node_toggled)(const struct accesskit_node *node);
    void (*node_set_toggled)(struct accesskit_node *node, accesskit_toggled value);
    void (*node_clear_toggled)(struct accesskit_node *node);
    struct accesskit_opt_live (*node_live)(const struct accesskit_node *node);
    void (*node_set_live)(struct accesskit_node *node, accesskit_live value);
    void (*node_clear_live)(struct accesskit_node *node);
    struct accesskit_opt_text_direction (*node_text_direction)(const struct accesskit_node *node);
    void (*node_set_text_direction)(struct accesskit_node *node, accesskit_text_direction value);
    void (*node_clear_text_direction)(struct accesskit_node *node);
    struct accesskit_opt_orientation (*node_orientation)(const struct accesskit_node *node);
    void (*node_set_orientation)(struct accesskit_node *node, accesskit_orientation value);
    void (*node_clear_orientation)(struct accesskit_node *node);
    struct accesskit_opt_sort_direction (*node_sort_direction)(const struct accesskit_node *node);
    void (*node_set_sort_direction)(struct accesskit_node *node, accesskit_sort_direction value);
    void (*node_clear_sort_direction)(struct accesskit_node *node);
    struct accesskit_opt_aria_current (*node_aria_current)(const struct accesskit_node *node);
    void (*node_set_aria_current)(struct accesskit_node *node, accesskit_aria_current value);
    void (*node_clear_aria_current)(struct accesskit_node *node);
    struct accesskit_opt_auto_complete (*node_auto_complete)(const struct accesskit_node *node);
    void (*node_set_auto_complete)(struct accesskit_node *node, accesskit_auto_complete value);
    void (*node_clear_auto_complete)(struct accesskit_node *node);
    struct accesskit_opt_has_popup (*node_has_popup)(const struct accesskit_node *node);
    void (*node_set_has_popup)(struct accesskit_node *node, accesskit_has_popup value);
    void (*node_clear_has_popup)(struct accesskit_node *node);
    struct accesskit_opt_list_style (*node_list_style)(const struct accesskit_node *node);
    void (*node_set_list_style)(struct accesskit_node *node, accesskit_list_style value);
    void (*node_clear_list_style)(struct accesskit_node *node);
    struct accesskit_opt_text_align (*node_text_align)(const struct accesskit_node *node);
    void (*node_set_text_align)(struct accesskit_node *node, accesskit_text_align value);
    void (*node_clear_text_align)(struct accesskit_node *node);
    struct accesskit_opt_vertical_offset (*node_vertical_offset)(const struct accesskit_node *node);
    void (*node_set_vertical_offset)(struct accesskit_node *node, accesskit_vertical_offset value);
    void (*node_clear_vertical_offset)(struct accesskit_node *node);
    const struct accesskit_affine * (*node_transform)(const struct accesskit_node *node);
    void (*node_set_transform)(struct accesskit_node *node, struct accesskit_affine value);
    void (*node_clear_transform)(struct accesskit_node *node);
    struct accesskit_opt_rect (*node_bounds)(const struct accesskit_node *node);
    void (*node_set_bounds)(struct accesskit_node *node, struct accesskit_rect value);
    void (*node_clear_bounds)(struct accesskit_node *node);
    struct accesskit_opt_text_selection (*node_text_selection)(const struct accesskit_node *node);
    void (*node_set_text_selection)(struct accesskit_node *node, struct accesskit_text_selection value);
    void (*node_clear_text_selection)(struct accesskit_node *node);
    struct accesskit_custom_action * (*custom_action_new)(int32_t id);
    void (*custom_action_free)(struct accesskit_custom_action *action);
    int32_t (*custom_action_id)(const struct accesskit_custom_action *action);
    void (*custom_action_set_id)(struct accesskit_custom_action *action, int32_t id);
    char * (*custom_action_description)(const struct accesskit_custom_action *action);
    void (*custom_action_set_description)(struct accesskit_custom_action *action, const char *description);
    void (*custom_action_set_description_with_length)(struct accesskit_custom_action *action, const char *description, size_t length);
    void (*custom_actions_free)(struct accesskit_custom_actions *value);
    struct accesskit_custom_actions * (*node_custom_actions)(const struct accesskit_node *node);
    void (*node_set_custom_actions)(struct accesskit_node *node, size_t length, struct accesskit_custom_action *const *values);
    void (*node_push_custom_action)(struct accesskit_node *node, struct accesskit_custom_action *action);
    void (*node_clear_custom_actions)(struct accesskit_node *node);
    struct accesskit_node * (*node_new)(accesskit_role role);
    void (*node_free)(struct accesskit_node *node);
    char * (*node_debug)(const struct accesskit_node *node);
    struct accesskit_tree_info * (*tree_info_new)(accesskit_node_id root);
    void (*tree_info_free)(struct accesskit_tree_info *tree);
    char * (*tree_info_get_toolkit_name)(const struct accesskit_tree_info *tree);
    void (*tree_info_set_toolkit_name)(struct accesskit_tree_info *tree, const char *toolkit_name);
    void (*tree_info_set_toolkit_name_with_length)(struct accesskit_tree_info *tree, const char *toolkit_name, size_t length);
    void (*tree_info_clear_toolkit_name)(struct accesskit_tree_info *tree);
    char * (*tree_info_get_toolkit_version)(const struct accesskit_tree_info *tree);
    void (*tree_info_set_toolkit_version)(struct accesskit_tree_info *tree, const char *toolkit_version);
    void (*tree_info_set_toolkit_version_with_length)(struct accesskit_tree_info *tree, const char *toolkit_version, size_t length);
    void (*tree_info_clear_toolkit_version)(struct accesskit_tree_info *tree);
    char * (*tree_info_debug)(const struct accesskit_tree_info *tree);
    struct accesskit_tree_update * (*tree_update_with_focus)(accesskit_node_id focus);
    struct accesskit_tree_update * (*tree_update_with_capacity_and_focus)(size_t capacity, accesskit_node_id focus);
    void (*tree_update_free)(struct accesskit_tree_update *update);
    void (*tree_update_push_node)(struct accesskit_tree_update *update, accesskit_node_id id, struct accesskit_node *node);
    void (*tree_update_set_tree_info)(struct accesskit_tree_update *update, struct accesskit_tree_info *tree);
    void (*tree_update_clear_tree_info)(struct accesskit_tree_update *update);
    void (*tree_update_set_focus)(struct accesskit_tree_update *update, accesskit_node_id focus);
    struct accesskit_tree_id (*tree_update_get_tree_id)(const struct accesskit_tree_update *update);
    void (*tree_update_set_tree_id)(struct accesskit_tree_update *update, struct accesskit_tree_id tree_id);
    char * (*tree_update_debug)(const struct accesskit_tree_update *tree_update);
    void (*action_request_free)(struct accesskit_action_request *request);
    struct accesskit_affine (*affine_identity)(void);
    struct accesskit_affine (*affine_flip_y)(void);
    struct accesskit_affine (*affine_flip_x)(void);
    struct accesskit_affine (*affine_scale)(double s);
    struct accesskit_affine (*affine_scale_non_uniform)(double s_x, double s_y);
    struct accesskit_affine (*affine_translate)(struct accesskit_vec2 p);
    struct accesskit_affine (*affine_map_unit_square)(struct accesskit_rect rect);
    double (*affine_determinant)(struct accesskit_affine affine);
    struct accesskit_affine (*affine_inverse)(struct accesskit_affine affine);
    struct accesskit_rect (*affine_transform_rect_bbox)(struct accesskit_affine affine, struct accesskit_rect rect);
    bool (*affine_is_finite)(const struct accesskit_affine *affine);
    bool (*affine_is_nan)(const struct accesskit_affine *affine);
    struct accesskit_affine (*affine_mul)(struct accesskit_affine a, struct accesskit_affine b);
    struct accesskit_point (*affine_transform_point)(struct accesskit_affine affine, struct accesskit_point point);
    struct accesskit_vec2 (*point_to_vec2)(struct accesskit_point point);
    struct accesskit_point (*point_add_vec2)(struct accesskit_point point, struct accesskit_vec2 vec);
    struct accesskit_point (*point_sub_vec2)(struct accesskit_point point, struct accesskit_vec2 vec);
    struct accesskit_vec2 (*point_sub_point)(struct accesskit_point a, struct accesskit_point b);
    struct accesskit_rect (*rect_new)(double x0, double y0, double x1, double y1);
    struct accesskit_rect (*rect_from_points)(struct accesskit_point p0, struct accesskit_point p1);
    struct accesskit_rect (*rect_from_origin_size)(struct accesskit_point origin, struct accesskit_size size);
    struct accesskit_rect (*rect_with_origin)(struct accesskit_rect rect, struct accesskit_point origin);
    struct accesskit_rect (*rect_with_size)(struct accesskit_rect rect, struct accesskit_size size);
    double (*rect_width)(const struct accesskit_rect *rect);
    double (*rect_height)(const struct accesskit_rect *rect);
    double (*rect_min_x)(const struct accesskit_rect *rect);
    double (*rect_max_x)(const struct accesskit_rect *rect);
    double (*rect_min_y)(const struct accesskit_rect *rect);
    double (*rect_max_y)(const struct accesskit_rect *rect);
    struct accesskit_point (*rect_origin)(const struct accesskit_rect *rect);
    struct accesskit_size (*rect_size)(const struct accesskit_rect *rect);
    struct accesskit_rect (*rect_abs)(const struct accesskit_rect *rect);
    double (*rect_area)(const struct accesskit_rect *rect);
    bool (*rect_is_empty)(const struct accesskit_rect *rect);
    bool (*rect_contains)(const struct accesskit_rect *rect, struct accesskit_point point);
    struct accesskit_rect (*rect_union)(const struct accesskit_rect *rect, struct accesskit_rect other);
    struct accesskit_rect (*rect_union_pt)(const struct accesskit_rect *rect, struct accesskit_point pt);
    struct accesskit_rect (*rect_intersect)(const struct accesskit_rect *rect, struct accesskit_rect other);
    struct accesskit_rect (*rect_translate)(struct accesskit_rect rect, struct accesskit_vec2 translation);
    struct accesskit_vec2 (*size_to_vec2)(struct accesskit_size size);
    struct accesskit_size (*size_scale)(struct accesskit_size size, double scalar);
    struct accesskit_size (*size_add)(struct accesskit_size a, struct accesskit_size b);
    struct accesskit_size (*size_sub)(struct accesskit_size a, struct accesskit_size b);
    struct accesskit_point (*vec2_to_point)(struct accesskit_vec2 vec2);
    struct accesskit_size (*vec2_to_size)(struct accesskit_vec2 vec2);
    struct accesskit_vec2 (*vec2_add)(struct accesskit_vec2 a, struct accesskit_vec2 b);
    struct accesskit_vec2 (*vec2_sub)(struct accesskit_vec2 a, struct accesskit_vec2 b);
    struct accesskit_vec2 (*vec2_scale)(struct accesskit_vec2 vec, double scalar);
    struct accesskit_vec2 (*vec2_neg)(struct accesskit_vec2 vec);
    struct accesskit_unix_adapter * (*unix_adapter_new)(accesskit_activation_handler_callback activation_handler, void *activation_handler_userdata, accesskit_action_handler_callback action_handler, void *action_handler_userdata, accesskit_deactivation_handler_callback deactivation_handler, void *deactivation_handler_userdata);
    void (*unix_adapter_free)(struct accesskit_unix_adapter *adapter);
    void (*unix_adapter_set_root_window_bounds)(struct accesskit_unix_adapter *adapter, struct accesskit_rect outer, struct accesskit_rect inner);
    void (*unix_adapter_update_if_active)(struct accesskit_unix_adapter *adapter, accesskit_tree_update_factory update_factory, void *update_factory_userdata);
    void (*unix_adapter_update_window_focus_state)(struct accesskit_unix_adapter *adapter, bool is_focused);
    char * (*unix_adapter_debug)(const struct accesskit_unix_adapter *adapter);
    void (*set_allocator)(void *(*)(size_t size, void *context), void (*)(void *ptr, void *context), void *context);
    accesskit_error (*last_error)(void);
} accesskit_surface;

/* One entry per declaration, so no member is left uninitialised. */
static const accesskit_surface accesskit_surface_all = {
    .node_role = accesskit_node_role,
    .node_set_role = accesskit_node_set_role,
    .node_supports_action = accesskit_node_supports_action,
    .node_add_action = accesskit_node_add_action,
    .node_remove_action = accesskit_node_remove_action,
    .node_clear_actions = accesskit_node_clear_actions,
    .node_child_supports_action = accesskit_node_child_supports_action,
    .node_add_child_action = accesskit_node_add_child_action,
    .node_remove_child_action = accesskit_node_remove_child_action,
    .node_clear_child_actions = accesskit_node_clear_child_actions,
    .node_is_hidden = accesskit_node_is_hidden,
    .node_set_hidden = accesskit_node_set_hidden,
    .node_clear_hidden = accesskit_node_clear_hidden,
    .node_is_multiselectable = accesskit_node_is_multiselectable,
    .node_set_multiselectable = accesskit_node_set_multiselectable,
    .node_clear_multiselectable = accesskit_node_clear_multiselectable,
    .node_is_required = accesskit_node_is_required,
    .node_set_required = accesskit_node_set_required,
    .node_clear_required = accesskit_node_clear_required,
    .node_is_visited = accesskit_node_is_visited,
    .node_set_visited = accesskit_node_set_visited,
    .node_clear_visited = accesskit_node_clear_visited,
    .node_is_busy = accesskit_node_is_busy,
    .node_set_busy = accesskit_node_set_busy,
    .node_clear_busy = accesskit_node_clear_busy,
    .node_is_live_atomic = accesskit_node_is_live_atomic,
    .node_set_live_atomic = accesskit_node_set_live_atomic,
    .node_clear_live_atomic = accesskit_node_clear_live_atomic,
    .node_is_modal = accesskit_node_is_modal,
    .node_set_modal = accesskit_node_set_modal,
    .node_clear_modal = accesskit_node_clear_modal,
    .node_is_touch_transparent = accesskit_node_is_touch_transparent,
    .node_set_touch_transparent = accesskit_node_set_touch_transparent,
    .node_clear_touch_transparent = accesskit_node_clear_touch_transparent,
    .node_is_read_only = accesskit_node_is_read_only,
    .node_set_read_only = accesskit_node_set_read_only,
    .node_clear_read_only = accesskit_node_clear_read_only,
    .node_is_disabled = accesskit_node_is_disabled,
    .node_set_disabled = accesskit_node_set_disabled,
    .node_clear_disabled = accesskit_node_clear_disabled,
    .node_is_italic = accesskit_node_is_italic,
    .node_set_italic = accesskit_node_set_italic,
    .node_clear_italic = accesskit_node_clear_italic,
    .node_clips_children = accesskit_node_clips_children,
    .node_set_clips_children = accesskit_node_set_clips_children,
    .node_clear_clips_children = accesskit_node_clear_clips_children,
    .node_is_line_breaking_object = accesskit_node_is_line_breaking_object,
    .node_set_is_line_breaking_object = accesskit_node_set_is_line_breaking_object,
    .node_clear_is_line_breaking_object = accesskit_node_clear_is_line_breaking_object,
    .node_is_page_breaking_object = accesskit_node_is_page_breaking_object,
    .node_set_is_page_breaking_object = accesskit_node_set_is_page_breaking_object,
    .node_clear_is_page_breaking_object = accesskit_node_clear_is_page_breaking_object,
    .node_is_spelling_error = accesskit_node_is_spelling_error,
    .node_set_is_spelling_error = accesskit_node_set_is_spelling_error,
    .node_clear_is_spelling_error = accesskit_node_clear_is_spelling_error,
    .node_is_grammar_error = accesskit_node_is_grammar_error,
    .node_set_is_grammar_error = accesskit_node_set_is_grammar_error,
    .node_clear_is_grammar_error = accesskit_node_clear_is_grammar_error,
    .node_is_search_match = accesskit_node_is_search_match,
    .node_set_is_search_match = accesskit_node_set_is_search_match,
    .node_clear_is_search_match = accesskit_node_clear_is_search_match,
    .node_is_suggestion = accesskit_node_is_suggestion,
    .node_set_is_suggestion = accesskit_node_set_is_suggestion,
    .node_clear_is_suggestion = accesskit_node_clear_is_suggestion,
    .node_children = accesskit_node_children,
    .node_set_children = accesskit_node_set_children,
    .node_push_child = accesskit_node_push_child,
    .node_clear_children = accesskit_node_clear_children,
    .node_controls = accesskit_node_controls,
    .node_set_controls = accesskit_node_set_controls,
    .node_push_controlled = accesskit_node_push_controlled,
    .node_clear_controls = accesskit_node_clear_controls,
    .node_details = accesskit_node_details,
    .node_set_details = accesskit_node_set_details,
    .node_push_detail = accesskit_node_push_detail,
    .node_clear_details = accesskit_node_clear_details,
    .node_described_by = accesskit_node_described_by,
    .node_set_described_by = accesskit_node_set_described_by,
    .node_push_described_by = accesskit_node_push_described_by,
    .node_clear_described_by = accesskit_node_clear_described_by,
    .node_flow_to = accesskit_node_flow_to,
    .node_set_flow_to = accesskit_node_set_flow_to,
    .node_push_flow_to = accesskit_node_push_flow_to,
    .node_clear_flow_to = accesskit_node_clear_flow_to,
    .node_labelled_by = accesskit_node_labelled_by,
    .node_set_labelled_by = accesskit_node_set_labelled_by,
    .node_push_labelled_by = accesskit_node_push_labelled_by,
    .node_clear_labelled_by = accesskit_node_clear_labelled_by,
    .node_owns = accesskit_node_owns,
    .node_set_owns = accesskit_node_set_owns,
    .node_push_owned = accesskit_node_push_owned,
    .node_clear_owns = accesskit_node_clear_owns,
    .node_radio_group = accesskit_node_radio_group,
    .node_set_radio_group = accesskit_node_set_radio_group,
    .node_push_to_radio_group = accesskit_node_push_to_radio_group,
    .node_clear_radio_group = accesskit_node_clear_radio_group,
    .node_active_descendant = accesskit_node_active_descendant,
    .node_set_active_descendant = accesskit_node_set_active_descendant,
    .node_clear_active_descendant = accesskit_node_clear_active_descendant,
    .node_error_message = accesskit_node_error_message,
    .node_set_error_message = accesskit_node_set_error_message,
    .node_clear_error_message = accesskit_node_clear_error_message,
    .node_in_page_link_target = accesskit_node_in_page_link_target,
    .node_set_in_page_link_target = accesskit_node_set_in_page_link_target,
    .node_clear_in_page_link_target = accesskit_node_clear_in_page_link_target,
    .node_member_of = accesskit_node_member_of,
    .node_set_member_of = accesskit_node_set_member_of,
    .node_clear_member_of = accesskit_node_clear_member_of,
    .node_next_on_line = accesskit_node_next_on_line,
    .node_set_next_on_line = accesskit_node_set_next_on_line,
    .node_clear_next_on_line = accesskit_node_clear_next_on_line,
    .node_previous_on_line = accesskit_node_previous_on_line,
    .node_set_previous_on_line = accesskit_node_set_previous_on_line,
    .node_clear_previous_on_line = accesskit_node_clear_previous_on_line,
    .node_popup_for = accesskit_node_popup_for,
    .node_set_popup_for = accesskit_node_set_popup_for,
    .node_clear_popup_for = accesskit_node_clear_popup_for,
    .node_tree_id = accesskit_node_tree_id,
    .node_set_tree_id = accesskit_node_set_tree_id,
    .node_clear_tree_id = accesskit_node_clear_tree_id,
    .string_free = accesskit_string_free,
    .node_label = accesskit_node_label,
    .node_set_label = accesskit_node_set_label,
    .node_set_label_with_length = accesskit_node_set_label_with_length,
    .node_clear_label = accesskit_node_clear_label,
    .node_description = accesskit_node_description,
    .node_set_description = accesskit_node_set_description,
    .node_set_description_with_length = accesskit_node_set_description_with_length,
    .node_clear_description = accesskit_node_clear_description,
    .node_value = accesskit_node_value,
    .node_set_value = accesskit_node_set_value,
    .node_set_value_with_length = accesskit_node_set_value_with_length,
    .node_clear_value = accesskit_node_clear_value,
    .node_access_key = accesskit_node_access_key,
    .node_set_access_key = accesskit_node_set_access_key,
    .node_set_access_key_with_length = accesskit_node_set_access_key_with_length,
    .node_clear_access_key = accesskit_node_clear_access_key,
    .node_author_id = accesskit_node_author_id,
    .node_set_author_id = accesskit_node_set_author_id,
    .node_set_author_id_with_length = accesskit_node_set_author_id_with_length,
    .node_clear_author_id = accesskit_node_clear_author_id,
    .node_class_name = accesskit_node_class_name,
    .node_set_class_name = accesskit_node_set_class_name,
    .node_set_class_name_with_length = accesskit_node_set_class_name_with_length,
    .node_clear_class_name = accesskit_node_clear_class_name,
    .node_font_family = accesskit_node_font_family,
    .node_set_font_family = accesskit_node_set_font_family,
    .node_set_font_family_with_length = accesskit_node_set_font_family_with_length,
    .node_clear_font_family = accesskit_node_clear_font_family,
    .node_html_id = accesskit_node_html_id,
    .node_set_html_id = accesskit_node_set_html_id,
    .node_set_html_id_with_length = accesskit_node_set_html_id_with_length,
    .node_clear_html_id = accesskit_node_clear_html_id,
    .node_html_tag = accesskit_node_html_tag,
    .node_set_html_tag = accesskit_node_set_html_tag,
    .node_set_html_tag_with_length = accesskit_node_set_html_tag_with_length,
    .node_clear_html_tag = accesskit_node_clear_html_tag,
    .node_inner_html = accesskit_node_inner_html,
    .node_set_inner_html = accesskit_node_set_inner_html,
    .node_set_inner_html_with_length = accesskit_node_set_inner_html_with_length,
    .node_clear_inner_html = accesskit_node_clear_inner_html,
    .node_keyboard_shortcut = accesskit_node_keyboard_shortcut,
    .node_set_keyboard_shortcut = accesskit_node_set_keyboard_shortcut,
    .node_set_keyboard_shortcut_with_length = accesskit_node_set_keyboard_shortcut_with_length,
    .node_clear_keyboard_shortcut = accesskit_node_clear_keyboard_shortcut,
    .node_language = accesskit_node_language,
    .node_set_language = accesskit_node_set_language,
    .node_set_language_with_length = accesskit_node_set_language_with_length,
    .node_clear_language = accesskit_node_clear_language,
    .node_placeholder = accesskit_node_placeholder,
    .node_set_placeholder = accesskit_node_set_placeholder,
    .node_set_placeholder_with_length = accesskit_node_set_placeholder_with_length,
    .node_clear_placeholder = accesskit_node_clear_placeholder,
    .node_role_description = accesskit_node_role_description,
    .node_set_role_description = accesskit_node_set_role_description,
    .node_set_role_description_with_length = accesskit_node_set_role_description_with_length,
    .node_clear_role_description = accesskit_node_clear_role_description,
    .node_state_description = accesskit_node_state_description,
    .node_set_state_description = accesskit_node_set_state_description,
    .node_set_state_description_with_length = accesskit_node_set_state_description_with_length,
    .node_clear_state_description = accesskit_node_clear_state_description,
    .node_tooltip = accesskit_node_tooltip,
    .node_set_tooltip = accesskit_node_set_tooltip,
    .node_set_tooltip_with_length = accesskit_node_set_tooltip_with_length,
    .node_clear_tooltip = accesskit_node_clear_tooltip,
    .node_url = accesskit_node_url,
    .node_set_url = accesskit_node_set_url,
    .node_set_url_with_length = accesskit_node_set_url_with_length,
    .node_clear_url = accesskit_node_clear_url,
    .node_row_index_text = accesskit_node_row_index_text,
    .node_set_row_index_text = accesskit_node_set_row_index_text,
    .node_set_row_index_text_with_length = accesskit_node_set_row_index_text_with_length,
    .node_clear_row_index_text = accesskit_node_clear_row_index_text,
    .node_column_index_text = accesskit_node_column_index_text,
    .node_set_column_index_text = accesskit_node_set_column_index_text,
    .node_set_column_index_text_with_length = accesskit_node_set_column_index_text_with_length,
    .node_clear_column_index_text = accesskit_node_clear_column_index_text,
    .node_braille_label = accesskit_node_braille_label,
    .node_set_braille_label = accesskit_node_set_braille_label,
    .node_set_braille_label_with_length = accesskit_node_set_braille_label_with_length,
    .node_clear_braille_label = accesskit_node_clear_braille_label,
    .node_braille_role_description = accesskit_node_braille_role_description,
    .node_set_braille_role_description = accesskit_node_set_braille_role_description,
    .node_set_braille_role_description_with_length = accesskit_node_set_braille_role_description_with_length,
    .node_clear_braille_role_description = accesskit_node_clear_braille_role_description,
    .node_scroll_x = accesskit_node_scroll_x,
    .node_set_scroll_x = accesskit_node_set_scroll_x,
    .node_clear_scroll_x = accesskit_node_clear_scroll_x,
    .node_scroll_x_min = accesskit_node_scroll_x_min,
    .node_set_scroll_x_min = accesskit_node_set_scroll_x_min,
    .node_clear_scroll_x_min = accesskit_node_clear_scroll_x_min,
    .node_scroll_x_max = accesskit_node_scroll_x_max,
    .node_set_scroll_x_max = accesskit_node_set_scroll_x_max,
    .node_clear_scroll_x_max = accesskit_node_clear_scroll_x_max,
    .node_scroll_y = accesskit_node_scroll_y,
    .node_set_scroll_y = accesskit_node_set_scroll_y,
    .node_clear_scroll_y = accesskit_node_clear_scroll_y,
    .node_scroll_y_min = accesskit_node_scroll_y_min,
    .node_set_scroll_y_min = accesskit_node_set_scroll_y_min,
    .node_clear_scroll_y_min = accesskit_node_clear_scroll_y_min,
    .node_scroll_y_max = accesskit_node_scroll_y_max,
    .node_set_scroll_y_max = accesskit_node_set_scroll_y_max,
    .node_clear_scroll_y_max = accesskit_node_clear_scroll_y_max,
    .node_numeric_value = accesskit_node_numeric_value,
    .node_set_numeric_value = accesskit_node_set_numeric_value,
    .node_clear_numeric_value = accesskit_node_clear_numeric_value,
    .node_min_numeric_value = accesskit_node_min_numeric_value,
    .node_set_min_numeric_value = accesskit_node_set_min_numeric_value,
    .node_clear_min_numeric_value = accesskit_node_clear_min_numeric_value,
    .node_max_numeric_value = accesskit_node_max_numeric_value,
    .node_set_max_numeric_value = accesskit_node_set_max_numeric_value,
    .node_clear_max_numeric_value = accesskit_node_clear_max_numeric_value,
    .node_numeric_value_step = accesskit_node_numeric_value_step,
    .node_set_numeric_value_step = accesskit_node_set_numeric_value_step,
    .node_clear_numeric_value_step = accesskit_node_clear_numeric_value_step,
    .node_numeric_value_jump = accesskit_node_numeric_value_jump,
    .node_set_numeric_value_jump = accesskit_node_set_numeric_value_jump,
    .node_clear_numeric_value_jump = accesskit_node_clear_numeric_value_jump,
    .node_font_size = accesskit_node_font_size,
    .node_set_font_size = accesskit_node_set_font_size,
    .node_clear_font_size = accesskit_node_clear_font_size,
    .node_font_weight = accesskit_node_font_weight,
    .node_set_font_weight = accesskit_node_set_font_weight,
    .node_clear_font_weight = accesskit_node_clear_font_weight,
    .node_row_count = accesskit_node_row_count,
    .node_set_row_count = accesskit_node_set_row_count,
    .node_clear_row_count = accesskit_node_clear_row_count,
    .node_column_count = accesskit_node_column_count,
    .node_set_column_count = accesskit_node_set_column_count,
    .node_clear_column_count = accesskit_node_clear_column_count,
    .node_row_index = accesskit_node_row_index,
    .node_set_row_index = accesskit_node_set_row_index,
    .node_clear_row_index = accesskit_node_clear_row_index,
    .node_column_index = accesskit_node_column_index,
    .node_set_column_index = accesskit_node_set_column_index,
    .node_clear_column_index = accesskit_node_clear_column_index,
    .node_row_span = accesskit_node_row_span,
    .node_set_row_span = accesskit_node_set_row_span,
    .node_clear_row_span = accesskit_node_clear_row_span,
    .node_column_span = accesskit_node_column_span,
    .node_set_column_span = accesskit_node_set_column_span,
    .node_clear_column_span = accesskit_node_clear_column_span,
    .node_level = accesskit_node_level,
    .node_set_level = accesskit_node_set_level,
    .node_clear_level = accesskit_node_clear_level,
    .node_size_of_set = accesskit_node_size_of_set,
    .node_set_size_of_set = accesskit_node_set_size_of_set,
    .node_clear_size_of_set = accesskit_node_clear_size_of_set,
    .node_position_in_set = accesskit_node_position_in_set,
    .node_set_position_in_set = accesskit_node_set_position_in_set,
    .node_clear_position_in_set = accesskit_node_clear_position_in_set,
    .node_color_value = accesskit_node_color_value,
    .node_set_color_value = accesskit_node_set_color_value,
    .node_clear_color_value = accesskit_node_clear_color_value,
    .node_background_color = accesskit_node_background_color,
    .node_set_background_color = accesskit_node_set_background_color,
    .node_clear_background_color = accesskit_node_clear_background_color,
    .node_foreground_color = accesskit_node_foreground_color,
    .node_set_foreground_color = accesskit_node_set_foreground_color,
    .node_clear_foreground_color = accesskit_node_clear_foreground_color,
    .node_overline = accesskit_node_overline,
    .node_set_overline = accesskit_node_set_overline,
    .node_clear_overline = accesskit_node_clear_overline,
    .node_strikethrough = accesskit_node_strikethrough,
    .node_set_strikethrough = accesskit_node_set_strikethrough,
    .node_clear_strikethrough = accesskit_node_clear_strikethrough,
    .node_underline = accesskit_node_underline,
    .node_set_underline = accesskit_node_set_underline,
    .node_clear_underline = accesskit_node_clear_underline,
    .node_character_lengths = accesskit_node_character_lengths,
    .node_set_character_lengths = accesskit_node_set_character_lengths,
    .node_clear_character_lengths = accesskit_node_clear_character_lengths,
    .node_word_starts = accesskit_node_word_starts,
    .node_set_word_starts = accesskit_node_set_word_starts,
    .node_clear_word_starts = accesskit_node_clear_word_starts,
    .node_character_positions = accesskit_node_character_positions,
    .node_set_character_positions = accesskit_node_set_character_positions,
    .node_clear_character_positions = accesskit_node_clear_character_positions,
    .node_character_widths = accesskit_node_character_widths,
    .node_set_character_widths = accesskit_node_set_character_widths,
    .node_clear_character_widths = accesskit_node_clear_character_widths,
    .node_is_expanded = accesskit_node_is_expanded,
    .node_set_expanded = accesskit_node_set_expanded,
    .node_clear_expanded = accesskit_node_clear_expanded,
    .node_is_selected = accesskit_node_is_selected,
    .node_set_selected = accesskit_node_set_selected,
    .node_clear_selected = accesskit_node_clear_selected,
    .node_invalid = accesskit_node_invalid,
    .node_set_invalid = accesskit_node_set_invalid,
    .node_clear_invalid = accesskit_node_clear_invalid,
    .node_toggled = accesskit_node_toggled,
    .node_set_toggled = accesskit_node_set_toggled,
    .node_clear_toggled = accesskit_node_clear_toggled,
    .node_live = accesskit_node_live,
    .node_set_live = accesskit_node_set_live,
    .node_clear_live = accesskit_node_clear_live,
    .node_text_direction = accesskit_node_text_direction,
    .node_set_text_direction = accesskit_node_set_text_direction,
    .node_clear_text_direction = accesskit_node_clear_text_direction,
    .node_orientation = accesskit_node_orientation,
    .node_set_orientation = accesskit_node_set_orientation,
    .node_clear_orientation = accesskit_node_clear_orientation,
    .node_sort_direction = accesskit_node_sort_direction,
    .node_set_sort_direction = accesskit_node_set_sort_direction,
    .node_clear_sort_direction = accesskit_node_clear_sort_direction,
    .node_aria_current = accesskit_node_aria_current,
    .node_set_aria_current = accesskit_node_set_aria_current,
    .node_clear_aria_current = accesskit_node_clear_aria_current,
    .node_auto_complete = accesskit_node_auto_complete,
    .node_set_auto_complete = accesskit_node_set_auto_complete,
    .node_clear_auto_complete = accesskit_node_clear_auto_complete,
    .node_has_popup = accesskit_node_has_popup,
    .node_set_has_popup = accesskit_node_set_has_popup,
    .node_clear_has_popup = accesskit_node_clear_has_popup,
    .node_list_style = accesskit_node_list_style,
    .node_set_list_style = accesskit_node_set_list_style,
    .node_clear_list_style = accesskit_node_clear_list_style,
    .node_text_align = accesskit_node_text_align,
    .node_set_text_align = accesskit_node_set_text_align,
    .node_clear_text_align = accesskit_node_clear_text_align,
    .node_vertical_offset = accesskit_node_vertical_offset,
    .node_set_vertical_offset = accesskit_node_set_vertical_offset,
    .node_clear_vertical_offset = accesskit_node_clear_vertical_offset,
    .node_transform = accesskit_node_transform,
    .node_set_transform = accesskit_node_set_transform,
    .node_clear_transform = accesskit_node_clear_transform,
    .node_bounds = accesskit_node_bounds,
    .node_set_bounds = accesskit_node_set_bounds,
    .node_clear_bounds = accesskit_node_clear_bounds,
    .node_text_selection = accesskit_node_text_selection,
    .node_set_text_selection = accesskit_node_set_text_selection,
    .node_clear_text_selection = accesskit_node_clear_text_selection,
    .custom_action_new = accesskit_custom_action_new,
    .custom_action_free = accesskit_custom_action_free,
    .custom_action_id = accesskit_custom_action_id,
    .custom_action_set_id = accesskit_custom_action_set_id,
    .custom_action_description = accesskit_custom_action_description,
    .custom_action_set_description = accesskit_custom_action_set_description,
    .custom_action_set_description_with_length = accesskit_custom_action_set_description_with_length,
    .custom_actions_free = accesskit_custom_actions_free,
    .node_custom_actions = accesskit_node_custom_actions,
    .node_set_custom_actions = accesskit_node_set_custom_actions,
    .node_push_custom_action = accesskit_node_push_custom_action,
    .node_clear_custom_actions = accesskit_node_clear_custom_actions,
    .node_new = accesskit_node_new,
    .node_free = accesskit_node_free,
    .node_debug = accesskit_node_debug,
    .tree_info_new = accesskit_tree_info_new,
    .tree_info_free = accesskit_tree_info_free,
    .tree_info_get_toolkit_name = accesskit_tree_info_get_toolkit_name,
    .tree_info_set_toolkit_name = accesskit_tree_info_set_toolkit_name,
    .tree_info_set_toolkit_name_with_length = accesskit_tree_info_set_toolkit_name_with_length,
    .tree_info_clear_toolkit_name = accesskit_tree_info_clear_toolkit_name,
    .tree_info_get_toolkit_version = accesskit_tree_info_get_toolkit_version,
    .tree_info_set_toolkit_version = accesskit_tree_info_set_toolkit_version,
    .tree_info_set_toolkit_version_with_length = accesskit_tree_info_set_toolkit_version_with_length,
    .tree_info_clear_toolkit_version = accesskit_tree_info_clear_toolkit_version,
    .tree_info_debug = accesskit_tree_info_debug,
    .tree_update_with_focus = accesskit_tree_update_with_focus,
    .tree_update_with_capacity_and_focus = accesskit_tree_update_with_capacity_and_focus,
    .tree_update_free = accesskit_tree_update_free,
    .tree_update_push_node = accesskit_tree_update_push_node,
    .tree_update_set_tree_info = accesskit_tree_update_set_tree_info,
    .tree_update_clear_tree_info = accesskit_tree_update_clear_tree_info,
    .tree_update_set_focus = accesskit_tree_update_set_focus,
    .tree_update_get_tree_id = accesskit_tree_update_get_tree_id,
    .tree_update_set_tree_id = accesskit_tree_update_set_tree_id,
    .tree_update_debug = accesskit_tree_update_debug,
    .action_request_free = accesskit_action_request_free,
    .affine_identity = accesskit_affine_identity,
    .affine_flip_y = accesskit_affine_flip_y,
    .affine_flip_x = accesskit_affine_flip_x,
    .affine_scale = accesskit_affine_scale,
    .affine_scale_non_uniform = accesskit_affine_scale_non_uniform,
    .affine_translate = accesskit_affine_translate,
    .affine_map_unit_square = accesskit_affine_map_unit_square,
    .affine_determinant = accesskit_affine_determinant,
    .affine_inverse = accesskit_affine_inverse,
    .affine_transform_rect_bbox = accesskit_affine_transform_rect_bbox,
    .affine_is_finite = accesskit_affine_is_finite,
    .affine_is_nan = accesskit_affine_is_nan,
    .affine_mul = accesskit_affine_mul,
    .affine_transform_point = accesskit_affine_transform_point,
    .point_to_vec2 = accesskit_point_to_vec2,
    .point_add_vec2 = accesskit_point_add_vec2,
    .point_sub_vec2 = accesskit_point_sub_vec2,
    .point_sub_point = accesskit_point_sub_point,
    .rect_new = accesskit_rect_new,
    .rect_from_points = accesskit_rect_from_points,
    .rect_from_origin_size = accesskit_rect_from_origin_size,
    .rect_with_origin = accesskit_rect_with_origin,
    .rect_with_size = accesskit_rect_with_size,
    .rect_width = accesskit_rect_width,
    .rect_height = accesskit_rect_height,
    .rect_min_x = accesskit_rect_min_x,
    .rect_max_x = accesskit_rect_max_x,
    .rect_min_y = accesskit_rect_min_y,
    .rect_max_y = accesskit_rect_max_y,
    .rect_origin = accesskit_rect_origin,
    .rect_size = accesskit_rect_size,
    .rect_abs = accesskit_rect_abs,
    .rect_area = accesskit_rect_area,
    .rect_is_empty = accesskit_rect_is_empty,
    .rect_contains = accesskit_rect_contains,
    .rect_union = accesskit_rect_union,
    .rect_union_pt = accesskit_rect_union_pt,
    .rect_intersect = accesskit_rect_intersect,
    .rect_translate = accesskit_rect_translate,
    .size_to_vec2 = accesskit_size_to_vec2,
    .size_scale = accesskit_size_scale,
    .size_add = accesskit_size_add,
    .size_sub = accesskit_size_sub,
    .vec2_to_point = accesskit_vec2_to_point,
    .vec2_to_size = accesskit_vec2_to_size,
    .vec2_add = accesskit_vec2_add,
    .vec2_sub = accesskit_vec2_sub,
    .vec2_scale = accesskit_vec2_scale,
    .vec2_neg = accesskit_vec2_neg,
    .unix_adapter_new = accesskit_unix_adapter_new,
    .unix_adapter_free = accesskit_unix_adapter_free,
    .unix_adapter_set_root_window_bounds = accesskit_unix_adapter_set_root_window_bounds,
    .unix_adapter_update_if_active = accesskit_unix_adapter_update_if_active,
    .unix_adapter_update_window_focus_state = accesskit_unix_adapter_update_window_focus_state,
    .unix_adapter_debug = accesskit_unix_adapter_debug,
    .set_allocator = accesskit_set_allocator,
    .last_error = accesskit_last_error,
};

#endif /* ZACCESSKIT_TEST_C_CONSUMER_SURFACE_H */
