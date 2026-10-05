//! The node fill: what one AccessKit node becomes on the Android side.
//!
//! Upstream is `AK/android/src/node.rs`, the 447 lines whose `impl
//! NodeWrapper` runs from `:29` to `:445`, with `Range` at
//! `AK/android/src/util.rs:112-130` and `add_action` at `:17-23`.
//!
//! **What this module exports.** `className`, `Range`, `rangeFromNode`,
//! `rangeType`, `currentItemIndex`, `scrollX`, `maxScrollX`, `scrollY`,
//! `maxScrollY`, `nodeText`, `TextSelectionSpan`, `nodeTextSelection`,
//! `populateNodeInfo`, `FillError`, `lookups`, `literal_lookups` and
//! `lookup_count`. The Android constant integers come from `values.zig`, which
//! holds them once, so this module names no constant of its own.
//!
//! **What this module deliberately does not do.** It owns no JNI table, no id
//! map and no tree. `jni_table.zig` owns the table, `node_id_map.zig` owns the
//! two-way id map, and the `consumer` and `schema` namespaces own the tree. It
//! also declares no Android integer constant, because `values.zig` declares
//! all of them and a second copy is a second thing to keep in sync. It holds no
//! state, so it has no teardown and no file-scope `var`.
//!
//! **The compiler.** Zig 0.16.0, the version `build.zig.zon` pins in
//! `.minimum_zig_version`.
//!
//! **The shortest sequence.** Call `populateNodeInfo` with the node info object
//! the caller obtained from `AccessibilityNodeInfo.obtain` and it writes every
//! property that object carries.
//!
//! **What the caller must release.** `nodeText` answers a list the caller
//! releases with the allocator the call was given. The caller releases
//! `node_info` and `host`, because the caller owns both, and the caller opens
//! and closes the JNI local frame the fill runs inside. `populateNodeInfo`
//! pushes no frame and pops none, because a callee must not close a frame the
//! caller opened. The frame needs a capacity of one, because every reference
//! the fill builds is a local reference released with `deleteLocalRef` before
//! the next one is taken.
//!
//! **Why a local reference is released as soon as the lookup that needed it is
//! done.** A fill that kept every class, string and object reference until the
//! end would need a frame wide enough for all of them, and
//! `values.LOCAL_FRAME_CAPACITY` is `2`. A `jmethodID` and a `jfieldID` stay
//! valid after the class reference they came from is released, because the
//! class is not unloaded while any reference to it survives, so releasing the
//! class reference does not invalidate the id.
//!
//! **The loop bounds.** Every walk in this file carries a named bound.
//!
//! | Walk | Bound | Where |
//! |---|---|---|
//! | the filtered children of one node | the node count | `fillChildren` |
//! | the host screen slots one call fills | `location_slot_count` | the recorder |
//! | `lookups` | `lookup_count` | `lookupAt` and the tests |
//! | `literal_lookups` | `literal_lookup_count` | `findLiteral` |
//! | `java_classes` | `java_class_count` | the class test |
//! | `class_name_cases` | `class_name_case_count` | the class-name test |
//! | `pinned` and `expected` in the tests | the array length | the tests |
//! | `expected_lookups` and `expected_calls` | the array length | the sequence test |
//!
//! Every array walk ends by exhausting its array, so the loop test is the bound
//! and nothing else can stop it. The child walk is bounded by the node count
//! because each step visits one node of a tree that holds at most that many,
//! and the cursor `hierarchy.filteredChildren` answers carries the same bound.
//! Reaching that bound is `error.TreeCycle`, which is the tag the consumer layer
//! reports for a walk that revisits a node.
//!
//! There is no open loop, no `while (true)` and no walk without a branch that
//! reports exhaustion.

const std = @import("std");

const classes = @import("classes.zig");
const constants = @import("constants.zig");
const jni = @import("jni_table.zig");
const methods = @import("methods.zig");
const node_id_map = @import("node_id_map.zig");
const values = @import("values.zig");

const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");

const FilterFn = consumer.filter.FilterFn;
const FilterResult = consumer.filter.FilterResult;
const FullNodeId = consumer.tree_index.FullNodeId;
const NodeRef = consumer.node_id.NodeRef;
const ParentAndIndex = consumer.tree_index.ParentAndIndex;
const QueryError = consumer.tree.QueryError;
const TreeState = consumer.tree_state.TreeState;

const geometry = consumer.node_ref.geometry;
const hierarchy = consumer.node_ref.hierarchy;
const predicates = consumer.node_ref.predicates;
const properties = consumer.node_ref.properties;
const set_state = consumer.node_ref.set_state;
const strings = consumer.node_ref.strings;
const text_position = consumer.text.position;
const text_query = consumer.text.query;
const text_range = consumer.text.range;

const JClass = jni.JClass;
const JFieldId = jni.JFieldId;
const JFloat = jni.JFloat;
const JInt = values.JInt;
const JMethodId = jni.JMethodId;
const JniEnv = jni.JniEnv;
const JniTable = jni.JniTable;
const JObject = jni.JObject;
const JString = jni.JString;
const JValue = jni.JValue;

const testing = std.testing;

/// Every failure `populateNodeInfo`, `nodeText` and `nodeTextSelection` can
/// report.
///
/// The first three groups come from the layers below. `JavaException` and
/// `JavaMemberMissing` come from the JNI boundary, where a `null` class, a
/// `null` method id or a `null` result is data and not a crash, so this module
/// names both outcomes instead of aborting on them.
pub const FillError = QueryError ||
    std.mem.Allocator.Error ||
    schema.NarrowError ||
    node_id_map.Error ||
    error{
        /// A JNI call left an exception pending on the calling thread. The
        /// exception is still pending, because this module never clears one, and
        /// every later JNI call on the same thread fails until the caller clears
        /// it. Nothing this module built survives.
        JavaException,
        /// A JNI lookup answered `null` with no exception pending, so the class,
        /// the member or the static field is not on the classpath. The node
        /// property that needed it is not written.
        JavaMemberMissing,
    };

/// One Java class, as the two spellings the JNI takes.
///
/// `descriptor` is the form `GetMethodID` takes and the form `methods.zig`
/// records. `internal_name` is the form `FindClass` takes: the same string with
/// the `L` and the `;` removed and each `.` written as `/`. Both are asserted
/// against each other by a test, because `FindClass` compares one at run time
/// on a device.
const JavaClass = struct {
    descriptor: classes.ClassDescriptor,
    internal_name: [:0]const u8,
};

/// The node info object the fill writes.
const node_info_class = JavaClass{
    .descriptor = "Landroid/view/accessibility/AccessibilityNodeInfo;",
    .internal_name = "android/view/accessibility/AccessibilityNodeInfo",
};

/// The host view every node hangs off.
const view_class = JavaClass{
    .descriptor = "Landroid/view/View;",
    .internal_name = "android/view/View",
};

/// The box the screen bounds go in.
const rect_class = JavaClass{
    .descriptor = "Landroid/graphics/Rect;",
    .internal_name = "android/graphics/Rect",
};

/// The extras bag the target URL goes into.
const bundle_class = JavaClass{
    .descriptor = "Landroid/os/Bundle;",
    .internal_name = "android/os/Bundle",
};

/// The numeric range of a slider.
const range_info_class = JavaClass{
    .descriptor = "Landroid/view/accessibility/AccessibilityNodeInfo$RangeInfo;",
    .internal_name = "android/view/accessibility/AccessibilityNodeInfo$RangeInfo",
};

/// The action object `ACTION_SET_PROGRESS` is read from.
const accessibility_action_class = JavaClass{
    .descriptor = "Landroid/view/accessibility/AccessibilityNodeInfo$AccessibilityAction;",
    .internal_name = "android/view/accessibility/AccessibilityNodeInfo$AccessibilityAction",
};

/// One Java member lookup, as the three strings `GetMethodID` takes.
///
/// Every lookup the fill builds is declared once, as a file-scope `const`, and
/// the code and the tests both read that one declaration. A misspelt descriptor
/// is not a compile error anywhere and is a `NoSuchMethodError` on a device, so
/// each row is asserted.
const Lookup = struct {
    class: JavaClass,
    name: methods.MethodName,
    signature: [:0]const u8,
};

/// `AccessibilityNodeInfo.addChild(View, int)`, `AK/android/src/node.rs:204`.
const add_child = Lookup{
    .class = node_info_class,
    .name = "addChild",
    .signature = "(Landroid/view/View;I)V",
};

/// `AccessibilityNodeInfo.setParent(View)`, `AK/android/src/node.rs:214`.
const set_parent_host = Lookup{
    .class = node_info_class,
    .name = "setParent",
    .signature = "(Landroid/view/View;)V",
};

/// `AccessibilityNodeInfo.setParent(View, int)`, `AK/android/src/node.rs:222`.
const set_parent_node = Lookup{
    .class = node_info_class,
    .name = "setParent",
    .signature = "(Landroid/view/View;I)V",
};

/// `View.getLocationOnScreen(int[])`, `AK/android/src/node.rs:234`.
const get_location_on_screen = Lookup{
    .class = view_class,
    .name = "getLocationOnScreen",
    .signature = "([I)V",
};

/// `android.graphics.Rect.<init>(int, int, int, int)`, `AK/android/src/node.rs:241`.
const rect_constructor = Lookup{
    .class = rect_class,
    .name = "<init>",
    .signature = "(IIII)V",
};

/// `AccessibilityNodeInfo.setBoundsInScreen(Rect)`, `AK/android/src/node.rs:259`.
const set_bounds_in_screen = Lookup{
    .class = node_info_class,
    .name = "setBoundsInScreen",
    .signature = "(Landroid/graphics/Rect;)V",
};

/// `AccessibilityNodeInfo.setCheckable(boolean)`, `AK/android/src/node.rs:264`.
const set_checkable = Lookup{
    .class = node_info_class,
    .name = "setCheckable",
    .signature = "(Z)V",
};

/// `AccessibilityNodeInfo.setChecked(boolean)`, `AK/android/src/node.rs:265`.
const set_checked = Lookup{
    .class = node_info_class,
    .name = "setChecked",
    .signature = "(Z)V",
};

/// `AccessibilityNodeInfo.setEditable(boolean)`, `AK/android/src/node.rs:276`.
const set_editable = Lookup{
    .class = node_info_class,
    .name = "setEditable",
    .signature = "(Z)V",
};

/// `AccessibilityNodeInfo.setEnabled(boolean)`, `AK/android/src/node.rs:280`.
const set_enabled = Lookup{
    .class = node_info_class,
    .name = "setEnabled",
    .signature = "(Z)V",
};

/// `AccessibilityNodeInfo.setFocusable(boolean)`, `AK/android/src/node.rs:283`.
const set_focusable = Lookup{
    .class = node_info_class,
    .name = "setFocusable",
    .signature = "(Z)V",
};

/// `AccessibilityNodeInfo.setFocused(boolean)`, `AK/android/src/node.rs:285`.
const set_focused = Lookup{
    .class = node_info_class,
    .name = "setFocused",
    .signature = "(Z)V",
};

/// `AccessibilityNodeInfo.setPassword(boolean)`, `AK/android/src/node.rs:287`.
const set_password = Lookup{
    .class = node_info_class,
    .name = "setPassword",
    .signature = "(Z)V",
};

/// `AccessibilityNodeInfo.setScrollable(boolean)`, `AK/android/src/node.rs:292`.
const set_scrollable = Lookup{
    .class = node_info_class,
    .name = "setScrollable",
    .signature = "(Z)V",
};

/// `AccessibilityNodeInfo.setSelected(boolean)`, `AK/android/src/node.rs:298`.
const set_selected = Lookup{
    .class = node_info_class,
    .name = "setSelected",
    .signature = "(Z)V",
};

/// `AccessibilityNodeInfo.setVisibleToUser(boolean)`, `AK/android/src/node.rs:309`.
const set_visible_to_user = Lookup{
    .class = node_info_class,
    .name = "setVisibleToUser",
    .signature = "(Z)V",
};

/// `AccessibilityNodeInfo.setContentDescription(CharSequence)`, `:311`.
const set_content_description = Lookup{
    .class = node_info_class,
    .name = "setContentDescription",
    .signature = "(Ljava/lang/CharSequence;)V",
};

/// `AccessibilityNodeInfo.setText(CharSequence)`, `AK/android/src/node.rs:322`.
const set_text = Lookup{
    .class = node_info_class,
    .name = "setText",
    .signature = "(Ljava/lang/CharSequence;)V",
};

/// `AccessibilityNodeInfo.setTextSelection(int, int)`, `:332`.
const set_text_selection = Lookup{
    .class = node_info_class,
    .name = "setTextSelection",
    .signature = "(II)V",
};

/// `AccessibilityNodeInfo.getExtras()`, `AK/android/src/node.rs:344`.
const get_extras = Lookup{
    .class = node_info_class,
    .name = "getExtras",
    .signature = "()Landroid/os/Bundle;",
};

/// `android.os.Bundle.putString(String, String)`, `AK/android/src/node.rs:351`.
const put_string = Lookup{
    .class = bundle_class,
    .name = "putString",
    .signature = "(Ljava/lang/String;Ljava/lang/String;)V",
};

/// `AccessibilityNodeInfo.setClassName(CharSequence)`, `:359`.
const set_class_name = Lookup{
    .class = node_info_class,
    .name = "setClassName",
    .signature = "(Ljava/lang/CharSequence;)V",
};

/// `AccessibilityNodeInfo.addAction(int)`, `AK/android/src/node.rs:23`.
const add_action = Lookup{
    .class = node_info_class,
    .name = "addAction",
    .signature = "(I)V",
};

/// `AccessibilityNodeInfo.setMovementGranularities(int)`, `AK/android/src/node.rs:390`.
const set_movement_granularities = Lookup{
    .class = node_info_class,
    .name = "setMovementGranularities",
    .signature = "(I)V",
};

/// `AccessibilityNodeInfo$RangeInfo.obtain(int, float, float, float)`, `:114`.
const obtain_range_info = Lookup{
    .class = range_info_class,
    .name = "obtain",
    .signature = "(IFFF)Landroid/view/accessibility/AccessibilityNodeInfo$RangeInfo;",
};

/// `AccessibilityNodeInfo.setRangeInfo(RangeInfo)`, `AK/android/src/node.rs:412`.
const set_range_info = Lookup{
    .class = node_info_class,
    .name = "setRangeInfo",
    .signature = "(Landroid/view/accessibility/AccessibilityNodeInfo$RangeInfo;)V",
};

/// `AccessibilityNodeInfo.addAction(AccessibilityAction)`, `AK/android/src/node.rs:432`.
const add_action_object = Lookup{
    .class = node_info_class,
    .name = "addAction",
    .signature = "(Landroid/view/accessibility/AccessibilityNodeInfo$AccessibilityAction;)V",
};

/// `AccessibilityNodeInfo.setLiveRegion(int)`, `AK/android/src/node.rs:444`.
const set_live_region = Lookup{
    .class = node_info_class,
    .name = "setLiveRegion",
    .signature = "(I)V",
};

/// Every lookup `populateNodeInfo` builds, in the order it builds them.
///
/// The array length is `lookup_count`, which is the bound every test walks.
pub const lookups = [_]Lookup{
    add_child,
    set_parent_host,
    set_parent_node,
    get_location_on_screen,
    rect_constructor,
    set_bounds_in_screen,
    set_checkable,
    set_checked,
    set_editable,
    set_enabled,
    set_focusable,
    set_focused,
    set_password,
    set_scrollable,
    set_selected,
    set_visible_to_user,
    set_content_description,
    set_text,
    set_text_selection,
    get_extras,
    put_string,
    set_class_name,
    add_action,
    set_movement_granularities,
    obtain_range_info,
    set_range_info,
    add_action_object,
    set_live_region,
};

/// How many rows `lookups` holds.
pub const lookup_count = lookups.len;

/// The lookups `methods.zig` records no row for, so no row can confirm them.
///
/// A test compares each row against a literal written inside the test, because
/// reading the expected value out of the same declaration the code uses would
/// prove nothing.
pub const literal_lookups = [_]Lookup{
    set_bounds_in_screen,
    set_checkable,
    set_checked,
    set_editable,
    set_enabled,
    set_focusable,
    set_focused,
    set_password,
    set_scrollable,
    set_selected,
    set_visible_to_user,
    set_content_description,
    set_text,
    set_text_selection,
    get_extras,
    put_string,
    set_class_name,
    add_action_object,
    set_movement_granularities,
    set_range_info,
    set_live_region,
};

/// How many rows `literal_lookups` holds.
pub const literal_lookup_count = literal_lookups.len;

/// The static field the set-progress action object is read from.
///
/// `methods.zig` records no row for it, because a static field is not a method
/// lookup, so the field name and its type descriptor are asserted by a test.
const action_set_progress_field = Lookup{
    .class = accessibility_action_class,
    .name = "ACTION_SET_PROGRESS",
    .signature = "Landroid/view/accessibility/AccessibilityNodeInfo$AccessibilityAction;",
};

/// How many `int` values `getLocationOnScreen` writes, the x and then the y.
const location_slot_count = 2;

/// The largest argument count any descriptor in this module names.
const max_jni_argument_count = 4;

/// The scale `currentItemIndex` reports on, as Android defines it.
const item_index_scale: JInt = 100;

/// The Android class name the upstream `class_name` reports for `node`.
///
/// The name comes from the node's role. A button that states a pressed state
/// reports `android.widget.ToggleButton` and every other button reports
/// `android.widget.Button`. Each role group upstream names keeps its own
/// group, and a role upstream does not name reports `android.view.View`.
///
/// `AK/android/src/node.rs:124-170`. Allocates nothing, blocks nothing and
/// reads no clock. The returned string is a constant with static lifetime, so
/// the caller owns nothing and releases nothing.
pub fn className(node: NodeRef) [:0]const u8 {
    return switch (properties.role(node)) {
        .text_input,
        .multiline_text_input,
        .search_input,
        .email_input,
        .number_input,
        .password_input,
        .phone_number_input,
        .url_input,
        => "android.widget.EditText",
        .slider => "android.widget.SeekBar",
        .color_well,
        .combo_box,
        .editable_combo_box,
        .date_input,
        .date_time_input,
        .week_input,
        .month_input,
        .time_input,
        => "android.widget.Spinner",
        .button => if (predicates.supportsToggle(node))
            "android.widget.ToggleButton"
        else
            "android.widget.Button",
        .pdf_actionable_highlight => "android.widget.Button",
        .check_box => "android.widget.CheckBox",
        .radio_button => "android.widget.RadioButton",
        .radio_group => "android.widget.RadioGroup",
        .switch_ => "android.widget.ToggleButton",
        .canvas, .image, .svg_root => "android.widget.ImageView",
        .meter, .progress_indicator => "android.widget.ProgressBar",
        .tab_list => "android.widget.TabWidget",
        .grid, .table, .tree_grid => "android.widget.GridView",
        .description_list, .list, .list_box, .scroll_view => "android.widget.ListView",
        .dialog => "android.app.Dialog",
        .root_web_area => "android.webkit.WebView",
        .menu_item, .menu_item_check_box, .menu_item_radio => "android.view.MenuItem",
        .label => "android.widget.TextView",
        else => "android.view.View",
    };
}

/// The four numbers one Android `RangeInfo` carries.
///
/// Every field is a number from a node property, so a `Range` holds no
/// reference to a node, a copy is independent of the original, and nothing
/// releases it.
pub const Range = struct {
    /// The value the control shows now, from `numeric_value`.
    current: f64,
    /// The lowest value the control accepts, from `min_numeric_value`.
    min: f64,
    /// The highest value the control accepts, from `max_numeric_value`.
    max: f64,
    /// The amount one step changes the value by, from `numeric_value_step`.
    /// `null` means the node states no step, which `RangeInfo` accepts.
    step: ?f64,
};

/// The range `node` describes, or `null` when it describes none.
///
/// `null` covers both of the upstream `?` sites: a node that states no value,
/// and a node that states no `numeric_value`. The step stays optional because
/// a range control may state no step.
///
/// `AK/android/src/util.rs:112-119` and `AK/android/src/node.rs:407-416`.
///
/// Allocates nothing and takes no allocator, because `hasValue` and the four
/// numeric properties allocate nothing. `error.TreeCycle` comes from the
/// inherited walk inside `hasValue`, `error.NoSuchNode` from the same walk, and
/// neither changes the node.
pub fn rangeFromNode(node: NodeRef) QueryError!?Range {
    if (!try set_state.hasValue(node)) return null;
    return .{
        .current = properties.numericValue(node) orelse return null,
        .min = properties.minNumericValue(node) orelse return null,
        .max = properties.maxNumericValue(node) orelse return null,
        .step = properties.numericValueStep(node),
    };
}

/// The `RANGE_TYPE_*` value Android wants for `range`.
///
/// `RANGE_TYPE_INT` when the current value, the minimum and the maximum are all
/// whole numbers, and the step is absent or a whole number.
/// `RANGE_TYPE_FLOAT` in every other case, so a range with any fractional part
/// stays a float range.
pub fn rangeType(range: Range) JInt {
    if (isWholeNumber(range.current) and isWholeNumber(range.min) and
        isWholeNumber(range.max))
    {
        const step = range.step orelse return values.RANGE_TYPE_INT;
        if (isWholeNumber(step)) return values.RANGE_TYPE_INT;
    }
    return values.RANGE_TYPE_FLOAT;
}

/// The position of `range.current` on the scale Android names a current item
/// index with, or 0 when the range spans no distance.
///
/// The scale runs from 0 at `min` to 100 at `max`. A range whose `max` is at or
/// below its `min` spans no distance, so the answer is 0 rather than a division
/// by zero. A current value below `min` or above `max` clamps to 0 or to 100.
pub fn currentItemIndex(range: Range) JInt {
    if (range.max <= range.min) return 0;
    const span = range.max - range.min;
    const offset = (range.current - range.min) / span * @as(f64, item_index_scale);
    const floored = @floor(offset);
    if (floored <= 0) return 0;
    if (floored >= @as(f64, item_index_scale)) return item_index_scale;
    return @intFromFloat(floored);
}

/// The node's horizontal scroll offset, measured from its own minimum.
///
/// `null` when the node states no `scroll_x`, which is how the caller learns
/// that the node is not a horizontally scrolling container. A node that states
/// no `scroll_x_min` contributes 0, which is what `unwrap_or(0.0)` does
/// upstream. `error.OutOfRange` means the difference is not an `i32`.
pub fn scrollX(node: NodeRef) schema.NarrowError!?JInt {
    const value = properties.scrollX(node) orelse return null;
    const min = properties.scrollXMin(node) orelse 0.0;
    return try schema.toI32Checked(value - min);
}

/// The node's rightmost horizontal scroll offset, measured from its own minimum.
///
/// `null` and `error.OutOfRange` mean what they mean in `scrollX`.
pub fn maxScrollX(node: NodeRef) schema.NarrowError!?JInt {
    const value = properties.scrollXMax(node) orelse return null;
    const min = properties.scrollXMin(node) orelse 0.0;
    return try schema.toI32Checked(value - min);
}

/// The node's vertical scroll offset, measured from its own minimum.
///
/// `null` and `error.OutOfRange` mean what they mean in `scrollX`.
pub fn scrollY(node: NodeRef) schema.NarrowError!?JInt {
    const value = properties.scrollY(node) orelse return null;
    const min = properties.scrollYMin(node) orelse 0.0;
    return try schema.toI32Checked(value - min);
}

/// The node's bottommost vertical scroll offset, measured from its own minimum.
///
/// `null` and `error.OutOfRange` mean what they mean in `scrollX`.
pub fn maxScrollY(node: NodeRef) schema.NarrowError!?JInt {
    const value = properties.scrollYMax(node) orelse return null;
    const min = properties.scrollYMin(node) orelse 0.0;
    return try schema.toI32Checked(value - min);
}

/// The text Android shows for `node`, or `null` when the node shows none.
///
/// `null` is the upstream answer for a node that states no value. A text input
/// that states no value still has a document range, so it answers with that
/// range's text.
///
/// The returned list owns its buffer. The caller releases it with `gpa`, the
/// allocator this call was given, and nothing else survives the call. On error
/// the document range is released inside the call, so nothing is left to free.
pub fn nodeText(gpa: std.mem.Allocator, node: NodeRef) FillError!?std.ArrayList(u8) {
    if (!try set_state.hasValue(node)) return null;
    const document = try text_query.documentRange(gpa, node);
    return try text_range.text(gpa, document);
}

/// The two ends of the selection on `node` as global UTF-16 indices.
///
/// `start` is the anchor and `end` is the focus. `null` means the node does not
/// hold the focus, or a focused node states no selection, which is the two
/// answers upstream gives. Both indices are byte-free counts of UTF-16 code
/// units from the start of the document the node measures.
pub const TextSelectionSpan = struct {
    start: usize,
    end: usize,
};

/// The two ends of the selection on `node`, or `null` when it states none.
///
/// `null` means the node does not hold the focus, or a focused node states no
/// selection. `error.TreeCycle` comes from the run walk inside
/// `toGlobalUtf16Index`. Allocates nothing that the caller releases, because
/// the selection range owns two handles and no memory.
pub fn nodeTextSelection(
    gpa: std.mem.Allocator,
    node: NodeRef,
) FillError!?TextSelectionSpan {
    if (!predicates.isFocused(node)) return null;
    const selection = try text_query.textSelection(gpa, node) orelse return null;
    return .{
        .start = try text_position.toGlobalUtf16Index(text_range.start(selection)),
        .end = try text_position.toGlobalUtf16Index(text_range.end(selection)),
    };
}

/// Writes every property of `node` into `node_info`.
///
/// The order of the writes is upstream's and is part of the contract, because
/// Android reads the last write of each property and a caller that reorders the
/// steps changes which value wins. The steps run as: one `addChild` per filtered
/// child, `setParent`, the screen bounds, the check state, the eight boolean
/// flags, the description, the text, the selection, the target URL extras, the
/// class name, the action list, the range info, the set-progress action and the
/// live region.
///
/// `host` is the host view and `id_map` mints the virtual ids the parent and the
/// children carry. Neither is released here. `id_map` may grow, because a child
/// or a parent the tree has never named gets its id on this call, and on
/// `error.OutOfMemory` every id minted on this call stays in `id_map`.
///
/// **The caller opens the JNI local frame and this call must run inside it.**
/// The frame needs a capacity of one, because the fill releases every reference
/// it builds with `deleteLocalRef` before it takes the next one, so at most one
/// local reference is live at a time. The fill does not push a frame of its own
/// and does not pop one, because a callee must not close a frame the caller
/// opened. The caller opens the frame with `pushLocalFrame` and closes it with
/// `popLocalFrame` in a `defer`.
///
/// **Every error leaves the node info partly written and nothing else
/// survives.** `error.JavaException` means a JNI call threw, the exception is
/// still pending, and every later JNI call on the calling thread fails until the
/// caller clears it. `error.JavaMemberMissing` means a class, a member or a
/// static field is not on the classpath, and the property that needed it is
/// absent from the node info. `error.OutOfRange` means a coordinate, a scroll
/// offset or a selection index is not an `i32`, and the node info carries no
/// bounds, no scroll offset and no selection. `error.TreeCycle` means a walk
/// over the tree reached its bound, and the walk stopped there. Every local
/// reference the call built is released before it returns on each of those
/// paths.
pub fn populateNodeInfo(
    gpa: std.mem.Allocator,
    jni_table: JniTable,
    host: JObject,
    id_map: *node_id_map.NodeIdMap,
    node: NodeRef,
    node_info: JObject,
) FillError!void {
    if (node_info == null) return error.JavaMemberMissing;
    try fillChildren(jni_table, host, id_map, node, node_info);
    try fillParent(jni_table, host, id_map, node, node_info);
    try fillScreenBounds(jni_table, host, node, node_info);
    try fillFlags(jni_table, node, node_info);
    try fillStrings(gpa, jni_table, node, node_info);
    try fillClassName(jni_table, node, node_info);
    try fillActions(jni_table, node, node_info);
    try fillRangeInfo(jni_table, node, node_info);
    try fillSetProgress(jni_table, node, node_info);
    try fillLiveRegion(jni_table, node, node_info);
}

/// The filter the Android adapter applies to the tree before it fills a node.
///
/// Upstream names one `filter` in `AK/android/src/node.rs` and it is
/// `common_filter`. The port has no closure, so this adapter passes
/// `consumer.filter.commonFilter` through `FilterFn`. The value carries no
/// context and needs no teardown.
const android_filter: FilterFn = .{
    .context = null,
    .filter = androidFilterCall,
};

/// The steps one filtered-child walk over `node` may take.
///
/// The bound is the node count the tree holds, which is the bound the consumer
/// layer names for every other walk of a tree, and it is the bound the cursor
/// `hierarchy.filteredChildren` answers carries. Reaching it is
/// `error.TreeCycle`.
fn filtered_child_step_bound(node: NodeRef) usize {
    return consumer.tree_state.treeWalkStepBound(node.tree_state.nodes.count());
}

/// Whether `value` is a whole number, which is what `RANGE_TYPE_INT` needs.
///
/// A value that is not finite is not a whole number, because an infinite or a
/// not-a-number value cannot be a range end.
fn isWholeNumber(value: f64) bool {
    return std.math.isFinite(value) and @trunc(value) == value;
}

/// `value` narrowed to `jfloat` the way upstream narrows it with `as`.
///
/// Upstream writes `min as f32`, and an `as` cast saturates at the largest
/// magnitude rather than trapping. `@floatCast` traps instead, so the two
/// bounds are checked here and the saturated value is returned.
fn toJavaFloat(value: f64) JFloat {
    const largest = std.math.floatMax(JFloat);
    if (value > largest) return largest;
    if (value < -largest) return -largest;
    return @floatCast(value);
}

/// Whether `node` is checkable, read from the two states Android reads a check
/// state from.
///
/// **The port has no `is_checkable`.** Upstream decides it from the node's role
/// and this module does not carry that role list, so this answers from the two
/// states that exist: a pressed state through `predicates.supportsToggle` and a
/// selection state through `properties.isSelected`. A node that states neither
/// answers `false`, which is the answer upstream gives every other node.
fn isCheckable(node: NodeRef) bool {
    return predicates.supportsToggle(node) or properties.isSelected(node) != null;
}

/// The value Android's check state takes for `node`.
///
/// **The port has no `is_checked`.** This reads the pressed state first and the
/// selection state second, so it answers from whichever of the two `isCheckable`
/// found.
fn isChecked(node: NodeRef) bool {
    const toggled = properties.toggled(node) orelse
        return properties.isSelected(node) orelse false;
    return toggled == .true_;
}

/// Whether `node` is a scrollable container.
///
/// **The port has no `is_scrollable`.** This answers from the two scroll
/// offsets that exist, because a node that states either one is a container the
/// user scrolls.
fn isScrollable(node: NodeRef) bool {
    return properties.scrollX(node) != null or properties.scrollY(node) != null;
}

/// Whether `node` is a range control, which decides whether it keeps the click
/// action.
///
/// **The port has no `is_range_control`.** This answers from `rangeFromNode`,
/// because a node that states a numeric range is the control a `RangeInfo`
/// fits. A node that states no range answers `false`.
fn isRangeControl(node: NodeRef) FillError!bool {
    return (try rangeFromNode(node)) != null;
}

/// The class `descriptor` names, or the error the lookup produced.
///
/// The returned reference is a local reference and belongs to the caller's
/// frame, so the caller releases it with `deleteLocalRef`.
fn findClassChecked(
    jni_table: JniTable,
    java_class: JavaClass,
) FillError!JClass {
    const class = jni_table.findClass(java_class.internal_name);
    if (jni_table.exceptionCheck()) return error.JavaException;
    if (class == null) return error.JavaMemberMissing;
    return class;
}

/// The id of `lookup` on its own class, or the error the lookup produced.
///
/// The id stays valid after the class reference is released, so this releases
/// the class before it answers.
fn methodIdChecked(jni_table: JniTable, lookup: Lookup) FillError!JMethodId {
    const class = try findClassChecked(jni_table, lookup.class);
    defer jni_table.deleteLocalRef(class);
    const method = jni_table.getMethodId(class, lookup.name, lookup.signature);
    if (jni_table.exceptionCheck()) return error.JavaException;
    if (method == null) return error.JavaMemberMissing;
    return method;
}

/// Calls `lookup` on `object` and discards what it answers.
///
/// `object` is released by the caller, not here. A call that throws leaves the
/// exception pending and this returns `error.JavaException` without reading the
/// result.
fn callVoidChecked(
    jni_table: JniTable,
    object: JObject,
    lookup: Lookup,
    args: []const JValue,
) FillError!void {
    if (object == null) return error.JavaMemberMissing;
    const method = try methodIdChecked(jni_table, lookup);
    jni_table.callVoidMethod(object, method, args);
    if (jni_table.exceptionCheck()) return error.JavaException;
}

/// Calls `lookup` on `object` and answers the reference it produced.
///
/// The answer is a local reference and the caller releases it. A call that
/// throws answers `null`, and this returns `error.JavaException` without
/// releasing what the call did not produce.
fn callObjectChecked(
    jni_table: JniTable,
    object: JObject,
    lookup: Lookup,
    args: []const JValue,
) FillError!JObject {
    if (object == null) return error.JavaMemberMissing;
    const method = try methodIdChecked(jni_table, lookup);
    const result = jni_table.callObjectMethod(object, method, args);
    if (jni_table.exceptionCheck()) return error.JavaException;
    if (result == null) return error.JavaMemberMissing;
    return result;
}

/// Calls the static `lookup` on its own class and answers the reference.
///
/// The class and the answer are local references and the caller releases both.
fn callStaticObjectChecked(
    jni_table: JniTable,
    lookup: Lookup,
    args: []const JValue,
) FillError!JObject {
    const class = try findClassChecked(jni_table, lookup.class);
    defer jni_table.deleteLocalRef(class);
    const method = try methodIdChecked(jni_table, lookup);
    const result = jni_table.callStaticObjectMethod(class, method, args);
    if (jni_table.exceptionCheck()) return error.JavaException;
    if (result == null) return error.JavaMemberMissing;
    return result;
}

/// A Java string holding `text`, or the error the construction produced.
///
/// The answer is a local reference and the caller releases it. The text is
/// encoded as UTF-16 before it crosses, because a Java string is UTF-16.
fn newStringChecked(jni_table: JniTable, text: []const u8) FillError!JString {
    const value = jni_table.newString(text);
    if (jni_table.exceptionCheck()) return error.JavaException;
    if (value == null) return error.JavaMemberMissing;
    return value;
}

/// The object `constructor` builds on `class` from `args`.
///
/// Both the class and the answer are local references and the caller releases
/// both.
fn newObjectChecked(
    jni_table: JniTable,
    class: JClass,
    constructor: Lookup,
    args: []const JValue,
) FillError!JObject {
    if (class == null) return error.JavaMemberMissing;
    const method = try methodIdChecked(jni_table, constructor);
    const result = jni_table.newObject(class, method, args);
    if (jni_table.exceptionCheck()) return error.JavaException;
    if (result == null) return error.JavaMemberMissing;
    return result;
}

/// A zero-filled Java `int[]` of `len` elements.
///
/// The answer is a local reference and the caller releases it.
fn newIntArrayChecked(jni_table: JniTable, len: usize) FillError!JObject {
    const array = jni_table.newIntArray(len);
    if (jni_table.exceptionCheck()) return error.JavaException;
    if (array == null) return error.JavaMemberMissing;
    return array;
}

/// Adds the action whose id is `action_id` to `node_info`.
///
/// `docs/29` row 44 records the overload the upstream helper at
/// `AK/android/src/node.rs:23` calls as `AccessibilityNodeInfo.addAction(int)`
/// `(I)V`, and `methods.zig` pins that row. **Upstream builds an
/// `AccessibilityNodeInfo$AccessibilityAction` object and hands it to the
/// object-taking overload, and this module sends the action id as an `int`
/// instead.** The constructor descriptor is the reason: no document under
/// `docs/` records one, `methods.zig` holds the row as `.reached_by_name` with
/// `signature = null`, and `docs/29` line 257 says the same, so building the
/// object would mean guessing a string that fails at run time on a device.
///
/// The one action the port does send as an object is `ACTION_SET_PROGRESS`,
/// because Android exposes it as a static field rather than an action bit. See
/// `fillSetProgress`.
fn addAction(jni_table: JniTable, node_info: JObject, action_id: JInt) FillError!void {
    try callVoidChecked(jni_table, node_info, add_action, &.{.{ .i = action_id }});
}

/// Adds one `addChild` edge per filtered child of `node`.
///
/// `AK/android/src/node.rs:203-211`. The walk is bounded by
/// `filtered_child_step_bound` and reaching the bound is `error.TreeCycle`.
fn fillChildren(
    jni_table: JniTable,
    host: JObject,
    id_map: *node_id_map.NodeIdMap,
    node: NodeRef,
    node_info: JObject,
) FillError!void {
    const bound = filtered_child_step_bound(node);
    var children = try hierarchy.filteredChildren(node, android_filter);
    var seen: usize = 0;
    while (seen < bound) : (seen += 1) {
        const child = try children.next() orelse return;
        const child_id = try id_map.getOrCreateJavaId(child);
        try callVoidChecked(jni_table, node_info, add_child, &.{
            .{ .l = host },
            .{ .i = child_id },
        });
    }
    return error.TreeCycle;
}

/// Points `node_info` at the node's filtered parent.
///
/// `AK/android/src/node.rs:212-230`. A root parent means the host view, and
/// every other parent carries its own virtual id. A node with no filtered
/// parent leaves the parent Android gave the object.
fn fillParent(
    jni_table: JniTable,
    host: JObject,
    id_map: *node_id_map.NodeIdMap,
    node: NodeRef,
    node_info: JObject,
) FillError!void {
    const parent = try hierarchy.filteredParent(node, android_filter) orelse return;
    if (hierarchy.isRoot(parent)) {
        try callVoidChecked(jni_table, node_info, set_parent_host, &.{.{ .l = host }});
        return;
    }
    const parent_id = try id_map.getOrCreateJavaId(parent);
    try callVoidChecked(jni_table, node_info, set_parent_node, &.{
        .{ .l = host },
        .{ .i = parent_id },
    });
}

/// Writes the node's bounding box in screen coordinates.
///
/// `AK/android/src/node.rs:232-261`. The node's own bounding box is in the tree
/// container's coordinate space, so the host's screen origin is added to each of
/// the four corners before they are narrowed.
///
/// Upstream narrows each corner with `as` and then adds the origin in `i32`
/// space, so an out-of-range coordinate saturates and then wraps. This module
/// adds in `f64` and narrows once, so an out-of-range coordinate is
/// `error.OutOfRange` and the node info carries no bounds at all. That is the
/// recorded deviation, and it is the reason the four corners are narrowed with
/// `toI32Checked` rather than with a bare cast.
fn fillScreenBounds(
    jni_table: JniTable,
    host: JObject,
    node: NodeRef,
    node_info: JObject,
) FillError!void {
    const box = try geometry.boundingBox(node) orelse return;
    const location = try newIntArrayChecked(jni_table, location_slot_count);
    defer jni_table.deleteLocalRef(location);
    try callVoidChecked(jni_table, host, get_location_on_screen, &.{.{ .l = location }});
    var origin = [_]JInt{0} ** location_slot_count;
    jni_table.getIntArrayRegion(location, 0, location_slot_count, &origin);
    if (jni_table.exceptionCheck()) return error.JavaException;
    const host_x: f64 = @floatFromInt(origin[0]);
    const host_y: f64 = @floatFromInt(origin[1]);
    const corners = [_]JValue{
        .{ .i = try schema.toI32Checked(box.x0 + host_x) },
        .{ .i = try schema.toI32Checked(box.y0 + host_y) },
        .{ .i = try schema.toI32Checked(box.x1 + host_x) },
        .{ .i = try schema.toI32Checked(box.y1 + host_y) },
    };
    const class = try findClassChecked(jni_table, rect_class);
    defer jni_table.deleteLocalRef(class);
    const screen_box = try newObjectChecked(jni_table, class, rect_constructor, &corners);
    defer jni_table.deleteLocalRef(screen_box);
    try callVoidChecked(jni_table, node_info, set_bounds_in_screen, &.{.{ .l = screen_box }});
}

/// Writes the check state and the eight boolean flags.
///
/// `AK/android/src/node.rs:263-309`. The check pair is written only for a
/// checkable node, and the other eight are written for every node.
fn fillFlags(jni_table: JniTable, node: NodeRef, node_info: JObject) FillError!void {
    if (isCheckable(node)) {
        try callVoidChecked(jni_table, node_info, set_checkable, &.{booleanValue(true)});
        try callVoidChecked(jni_table, node_info, set_checked, &.{booleanValue(isChecked(node))});
    }
    try callVoidChecked(jni_table, node_info, set_editable, &.{
        booleanValue(!predicates.isReadOnly(node)),
    });
    try callVoidChecked(jni_table, node_info, set_enabled, &.{
        booleanValue(!properties.isDisabled(node)),
    });
    try callVoidChecked(
        jni_table,
        node_info,
        set_focusable,
        &.{booleanValue(try predicates.isFocusable(node, android_filter))},
    );
    try callVoidChecked(jni_table, node_info, set_focused, &.{
        booleanValue(predicates.isFocused(node)),
    });
    try callVoidChecked(jni_table, node_info, set_password, &.{
        booleanValue(properties.role(node) == .password_input),
    });
    try callVoidChecked(jni_table, node_info, set_scrollable, &.{
        booleanValue(isScrollable(node)),
    });
    try callVoidChecked(jni_table, node_info, set_selected, &.{
        booleanValue(properties.isSelected(node) orelse false),
    });
    // Upstream asks when the property should ever answer false and does not, so
    // every node this fill writes is visible to the user.
    try callVoidChecked(jni_table, node_info, set_visible_to_user, &.{booleanValue(true)});
}

/// Writes the description, the text, the selection and the target URL.
///
/// `AK/android/src/node.rs:311-357`. Each step is written only when the node
/// states the value behind it, and every Java string built here is released
/// before the next one is built.
fn fillStrings(
    gpa: std.mem.Allocator,
    jni_table: JniTable,
    node: NodeRef,
    node_info: JObject,
) FillError!void {
    var description_list = try strings.description(gpa, node);
    defer releaseList(gpa, &description_list);
    if (description_list) |description| {
        const value = try newStringChecked(jni_table, description.items);
        defer jni_table.deleteLocalRef(value);
        try callVoidChecked(jni_table, node_info, set_content_description, &.{.{ .l = value }});
    }
    var text_list = try nodeText(gpa, node);
    defer releaseList(gpa, &text_list);
    if (text_list) |text| {
        const value = try newStringChecked(jni_table, text.items);
        defer jni_table.deleteLocalRef(value);
        try callVoidChecked(jni_table, node_info, set_text, &.{.{ .l = value }});
    }
    if (try nodeTextSelection(gpa, node)) |span| {
        try callVoidChecked(jni_table, node_info, set_text_selection, &.{
            .{ .i = try schema.toI32Checked(@as(f64, @floatFromInt(span.start))) },
            .{ .i = try schema.toI32Checked(@as(f64, @floatFromInt(span.end))) },
        });
    }
    if (strings.url(node)) |url| {
        const extras = try callObjectChecked(jni_table, node_info, get_extras, &.{});
        defer jni_table.deleteLocalRef(extras);
        const key = try newStringChecked(jni_table, values.TARGET_URL_EXTRAS_KEY);
        defer jni_table.deleteLocalRef(key);
        const value = try newStringChecked(jni_table, url);
        defer jni_table.deleteLocalRef(value);
        try callVoidChecked(jni_table, extras, put_string, &.{
            .{ .l = key },
            .{ .l = value },
        });
    }
}

/// Writes the widget class name, `AK/android/src/node.rs:359-366`.
fn fillClassName(jni_table: JniTable, node: NodeRef, node_info: JObject) FillError!void {
    const value = try newStringChecked(jni_table, className(node));
    defer jni_table.deleteLocalRef(value);
    try callVoidChecked(jni_table, node_info, set_class_name, &.{.{ .l = value }});
}

/// Writes the action list, in upstream order.
///
/// `AK/android/src/node.rs:368-405`.
///
/// A node that takes focus but is not focused yet gets the focus action. The
/// click action goes to a clickable node, and also to a focusable node that is
/// not a range control, because a range control without a click action lets a
/// double tap set its value to the middle. A node that supports text ranges
/// gets the three selection actions and one granularity mask. The two scroll
/// actions follow from the four scroll actions and from the two step actions.
fn fillActions(jni_table: JniTable, node: NodeRef, node_info: JObject) FillError!void {
    const can_focus = try predicates.isFocusable(node, android_filter) and
        !predicates.isFocused(node);
    var clickable = try predicates.isClickable(node, android_filter);
    if (!clickable and can_focus) {
        const range_control = try isRangeControl(node);
        clickable = !range_control;
    }
    if (clickable) try addAction(jni_table, node_info, values.ACTION_CLICK);
    if (can_focus) try addAction(jni_table, node_info, values.ACTION_FOCUS);
    if (try text_query.supportsTextRanges(node)) {
        try addAction(jni_table, node_info, values.ACTION_SET_SELECTION);
        try addAction(jni_table, node_info, values.ACTION_NEXT_AT_MOVEMENT_GRANULARITY);
        try addAction(jni_table, node_info, values.ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY);
        try callVoidChecked(
            jni_table,
            node_info,
            set_movement_granularities,
            &.{.{ .i = values.MOVEMENT_GRANULARITIES_ALL }},
        );
    }
    var backward = try predicates.supportsAction(node, .scroll_left, android_filter);
    if (!backward) backward = try predicates.supportsAction(node, .scroll_up, android_filter);
    if (!backward) backward = try predicates.supportsDecrement(node, android_filter);
    if (backward) try addAction(jni_table, node_info, values.ACTION_SCROLL_BACKWARD);
    var forward = try predicates.supportsAction(node, .scroll_right, android_filter);
    if (!forward) forward = try predicates.supportsAction(node, .scroll_down, android_filter);
    if (!forward) forward = try predicates.supportsIncrement(node, android_filter);
    if (forward) try addAction(jni_table, node_info, values.ACTION_SCROLL_FORWARD);
}

/// Writes the range info, `AK/android/src/node.rs:407-416`.
///
/// `RangeInfo.obtain` takes the type, then the minimum, then the maximum, then
/// the current value, and the port keeps that order at
/// `AK/android/src/util.rs:114-119`.
fn fillRangeInfo(jni_table: JniTable, node: NodeRef, node_info: JObject) FillError!void {
    const range = try rangeFromNode(node) orelse return;
    const arguments = [_]JValue{
        .{ .i = rangeType(range) },
        .{ .f = toJavaFloat(range.min) },
        .{ .f = toJavaFloat(range.max) },
        .{ .f = toJavaFloat(range.current) },
    };
    const info = try callStaticObjectChecked(jni_table, obtain_range_info, &arguments);
    defer jni_table.deleteLocalRef(info);
    try callVoidChecked(jni_table, node_info, set_range_info, &.{.{ .l = info }});
}

/// Adds the set-progress action, `AK/android/src/node.rs:417-437`.
///
/// **The port has no `supports_set_progress`.** This answers from
/// `predicates.supportsIncrement`, because a node that accepts the increment
/// action is the node whose value a progress action changes.
fn fillSetProgress(jni_table: JniTable, node: NodeRef, node_info: JObject) FillError!void {
    if (!try predicates.supportsIncrement(node, android_filter)) return;
    const class = try findClassChecked(jni_table, action_set_progress_field.class);
    defer jni_table.deleteLocalRef(class);
    const field = jni_table.getStaticFieldId(
        class,
        action_set_progress_field.name,
        action_set_progress_field.signature,
    );
    if (jni_table.exceptionCheck()) return error.JavaException;
    if (field == null) return error.JavaMemberMissing;
    const action = jni_table.getStaticObjectField(class, field);
    if (jni_table.exceptionCheck()) return error.JavaException;
    if (action == null) return error.JavaMemberMissing;
    defer jni_table.deleteLocalRef(action);
    try callVoidChecked(jni_table, node_info, add_action_object, &.{.{ .l = action }});
}

/// Writes the live region level, `AK/android/src/node.rs:439-445`.
///
/// The level is written for every node, so a node that is not a live region
/// still reports `LIVE_REGION_NONE`.
fn fillLiveRegion(jni_table: JniTable, node: NodeRef, node_info: JObject) FillError!void {
    const level: JInt = switch (try set_state.live(node)) {
        .off => values.LIVE_REGION_NONE,
        .polite => values.LIVE_REGION_POLITE,
        .assertive => values.LIVE_REGION_ASSERTIVE,
    };
    try callVoidChecked(jni_table, node_info, set_live_region, &.{.{ .i = level }});
}

/// One argument, the way a `jboolean` crosses.
///
/// `jni.JValue` is an eight-byte union and a Java boolean is one byte, so the
/// argument is written through the `z` member and nowhere else.
fn booleanValue(flag: bool) JValue {
    return .{ .z = if (flag) 1 else 0 };
}

/// Releases `list` when it holds one, and does nothing when it holds `null`.
///
/// A `defer` runs on the error path as well as on the success path, so the list
/// a failing call already built is released the same way a list a succeeding
/// call built is.
fn releaseList(gpa: std.mem.Allocator, list: *?std.ArrayList(u8)) void {
    if (list.*) |*owned| owned.deinit(gpa);
}

/// Applies `consumer.filter.commonFilter` in the shape `FilterFn` takes.
///
/// The context is always `null` and the filter reads only the node, so a context
/// would be state no one reads.
fn androidFilterCall(_: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    return consumer.filter.commonFilter(node);
}

// --- The recording JNI table ---------------------------------------------------

/// How many classes one recorded fill may resolve.
const recorded_class_capacity = 64;

/// How many member lookups one recorded fill may make.
const recorded_member_capacity = 128;

/// How many member calls one recorded fill may make.
const recorded_call_capacity = 128;

/// The first fabricated handle the recorder hands out, so a fabricated handle is
/// never confused with the null the JNI default is.
const fabricated_handle_base = 0x1000;

/// One `FindClass` answer, kept so a later lookup can name its class.
const ResolvedClass = struct {
    /// The internal name the fill asked for. Borrowed from a `JavaClass`
    /// declaration, so it has static lifetime.
    name: [:0]const u8,
};

/// One member lookup, kept so a later call can name its member.
const ResolvedMember = struct {
    /// Which entry of `Recorder.classes` names the class, counted from one.
    class_index: usize,
    /// The member name. Borrowed from a `Lookup` literal, so it has static
    /// lifetime.
    name: [:0]const u8,
    /// The JNI descriptor. Borrowed from a `Lookup` literal, so it has static
    /// lifetime.
    signature: [:0]const u8,
};

/// One member call or one constructor, kept in the order the fill made it.
const RecordedCall = struct {
    /// Which entry of `Recorder.members` names the member, counted from one.
    /// Zero is the id a missing method answers, so it names no member.
    member_index: usize,
    /// The arguments, and how many slots the fill filled. The slots past
    /// `arg_count` hold zeroes.
    args: [max_jni_argument_count]JValue,
    arg_count: usize,
};

/// What the recording table parks in its `env` and what a test reads back.
///
/// The recorder owns no memory and returns no error, so a test can drive the
/// whole fill without a failing allocator in the middle of a recorded call.
const Recorder = struct {
    // SAFETY: `recordFindClass` appends to `classes` only below
    // `recorded_class_capacity` and only bumps `class_count` after the write,
    // so every reader that checks the count sees a filled row.
    classes: [recorded_class_capacity]ResolvedClass = undefined,
    class_count: usize = 0,
    // SAFETY: `recordGetMethodId` and `recordGetStaticFieldId` append below
    // `recorded_member_capacity` and bump `member_count` only after the write,
    // so a `member_count`-bounded read never reaches an unwritten row.
    members: [recorded_member_capacity]ResolvedMember = undefined,
    member_count: usize = 0,
    // SAFETY: `recordCall` appends below `recorded_call_capacity` and bumps
    // `call_count` only after the write, so a `call_count`-bounded read never
    // reaches an unwritten row.
    calls: [recorded_call_capacity]RecordedCall = undefined,
    call_count: usize = 0,
    /// The two numbers `getIntArrayRegion` writes, the host screen origin.
    host_screen: [location_slot_count]JInt = .{ 0, 0 },
    /// How many local references the fill released.
    local_release_count: usize = 0,
    /// What `exceptionCheck` answers.
    exception_pending: bool = false,
    /// What `findClass` answers. `true` makes it answer `null` with no
    /// exception pending, which is the `JavaMemberMissing` path.
    class_missing: bool = false,
    string_count: usize = 0,
    object_count: usize = 0,
    array_count: usize = 0,
    static_field_count: usize = 0,

    /// The member name of the call at `index`, or a placeholder when the index
    /// names no call or no member.
    fn memberName(self: *const Recorder, index: usize) []const u8 {
        if (index >= self.call_count) return "<no call>";
        const call = self.calls[index];
        if (call.member_index == 0 or call.member_index > self.member_count) {
            return "<no member>";
        }
        return self.members[call.member_index - 1].name;
    }

    /// The `Lookup` the call at `index` used, or `null` when the index names
    /// none.
    fn lookupAt(self: *const Recorder, index: usize) ?Lookup {
        if (index >= self.call_count) return null;
        const member_index = self.calls[index].member_index;
        if (member_index == 0 or member_index > self.member_count) return null;
        const member = self.members[member_index - 1];
        if (member.class_index == 0 or member.class_index > self.class_count) return null;
        const class_name = self.classes[member.class_index - 1].name;
        // The walk is over the rows of `lookups`, so `lookup_count` is the
        // bound and the loop ends by exhausting it.
        for (lookups) |candidate| {
            if (!std.mem.eql(u8, candidate.class.internal_name, class_name)) continue;
            if (!std.mem.eql(u8, candidate.name, member.name)) continue;
            if (!std.mem.eql(u8, candidate.signature, member.signature)) continue;
            return candidate;
        }
        return null;
    }
};

/// The recorder the table parks in `env`, or `null` when there is none.
///
/// `null` is data and not a failure, so every recording function answers the JNI
/// default when the environment carries no recorder.
fn recorderOf(env: JniEnv) ?*Recorder {
    const handle = env orelse return null;
    // SAFETY: the table parks the recorder as `.env`, and `JniTable.env` is
    // `?*const anyopaque`, so the const is the table's and not the recorder's.
    // The alignment is the one the recorder was declared with.
    return @ptrCast(@alignCast(@constCast(handle)));
}

/// Records one `FindClass` answer and answers a fabricated class handle.
fn recordFindClass(env: JniEnv, name: [:0]const u8) JClass {
    const recorder = recorderOf(env) orelse return null;
    if (recorder.class_missing) return null;
    if (recorder.class_count == recorded_class_capacity) return null;
    recorder.classes[recorder.class_count] = .{ .name = name };
    recorder.class_count += 1;
    return @ptrFromInt(recorder.class_count);
}

/// The class index a fabricated class handle carries.
fn classIndexOf(class: JClass) ?usize {
    if (class == null) return null;
    return @intFromPtr(class);
}

/// Records one instance method lookup and answers a fabricated method id.
fn recordGetMethodId(
    env: JniEnv,
    class: JClass,
    name: [:0]const u8,
    signature: [:0]const u8,
) JMethodId {
    const recorder = recorderOf(env) orelse return null;
    if (recorder.member_count == recorded_member_capacity) return null;
    recorder.members[recorder.member_count] = .{
        .class_index = classIndexOf(class) orelse return null,
        .name = name,
        .signature = signature,
    };
    recorder.member_count += 1;
    return @ptrFromInt(recorder.member_count);
}

/// Records one static field lookup and answers a fabricated field id.
fn recordGetStaticFieldId(
    env: JniEnv,
    class: JClass,
    name: [:0]const u8,
    signature: [:0]const u8,
) JFieldId {
    const recorder = recorderOf(env) orelse return null;
    if (recorder.member_count == recorded_member_capacity) return null;
    recorder.members[recorder.member_count] = .{
        .class_index = classIndexOf(class) orelse return null,
        .name = name,
        .signature = signature,
    };
    recorder.member_count += 1;
    return @ptrFromInt(recorder.member_count);
}

/// Answers a fabricated action object and counts the field read.
fn recordGetStaticObjectField(env: JniEnv, _: JClass, _: JFieldId) JObject {
    const recorder = recorderOf(env) orelse return null;
    recorder.static_field_count += 1;
    return @ptrFromInt(fabricated_handle_base + recorder.static_field_count);
}

/// Records the arguments of one member call and discards its result.
fn recordCall(
    recorder: *Recorder,
    method: JMethodId,
    args: []const JValue,
) void {
    if (recorder.call_count == recorded_call_capacity) return;
    if (method == null) return;
    const slot = &recorder.calls[recorder.call_count];
    slot.* = .{
        .member_index = @intFromPtr(method),
        .args = std.mem.zeroes([max_jni_argument_count]JValue),
        .arg_count = @min(args.len, max_jni_argument_count),
    };
    @memcpy(slot.args[0..slot.arg_count], args[0..slot.arg_count]);
    recorder.call_count += 1;
}

/// Records one `void` member call.
fn recordCallVoidMethod(
    env: JniEnv,
    _: JObject,
    method: JMethodId,
    args: []const JValue,
) void {
    const recorder = recorderOf(env) orelse return;
    recordCall(recorder, method, args);
}

/// Records one reference-returning member call and answers a fabricated object.
fn recordCallObjectMethod(
    env: JniEnv,
    _: JObject,
    method: JMethodId,
    args: []const JValue,
) JObject {
    const recorder = recorderOf(env) orelse return null;
    recordCall(recorder, method, args);
    recorder.object_count += 1;
    return @ptrFromInt(fabricated_handle_base + recorder.object_count);
}

/// Records one static reference-returning call and answers a fabricated object.
fn recordCallStaticObjectMethod(
    env: JniEnv,
    _: JClass,
    method: JMethodId,
    args: []const JValue,
) JObject {
    const recorder = recorderOf(env) orelse return null;
    recordCall(recorder, method, args);
    recorder.object_count += 1;
    return @ptrFromInt(fabricated_handle_base + recorder.object_count);
}

/// Answers a fabricated Java string and counts the string.
fn recordNewString(env: JniEnv, _: []const u8) JString {
    const recorder = recorderOf(env) orelse return null;
    recorder.string_count += 1;
    return @ptrFromInt(fabricated_handle_base + recorder.string_count);
}

/// Records one constructor call and answers a fabricated object.
fn recordNewObject(
    env: JniEnv,
    _: JClass,
    method: JMethodId,
    args: []const JValue,
) JObject {
    const recorder = recorderOf(env) orelse return null;
    recordCall(recorder, method, args);
    recorder.object_count += 1;
    return @ptrFromInt(fabricated_handle_base + recorder.object_count);
}

/// Answers a fabricated `int[]` and counts the array.
fn recordNewIntArray(env: JniEnv, _: usize) JObject {
    const recorder = recorderOf(env) orelse return null;
    recorder.array_count += 1;
    return @ptrFromInt(fabricated_handle_base + recorder.array_count);
}

/// Writes the host screen origin into the caller's buffer.
fn recordGetIntArrayRegion(
    env: JniEnv,
    _: JObject,
    start: usize,
    len: usize,
    out: []JInt,
) void {
    const recorder = recorderOf(env) orelse return;
    // The walk is over `out`, so its length is the bound and the loop ends by
    // reaching it or by leaving the two host slots behind.
    const end = @min(len, out.len);
    const from = @min(start, location_slot_count);
    var index: usize = 0;
    while (index < end) : (index += 1) {
        const source = from + index;
        if (source >= location_slot_count) break;
        out[index] = recorder.host_screen[source];
    }
}

/// Counts one local reference the fill released.
fn recordDeleteLocalRef(env: JniEnv, _: JObject) void {
    const recorder = recorderOf(env) orelse return;
    recorder.local_release_count += 1;
}

/// Answers what the recorder was told to answer.
fn recordExceptionCheck(env: JniEnv) bool {
    const recorder = recorderOf(env) orelse return false;
    return recorder.exception_pending;
}

/// Answers `null`, because the fill makes no static method call.
fn stubGetStaticMethodId(
    _: JniEnv,
    _: JClass,
    _: [:0]const u8,
    _: [:0]const u8,
) JMethodId {
    return null;
}

/// Answers `JNI_FALSE`, because the fill makes no boolean call.
fn stubCallBooleanMethod(
    _: JniEnv,
    _: JObject,
    _: JMethodId,
    _: []const JValue,
) jni.JBoolean {
    return 0;
}

/// Answers zero, because the fill makes no `jint` call.
fn stubCallIntMethod(_: JniEnv, _: JObject, _: JMethodId, _: []const JValue) JInt {
    return 0;
}

/// Answers zero, because the fill makes no `jfloat` call.
fn stubCallFloatMethod(_: JniEnv, _: JObject, _: JMethodId, _: []const JValue) JFloat {
    return 0;
}

/// Hands the reference back, because the fill takes no global reference.
fn stubNewGlobalRef(_: JniEnv, obj: JObject) JObject {
    return obj;
}

/// Hands the reference back, because the fill takes no weak reference.
fn stubNewWeakGlobalRef(_: JniEnv, obj: JObject) JObject {
    return obj;
}

/// Does nothing, because the fill takes no global reference.
fn stubDeleteGlobalRef(_: JniEnv, _: JObject) void {}

/// Answers `false`, because the fill asks no instance-of question.
fn stubIsInstanceOf(_: JniEnv, _: JObject, _: JClass) bool {
    return false;
}

/// Answers zero, because the caller opens the frame the fill runs in.
fn stubPushLocalFrame(_: JniEnv, _: JInt) JInt {
    return 0;
}

/// Hands the result back, because the caller closes the frame.
fn stubPopLocalFrame(_: JniEnv, result: JObject) JObject {
    return result;
}

/// Answers zero, because the fill registers no native method.
fn stubRegisterNativeMethods(_: JniEnv, _: JClass, _: []const jni.JNINativeMethod) JInt {
    return 0;
}

/// The table that records every call the fill makes into `recorder`.
///
/// Every slot the fill reaches is a recording function, and every slot it does
/// not reach is a stub that answers the JNI default, so no call can index a
/// null function table entry.
fn recordingTable(recorder: *Recorder) JniTable {
    return .{
        .env = recorder,
        .findClassFn = recordFindClass,
        .getMethodIdFn = recordGetMethodId,
        .getStaticMethodIdFn = stubGetStaticMethodId,
        .getStaticFieldIdFn = recordGetStaticFieldId,
        .getStaticObjectFieldFn = recordGetStaticObjectField,
        .callObjectMethodFn = recordCallObjectMethod,
        .callStaticObjectMethodFn = recordCallStaticObjectMethod,
        .callBooleanMethodFn = stubCallBooleanMethod,
        .callIntMethodFn = stubCallIntMethod,
        .callFloatMethodFn = stubCallFloatMethod,
        .callVoidMethodFn = recordCallVoidMethod,
        .newStringFn = recordNewString,
        .newObjectFn = recordNewObject,
        .newIntArrayFn = recordNewIntArray,
        .getIntArrayRegionFn = recordGetIntArrayRegion,
        .newGlobalRefFn = stubNewGlobalRef,
        .newWeakGlobalRefFn = stubNewWeakGlobalRef,
        .deleteGlobalRefFn = stubDeleteGlobalRef,
        .deleteLocalRefFn = recordDeleteLocalRef,
        .isInstanceOfFn = stubIsInstanceOf,
        .exceptionCheckFn = recordExceptionCheck,
        .pushLocalFrameFn = stubPushLocalFrame,
        .popLocalFrameFn = stubPopLocalFrame,
        .registerNativeMethodsFn = stubRegisterNativeMethods,
    };
}

// --- Tests --------------------------------------------------------------------

/// The local id of node `number` in tree 0, which every fixture below uses.
fn fixtureId(number: u64) FullNodeId {
    return FullNodeId.init(.{ .value = number }, .init(0));
}

/// Stores one node under `id`, with `parent` as its parent or with no parent.
fn putNode(
    gpa: std.mem.Allocator,
    state: *TreeState,
    id: FullNodeId,
    parent: ?FullNodeId,
    role: schema.Role,
) std.mem.Allocator.Error!void {
    try state.nodes.put(gpa, id, .{
        .parent_and_index = if (parent) |parent_id|
            ParentAndIndex{ .parent_id = parent_id, .index = 0 }
        else
            null,
        .data = schema.Node.init(gpa, role),
    });
}

/// The handle to the node `id`, which the fixture has already stored.
fn handleOf(state: *TreeState, id: FullNodeId) error{NodeMissingFromState}!NodeRef {
    return NodeRef.init(state, id) orelse error.NodeMissingFromState;
}

/// One case of the class-name table: a role, whether it states a pressed state,
/// and the name the fill must report.
const ClassNameCase = struct {
    role: schema.Role,
    toggled: bool = false,
    expected: [:0]const u8,
};

/// Every role group the upstream `class_name` names, plus the default.
const class_name_cases = [_]ClassNameCase{
    // Eight text entry roles.
    .{ .role = .text_input, .expected = "android.widget.EditText" },
    .{ .role = .multiline_text_input, .expected = "android.widget.EditText" },
    .{ .role = .search_input, .expected = "android.widget.EditText" },
    .{ .role = .email_input, .expected = "android.widget.EditText" },
    .{ .role = .number_input, .expected = "android.widget.EditText" },
    .{ .role = .password_input, .expected = "android.widget.EditText" },
    .{ .role = .phone_number_input, .expected = "android.widget.EditText" },
    .{ .role = .url_input, .expected = "android.widget.EditText" },
    // One slider.
    .{ .role = .slider, .expected = "android.widget.SeekBar" },
    // Eight spinner roles.
    .{ .role = .color_well, .expected = "android.widget.Spinner" },
    .{ .role = .combo_box, .expected = "android.widget.Spinner" },
    .{ .role = .editable_combo_box, .expected = "android.widget.Spinner" },
    .{ .role = .date_input, .expected = "android.widget.Spinner" },
    .{ .role = .date_time_input, .expected = "android.widget.Spinner" },
    .{ .role = .week_input, .expected = "android.widget.Spinner" },
    .{ .role = .month_input, .expected = "android.widget.Spinner" },
    .{ .role = .time_input, .expected = "android.widget.Spinner" },
    // A button, both arms of the toggle test.
    .{ .role = .button, .expected = "android.widget.Button" },
    .{ .role = .button, .toggled = true, .expected = "android.widget.ToggleButton" },
    // The rest, one row each.
    .{ .role = .pdf_actionable_highlight, .expected = "android.widget.Button" },
    .{ .role = .check_box, .expected = "android.widget.CheckBox" },
    .{ .role = .radio_button, .expected = "android.widget.RadioButton" },
    .{ .role = .radio_group, .expected = "android.widget.RadioGroup" },
    .{ .role = .switch_, .expected = "android.widget.ToggleButton" },
    .{ .role = .canvas, .expected = "android.widget.ImageView" },
    .{ .role = .image, .expected = "android.widget.ImageView" },
    .{ .role = .svg_root, .expected = "android.widget.ImageView" },
    .{ .role = .meter, .expected = "android.widget.ProgressBar" },
    .{ .role = .progress_indicator, .expected = "android.widget.ProgressBar" },
    .{ .role = .tab_list, .expected = "android.widget.TabWidget" },
    .{ .role = .grid, .expected = "android.widget.GridView" },
    .{ .role = .table, .expected = "android.widget.GridView" },
    .{ .role = .tree_grid, .expected = "android.widget.GridView" },
    .{ .role = .description_list, .expected = "android.widget.ListView" },
    .{ .role = .list, .expected = "android.widget.ListView" },
    .{ .role = .list_box, .expected = "android.widget.ListView" },
    .{ .role = .scroll_view, .expected = "android.widget.ListView" },
    .{ .role = .dialog, .expected = "android.app.Dialog" },
    .{ .role = .root_web_area, .expected = "android.webkit.WebView" },
    .{ .role = .menu_item, .expected = "android.view.MenuItem" },
    .{ .role = .menu_item_check_box, .expected = "android.view.MenuItem" },
    .{ .role = .menu_item_radio, .expected = "android.view.MenuItem" },
    .{ .role = .label, .expected = "android.widget.TextView" },
    // The default, twice, so the arm is pinned for a plain and for a terminal.
    .{ .role = .group, .expected = "android.view.View" },
    .{ .role = .window, .expected = "android.view.View" },
};

/// How many rows `class_name_cases` holds.
const class_name_case_count = class_name_cases.len;

/// Every Java class this module names, so the two spellings are both checked.
const java_classes = [_]JavaClass{
    node_info_class,
    view_class,
    rect_class,
    bundle_class,
    range_info_class,
    accessibility_action_class,
};

/// How many classes `java_classes` holds.
const java_class_count = java_classes.len;

test "className answers one name per role group and the default" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    // The walk is over the case array, so the bound is its length.
    for (class_name_cases, 0..) |case, index| {
        const id = fixtureId(index + 1);
        try putNode(gpa, &state, id, null, case.role);
        if (case.toggled) {
            try schema.enums.setToggled(
                &state.nodes.getPtr(id).?.data.properties,
                .true_,
            );
        }
        const node = try handleOf(&state, id);
        try testing.expectEqualStrings(case.expected, className(node));
    }
    try testing.expectEqual(@as(usize, 45), class_name_case_count);
}

test "rangeType answers INT for a whole range and FLOAT for a fractional one" {
    const whole = Range{ .current = 5, .min = 0, .max = 10, .step = null };
    try testing.expectEqual(values.RANGE_TYPE_INT, rangeType(whole));
    const whole_step = Range{ .current = 5, .min = 0, .max = 10, .step = 1 };
    try testing.expectEqual(values.RANGE_TYPE_INT, rangeType(whole_step));
    const fractional_current = Range{ .current = 5.5, .min = 0, .max = 10, .step = null };
    try testing.expectEqual(values.RANGE_TYPE_FLOAT, rangeType(fractional_current));
    const fractional_min = Range{ .current = 5, .min = 0.5, .max = 10, .step = null };
    try testing.expectEqual(values.RANGE_TYPE_FLOAT, rangeType(fractional_min));
    const fractional_max = Range{ .current = 5, .min = 0, .max = 10.5, .step = null };
    try testing.expectEqual(values.RANGE_TYPE_FLOAT, rangeType(fractional_max));
    const fractional_step = Range{ .current = 5, .min = 0, .max = 10, .step = 0.5 };
    try testing.expectEqual(values.RANGE_TYPE_FLOAT, rangeType(fractional_step));
}

test "currentItemIndex maps the range onto 0 to 100" {
    const in_range = Range{ .current = 5, .min = 0, .max = 10, .step = null };
    try testing.expectEqual(@as(JInt, 50), currentItemIndex(in_range));
    const at_min = Range{ .current = 0, .min = 0, .max = 10, .step = null };
    try testing.expectEqual(@as(JInt, 0), currentItemIndex(at_min));
    const at_max = Range{ .current = 10, .min = 0, .max = 10, .step = null };
    try testing.expectEqual(@as(JInt, 100), currentItemIndex(at_max));
    const offset_range = Range{ .current = 15, .min = 10, .max = 20, .step = null };
    try testing.expectEqual(@as(JInt, 50), currentItemIndex(offset_range));
    const inverted = Range{ .current = 5, .min = 10, .max = 0, .step = null };
    try testing.expectEqual(@as(JInt, 0), currentItemIndex(inverted));
    const below_min = Range{ .current = -5, .min = 0, .max = 10, .step = null };
    try testing.expectEqual(@as(JInt, 0), currentItemIndex(below_min));
    const above_max = Range{ .current = 15, .min = 0, .max = 10, .step = null };
    try testing.expectEqual(@as(JInt, 100), currentItemIndex(above_max));
}

test "rangeFromNode reads the four numeric properties of a range control" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    const id = fixtureId(1);
    try putNode(gpa, &state, id, null, .slider);
    const properties_ref = &state.nodes.getPtr(id).?.data.properties;
    try schema.strings.setValue(properties_ref, "5");
    try schema.numbers.setNumericValue(properties_ref, 5);
    try schema.numbers.setMinNumericValue(properties_ref, 0);
    try schema.numbers.setMaxNumericValue(properties_ref, 10);
    try schema.numbers.setNumericValueStep(properties_ref, 1);

    const range = (try rangeFromNode(try handleOf(&state, id))).?;
    try testing.expectEqual(@as(f64, 5), range.current);
    try testing.expectEqual(@as(f64, 0), range.min);
    try testing.expectEqual(@as(f64, 10), range.max);
    try testing.expectEqual(@as(f64, 1), range.step.?);
    try testing.expectEqual(values.RANGE_TYPE_INT, rangeType(range));
}

test "rangeFromNode answers null for a node that states no value" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    const id = fixtureId(1);
    try putNode(gpa, &state, id, null, .slider);
    try testing.expectEqual(@as(?Range, null), try rangeFromNode(try handleOf(&state, id)));
}

test "the four scroll readers subtract their own minimum" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    const id = fixtureId(1);
    try putNode(gpa, &state, id, null, .group);
    const props = &state.nodes.getPtr(id).?.data.properties;
    try schema.numbers.setScrollX(props, 120);
    try schema.numbers.setScrollXMin(props, 20);
    try schema.numbers.setScrollXMax(props, 320);
    try schema.numbers.setScrollY(props, 90);
    try schema.numbers.setScrollYMin(props, 40);
    try schema.numbers.setScrollYMax(props, 140);
    const node = try handleOf(&state, id);

    try testing.expectEqual(@as(JInt, 100), (try scrollX(node)).?);
    try testing.expectEqual(@as(JInt, 300), (try maxScrollX(node)).?);
    try testing.expectEqual(@as(JInt, 50), (try scrollY(node)).?);
    try testing.expectEqual(@as(JInt, 100), (try maxScrollY(node)).?);
}

test "the four scroll readers answer null for a node with no scroll property" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    const id = fixtureId(1);
    try putNode(gpa, &state, id, null, .group);
    const node = try handleOf(&state, id);

    try testing.expectEqual(@as(?JInt, null), try scrollX(node));
    try testing.expectEqual(@as(?JInt, null), try maxScrollX(node));
    try testing.expectEqual(@as(?JInt, null), try scrollY(node));
    try testing.expectEqual(@as(?JInt, null), try maxScrollY(node));
}

test "the four scroll readers answer null when the node states only a maximum" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    const id = fixtureId(1);
    try putNode(gpa, &state, id, null, .group);
    try schema.numbers.setScrollXMax(&state.nodes.getPtr(id).?.data.properties, 50);
    const node = try handleOf(&state, id);

    try testing.expectEqual(@as(?JInt, null), try scrollX(node));
    try testing.expectEqual(@as(JInt, 50), (try maxScrollX(node)).?);
    try testing.expectEqual(@as(?JInt, null), try scrollY(node));
}

test "nodeText answers null for a node that states no value" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    const id = fixtureId(1);
    try putNode(gpa, &state, id, null, .button);
    const node = try handleOf(&state, id);

    try testing.expectEqual(@as(?std.ArrayList(u8), null), try nodeText(gpa, node));
}

test "nodeTextSelection answers null for a node that does not hold the focus" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    const id = fixtureId(1);
    try putNode(gpa, &state, id, null, .text_input);
    const node = try handleOf(&state, id);

    try testing.expectEqual(@as(?TextSelectionSpan, null), try nodeTextSelection(gpa, node));
}

test "every Java class names one descriptor and the FindClass spelling of it" {
    for (java_classes) |java_class| {
        try testing.expect(classes.find(java_class.descriptor) != null);
        try testing.expectEqualStrings(
            java_class.descriptor[1 .. java_class.descriptor.len - 1],
            java_class.internal_name,
        );
        try testing.expect(std.mem.indexOfScalar(u8, java_class.internal_name, '.') == null);
    }
    try testing.expectEqual(@as(usize, 6), java_class_count);
}

test "every lookup the fill builds names one of the 68 Java method names" {
    // The walk is over the 28 rows of `lookups`, so the bound is `lookup_count`.
    var checked: usize = 0;
    for (lookups) |lookup| {
        try testing.expect(classes.find(lookup.class.descriptor) != null);
        if (std.mem.eql(u8, lookup.name, "<init>")) {
            checked += 1;
            continue;
        }
        try testing.expect(methods.hasName(lookup.name));
        checked += 1;
    }
    try testing.expectEqual(lookup_count, checked);
}

test "the seven lookups methods.zig records agree with methods.zig" {
    const pinned = [_]struct { class: []const u8, name: []const u8, signature: []const u8 }{
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "addChild",
            .signature = "(Landroid/view/View;I)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setParent",
            .signature = "(Landroid/view/View;)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setParent",
            .signature = "(Landroid/view/View;I)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "addAction",
            .signature = "(I)V",
        },
        .{ .class = "Landroid/view/View;", .name = "getLocationOnScreen", .signature = "([I)V" },
        .{ .class = "Landroid/graphics/Rect;", .name = "<init>", .signature = "(IIII)V" },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo$RangeInfo;",
            .name = "obtain",
            .signature = "(IFFF)Landroid/view/accessibility/AccessibilityNodeInfo$RangeInfo;",
        },
    };
    try testing.expectEqual(@as(usize, 7), pinned.len);
    for (pinned) |row| {
        try testing.expect(methods.findById(row.class, row.name, row.signature) != null);
    }
    for (lookups) |lookup| {
        const row = methods.findById(
            lookup.class.descriptor,
            lookup.name,
            lookup.signature,
        );
        const is_literal = findLiteral(lookup);
        if (is_literal) {
            try testing.expectEqual(@as(?methods.MethodId, null), row);
            continue;
        }
        try testing.expect(row != null);
    }
}

test "the twenty-one descriptors methods.zig holds no row for are spelled as the fill writes them" {
    // The expected rows are literals in this test on purpose. Reading them out
    // of `literal_lookups` would compare the code with itself.
    const expected = [_]struct { class: []const u8, name: []const u8, signature: []const u8 }{
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setBoundsInScreen",
            .signature = "(Landroid/graphics/Rect;)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setCheckable",
            .signature = "(Z)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setChecked",
            .signature = "(Z)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setEditable",
            .signature = "(Z)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setEnabled",
            .signature = "(Z)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setFocusable",
            .signature = "(Z)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setFocused",
            .signature = "(Z)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setPassword",
            .signature = "(Z)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setScrollable",
            .signature = "(Z)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setSelected",
            .signature = "(Z)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setVisibleToUser",
            .signature = "(Z)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setContentDescription",
            .signature = "(Ljava/lang/CharSequence;)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setText",
            .signature = "(Ljava/lang/CharSequence;)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setTextSelection",
            .signature = "(II)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "getExtras",
            .signature = "()Landroid/os/Bundle;",
        },
        .{
            .class = "Landroid/os/Bundle;",
            .name = "putString",
            .signature = "(Ljava/lang/String;Ljava/lang/String;)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setClassName",
            .signature = "(Ljava/lang/CharSequence;)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "addAction",
            // The descriptor is one JNI token of 74 characters, and this field
            // already sits on its own line at the structural indent of 12, so
            // the line is 101 columns and a `++` split needs three more than
            // the single column it has spare.
            .signature = "(Landroid/view/accessibility/AccessibilityNodeInfo$AccessibilityAction;)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setMovementGranularities",
            .signature = "(I)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setRangeInfo",
            .signature = "(Landroid/view/accessibility/AccessibilityNodeInfo$RangeInfo;)V",
        },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
            .name = "setLiveRegion",
            .signature = "(I)V",
        },
    };
    try testing.expectEqual(@as(usize, 21), literal_lookup_count);
    try testing.expectEqual(expected.len, literal_lookups.len);
    // The walk is over the 21 rows, so the bound is `literal_lookup_count`.
    for (literal_lookups, expected) |actual, want| {
        try testing.expectEqualStrings(want.class, actual.class.descriptor);
        try testing.expectEqualStrings(want.name, actual.name);
        try testing.expectEqualStrings(want.signature, actual.signature);
        try testing.expect(classes.find(actual.class.descriptor) != null);
        try testing.expect(methods.hasName(actual.name));
        try testing.expectEqual(
            @as(?methods.MethodId, null),
            methods.findById(actual.class.descriptor, actual.name, actual.signature),
        );
    }
}

test "the action id the set-progress step reads is named as methods.zig records it" {
    try testing.expect(methods.hasName("addAction"));
    try testing.expectEqual(
        @as(?methods.MethodId, null),
        methods.findById(
            "Landroid/view/accessibility/AccessibilityNodeInfo;",
            "addAction",
            "(Landroid/view/accessibility/AccessibilityNodeInfo$AccessibilityAction;)V",
        ),
    );
    try testing.expectEqualStrings(
        "Landroid/view/accessibility/AccessibilityNodeInfo$AccessibilityAction;",
        action_set_progress_field.signature,
    );
    try testing.expectEqualStrings("ACTION_SET_PROGRESS", action_set_progress_field.name);
    const row = constants.find(action_set_progress_field.name);
    try testing.expect(row != null);
    try testing.expectEqual(constants.Group.action_id, row.?.group);
    const value = values.findValue(action_set_progress_field.name);
    try testing.expect(value != null);
    try testing.expectEqual(@as(?i32, 0x0102003d), value.?.value);
    try testing.expect(classes.find(action_set_progress_field.class.descriptor) != null);
}

test "the action ids, granularities, range types and live regions carry the upstream values" {
    try testing.expectEqual(@as(JInt, 1 << 0), values.ACTION_FOCUS);
    try testing.expectEqual(@as(JInt, 1 << 4), values.ACTION_CLICK);
    try testing.expectEqual(@as(JInt, 1 << 6), values.ACTION_ACCESSIBILITY_FOCUS);
    try testing.expectEqual(@as(JInt, 1 << 7), values.ACTION_CLEAR_ACCESSIBILITY_FOCUS);
    try testing.expectEqual(@as(JInt, 1 << 8), values.ACTION_NEXT_AT_MOVEMENT_GRANULARITY);
    try testing.expectEqual(@as(JInt, 1 << 9), values.ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY);
    try testing.expectEqual(@as(JInt, 1 << 12), values.ACTION_SCROLL_FORWARD);
    try testing.expectEqual(@as(JInt, 1 << 13), values.ACTION_SCROLL_BACKWARD);
    try testing.expectEqual(@as(JInt, 1 << 17), values.ACTION_SET_SELECTION);
    try testing.expectEqual(@as(JInt, 0x0102003d), values.ACTION_SET_PROGRESS);
    try testing.expectEqual(@as(JInt, 1 << 0), values.MOVEMENT_GRANULARITY_CHARACTER);
    try testing.expectEqual(@as(JInt, 1 << 1), values.MOVEMENT_GRANULARITY_WORD);
    try testing.expectEqual(@as(JInt, 1 << 2), values.MOVEMENT_GRANULARITY_LINE);
    try testing.expectEqual(@as(JInt, 1 << 3), values.MOVEMENT_GRANULARITY_PARAGRAPH);
    try testing.expectEqual(@as(JInt, 15), values.MOVEMENT_GRANULARITIES_ALL);
    try testing.expectEqual(@as(JInt, 0), values.RANGE_TYPE_INT);
    try testing.expectEqual(@as(JInt, 1), values.RANGE_TYPE_FLOAT);
    try testing.expectEqual(@as(JInt, 0), values.LIVE_REGION_NONE);
    try testing.expectEqual(@as(JInt, 1), values.LIVE_REGION_POLITE);
    try testing.expectEqual(@as(JInt, 2), values.LIVE_REGION_ASSERTIVE);
    try testing.expectEqual(@as(JInt, -1), values.HOST_VIEW_ID);
    try testing.expectEqual(@as(JInt, -1), constants.host_view_id);
}

test "the target URL extras key is spelled as the fill writes it" {
    try testing.expectEqualStrings(
        "AccessibilityNodeInfo.targetUrl",
        values.TARGET_URL_EXTRAS_KEY,
    );
}

test "the fill writes the properties of a node with bounds, a parent and one child in order" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    var id_map = try node_id_map.NodeIdMap.init(gpa, 3);
    defer id_map.deinit(gpa);

    const root_id = fixtureId(1);
    const node_id = fixtureId(2);
    const child_id = fixtureId(3);
    try putNode(gpa, &state, root_id, null, .group);
    try putNode(gpa, &state, node_id, root_id, .group);
    try putNode(gpa, &state, child_id, node_id, .group);
    state.root_id = root_id;
    try schema.option.setBounds(
        &state.nodes.getPtr(node_id).?.data.properties,
        schema.rectInit(1, 2, 3, 4),
    );
    try schema.ids_props.setChildren(
        &state.nodes.getPtr(node_id).?.data.properties,
        &.{child_id.local},
    );

    const node = try handleOf(&state, node_id);
    var recorder: Recorder = .{ .host_screen = .{ 10, 20 } };
    const table = recordingTable(&recorder);
    const host: JObject = @ptrFromInt(fabricated_handle_base + 0x100);
    const node_info: JObject = @ptrFromInt(fabricated_handle_base + 0x101);

    try populateNodeInfo(gpa, table, host, &id_map, node, node_info);

    // The steps the fill takes for this node, as the indexes of `lookups`.
    const expected_lookups = [_]usize{ 0, 1, 3, 4, 5, 8, 9, 10, 11, 12, 13, 14, 15, 21, 27 };
    try testing.expectEqual(expected_lookups.len, recorder.member_count);
    // The walk is over `expected_lookups`, so the array length is the bound.
    for (expected_lookups, 0..) |index, order| {
        const lookup = lookups[index];
        const member = recorder.members[order];
        const class_name = recorder.classes[member.class_index - 1].name;
        try testing.expectEqualStrings(lookup.class.internal_name, class_name);
        try testing.expectEqualStrings(lookup.name, member.name);
        try testing.expectEqualStrings(lookup.signature, member.signature);
    }

    // The calls the fill makes, in the order it makes them.
    const expected_calls = [_][:0]const u8{
        "addChild",
        "setParent",
        "getLocationOnScreen",
        "<init>",
        "setBoundsInScreen",
        "setEditable",
        "setEnabled",
        "setFocusable",
        "setFocused",
        "setPassword",
        "setScrollable",
        "setSelected",
        "setVisibleToUser",
        "setClassName",
        "setLiveRegion",
    };
    try testing.expectEqual(expected_calls.len, recorder.call_count);
    for (expected_calls, 0..) |name, order| {
        try testing.expectEqualStrings(name, recorder.memberName(order));
    }

    // The one child edge carries the child id the map minted, and the parent
    // edge names the host because the filtered parent is the root.
    try testing.expectEqual(@as(usize, 2), recorder.calls[0].arg_count);
    try testing.expectEqual(@as(?*anyopaque, host), recorder.calls[0].args[0].l);
    const mapped_child = id_map.getAccesskitId(recorder.calls[0].args[1].i).?;
    try testing.expect(std.meta.eql(mapped_child, child_id));
    try testing.expectEqual(@as(usize, 1), recorder.calls[1].arg_count);
    try testing.expectEqual(@as(?*anyopaque, host), recorder.calls[1].args[0].l);

    // The box carries the node bounds shifted by the host screen origin.
    const rect_call = recorder.calls[3];
    try testing.expectEqual(@as(usize, 4), rect_call.arg_count);
    try testing.expectEqual(@as(JInt, 11), rect_call.args[0].i);
    try testing.expectEqual(@as(JInt, 22), rect_call.args[1].i);
    try testing.expectEqual(@as(JInt, 13), rect_call.args[2].i);
    try testing.expectEqual(@as(JInt, 24), rect_call.args[3].i);

    // A plain group is visible, not focused, and not a live region.
    const visible_call = recorder.calls[12];
    try testing.expectEqualStrings("setVisibleToUser", recorder.memberName(12));
    try testing.expectEqual(@as(JInt, 1), visible_call.args[0].z);
    const live_call = recorder.calls[14];
    try testing.expectEqualStrings("setLiveRegion", recorder.memberName(14));
    try testing.expectEqual(values.LIVE_REGION_NONE, live_call.args[0].i);

    // Every local reference the fill built is released before it returns.
    try testing.expectEqual(@as(usize, 1), recorder.array_count);
    try testing.expect(recorder.local_release_count >= 4);
    try testing.expectEqualStrings("addChild", recorder.lookupAt(0).?.name);
}

test "the fill reports a pending Java exception and stops" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    var id_map = try node_id_map.NodeIdMap.init(gpa, 1);
    defer id_map.deinit(gpa);

    const node_id = fixtureId(2);
    try putNode(gpa, &state, node_id, null, .group);
    const node = try handleOf(&state, node_id);
    var recorder: Recorder = .{ .exception_pending = true };
    const table = recordingTable(&recorder);
    const host: JObject = @ptrFromInt(fabricated_handle_base + 0x100);
    const node_info: JObject = @ptrFromInt(fabricated_handle_base + 0x101);

    try testing.expectError(
        error.JavaException,
        populateNodeInfo(gpa, table, host, &id_map, node, node_info),
    );
    try testing.expectEqual(@as(usize, 0), recorder.call_count);
}

test "the fill reports a class that is not on the classpath" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    var id_map = try node_id_map.NodeIdMap.init(gpa, 1);
    defer id_map.deinit(gpa);

    const node_id = fixtureId(2);
    try putNode(gpa, &state, node_id, null, .group);
    const node = try handleOf(&state, node_id);
    const host: JObject = @ptrFromInt(fabricated_handle_base + 0x100);
    const node_info: JObject = @ptrFromInt(fabricated_handle_base + 0x101);

    // The extras call succeeds against a table that resolves every class, so
    // the reference it answers is a real one and not `null`.
    var found: Recorder = .{};
    const extras = try callObjectChecked(recordingTable(&found), node_info, get_extras, &.{});
    try testing.expect(extras != null);
    try testing.expectEqual(@as(usize, 1), found.object_count);

    // The same call fails the moment `findClass` answers `null`, and the fill
    // reports that instead of writing a property with a missing class.
    var missing: Recorder = .{ .class_missing = true };
    try testing.expectError(
        error.JavaMemberMissing,
        populateNodeInfo(gpa, recordingTable(&missing), host, &id_map, node, node_info),
    );
    try testing.expectEqual(@as(usize, 0), missing.call_count);
}

test "the fill rejects a null node info before it makes any call" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    var id_map = try node_id_map.NodeIdMap.init(gpa, 1);
    defer id_map.deinit(gpa);

    const node_id = fixtureId(2);
    try putNode(gpa, &state, node_id, null, .group);
    const node = try handleOf(&state, node_id);
    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);
    const host: JObject = @ptrFromInt(fabricated_handle_base + 0x100);

    try testing.expectError(
        error.JavaMemberMissing,
        populateNodeInfo(gpa, table, host, &id_map, node, null),
    );
    try testing.expectEqual(@as(usize, 0), recorder.class_count);
}

/// Whether `lookup` is one of the rows `methods.zig` records no row for.
fn findLiteral(lookup: Lookup) bool {
    // The walk is over the rows of `literal_lookups`, so `literal_lookup_count`
    // is the bound and the loop ends by exhausting it.
    for (literal_lookups) |candidate| {
        if (!std.mem.eql(u8, candidate.class.descriptor, lookup.class.descriptor)) continue;
        if (!std.mem.eql(u8, candidate.name, lookup.name)) continue;
        if (!std.mem.eql(u8, candidate.signature, lookup.signature)) continue;
        return true;
    }
    return false;
}
