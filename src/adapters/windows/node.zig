//! Windows UI Automation node queries and COM providers.
//! Providers own weak context handles. Each call borrows the tree through one context lease.

const std = @import("std");
const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const bindings = @import("bindings.zig");
const FullNodeId = consumer.tree_index.FullNodeId;
const NodeRef = consumer.node_id.NodeRef;
const context = @import("context.zig");
const com = @import("com.zig");
const util = @import("util.zig");
const filters = @import("filters.zig");
const errors = @import("error_codes.zig");
const elements = @import("elements.zig");
const queued_events = @import("queued_events.zig");
const syscalls = @import("syscalls.zig");
const properties = consumer.node_ref.properties;
const predicates = consumer.node_ref.predicates;
const strings = consumer.node_ref.strings;
const set_state = consumer.node_ref.set_state;
const hierarchy = consumer.node_ref.hierarchy;
const geometry = consumer.node_ref.geometry;
const containers = consumer.node_ref.containers;
const text_query = consumer.text.query;
const ProviderError = context.ProviderError;
const Hresult = bindings.Hresult;
const uia = bindings.uia;

/// Immutable UIA identity. No tree borrow is needed, including after removal.
pub fn runtimeIdFromNodeId(id: FullNodeId) [5]i32 {
    const full = id.toU128();
    return .{
        @intCast(uia.UiaAppendRuntimeId),
        @bitCast(@as(u32, @truncate(full >> 96))),
        @bitCast(@as(u32, @truncate(full >> 64))),
        @bitCast(@as(u32, @truncate(full >> 32))),
        @bitCast(@as(u32, @truncate(full))),
    };
}

/// A callback-scoped node borrow, corresponding to upstream node.rs:52-771.
/// Never retain a wrapper after the context lease ends.
pub const NodeWrapper = struct {
    node: NodeRef,

    pub fn controlType(self: NodeWrapper) bindings.ControlTypeId {
        comptime std.debug.assert(@typeInfo(schema.Role).@"enum".fields.len == 182);
        return switch (properties.role(self.node)) {
            .unknown, .text_run, .pdf_actionable_highlight => uia.UIA_CustomControlTypeId,
            .cell, .grid_cell, .row, .row_header, .column_header,
            .layout_table_cell, .layout_table_row => uia.UIA_DataItemControlTypeId,
            .label, .abbr, .alert, .caption, .code, .emphasis, .figure_caption,
            .heading, .legend, .line_break, .mark, .marquee, .ruby_annotation,
            .strong, .time => uia.UIA_TextControlTypeId,
            .image, .canvas, .svg_root, .graphics_symbol, .doc_cover => uia.UIA_ImageControlTypeId,
            .link, .doc_back_link, .doc_biblio_ref, .doc_gloss_ref,
            .doc_note_ref => uia.UIA_HyperlinkControlTypeId,
            .list_item, .list_box_option, .menu_list_option, .term,
            .doc_biblio_entry, .doc_endnote, .doc_footnote => uia.UIA_ListItemControlTypeId,
            .tree_item => uia.UIA_TreeItemControlTypeId,
            .menu_item => uia.UIA_MenuItemControlTypeId,
            .check_box, .menu_item_check_box => uia.UIA_CheckBoxControlTypeId,
            .radio_button, .menu_item_radio => uia.UIA_RadioButtonControlTypeId,
            .text_input, .multiline_text_input, .search_input, .date_input,
            .date_time_input, .week_input, .month_input, .time_input, .email_input,
            .number_input, .password_input, .phone_number_input,
            .url_input => uia.UIA_EditControlTypeId,
            .button, .default_button, .switch_, .color_well,
            .disclosure_triangle => uia.UIA_ButtonControlTypeId,
            .pane, .application, .embedded_object, .ime_candidate, .keyboard,
            .scroll_view, .tab_panel, .timer, .title_bar,
            .graphics_object => uia.UIA_PaneControlTypeId,
            .list, .description_list, .list_box, .menu_list_popup => uia.UIA_ListControlTypeId,
            .table, .layout_table => uia.UIA_TableControlTypeId,
            .menu => uia.UIA_MenuControlTypeId,
            .alert_dialog, .dialog, .window => uia.UIA_WindowControlTypeId,
            .combo_box, .editable_combo_box => uia.UIA_ComboBoxControlTypeId,
            .document, .terminal, .iframe, .root_web_area, .web_view,
            .pdf_root, .graphics_document => uia.UIA_DocumentControlTypeId,
            .grid, .tree_grid, .list_grid => uia.UIA_DataGridControlTypeId,
            .menu_bar => uia.UIA_MenuBarControlTypeId,
            .meter, .progress_indicator => uia.UIA_ProgressBarControlTypeId,
            .scroll_bar => uia.UIA_ScrollBarControlTypeId,
            .slider => uia.UIA_SliderControlTypeId,
            .spin_button => uia.UIA_SpinnerControlTypeId,
            .splitter, .doc_page_break => uia.UIA_SeparatorControlTypeId,
            .status => uia.UIA_StatusBarControlTypeId,
            .tab => uia.UIA_TabItemControlTypeId,
            .tab_list => uia.UIA_TabControlTypeId,
            .toolbar => uia.UIA_ToolBarControlTypeId,
            .tooltip => uia.UIA_ToolTipControlTypeId,
            .tree => uia.UIA_TreeControlTypeId,
            else => uia.UIA_GroupControlTypeId,
        };
    }

    pub fn localizedControlType(self: NodeWrapper) ?[]const u8 {
        return properties.roleDescription(self.node);
    }

    pub fn ariaRole(self: NodeWrapper) ?[]const u8 {
        return switch (properties.role(self.node)) {
            .alert => "alert", .alert_dialog => "alertdialog", .application => "application",
            .article => "article", .banner, .header => "banner",
            .button, .default_button => "button", .blockquote => "blockquote",
            .caption, .figure_caption => "caption", .cell => "cell", .check_box => "checkbox",
            .code => "code", .column_header => "columnheader",
            .combo_box, .editable_combo_box => "combobox", .comment => "comment",
            .complementary => "complementary", .content_info, .footer => "contentinfo",
            .definition => "definition", .content_deletion => "deletion", .dialog => "dialog",
            .document, .iframe, .web_view, .root_web_area, .terminal, .pdf_root => "document",
            .emphasis => "emphasis", .feed => "feed", .figure => "figure", .form => "form",
            .generic_container => "generic", .graphics_document => "graphics-document",
            .graphics_object => "graphics-object", .graphics_symbol => "graphics-symbol",
            .grid, .list_grid => "grid", .grid_cell => "gridcell",
            .group, .details, .iframe_presentational, .title_bar, .layout_table,
            .layout_table_cell, .layout_table_row, .audio, .video, .list_marker,
            .embedded_object, .ime_candidate => "group",
            .heading => "heading", .image, .canvas => "img", .content_insertion => "insertion",
            .link => "link", .list, .description_list, .menu_list_popup => "list",
            .list_box => "listbox", .list_item => "listitem", .log => "log", .main => "main",
            .mark => "marker", .marquee => "marquee", .math => "math", .menu => "menu",
            .menu_bar => "menubar", .menu_item => "menuitem",
            .menu_item_check_box => "menuitemcheckbox", .menu_item_radio => "menuitemradio",
            .meter => "meter", .navigation => "navigation", .note => "note",
            .list_box_option, .menu_list_option => "option", .paragraph => "paragraph",
            .progress_indicator => "progressbar", .radio_button => "radio",
            .radio_group => "radiogroup",
            .region, .pane, .window, .keyboard, .unknown, .scroll_view, .caret => "region",
            .row => "row", .row_group => "rowgroup", .row_header => "rowheader",
            .scroll_bar => "scrollbar", .search => "search", .search_input => "searchbox",
            .section_footer => "sectionfooter", .section_header => "sectionheader",
            .splitter => "separator", .slider => "slider", .spin_button => "spinbutton",
            .status => "status", .strong => "strong", .suggestion => "suggestion",
            .switch_ => "switch", .tab => "tab", .table => "table", .tab_list => "tablist",
            .tab_panel => "tabpanel", .term => "term",
            .text_input, .multiline_text_input, .date_input, .date_time_input, .week_input,
            .month_input, .time_input, .email_input, .number_input, .password_input,
            .phone_number_input, .url_input, .color_well => "textbox",
            .time => "time", .timer => "timer", .toolbar => "toolbar", .tooltip => "tooltip",
            .tree => "tree", .tree_grid => "treegrid", .tree_item => "treeitem",
            else => null,
        };
    }

    /// Returns an optional owned buffer. Release it with the supplied allocator.
    pub fn name(self: NodeWrapper, gpa: std.mem.Allocator) ProviderError!?std.ArrayList(u8) {
        return if (strings.labelComesFromValue(self.node))
            set_state.value(gpa, self.node) catch |failure| return writerError(failure)
        else
            strings.label(gpa, self.node) catch |failure| return writerError(failure);
    }

    pub fn description(self: NodeWrapper) ?[]const u8 {
        return schema.strings.description(&self.node.data().properties);
    }
    pub fn culture(self: NodeWrapper) ProviderError!?[]const u8 {
        return consumer.text.inherited.nodeLanguage(self.node);
    }
    pub fn placeholder(self: NodeWrapper) ProviderError!?[]const u8 {
        return strings.placeholder(self.node);
    }
    pub fn isContentElement(self: NodeWrapper) ProviderError!bool {
        return try filters.filter(self.node) == .include;
    }
    /// Returns owned ARIA bytes, or null. No borrowed value escapes construction.
    pub fn ariaProperties(self: NodeWrapper, gpa: std.mem.Allocator) ProviderError!?std.ArrayList(u8) {
        var result = util.AriaProperties.init();
        errdefer result.deinit(gpa);
        if (properties.isLiveAtomic(self.node)) try util.AriaProperties.writeBoolProperty(gpa, &result, "atomic", true);
        if (properties.brailleLabel(self.node)) |v|
            try util.AriaProperties.writeProperty(gpa, &result, .{ .name = "braillelabel", .value = v });
        if (properties.brailleRoleDescription(self.node)) |v|
            try util.AriaProperties.writeProperty(gpa, &result, .{ .name = "brailleroledescription", .value = v });
        if (properties.isBusy(self.node)) try util.AriaProperties.writeBoolProperty(gpa, &result, "busy", true);
        if (properties.columnIndexText(self.node)) |v|
            try util.AriaProperties.writeProperty(gpa, &result, .{ .name = "colindextext", .value = v });
        if (properties.ariaCurrent(self.node)) |v| {
            const raw_value: ?[]const u8 = switch (v) {
                .false_ => null, .true_ => "true", .page => "page", .step => "step",
                .location => "location", .date => "date", .time => "time",
            };
            if (raw_value) |text| try util.AriaProperties.writeProperty(gpa, &result, .{ .name = "current", .value = text });
        }
        if (properties.hasPopup(self.node)) |v| {
            try util.AriaProperties.writeProperty(gpa, &result, .{ .name = "haspopup", .value = @tagName(v) });
        }
        if (properties.level(self.node)) |v| try util.AriaProperties.writeUsizeProperty(gpa, &result, "level", v);
        if (predicates.isMultiline(self.node)) try util.AriaProperties.writeBoolProperty(gpa, &result, "multiline", true);
        if (properties.rowIndexText(self.node)) |v|
            try util.AriaProperties.writeProperty(gpa, &result, .{ .name = "rowindextext", .value = v });
        if (predicates.sortDirection(self.node)) |v| {
            try util.AriaProperties.writeProperty(gpa, &result, .{ .name = "sort", .value = @tagName(v) });
        }
        if (!result.hasProperties()) {
            result.deinit(gpa);
            return null;
        }
        const bytes = result.bytes;
        result.bytes = .empty;
        return bytes;
    }

    pub fn isEnabled(self: NodeWrapper) bool { return !properties.isDisabled(self.node); }
    pub fn isFocusable(self: NodeWrapper) ProviderError!bool {
        return predicates.isFocusable(self.node, filters.filter_fn);
    }
    pub fn isFocused(self: NodeWrapper) bool { return predicates.isFocused(self.node); }
    pub fn liveSetting(self: NodeWrapper) ProviderError!bindings.LiveSetting {
        return switch (try set_state.live(self.node)) {
            .off => .Off, .polite => .Polite, .assertive => .Assertive,
        };
    }
    pub fn automationId(self: NodeWrapper) ?[]const u8 {
        return set_state.htmlId(self.node) orelse set_state.authorId(self.node);
    }
    pub fn className(self: NodeWrapper) ?[]const u8 { return set_state.className(self.node); }
    pub fn orientation(self: NodeWrapper) bindings.OrientationType {
        return if (predicates.orientation(self.node)) |v| switch (v) {
            .horizontal => .Horizontal, .vertical => .Vertical,
        } else .None;
    }
    pub fn isTogglePatternSupported(self: NodeWrapper) bool {
        return properties.toggled(self.node) != null and !self.isSelectionItemPatternSupported();
    }
    pub fn toggleState(self: NodeWrapper) ProviderError!bindings.ToggleState {
        return switch (properties.toggled(self.node) orelse return error.InvalidOperation) {
            .false_ => .Off, .true_ => .On, .mixed => .Indeterminate,
        };
    }
    pub fn isInvokePatternSupported(self: NodeWrapper) ProviderError!bool {
        return predicates.isInvocable(self.node, filters.filter_fn);
    }
    pub fn isValuePatternSupported(self: NodeWrapper) ProviderError!bool {
        if (strings.supportsUrl(self.node)) return true;
        return try set_state.hasValue(self.node) and !strings.labelComesFromValue(self.node);
    }
    pub fn isRangeValuePatternSupported(self: NodeWrapper) bool {
        return properties.numericValue(self.node) != null;
    }
    /// Returns a caller-owned UTF-8 buffer; an absent value gives an empty buffer.
    pub fn value(self: NodeWrapper, gpa: std.mem.Allocator) ProviderError!std.ArrayList(u8) {
        if (strings.supportsUrl(self.node)) {
            var result: std.ArrayList(u8) = .empty;
            errdefer result.deinit(gpa);
            try result.appendSlice(gpa, strings.url(self.node).?);
            return result;
        }
        return (set_state.value(gpa, self.node) catch |failure| return writerError(failure)) orelse .empty;
    }
    pub fn isReadOnly(self: NodeWrapper) bool { return predicates.isReadOnly(self.node); }
    pub fn numericValue(self: NodeWrapper) f64 {
        return properties.numericValue(self.node).?;
    }
    pub fn minNumericValue(self: NodeWrapper) f64 { return properties.minNumericValue(self.node) orelse 0; }
    pub fn maxNumericValue(self: NodeWrapper) f64 { return properties.maxNumericValue(self.node) orelse 0; }
    pub fn numericValueStep(self: NodeWrapper) f64 { return properties.numericValueStep(self.node) orelse 0; }
    pub fn numericValueJump(self: NodeWrapper) f64 {
        return properties.numericValueJump(self.node) orelse self.numericValueStep();
    }
    pub fn isRequired(self: NodeWrapper) bool { return set_state.isRequired(self.node); }
    pub fn isScrollItemPatternSupported(self: NodeWrapper) ProviderError!bool {
        return predicates.supportsAction(self.node, .scroll_into_view, filters.filter_fn);
    }
    pub fn isSelectionItemPatternSupported(self: NodeWrapper) bool {
        return switch (properties.role(self.node)) {
            .radio_button, .menu_item_radio => if (properties.toggled(self.node)) |v| v != .mixed else false,
            .list_box_option, .list_item, .menu_list_option, .tab, .tree_item =>
                properties.isSelected(self.node) != null,
            .grid_cell => true,
            else => false,
        };
    }
    pub fn isSelected(self: NodeWrapper) bool {
        return switch (properties.role(self.node)) {
            .radio_button, .menu_item_radio => properties.toggled(self.node) == .true_,
            else => properties.isSelected(self.node) orelse false,
        };
    }
    pub fn positionInSet(self: NodeWrapper) ?i32 {
        const source_value = predicates.positionInSet(self.node) orelse return null;
        return oneBased(source_value);
    }
    pub fn sizeOfSet(self: NodeWrapper) ProviderError!?i32 {
        const owned_value = try predicates.sizeOfSetFromContainer(self.node, filters.filter_fn) orelse return null;
        return std.math.cast(i32, owned_value);
    }
    pub fn level(self: NodeWrapper) ?i32 {
        return oneBased(properties.level(self.node) orelse return null);
    }
    pub fn isSelectionPatternSupported(self: NodeWrapper) bool {
        return containers.isContainerWithSelectableChildren(self.node);
    }
    pub fn isMultiselectable(self: NodeWrapper) bool { return predicates.isMultiselectable(self.node); }
    pub fn isTextPatternSupported(self: NodeWrapper) ProviderError!bool {
        return text_query.supportsTextRanges(self.node);
    }
    pub fn isExpandCollapsePatternSupported(self: NodeWrapper) bool {
        return predicates.supportsExpandCollapse(self.node);
    }
    pub fn expandCollapseState(self: NodeWrapper) bindings.ExpandCollapseState {
        return if (schema.enums.isExpanded(&self.node.data().properties)) |v|
            if (v) .Expanded else .Collapsed
        else .LeafNode;
    }
    pub fn isPassword(self: NodeWrapper) bool { return properties.role(self.node) == .password_input; }
    pub fn isDialog(self: NodeWrapper) bool { return predicates.isDialog(self.node); }
    pub fn isWindowPatternSupported(self: NodeWrapper) bool { return self.isDialog(); }
    pub fn isModal(self: NodeWrapper) bool { return predicates.isModal(self.node); }
};

fn oneBased(value: usize) ?i32 {
    const next = std.math.add(usize, value, 1) catch return null;
    return std.math.cast(i32, next);
}

fn writerError(failure: (consumer.tree_state.QueryError || std.Io.Writer.Error)) ProviderError {
    return switch (failure) {
        // The consumer uses an allocating writer, so WriteFailed is allocation failure.
        error.WriteFailed => error.OutOfMemory,
        else => |err| err,
    };
}

const DecodedValue = struct {
    value: union(enum) {
        empty,
        boolean: bool,
        integer: i32,
        double: f64,
        text: []const u8,
        locale: []const u8,
    },
    owned: ?std.ArrayList(u8) = null,

    fn deinit(self: *DecodedValue, gpa: std.mem.Allocator) void {
        if (self.owned) |*buffer_slot| buffer_slot.deinit(gpa);
        self.* = .{ .value = .empty };
    }
    fn borrowed(value: ?[]const u8) DecodedValue {
        return .{ .value = if (value) |text| .{ .text = text } else .empty };
    }
    fn buffer(value: ?std.ArrayList(u8)) DecodedValue {
        return if (value) |text|
            .{ .value = .{ .text = text.items }, .owned = text }
        else .{ .value = .empty };
    }
    fn optionalInteger(value: ?i32) DecodedValue {
        return .{ .value = if (value) |integer| .{ .integer = integer } else .empty };
    }
    fn equal(a: DecodedValue, b: DecodedValue) bool {
        if (std.meta.activeTag(a.value) != std.meta.activeTag(b.value)) return false;
        return switch (a.value) {
            .empty => true,
            .boolean => |v| v == b.value.boolean,
            .integer => |v| v == b.value.integer,
            .double => |v| v == b.value.double,
            .text => |v| std.mem.eql(u8, v, b.value.text),
            .locale => |v| std.mem.eql(u8, v, b.value.locale),
        };
    }
    fn toVariant(self: DecodedValue, gpa: std.mem.Allocator, api: *const util.AutomationApi) ProviderError!util.VariantOwner {
        return switch (self.value) {
            .empty => util.VariantOwner.init(api),
            .boolean => |v| util.VariantOwner.fromBool(api, v),
            .integer => |v| util.VariantOwner.fromI32(api, v),
            .double => |v| util.VariantOwner.fromF64(api, v),
            .text => |v| util.VariantOwner.fromUtf8(api, v),
            .locale => |v| util.VariantOwner.fromLocaleName(gpa, api, v),
        };
    }
};

const simple_properties = [_]bindings.PropertyId{
    .ControlTypePropertyId, .LocalizedControlTypePropertyId, .AriaRolePropertyId,
    .NamePropertyId, .FullDescriptionPropertyId, .CulturePropertyId, .HelpTextPropertyId,
    .IsContentElementPropertyId, .IsControlElementPropertyId, .IsEnabledPropertyId,
    .IsKeyboardFocusablePropertyId, .HasKeyboardFocusPropertyId, .LiveSettingPropertyId,
    .AutomationIdPropertyId, .ClassNamePropertyId, .OrientationPropertyId,
    .IsRequiredForFormPropertyId, .IsPasswordPropertyId, .LevelPropertyId,
    .PositionInSetPropertyId, .SizeOfSetPropertyId, .AriaPropertiesPropertyId, .IsDialogPropertyId,
};

const Pattern = struct {
    id: bindings.PatternId,
    interface_index: u4,
    property_ids: []const bindings.PropertyId,
};
const patterns = [_]Pattern{
    .{ .id = .TogglePatternId, .interface_index = 3, .property_ids = &.{.ToggleToggleStatePropertyId} },
    .{ .id = .InvokePatternId, .interface_index = 4, .property_ids = &.{} },
    .{ .id = .ValuePatternId, .interface_index = 5,
        .property_ids = &.{ .ValueValuePropertyId, .ValueIsReadOnlyPropertyId } },
    .{ .id = .RangeValuePatternId, .interface_index = 6, .property_ids = &.{
        .RangeValueValuePropertyId, .RangeValueIsReadOnlyPropertyId,
        .RangeValueMinimumPropertyId, .RangeValueMaximumPropertyId,
        .RangeValueSmallChangePropertyId, .RangeValueLargeChangePropertyId,
    } },
    .{ .id = .ScrollItemPatternId, .interface_index = 7, .property_ids = &.{} },
    .{ .id = .SelectionItemPatternId, .interface_index = 8, .property_ids = &.{} },
    .{ .id = .SelectionPatternId, .interface_index = 9,
        .property_ids = &.{ .SelectionCanSelectMultiplePropertyId, .SelectionIsSelectionRequiredPropertyId } },
    .{ .id = .TextPatternId, .interface_index = 10, .property_ids = &.{} },
    .{ .id = .ExpandCollapsePatternId, .interface_index = 11,
        .property_ids = &.{.ExpandCollapseExpandCollapseStatePropertyId} },
    .{ .id = .WindowPatternId, .interface_index = 12, .property_ids = &.{.WindowIsModalPropertyId} },
};

fn patternSupported(wrapper: NodeWrapper, id: bindings.PatternId) ProviderError!bool {
    return switch (id) {
        .TogglePatternId => wrapper.isTogglePatternSupported(),
        .InvokePatternId => wrapper.isInvokePatternSupported(),
        .ValuePatternId => wrapper.isValuePatternSupported(),
        .RangeValuePatternId => wrapper.isRangeValuePatternSupported(),
        .ScrollItemPatternId => wrapper.isScrollItemPatternSupported(),
        .SelectionItemPatternId => wrapper.isSelectionItemPatternSupported(),
        .SelectionPatternId => wrapper.isSelectionPatternSupported(),
        .TextPatternId => wrapper.isTextPatternSupported(),
        .ExpandCollapsePatternId => wrapper.isExpandCollapsePatternSupported(),
        .WindowPatternId => wrapper.isWindowPatternSupported(),
        else => false,
    };
}

fn propertyValue(wrapper: NodeWrapper, gpa: std.mem.Allocator, id: bindings.PropertyId) ProviderError!DecodedValue {
    return switch (id) {
        .ControlTypePropertyId => .{ .value = .{ .integer = @intCast(@intFromEnum(wrapper.controlType())) } },
        .LocalizedControlTypePropertyId => DecodedValue.borrowed(wrapper.localizedControlType()),
        .AriaRolePropertyId => DecodedValue.borrowed(wrapper.ariaRole()),
        .NamePropertyId => DecodedValue.buffer(try wrapper.name(gpa)),
        .FullDescriptionPropertyId => DecodedValue.borrowed(wrapper.description()),
        .CulturePropertyId => if (try wrapper.culture()) |v|
            .{ .value = .{ .locale = v } } else .{ .value = .empty },
        .HelpTextPropertyId => DecodedValue.borrowed(try wrapper.placeholder()),
        .IsContentElementPropertyId, .IsControlElementPropertyId =>
            .{ .value = .{ .boolean = try wrapper.isContentElement() } },
        .IsEnabledPropertyId => .{ .value = .{ .boolean = wrapper.isEnabled() } },
        .IsKeyboardFocusablePropertyId => .{ .value = .{ .boolean = try wrapper.isFocusable() } },
        .HasKeyboardFocusPropertyId => .{ .value = .{ .boolean = wrapper.isFocused() } },
        .LiveSettingPropertyId => .{ .value = .{ .integer = @intFromEnum(try wrapper.liveSetting()) } },
        .AutomationIdPropertyId => DecodedValue.borrowed(wrapper.automationId()),
        .ClassNamePropertyId => DecodedValue.borrowed(wrapper.className()),
        .OrientationPropertyId => .{ .value = .{ .integer = @intFromEnum(wrapper.orientation()) } },
        .IsRequiredForFormPropertyId => .{ .value = .{ .boolean = wrapper.isRequired() } },
        .IsPasswordPropertyId => .{ .value = .{ .boolean = wrapper.isPassword() } },
        .LevelPropertyId => DecodedValue.optionalInteger(wrapper.level()),
        .PositionInSetPropertyId => DecodedValue.optionalInteger(wrapper.positionInSet()),
        .SizeOfSetPropertyId => DecodedValue.optionalInteger(try wrapper.sizeOfSet()),
        .AriaPropertiesPropertyId => DecodedValue.buffer(try wrapper.ariaProperties(gpa)),
        .IsDialogPropertyId => .{ .value = .{ .boolean = wrapper.isDialog() } },
        .ToggleToggleStatePropertyId => .{ .value = .{ .integer = @intFromEnum(try wrapper.toggleState()) } },
        .ValueValuePropertyId => DecodedValue.buffer(try wrapper.value(gpa)),
        .ValueIsReadOnlyPropertyId, .RangeValueIsReadOnlyPropertyId =>
            .{ .value = .{ .boolean = wrapper.isReadOnly() } },
        .RangeValueValuePropertyId => if (wrapper.isRangeValuePatternSupported())
            .{ .value = .{ .double = wrapper.numericValue() } } else error.InvalidOperation,
        .RangeValueMinimumPropertyId => .{ .value = .{ .double = wrapper.minNumericValue() } },
        .RangeValueMaximumPropertyId => .{ .value = .{ .double = wrapper.maxNumericValue() } },
        .RangeValueSmallChangePropertyId => .{ .value = .{ .double = wrapper.numericValueStep() } },
        .RangeValueLargeChangePropertyId => .{ .value = .{ .double = wrapper.numericValueJump() } },
        .SelectionCanSelectMultiplePropertyId => .{ .value = .{ .boolean = wrapper.isMultiselectable() } },
        .SelectionIsSelectionRequiredPropertyId => .{ .value = .{ .boolean = wrapper.isRequired() } },
        .SelectionItemIsSelectedPropertyId => .{ .value = .{ .boolean = wrapper.isSelected() } },
        .ExpandCollapseExpandCollapseStatePropertyId =>
            .{ .value = .{ .integer = @intFromEnum(wrapper.expandCollapseState()) } },
        .WindowIsModalPropertyId => .{ .value = .{ .boolean = wrapper.isModal() } },
        else => .{ .value = .empty },
    };
}

/// Queues exact simple and common-pattern deltas. The queue owns each converted value.
/// Old and new node borrows end before return. The handler owns implied text-selection events.
/// On failure, the queue retains any completed values for cancellation and clear-error retry.
pub fn enqueuePropertyChanges(
    gpa: std.mem.Allocator,
    platform: syscalls.Platform,
    registry: *elements.Registry,
    queue: *queued_events.QueuedEvents,
    old: NodeRef,
    new: NodeRef,
) ProviderError!void {
    const previous = NodeWrapper{ .node = old };
    const current = NodeWrapper{ .node = new };
    for (simple_properties) |id| try enqueueProperty(gpa, platform, registry, queue, previous, current, id);
    for (patterns) |pattern| {
        if (try patternSupported(previous, pattern.id) and try patternSupported(current, pattern.id)) {
            for (pattern.property_ids) |id|
                try enqueueProperty(gpa, platform, registry, queue, previous, current, id);
        }
    }
    if (!try sameControlled(old, new)) {
        const slot = try registry.slotFor(platform, new.id());
        const change = try queue.beginProperty(slot, .controller_for);
        var providers: std.ArrayList(*bindings.IUnknown) = .empty;
        defer providers.deinit(gpa);
        var controls = set_state.controls(new);
        try providers.ensureTotalCapacity(gpa, controls.ids.len);
        while (try nextControlled(&controls)) |controlled_node| {
            const controlled = try registry.slotFor(platform, controlled_node.id());
            const raw = controlled.interface orelse return error.ElementNotAvailable;
            providers.appendAssumeCapacity(@ptrCast(@alignCast(raw)));
        }
        change.new = try util.VariantOwner.fromComSlice(queue.automation, providers.items);
    }
}

fn enqueueProperty(gpa: std.mem.Allocator, platform: syscalls.Platform, registry: *elements.Registry,
    queue: *queued_events.QueuedEvents, old: NodeWrapper, new: NodeWrapper, id: bindings.PropertyId) ProviderError!void
{
    var previous = try propertyValue(old, gpa, id);
    defer previous.deinit(gpa);
    var current = try propertyValue(new, gpa, id);
    defer current.deinit(gpa);
    if (DecodedValue.equal(previous, current)) return;
    const slot = try registry.slotFor(platform, new.node.id());
    const change = try queue.beginProperty(slot, @enumFromInt(@intFromEnum(id)));
    change.old = try previous.toVariant(gpa, queue.automation);
    change.new = try current.toVariant(gpa, queue.automation);
}

fn nextControlled(cursor: *set_state.ControlsIterator) ProviderError!?NodeRef {
    // Every next consumes one schema relation entry; hidden nodes are skipped within that bound.
    while (try cursor.next()) |controlled| {
        if (try filters.filter(controlled) == .include) return controlled;
    }
    return null;
}

fn sameControlled(old: NodeRef, new: NodeRef) ProviderError!bool {
    var previous = set_state.controls(old);
    var current = set_state.controls(new);
    var equal = true;
    // Both cursors advance monotonically through their bounded relation slices.
    // Continue after the first difference so malformed old and new relations still report errors.
    while (previous.front < previous.back or current.front < current.back) {
        const before = try nextControlled(&previous);
        const after = try nextControlled(&current);
        if (before) |a| {
            if (after) |b| {
                if (a.id().toU128() != b.id().toU128()) equal = false;
            } else equal = false;
        } else if (after != null) equal = false;
    }
    return equal;
}

const State = struct {
    weak: context.WeakContext,
    node_id: ?FullNodeId,

    pub fn deinit(self: *State) void {
        self.weak.deinit();
    }
    fn resolve(self: State, lease: *context.ContextLease) ProviderError!NodeRef {
        const state = lease.state();
        const id = self.node_id orelse state.rootId();
        return state.nodeById(id) orelse error.ElementNotAvailable;
    }
    fn isRoot(self: State, lease: *context.ContextLease) bool {
        return if (self.node_id) |id| id.toU128() == lease.state().rootId().toU128() else false;
    }
};

/// COM object implementing all thirteen node interfaces. Use create to get its owned simple interface.
/// Final Release destroys the object and releases its weak context handle.
pub const PlatformNode = com.Object(State, .{
    com.Descriptor{ .Interface = bindings.IRawElementProviderSimple, .Iid = uia.IID_IRawElementProviderSimple },
    com.Descriptor{ .Interface = bindings.IRawElementProviderFragment, .Iid = uia.IID_IRawElementProviderFragment },
    com.Descriptor{ .Interface = bindings.IRawElementProviderFragmentRoot, .Iid = uia.IID_IRawElementProviderFragmentRoot },
    com.Descriptor{ .Interface = bindings.IToggleProvider, .Iid = uia.IID_IToggleProvider },
    com.Descriptor{ .Interface = bindings.IInvokeProvider, .Iid = uia.IID_IInvokeProvider },
    com.Descriptor{ .Interface = bindings.IValueProvider, .Iid = uia.IID_IValueProvider },
    com.Descriptor{ .Interface = bindings.IRangeValueProvider, .Iid = uia.IID_IRangeValueProvider },
    com.Descriptor{ .Interface = bindings.IScrollItemProvider, .Iid = uia.IID_IScrollItemProvider },
    com.Descriptor{ .Interface = bindings.ISelectionItemProvider, .Iid = uia.IID_ISelectionItemProvider },
    com.Descriptor{ .Interface = bindings.ISelectionProvider, .Iid = uia.IID_ISelectionProvider },
    com.Descriptor{ .Interface = bindings.ITextProvider, .Iid = uia.IID_ITextProvider },
    com.Descriptor{ .Interface = bindings.IExpandCollapseProvider, .Iid = uia.IID_IExpandCollapseProvider },
    com.Descriptor{ .Interface = bindings.IWindowProvider, .Iid = uia.IID_IWindowProvider },
});

/// Allocates one provider and consumes weak only on success. Null node_id tracks the current root.
/// The caller owns one COM reference, released through any supported interface's Release.
/// Construction never locks or borrows the tree, so registry construction can run under a lease.
pub fn create(gpa: std.mem.Allocator, weak: context.WeakContext, node_id: ?FullNodeId) ProviderError!*bindings.IRawElementProviderSimple {
    const object = try PlatformNode.create(gpa, .{
        &simple_vtable, &fragment_vtable, &root_vtable, &toggle_vtable, &invoke_vtable,
        &value_vtable, &range_value_vtable, &scroll_vtable, &selection_item_vtable,
        &selection_vtable, &text_vtable, &expand_vtable, &window_vtable,
    }, .{ .weak = weak, .node_id = node_id });
    return @ptrCast(@constCast(object.iface(0)));
}

fn objectFrom(comptime Interface: type, pointer: *const Interface) *PlatformNode {
    return PlatformNode.fromIface(Interface, @ptrCast(pointer));
}

fn status(failure: ProviderError) Hresult {
    return switch (failure) {
        error.OutOfMemory, error.ProviderLimitExceeded => errors.fromBits(0x8007000e),
        error.ElementNotAvailable, error.NoSuchNode, error.WindowUnavailable => errors.elementNotAvailable(),
        error.InvalidArgument, error.InvalidPosition, error.IndexOutOfRange, error.InvalidUtf8, error.InvalidUtf16,
        error.StringTooLong, error.ArrayTooLong, error.LocaleNameInvalid, error.WindowTitleTooLong,
        error.InteriorNul => errors.invalidArg(),
        error.BadVariantType => errors.fromBits(0x80020008),
        error.BadArrayIndex => errors.fromBits(0x8002000b),
        error.ArrayLocked => errors.fromBits(0x8002000d),
        error.NotImplemented => errors.notImplemented(),
        error.InvalidOperation => errors.invalidOperation(),
        else => errors.fail(),
    };
}

fn nativeHwnd(lease: *context.ContextLease) ProviderError!bindings.Hwnd {
    return @ptrCast(lease.hwnd() orelse return error.WindowUnavailable);
}

fn origin(lease: *context.ContextLease) ProviderError!schema.Point {
    return util.clientTopLeft(lease.automation(), try nativeHwnd(lease));
}

fn queryInterface(comptime Interface: type, provider: *bindings.IRawElementProviderSimple) ProviderError!*Interface {
    const unknown: *bindings.IUnknown = @ptrCast(provider);
    var result: *anyopaque = undefined;
    const iid = comptime PlatformNode.Descriptors[PlatformNode.indexOf(Interface).?].Iid;
    const hr = unknown.vtable.QueryInterface(unknown, iid, &result);
    _ = unknown.vtable.Release(unknown);
    if (hr.failed) return error.UnexpectedNativeFailure;
    return @ptrCast(@alignCast(result));
}

fn interfaceFor(comptime Interface: type, object: *PlatformNode) *Interface {
    const index = comptime PlatformNode.indexOf(Interface).?;
    _ = object.addRef();
    return @ptrCast(@constCast(object.iface(index)));
}

fn getter(comptime Interface: type, comptime T: type, comptime property_id: bindings.PropertyId)
    *const fn (*const Interface, ?*T) callconv(.winapi) Hresult
{
    return struct {
        fn get(pointer: *const Interface, out: ?*T) callconv(.winapi) Hresult {
            const result = out orelse return errors.invalidArg();
            result.* = std.mem.zeroes(T);
            const object = objectFrom(Interface, pointer);
            var lease = object.state.weak.lease() catch |err| return status(err);
            defer lease.deinit();
            const node = object.state.resolve(&lease) catch |err| return status(err);
            var value = propertyValue(.{ .node = node }, lease.allocator(), property_id) catch |err| return status(err);
            defer value.deinit(lease.allocator());
            if (T == ?bindings.Bstr) {
                result.* = util.utf8ToBstr(lease.automation(), value.value.text) catch |err| return status(err);
            } else if (T == f64) {
                result.* = value.value.double;
            } else if (T == bindings.Bool) {
                result.* = @intFromBool(value.value.boolean);
            } else {
                result.* = @enumFromInt(value.value.integer);
            }
            return errors.ok();
        }
    }.get;
}

const Simple = struct {
    fn options(_: *const bindings.IRawElementProviderSimple, out: ?*uia.ProviderOptions) callconv(.winapi) Hresult {
        const result = out orelse return errors.invalidArg();
        result.* = .ServerSideProvider;
        return errors.ok();
    }
    fn pattern(pointer: *const bindings.IRawElementProviderSimple, id: bindings.PatternId,
        out: ?*?*bindings.IUnknown) callconv(.winapi) Hresult
    {
        const result = out orelse return errors.invalidArg();
        result.* = null;
        const object = objectFrom(bindings.IRawElementProviderSimple, pointer);
        var lease = object.state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        const node = object.state.resolve(&lease) catch |err| return status(err);
        const supported = patternSupported(.{ .node = node }, id) catch |err| return status(err);
        if (!supported) return errors.ok();
        inline for (patterns) |entry| {
            if (id == entry.id) {
                _ = object.addRef();
                result.* = @ptrCast(@constCast(object.iface(entry.interface_index)));
                return errors.ok();
            }
        }
        return errors.ok();
    }
    fn property(pointer: *const bindings.IRawElementProviderSimple, id: bindings.PropertyId,
        out: ?*bindings.Variant) callconv(.winapi) Hresult
    {
        const result = out orelse return errors.invalidArg();
        result.* = std.mem.zeroes(bindings.Variant);
        const object = objectFrom(bindings.IRawElementProviderSimple, pointer);
        var lease = object.state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        const node = object.state.resolve(&lease) catch |err| return status(err);
        const gpa = lease.allocator();
        const api = lease.automation();
        for (simple_properties) |property_id| {
            if (id != property_id) continue;
            var decoded = propertyValue(.{ .node = node }, gpa, id) catch |err| return status(err);
            defer decoded.deinit(gpa);
            var value = decoded.toVariant(gpa, api) catch |err| return status(err);
            if (!value.isEmpty()) {
                result.* = value.take();
                return errors.ok();
            }
            break;
        }
        if (hierarchy.isRoot(node)) {
            if (id == .NamePropertyId) {
                const hwnd = nativeHwnd(&lease) catch |err| return status(err);
                lease.guard.releaseTreeGuard();
                const title = util.windowTitle(gpa, api, hwnd) catch |err| return status(err);
                if (title) |text| {
                    var value = util.VariantOwner.fromOwnedBstr(api, text);
                    result.* = value.take();
                }
                return errors.ok();
            }
            if (id == .NativeWindowHandlePropertyId) {
                const handle: usize = if (lease.hwnd()) |hwnd| @intFromPtr(hwnd) else 0;
                var value = util.VariantOwner.fromI32(api, @bitCast(@as(u32, @truncate(handle))));
                result.* = value.take();
                return errors.ok();
            }
        }
        switch (id) {
            .FrameworkIdPropertyId => {
                var value = util.VariantOwner.fromUtf8(api, lease.state().toolkitName()) catch |err| return status(err);
                result.* = value.take();
            },
            .ProviderDescriptionPropertyId => {
                const description = util.toolkitDescription(gpa, lease.state()) catch |err| return status(err);
                defer gpa.free(description);
                var value = util.VariantOwner.fromUtf16(api, description) catch |err| return status(err);
                result.* = value.take();
            },
            .ControllerForPropertyId => {
                var controls = set_state.controls(node);
                var providers: std.ArrayList(*bindings.IUnknown) = .empty;
                defer providers.deinit(gpa);
                defer for (providers.items) |provider| { _ = provider.vtable.Release(provider); };
                providers.ensureTotalCapacity(gpa, controls.ids.len) catch |err| return status(err);
                while (nextControlled(&controls) catch |err| return status(err)) |controlled| {
                    const provider = lease.provider(controlled.id()) catch |err| return status(err);
                    providers.appendAssumeCapacity(@ptrCast(provider));
                }
                var value = util.VariantOwner.fromComSlice(api, providers.items) catch |err| return status(err);
                result.* = value.take();
            },
            else => {},
        }
        return errors.ok();
    }
    fn host(pointer: *const bindings.IRawElementProviderSimple,
        out: ?*?*bindings.IRawElementProviderSimple) callconv(.winapi) Hresult
    {
        const result = out orelse return errors.invalidArg();
        result.* = null;
        const object = objectFrom(bindings.IRawElementProviderSimple, pointer);
        var lease = object.state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        _ = object.state.resolve(&lease) catch |err| return status(err);
        if (!object.state.isRoot(&lease)) return errors.ok();
        const hwnd = nativeHwnd(&lease) catch |err| return status(err);
        const api = lease.automation();
        // UIA may reenter this provider. Keep the owner pin, but no tree borrow.
        lease.guard.releaseTreeGuard();
        return api.host_provider_from_hwnd(api.context, hwnd, result);
    }
};

const simple_vtable: bindings.IRawElementProviderSimple.VTable = .{
    .base = PlatformNode.baseVTable(0),
    .get_ProviderOptions = Simple.options,
    .GetPatternProvider = Simple.pattern,
    .GetPropertyValue = Simple.property,
    .get_HostRawElementProvider = Simple.host,
};

const ActionMode = union(enum) {
    ordinary: schema.Action,
    scroll,
    expanded: bool,
    selected: bool,
};

fn perform(object: *PlatformNode, mode: ActionMode, data: ?schema.ActionData) Hresult {
    const gpa = object.state.weak.control.gpa;
    var owned_data = data;
    defer if (owned_data) |*payload| schema.actionDataDeinit(gpa, payload);
    var lease = object.state.weak.lease() catch |err| return status(err);
    defer lease.deinit();
    if (lease.isPlaceholder()) return errors.elementNotEnabled();
    const node = object.state.resolve(&lease) catch |err| return status(err);
    if (mode != .scroll and properties.isDisabled(node)) return errors.elementNotEnabled();
    const action: schema.Action = switch (mode) {
        .ordinary => |action| action,
        .scroll => .scroll_into_view,
        .expanded => |expanded| blk: {
            const current = schema.enums.isExpanded(&node.data().properties) orelse return errors.invalidOperation();
            if (current == expanded) return errors.invalidOperation();
            break :blk if (expanded) .expand else .collapse;
        },
        .selected => |selected| blk: {
            if (selected == (NodeWrapper{ .node = node }).isSelected()) return errors.ok();
            break :blk .click;
        },
    };
    const located = properties.locate(node) orelse return errors.elementNotAvailable();
    const request = schema.ActionRequest{
        .action = action,
        .target_tree = located.tree_id,
        .target_node = located.local_id,
        .data = owned_data,
    };
    owned_data = null;
    lease.dispatch(request) catch |err| return status(err);
    return errors.ok();
}

fn actionThunk(comptime Interface: type, comptime mode: ActionMode)
    *const fn (*const Interface) callconv(.winapi) Hresult
{
    return struct {
        fn action(pointer: *const Interface) callconv(.winapi) Hresult {
            return perform(objectFrom(Interface, pointer), mode, null);
        }
    }.action;
}

const Fragment = struct {
    fn navigate(pointer: *const bindings.IRawElementProviderFragment, direction: bindings.NavigateDirection,
        out: ?*?*bindings.IRawElementProviderFragment) callconv(.winapi) Hresult
    {
        const result = out orelse return errors.invalidArg();
        result.* = null;
        if (@intFromEnum(direction) < 0 or
            @intFromEnum(direction) > @intFromEnum(bindings.NavigateDirection.LastChild)) return errors.invalidArg();
        const object = objectFrom(bindings.IRawElementProviderFragment, pointer);
        var lease = object.state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        const node = object.state.resolve(&lease) catch |err| return status(err);
        const target = navigateNode(node, direction) catch |err| return status(err);
        if (target) |found| {
            const provider = lease.provider(found.id()) catch |err| return status(err);
            result.* = queryInterface(bindings.IRawElementProviderFragment, provider) catch |err| return status(err);
        }
        return errors.ok();
    }
    fn runtimeId(pointer: *const bindings.IRawElementProviderFragment,
        out: ?*?*bindings.SafeArray) callconv(.winapi) Hresult
    {
        const result = out orelse return errors.invalidArg();
        result.* = null;
        const object = objectFrom(bindings.IRawElementProviderFragment, pointer);
        const id = object.state.node_id orelse return errors.notImplemented();
        const words = runtimeIdFromNodeId(id);
        var array = util.safeArrayFromI32Slice(object.state.weak.control.automation, &words) catch |err| return status(err);
        result.* = array.take();
        return errors.ok();
    }
    fn bounds(pointer: *const bindings.IRawElementProviderFragment, out: ?*bindings.UiaRect) callconv(.winapi) Hresult {
        const result = out orelse return errors.invalidArg();
        result.* = std.mem.zeroes(bindings.UiaRect);
        const object = objectFrom(bindings.IRawElementProviderFragment, pointer);
        var lease = object.state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        const node = object.state.resolve(&lease) catch |err| return status(err);
        const box = geometry.boundingBox(node) catch |err| return status(err);
        if (box) |rect| {
            const offset = origin(&lease) catch |err| return status(err);
            result.* = .{
                .left = rect.x0 + offset.x, .top = rect.y0 + offset.y,
                .width = rect.x1 - rect.x0, .height = rect.y1 - rect.y0,
            };
        }
        return errors.ok();
    }
    fn embedded(_: *const bindings.IRawElementProviderFragment, out: ?*?*bindings.SafeArray) callconv(.winapi) Hresult {
        const result = out orelse return errors.invalidArg();
        result.* = null;
        return errors.ok();
    }
    fn root(pointer: *const bindings.IRawElementProviderFragment,
        out: ?*?*bindings.IRawElementProviderFragmentRoot) callconv(.winapi) Hresult
    {
        const result = out orelse return errors.invalidArg();
        result.* = null;
        const object = objectFrom(bindings.IRawElementProviderFragment, pointer);
        var lease = object.state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        _ = object.state.resolve(&lease) catch |err| return status(err);
        if (object.state.isRoot(&lease)) {
            result.* = interfaceFor(bindings.IRawElementProviderFragmentRoot, object);
        } else {
            const provider = lease.provider(lease.state().rootId()) catch |err| return status(err);
            result.* = queryInterface(bindings.IRawElementProviderFragmentRoot, provider) catch |err| return status(err);
        }
        return errors.ok();
    }
};

fn rootFilter(_: ?*anyopaque, node: NodeRef) consumer.tree_state.QueryError!consumer.filter.FilterResult {
    return filters.filterWithRootException(node);
}

fn navigateNode(node: NodeRef, direction: bindings.NavigateDirection) ProviderError!?NodeRef {
    return switch (direction) {
        .Parent => hierarchy.filteredParent(node, .{ .context = null, .filter = rootFilter }),
        .NextSibling => blk: {
            var cursor = try hierarchy.followingFilteredSiblings(node, filters.filter_fn);
            break :blk try cursor.next();
        },
        .PreviousSibling => blk: {
            var cursor = try hierarchy.precedingFilteredSiblings(node, filters.filter_fn);
            break :blk try cursor.next();
        },
        .FirstChild => blk: {
            var cursor = try hierarchy.filteredChildren(node, filters.filter_fn);
            break :blk try cursor.next();
        },
        .LastChild => blk: {
            var cursor = try hierarchy.filteredChildren(node, filters.filter_fn);
            break :blk try cursor.nextBack();
        },
    };
}

const Root = struct {
    fn fromPoint(pointer: *const bindings.IRawElementProviderFragmentRoot, x: f64, y: f64,
        out: ?*?*bindings.IRawElementProviderFragment) callconv(.winapi) Hresult
    {
        const result = out orelse return errors.invalidArg();
        result.* = null;
        const object = objectFrom(bindings.IRawElementProviderFragmentRoot, pointer);
        var lease = object.state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        const node = object.state.resolve(&lease) catch |err| return status(err);
        const point = localPoint(&lease, node, .{ .x = x, .y = y }) catch |err| return status(err);
        const target = geometry.nodeAtPoint(lease.allocator(), node, point, filters.filter_fn) catch |err| return status(err);
        if (target) |found| {
            const provider = lease.provider(found.id()) catch |err| return status(err);
            result.* = queryInterface(bindings.IRawElementProviderFragment, provider) catch |err| return status(err);
        }
        return errors.ok();
    }
    fn focus(pointer: *const bindings.IRawElementProviderFragmentRoot,
        out: ?*?*bindings.IRawElementProviderFragment) callconv(.winapi) Hresult
    {
        const result = out orelse return errors.invalidArg();
        result.* = null;
        const object = objectFrom(bindings.IRawElementProviderFragmentRoot, pointer);
        var lease = object.state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        _ = object.state.resolve(&lease) catch |err| return status(err);
        if (lease.state().focus()) |node| {
            const self_id = object.state.node_id orelse lease.state().rootId();
            if (self_id.toU128() != node.id().toU128()) {
                const provider = lease.provider(node.id()) catch |err| return status(err);
                result.* = queryInterface(bindings.IRawElementProviderFragment, provider) catch |err| return status(err);
            }
        }
        return errors.ok();
    }
};

fn localPoint(lease: *context.ContextLease, node: NodeRef, point: schema.Point) ProviderError!schema.Point {
    const offset = try origin(lease);
    const transform = try geometry.transform(node);
    const affine = @import("../../schema/geometry/affine.zig");
    return affine.mulPoint(affine.inverse(transform), .{ .x = point.x - offset.x, .y = point.y - offset.y });
}

const Value = struct {
    fn set(pointer: *const bindings.IValueProvider, value: ?[*:0]const u16) callconv(.winapi) Hresult {
        const input = value orelse return errors.invalidArg();
        const object = objectFrom(bindings.IValueProvider, pointer);
        var lease = object.state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        if (lease.isPlaceholder()) return errors.elementNotEnabled();
        const node = object.state.resolve(&lease) catch |err| return status(err);
        if (properties.isDisabled(node)) return errors.elementNotEnabled();
        const located = properties.locate(node) orelse return errors.elementNotAvailable();
        var count: usize = 0;
        while (count <= util.bstr_units_max) : (count += 1) {
            if (input[count] == 0) break;
        }
        if (count > util.bstr_units_max) return errors.invalidArg();
        const decoded = util.utf16ToUtf8(lease.allocator(), input[0..count]) catch |err| return status(err);
        lease.dispatch(.{
            .action = .set_value, .target_tree = located.tree_id,
            .target_node = located.local_id, .data = .{ .value = decoded },
        }) catch |err| return status(err);
        return errors.ok();
    }
};
const RangeValue = struct {
    fn set(pointer: *const bindings.IRangeValueProvider, value: f64) callconv(.winapi) Hresult {
        return perform(objectFrom(bindings.IRangeValueProvider, pointer), .{ .ordinary = .set_value },
            .{ .numeric_value = value });
    }
};

const fragment_vtable: bindings.IRawElementProviderFragment.VTable = .{
    .base = PlatformNode.baseVTable(1), .Navigate = Fragment.navigate,
    .GetRuntimeId = Fragment.runtimeId, .get_BoundingRectangle = Fragment.bounds,
    .GetEmbeddedFragmentRoots = Fragment.embedded,
    .SetFocus = actionThunk(bindings.IRawElementProviderFragment, .{ .ordinary = .focus }),
    .get_FragmentRoot = Fragment.root,
};
const root_vtable: bindings.IRawElementProviderFragmentRoot.VTable = .{
    .base = PlatformNode.baseVTable(2), .ElementProviderFromPoint = Root.fromPoint, .GetFocus = Root.focus,
};
const toggle_vtable: bindings.IToggleProvider.VTable = .{
    .base = PlatformNode.baseVTable(3),
    .Toggle = actionThunk(bindings.IToggleProvider, .{ .ordinary = .click }),
    .get_ToggleState = getter(bindings.IToggleProvider, bindings.ToggleState, .ToggleToggleStatePropertyId),
};
const invoke_vtable: bindings.IInvokeProvider.VTable = .{
    .base = PlatformNode.baseVTable(4),
    .Invoke = actionThunk(bindings.IInvokeProvider, .{ .ordinary = .click }),
};
const value_vtable: bindings.IValueProvider.VTable = .{
    .base = PlatformNode.baseVTable(5), .SetValue = Value.set,
    .get_Value = getter(bindings.IValueProvider, ?bindings.Bstr, .ValueValuePropertyId),
    .get_IsReadOnly = getter(bindings.IValueProvider, bindings.Bool, .ValueIsReadOnlyPropertyId),
};
const range_value_vtable: bindings.IRangeValueProvider.VTable = .{
    .base = PlatformNode.baseVTable(6), .SetValue = RangeValue.set,
    .get_Value = getter(bindings.IRangeValueProvider, f64, .RangeValueValuePropertyId),
    .get_IsReadOnly = getter(bindings.IRangeValueProvider, bindings.Bool, .RangeValueIsReadOnlyPropertyId),
    .get_Maximum = getter(bindings.IRangeValueProvider, f64, .RangeValueMaximumPropertyId),
    .get_Minimum = getter(bindings.IRangeValueProvider, f64, .RangeValueMinimumPropertyId),
    .get_LargeChange = getter(bindings.IRangeValueProvider, f64, .RangeValueLargeChangePropertyId),
    .get_SmallChange = getter(bindings.IRangeValueProvider, f64, .RangeValueSmallChangePropertyId),
};
const scroll_vtable: bindings.IScrollItemProvider.VTable = .{
    .base = PlatformNode.baseVTable(7), .ScrollIntoView = actionThunk(bindings.IScrollItemProvider, .scroll),
};

const SelectionItem = struct {
    fn container(pointer: *const bindings.ISelectionItemProvider,
        out: ?*?*bindings.IRawElementProviderSimple) callconv(.winapi) Hresult
    {
        const result = out orelse return errors.invalidArg();
        result.* = null;
        const object = objectFrom(bindings.ISelectionItemProvider, pointer);
        var lease = object.state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        const node = object.state.resolve(&lease) catch |err| return status(err);
        const found = containers.selectionContainer(node, filters.filter_fn) catch |err| return status(err);
        const selection_container = found orelse return errors.fail();
        result.* = lease.provider(selection_container.id()) catch |err| return status(err);
        return errors.ok();
    }
};

const Selection = struct {
    fn selected(pointer: *const bindings.ISelectionProvider,
        out: ?*?*bindings.SafeArray) callconv(.winapi) Hresult
    {
        const result = out orelse return errors.invalidArg();
        result.* = null;
        const object = objectFrom(bindings.ISelectionProvider, pointer);
        var lease = object.state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        const node = object.state.resolve(&lease) catch |err| return status(err);
        const gpa = lease.allocator();
        var items = containers.items(gpa, node, filters.filter_fn) catch |err| return status(err);
        defer items.deinit(gpa);
        var providers: std.ArrayList(*bindings.IUnknown) = .empty;
        defer providers.deinit(gpa);
        defer for (providers.items) |provider| { _ = provider.vtable.Release(provider); };
        providers.ensureTotalCapacity(gpa, items.items.len) catch |err| return status(err);
        for (items.items) |item| {
            // Upstream tests raw IsSelected, not the radio-toggle-derived wrapper value.
            if (properties.isSelected(item) != true) continue;
            const provider = lease.provider(item.id()) catch |err| return status(err);
            providers.appendAssumeCapacity(@ptrCast(provider));
        }
        var array = util.safeArrayFromComSlice(lease.automation(), providers.items) catch |err| return status(err);
        result.* = array.take();
        return errors.ok();
    }
};

fn textNode(object: *PlatformNode, lease: *context.ContextLease) ProviderError!NodeRef {
    const node = try object.state.resolve(lease);
    if (!try text_query.supportsTextRanges(node)) return error.InvalidOperation;
    return node;
}

fn rangeFor(lease: *context.ContextLease, range: consumer.text.range.Range) ProviderError!*bindings.ITextRangeProvider {
    var weak_range = try consumer.text.range.downgrade(lease.allocator(), range);
    errdefer weak_range.deinit();
    return lease.range(weak_range);
}

const Text = struct {
    fn selection(pointer: *const bindings.ITextProvider, out: ?*?*bindings.SafeArray) callconv(.winapi) Hresult {
        const result = out orelse return errors.invalidArg();
        result.* = null;
        const object = objectFrom(bindings.ITextProvider, pointer);
        var lease = object.state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        const node = textNode(object, &lease) catch |err| return status(err);
        const selected = text_query.textSelection(lease.allocator(), node) catch |err| return status(err);
        if (selected) |range| {
            const provider = rangeFor(&lease, range) catch |err| return status(err);
            const unknown: *bindings.IUnknown = @ptrCast(provider);
            defer _ = unknown.vtable.Release(unknown);
            var array = util.safeArrayFromComSlice(lease.automation(), &.{unknown}) catch |err| return status(err);
            result.* = array.take();
        }
        return errors.ok();
    }
    fn visible(_: *const bindings.ITextProvider, out: ?*?*bindings.SafeArray) callconv(.winapi) Hresult {
        const result = out orelse return errors.invalidArg();
        result.* = null;
        return errors.ok();
    }
    fn fromChild(_: *const bindings.ITextProvider, child: ?*bindings.IRawElementProviderSimple,
        out: ?*?*bindings.ITextRangeProvider) callconv(.winapi) Hresult
    {
        const result = out orelse return errors.invalidArg();
        result.* = null;
        if (child == null) return errors.invalidArg();
        return errors.notImplemented();
    }
    fn fromPoint(pointer: *const bindings.ITextProvider, point: bindings.UiaPoint,
        out: ?*?*bindings.ITextRangeProvider) callconv(.winapi) Hresult
    {
        const result = out orelse return errors.invalidArg();
        result.* = null;
        const object = objectFrom(bindings.ITextProvider, pointer);
        var lease = object.state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        const node = textNode(object, &lease) catch |err| return status(err);
        const local = localPoint(&lease, node, .{ .x = point.x, .y = point.y }) catch |err| return status(err);
        const position = text_query.textPositionAtPoint(lease.allocator(), node, local) catch |err| return status(err);
        const range = consumer.text.range.toDegenerateRange(lease.allocator(), position) catch |err| return status(err);
        result.* = rangeFor(&lease, range) catch |err| return status(err);
        return errors.ok();
    }
    fn document(pointer: *const bindings.ITextProvider,
        out: ?*?*bindings.ITextRangeProvider) callconv(.winapi) Hresult
    {
        const result = out orelse return errors.invalidArg();
        result.* = null;
        const object = objectFrom(bindings.ITextProvider, pointer);
        var lease = object.state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        const node = textNode(object, &lease) catch |err| return status(err);
        const range = text_query.documentRange(lease.allocator(), node) catch |err| return status(err);
        result.* = rangeFor(&lease, range) catch |err| return status(err);
        return errors.ok();
    }
    fn supported(pointer: *const bindings.ITextProvider,
        out: ?*uia.SupportedTextSelection) callconv(.winapi) Hresult
    {
        const result = out orelse return errors.invalidArg();
        result.* = .None;
        const object = objectFrom(bindings.ITextProvider, pointer);
        var lease = object.state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        const node = textNode(object, &lease) catch |err| return status(err);
        result.* = if (text_query.hasTextSelection(node)) .Single else .None;
        return errors.ok();
    }
};

const Window = struct {
    fn visual(_: *const bindings.IWindowProvider, state: uia.WindowVisualState) callconv(.winapi) Hresult {
        if (@intFromEnum(state) < 0 or
            @intFromEnum(state) > @intFromEnum(uia.WindowVisualState.Minimized)) return errors.invalidArg();
        return errors.invalidOperation();
    }
    fn close(_: *const bindings.IWindowProvider) callconv(.winapi) Hresult {
        return errors.notSupported();
    }
    fn idle(_: *const bindings.IWindowProvider, _: i32, out: ?*bindings.Bool) callconv(.winapi) Hresult {
        const result = out orelse return errors.invalidArg();
        result.* = 0;
        return errors.notSupported();
    }
    fn unsupported(comptime T: type) *const fn (*const bindings.IWindowProvider, ?*T) callconv(.winapi) Hresult {
        return struct {
            fn get(_: *const bindings.IWindowProvider, out: ?*T) callconv(.winapi) Hresult {
                const result = out orelse return errors.invalidArg();
                result.* = std.mem.zeroes(T);
                return errors.notSupported();
            }
        }.get;
    }
    fn interaction(_: *const bindings.IWindowProvider, out: ?*uia.WindowInteractionState) callconv(.winapi) Hresult {
        const result = out orelse return errors.invalidArg();
        result.* = .ReadyForUserInteraction;
        return errors.ok();
    }
};

const selection_item_vtable: bindings.ISelectionItemProvider.VTable = .{
    .base = PlatformNode.baseVTable(8),
    .Select = actionThunk(bindings.ISelectionItemProvider, .{ .selected = true }),
    .AddToSelection = actionThunk(bindings.ISelectionItemProvider, .{ .selected = true }),
    .RemoveFromSelection = actionThunk(bindings.ISelectionItemProvider, .{ .selected = false }),
    .get_IsSelected = getter(bindings.ISelectionItemProvider, bindings.Bool, .SelectionItemIsSelectedPropertyId),
    .get_SelectionContainer = SelectionItem.container,
};
const selection_vtable: bindings.ISelectionProvider.VTable = .{
    .base = PlatformNode.baseVTable(9), .GetSelection = Selection.selected,
    .get_CanSelectMultiple = getter(bindings.ISelectionProvider, bindings.Bool, .SelectionCanSelectMultiplePropertyId),
    .get_IsSelectionRequired = getter(bindings.ISelectionProvider, bindings.Bool, .SelectionIsSelectionRequiredPropertyId),
};
const text_vtable: bindings.ITextProvider.VTable = .{
    .base = PlatformNode.baseVTable(10), .GetSelection = Text.selection,
    .GetVisibleRanges = Text.visible, .RangeFromChild = Text.fromChild,
    .RangeFromPoint = Text.fromPoint, .get_DocumentRange = Text.document,
    .get_SupportedTextSelection = Text.supported,
};
const expand_vtable: bindings.IExpandCollapseProvider.VTable = .{
    .base = PlatformNode.baseVTable(11),
    .Expand = actionThunk(bindings.IExpandCollapseProvider, .{ .expanded = true }),
    .Collapse = actionThunk(bindings.IExpandCollapseProvider, .{ .expanded = false }),
    .get_ExpandCollapseState = getter(bindings.IExpandCollapseProvider, bindings.ExpandCollapseState, .ExpandCollapseExpandCollapseStatePropertyId),
};
const window_vtable: bindings.IWindowProvider.VTable = .{
    .base = PlatformNode.baseVTable(12), .SetVisualState = Window.visual, .Close = Window.close,
    .WaitForInputIdle = Window.idle,
    .get_CanMaximize = Window.unsupported(bindings.Bool),
    .get_CanMinimize = Window.unsupported(bindings.Bool),
    .get_IsModal = getter(bindings.IWindowProvider, bindings.Bool, .WindowIsModalPropertyId),
    .get_WindowVisualState = Window.unsupported(uia.WindowVisualState),
    .get_WindowInteractionState = Window.interaction,
    .get_IsTopmost = Window.unsupported(bindings.Bool),
};

test "node runtime ID preserves both identifier halves in five signed words" {
    const id = FullNodeId.init(.{ .value = 0xfedcba9876543210 }, .init(0x89abcdef));
    try std.testing.expectEqualSlices(i32, &.{ 3, @bitCast(@as(u32, 0xfedcba98)), 0x76543210, 0, @bitCast(@as(u32, 0x89abcdef)) }, &runtimeIdFromNodeId(id));
}

test "node selection and toggle patterns distinguish radio mixed and selectable grid cells" {
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(std.testing.allocator);
    const id = FullNodeId.init(.{ .value = 1 }, .init(0));
    try state.nodes.put(std.testing.allocator, id, .{ .parent_and_index = null, .data = schema.Node.init(std.testing.allocator, .radio_button) });
    const data = &state.nodes.getPtr(id).?.data;
    try schema.enums.setToggled(&data.properties, .mixed);
    const wrapper = NodeWrapper{ .node = state.nodeById(id).? };
    try std.testing.expect(!wrapper.isSelectionItemPatternSupported());
    try std.testing.expect(wrapper.isTogglePatternSupported());
    try schema.enums.setToggled(&data.properties, .true_);
    try std.testing.expect(wrapper.isSelectionItemPatternSupported());
    try std.testing.expect(wrapper.isSelected());
    try std.testing.expect(!wrapper.isTogglePatternSupported());
    data.setRole(.grid_cell);
    try std.testing.expect(wrapper.isSelectionItemPatternSupported());
    try std.testing.expect(!wrapper.isSelected());
}

test "node numeric range defaults and level conversion match UIA" {
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(std.testing.allocator);
    const id = FullNodeId.init(.{ .value = 1 }, .init(0));
    try state.nodes.put(std.testing.allocator, id, .{ .parent_and_index = null, .data = schema.Node.init(std.testing.allocator, .slider) });
    const data = &state.nodes.getPtr(id).?.data;
    try schema.numbers.setNumericValue(&data.properties, 7.25);
    try schema.numbers.setNumericValueStep(&data.properties, 0.5);
    try schema.numbers.setLevel(&data.properties, 2);
    const wrapper = NodeWrapper{ .node = state.nodeById(id).? };
    try std.testing.expect(wrapper.isRangeValuePatternSupported());
    try std.testing.expectEqual(@as(f64, 7.25), wrapper.numericValue());
    try std.testing.expectEqual(@as(f64, 0), wrapper.minNumericValue());
    try std.testing.expectEqual(@as(f64, 0.5), wrapper.numericValueJump());
    try std.testing.expectEqual(@as(?i32, 3), wrapper.level());
    try schema.numbers.setLevel(&data.properties, std.math.maxInt(usize));
    try std.testing.expectEqual(@as(?i32, null), wrapper.level());
    try schema.numbers.setPositionInSet(&data.properties, 0);
    try std.testing.expectEqual(@as(?i32, 1), wrapper.positionInSet());
    try schema.numbers.setPositionInSet(&data.properties, std.math.maxInt(i32) - 1);
    try std.testing.expectEqual(@as(?i32, std.math.maxInt(i32)), wrapper.positionInSet());
    try schema.numbers.setPositionInSet(&data.properties, std.math.maxInt(i32));
    try std.testing.expectEqual(@as(?i32, null), wrapper.positionInSet());
}

test "node COM queries transfer values and runtime identity survives removal and close" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    const util_test = @import("util.zig");
    const adapter_test = @import("adapter.zig");
    const syscall_test = @import("syscalls.zig");
    var runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer runtime.deinit();
    var abi = util_test.AutomationTestAbi.init(std.testing.allocator);
    const api = abi.api();
    const owner = try adapter_test.WindowsAdapter.create(std.testing.allocator, .{
        .io = runtime.io(),
        .platform = syscall_test.unavailablePlatform(),
        .factory = .{
            .create_node = create,
            .create_range = @import("text.zig").create,
            .enqueue_properties = enqueuePropertyChanges,
        },
        .automation = &api,
        .hwnd = null,
        .is_window_focused = true,
        .action_sink = .{ .native = .{ .callback = NodeTestActions.receive, .userdata = null } },
    });
    var owned = true;
    defer if (owned) owner.deinit();
    var update: schema.TreeUpdate = .{};
    var root = schema.Node.init(std.testing.allocator, .window);
    try schema.strings.setLabel(&root.properties, "Root");
    try schema.ids_props.setChildren(&root.properties, &.{.{ .value = 2 }});
    var child = schema.Node.init(std.testing.allocator, .text_input);
    try schema.strings.setLabel(&child.properties, "A\x00B");
    try schema.strings.setValue(&child.properties, "é");
    try update.pushNode(std.testing.allocator, .{ .value = 1 }, root);
    try update.pushNode(std.testing.allocator, .{ .value = 2 }, child);
    update.tree = schema.TreeInfo.init(.{ .value = 1 });
    update.focus = .{ .value = 2 };
    owner.state = .{ .active = try consumer.tree.Tree.init(std.testing.allocator, update, true) };
    const id = FullNodeId.init(.{ .value = 2 }, .init(0));
    const provider = try create(std.testing.allocator, owner.context.weak(), id);
    const unknown: *bindings.IUnknown = @ptrCast(provider);
    defer _ = unknown.Release();
    var value: bindings.Variant = undefined;
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(provider.GetPropertyValue(bindings.uia.UIA_NamePropertyId, &value))));
    try std.testing.expectEqual(@as(u16, 8), util_test.variantType(&value));
    try std.testing.expectEqualSlices(u16, &.{ 65, 0, 66 }, abi.stringUnits(value.Anonymous.Anonymous.Anonymous.bstrVal.?));
    try util_test.checkAutomationStatus(api.variant_clear(api.context, &value));
    var pattern: ?*bindings.IUnknown = null;
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(provider.GetPatternProvider(bindings.uia.UIA_ValuePatternId, &pattern))));
    const value_provider: *bindings.IValueProvider = @ptrCast(pattern.?);
    var returned: ?bindings.Bstr = null;
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(value_provider.get_Value(&returned))));
    try std.testing.expectEqualSlices(u16, &.{0xe9}, abi.stringUnits(returned.?));
    api.free_string(api.context, returned.?);
    _ = pattern.?.Release();
    var fragment_raw: *anyopaque = undefined;
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(unknown.QueryInterface(bindings.uia.IID_IRawElementProviderFragment, &fragment_raw))));
    const fragment: *bindings.IRawElementProviderFragment = @ptrCast(@alignCast(fragment_raw));
    defer _ = @as(*bindings.IUnknown, @ptrCast(fragment)).Release();
    const removed = owner.tree().?.state.nodes.fetchSwapRemove(id).?;
    var removed_node = removed.value.data;
    removed_node.deinit();
    try std.testing.expectEqual(@as(u32, bindings.uia.UIA_E_ELEMENTNOTAVAILABLE), @as(u32, @bitCast(provider.GetPropertyValue(bindings.uia.UIA_NamePropertyId, &value))));
    owner.deinit();
    owned = false;
    var runtime_id: ?*bindings.SafeArray = null;
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(fragment.GetRuntimeId(&runtime_id))));
    try std.testing.expectEqualSlices(i32, &.{ 3, 0, 2, 0, 0 }, abi.array(runtime_id.?).ints);
    try util_test.checkAutomationStatus(api.array_destroy(api.context, runtime_id.?));
    try std.testing.expectEqual(@as(u32, bindings.uia.UIA_E_ELEMENTNOTAVAILABLE), @as(u32, @bitCast(provider.GetPropertyValue(bindings.uia.UIA_NamePropertyId, &value))));
    try std.testing.expectEqual(@as(u32, 0), abi.live_strings);
    try std.testing.expectEqual(@as(u32, 0), abi.live_arrays);
}

const NodeTestActions = struct {
    weak: ?@import("context.zig").WeakContext = null,
    calls: usize = 0,
    action: ?schema.Action = null,
    target: u64 = 0,
    numeric: f64 = 0,
    text: [32]u8 = undefined,
    text_len: usize = 0,

    fn receive(request: *const schema.ActionRequest, userdata: ?*anyopaque) void {
        if (userdata) |raw| {
            const self: *NodeTestActions = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.action = request.action;
            self.target = request.target_node.value;
            if (request.data) |payload| {
                if (payload == .numeric_value) {
                    self.numeric = payload.numeric_value;
                }
                if (payload == .value) {
                    std.debug.assert(payload.value.len <= self.text.len);
                    self.text_len = payload.value.len;
                    @memcpy(self.text[0..self.text_len], payload.value);
                }
            }
            // A callback lease proves that dispatch released the read guard.
            if (self.weak) |weak| {
                var lease = weak.lease() catch @panic("Callback could not reenter the context.");
                lease.deinit();
            }
        }
    }
};

fn testOwner(io: std.Io, api: *const util.AutomationApi, actions: *NodeTestActions,
    update: schema.TreeUpdate) !*@import("adapter.zig").WindowsAdapter
{
    const adapter = @import("adapter.zig");
    const owner = try adapter.WindowsAdapter.create(std.testing.allocator, .{
        .io = io, .platform = syscalls.unavailablePlatform(),
        .factory = .{ .create_node = create, .create_range = @import("text.zig").create,
            .enqueue_properties = enqueuePropertyChanges },
        .automation = api, .hwnd = null, .is_window_focused = true,
        .action_sink = .{ .native = .{ .callback = NodeTestActions.receive, .userdata = actions } },
    });
    errdefer owner.deinit();
    owner.state = .{ .active = try consumer.tree.Tree.init(std.testing.allocator, update, true) };
    actions.weak = owner.context.weak();
    return owner;
}

fn testProvider(owner: *@import("adapter.zig").WindowsAdapter, id: u64) !*bindings.IRawElementProviderSimple {
    var weak = owner.context.weak();
    errdefer weak.deinit();
    return create(std.testing.allocator, weak, FullNodeId.init(.{ .value = id }, .init(0)));
}

fn testRelease(interface: anytype) void {
    const unknown: *bindings.IUnknown = @ptrCast(interface);
    _ = unknown.vtable.Release(unknown);
}

fn testInterface(comptime Interface: type, provider: *bindings.IRawElementProviderSimple) !*Interface {
    const unknown: *bindings.IUnknown = @ptrCast(provider);
    var raw: *anyopaque = undefined;
    const iid = comptime PlatformNode.Descriptors[PlatformNode.indexOf(Interface).?].Iid;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(unknown.vtable.QueryInterface(unknown, iid, &raw)));
    return @ptrCast(@alignCast(raw));
}

test "node real COM scalar queries actions and disabled scroll preserve pinned behavior" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var runtime = std.Io.Threaded.init(gpa, .{});
    defer runtime.deinit();
    var abi = util.AutomationTestAbi.init(gpa);
    const api = abi.api();
    var actions: NodeTestActions = .{};
    var update: schema.TreeUpdate = .{};
    var root = schema.Node.init(gpa, .window);
    try schema.ids_props.setChildren(&root.properties, &.{ .{ .value = 2 }, .{ .value = 5 }, .{ .value = 4 } });
    var slider = schema.Node.init(gpa, .slider);
    try schema.numbers.setNumericValue(&slider.properties, 7.25);
    try schema.numbers.setMinNumericValue(&slider.properties, -2);
    try schema.numbers.setMaxNumericValue(&slider.properties, 12);
    try schema.numbers.setNumericValueStep(&slider.properties, 0.5);
    var option = schema.Node.init(gpa, .list_box_option);
    try schema.enums.setSelected(&option.properties, true);
    var expanded = schema.Node.init(gpa, .disclosure_triangle);
    try schema.enums.setExpanded(&expanded.properties, false);
    try update.pushNode(gpa, .{ .value = 1 }, root);
    try update.pushNode(gpa, .{ .value = 2 }, slider);
    try update.pushNode(gpa, .{ .value = 3 }, option);
    try update.pushNode(gpa, .{ .value = 4 }, expanded);
    var list = schema.Node.init(gpa, .list_box);
    try schema.ids_props.setChildren(&list.properties, &.{.{ .value = 3 }});
    try update.pushNode(gpa, .{ .value = 5 }, list);
    update.tree = schema.TreeInfo.init(.{ .value = 1 });
    update.focus = .{ .value = 2 };
    const owner = try testOwner(runtime.io(), &api, &actions, update);
    defer owner.deinit();
    defer actions.weak.?.deinit();
    const provider = try testProvider(owner, 2);
    defer testRelease(provider);
    var direct: bindings.Variant = undefined;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(provider.GetPropertyValue(.RangeValueValuePropertyId, &direct)));
    try std.testing.expectEqual(@as(u16, 0), util.variantType(&direct));
    const range = try testInterface(bindings.IRangeValueProvider, provider);
    defer testRelease(range);
    var number: f64 = 0;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(range.get_Value(&number)));
    try std.testing.expectEqual(@as(f64, 7.25), number);
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(range.get_Minimum(&number)));
    try std.testing.expectEqual(@as(f64, -2), number);
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(range.get_Maximum(&number)));
    try std.testing.expectEqual(@as(f64, 12), number);
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(range.get_LargeChange(&number)));
    try std.testing.expectEqual(@as(f64, 0.5), number);
    try std.testing.expectEqual(errors.toBits(errors.invalidArg()), errors.toBits(range.get_Value(null)));
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(range.SetValue(9.5)));
    try std.testing.expectEqual(@as(?schema.Action, .set_value), actions.action);
    try std.testing.expectEqual(@as(f64, 9.5), actions.numeric);
    try std.testing.expectEqual(@as(u64, 2), actions.target);
    const item_provider = try testProvider(owner, 3);
    defer testRelease(item_provider);
    const item = try testInterface(bindings.ISelectionItemProvider, item_provider);
    defer testRelease(item);
    var container: ?*bindings.IRawElementProviderSimple = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(item.get_SelectionContainer(&container)));
    defer testRelease(container.?);
    const selection = try testInterface(bindings.ISelectionProvider, container.?);
    defer testRelease(selection);
    var selected_items: ?*bindings.SafeArray = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(selection.GetSelection(&selected_items)));
    try std.testing.expectEqual(@as(usize, 1), abi.array(selected_items.?).objects.len);
    const selected_provider: *bindings.IRawElementProviderSimple = @ptrCast(abi.array(selected_items.?).objects[0].?);
    const selected_fragment = try testInterface(bindings.IRawElementProviderFragment, selected_provider);
    defer testRelease(selected_fragment);
    var selected_runtime: ?*bindings.SafeArray = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(selected_fragment.GetRuntimeId(&selected_runtime)));
    try std.testing.expectEqual(@as(i32, 3), abi.array(selected_runtime.?).ints[2]);
    try util.checkAutomationStatus(api.array_destroy(api.context, selected_runtime.?));
    try util.checkAutomationStatus(api.array_destroy(api.context, selected_items.?));
    const count = actions.calls;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(item.Select()));
    try std.testing.expectEqual(count, actions.calls);
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(item.RemoveFromSelection()));
    try std.testing.expectEqual(@as(?schema.Action, .click), actions.action);
    const expand_provider = try testProvider(owner, 4);
    defer testRelease(expand_provider);
    const expand = try testInterface(bindings.IExpandCollapseProvider, expand_provider);
    defer testRelease(expand);
    try std.testing.expectEqual(errors.toBits(errors.invalidOperation()), errors.toBits(expand.Collapse()));
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(expand.Expand()));
    try std.testing.expectEqual(@as(?schema.Action, .expand), actions.action);
    var lease = try actions.weak.?.lease();
    const node = lease.state().nodeById(FullNodeId.init(.{ .value = 2 }, .init(0))).?;
    schema.flags.setDisabled(&@constCast(node.state).data.flags, true);
    lease.deinit();
    try std.testing.expectEqual(errors.toBits(errors.elementNotEnabled()), errors.toBits(range.SetValue(3)));
    const scroll = try testInterface(bindings.IScrollItemProvider, provider);
    defer testRelease(scroll);
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(scroll.ScrollIntoView()));
    try std.testing.expectEqual(@as(?schema.Action, .scroll_into_view), actions.action);
}

fn propertyTestUpdate(name: []const u8, controls: bool) !schema.TreeUpdate {
    const gpa = std.testing.allocator;
    var update: schema.TreeUpdate = .{};
    errdefer update.deinit(gpa);
    var root = schema.Node.init(gpa, .window);
    try schema.strings.setLabel(&root.properties, name);
    try schema.ids_props.setChildren(&root.properties, &.{ .{ .value = 2 }, .{ .value = 3 }, .{ .value = 4 } });
    if (controls) try schema.ids_props.setControls(&root.properties, &.{ .{ .value = 2 }, .{ .value = 3 }, .{ .value = 4 } });
    try update.pushNode(gpa, .{ .value = 1 }, root);
    var first = schema.Node.init(gpa, .button);
    try schema.strings.setLabel(&first.properties, "one");
    try update.pushNode(gpa, .{ .value = 2 }, first);
    var second = schema.Node.init(gpa, .button);
    try schema.strings.setLabel(&second.properties, "two");
    try update.pushNode(gpa, .{ .value = 3 }, second);
    var hidden = schema.Node.init(gpa, .button);
    try schema.strings.setLabel(&hidden.properties, "hidden");
    schema.flags.setHidden(&hidden.flags, true);
    try update.pushNode(gpa, .{ .value = 4 }, hidden);
    update.tree = schema.TreeInfo.init(.{ .value = 1 });
    update.focus = .{ .value = 2 };
    return update;
}

test "node calculator owns old VARIANT when new UTF8 conversion and clear fail then retries once" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var runtime = std.Io.Threaded.init(gpa, .{});
    defer runtime.deinit();
    var abi = util.AutomationTestAbi.init(gpa);
    const api = abi.api();
    var actions: NodeTestActions = .{};
    const owner = try testOwner(runtime.io(), &api, &actions, try propertyTestUpdate("\xff", false));
    defer owner.deinit();
    defer actions.weak.?.deinit();
    var old_tree = try consumer.tree.Tree.init(gpa, try propertyTestUpdate("old", false), true);
    defer old_tree.deinit();
    var lease = try actions.weak.?.lease();
    defer lease.deinit();
    const id = FullNodeId.init(.{ .value = 1 }, .init(0));
    var queue = queued_events.QueuedEvents.init(gpa, &api);
    defer _ = queue.deinit(owner.platform);
    try std.testing.expectError(error.InvalidUtf8,
        enqueuePropertyChanges(gpa, owner.platform, &owner.registry, &queue,
            old_tree.state.nodeById(id).?, lease.state().nodeById(id).?));
    try std.testing.expectEqual(@as(usize, 1), queue.len());
    const event = queue.events.items[0].property_changed;
    try std.testing.expectEqual(@intFromEnum(bindings.PropertyId.NamePropertyId), @intFromEnum(event.property_id));
    try std.testing.expectEqual(@as(u16, 8), util.variantType(&event.old.raw));
    try std.testing.expectEqual(@as(u16, 0), util.variantType(&event.new.raw));
    try std.testing.expectEqualSlices(u16, &.{ 'o', 'l', 'd' }, abi.stringUnits(event.old.raw.Anonymous.Anonymous.Anonymous.bstrVal.?));
    abi.clear_failure = 0x8002000d;
    const failed = queue.deinit(owner.platform);
    if (failed.first_error) |first_error| {
        try std.testing.expect(first_error == error.ArrayLocked);
    } else {
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(u32, 1), abi.live_strings);
    try std.testing.expectEqual(@as(u32, 0), abi.string_frees);
    abi.clear_failure = 0;
    try std.testing.expectEqual(@as(?util.AutomationError, null), queue.deinit(owner.platform).first_error);
    try std.testing.expectEqual(@as(u32, 0), abi.live_strings);
    try std.testing.expectEqual(@as(u32, 1), abi.string_frees);
    try std.testing.expectEqual(@as(usize, 0), queue.len());
}

test "node controller added-only event contains the entire filtered new provider array with independent references" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var runtime = std.Io.Threaded.init(gpa, .{});
    defer runtime.deinit();
    var abi = util.AutomationTestAbi.init(gpa);
    const api = abi.api();
    var actions: NodeTestActions = .{};
    const owner = try testOwner(runtime.io(), &api, &actions, try propertyTestUpdate("same", true));
    defer owner.deinit();
    defer actions.weak.?.deinit();
    var old_tree = try consumer.tree.Tree.init(gpa, try propertyTestUpdate("same", false), true);
    defer old_tree.deinit();
    var lease = try actions.weak.?.lease();
    defer lease.deinit();
    const id = FullNodeId.init(.{ .value = 1 }, .init(0));
    var queue = queued_events.QueuedEvents.init(gpa, &api);
    defer _ = queue.deinit(owner.platform);
    try enqueuePropertyChanges(gpa, owner.platform, &owner.registry, &queue,
        old_tree.state.nodeById(id).?, lease.state().nodeById(id).?);
    try std.testing.expectEqual(@as(usize, 1), queue.len());
    const event = queue.events.items[0].property_changed;
    try std.testing.expectEqual(@intFromEnum(bindings.PropertyId.ControllerForPropertyId), @intFromEnum(event.property_id));
    try std.testing.expectEqual(@as(u16, 0), util.variantType(&event.old.raw));
    try std.testing.expectEqual(@as(u16, 0x200d), util.variantType(&event.new.raw));
    const array = abi.array(event.new.raw.Anonymous.Anonymous.Anonymous.parray.?);
    try std.testing.expectEqual(@as(usize, 2), array.objects.len);
    for (array.objects, 0..) |maybe_provider, index| {
        const simple: *bindings.IRawElementProviderSimple = @ptrCast(maybe_provider.?);
        const fragment = try testInterface(bindings.IRawElementProviderFragment, simple);
        defer testRelease(fragment);
        var runtime_id: ?*bindings.SafeArray = null;
        try std.testing.expectEqual(@as(u32, 0), errors.toBits(fragment.GetRuntimeId(&runtime_id)));
        try std.testing.expectEqual(@as(i32, @intCast(index + 2)), abi.array(runtime_id.?).ints[2]);
        try util.checkAutomationStatus(api.array_destroy(api.context, runtime_id.?));
    }
    try std.testing.expectEqual(@as(?util.AutomationError, null), queue.deinit(owner.platform).first_error);
    try std.testing.expectEqual(@as(u32, 0), abi.live_arrays);
}

test "node COM navigation focus root host geometry and native allocation failures" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var runtime = std.Io.Threaded.init(gpa, .{});
    defer runtime.deinit();
    var abi = util.AutomationTestAbi.init(gpa);
    var api = abi.api();
    api.host_provider_from_hwnd = testReentrantHost;
    var actions: NodeTestActions = .{};
    const owner = try testOwner(runtime.io(), &api, &actions, try propertyTestUpdate("same", true));
    defer owner.deinit();
    defer actions.weak.?.deinit();
    owner.hwnd = @ptrFromInt(1);
    {
        var lease = try actions.weak.?.lease();
        defer lease.deinit();
        const node = lease.state().nodeById(FullNodeId.init(.{ .value = 2 }, .init(0))).?;
        try schema.option.setBounds(&@constCast(node.state).data.properties,
            .{ .x0 = 5, .y0 = 7, .x1 = 15, .y1 = 17 });
    }
    const provider = try testProvider(owner, 2);
    defer testRelease(provider);
    const fragment = try testInterface(bindings.IRawElementProviderFragment, provider);
    defer testRelease(fragment);
    try std.testing.expectEqual(errors.toBits(errors.invalidArg()), errors.toBits(fragment.GetRuntimeId(null)));
    const RawNavigate = *const fn (*const bindings.IRawElementProviderFragment, i32,
        ?*?*bindings.IRawElementProviderFragment) callconv(.winapi) Hresult;
    const raw_navigate: RawNavigate = @ptrCast(fragment.vtable.Navigate);
    var invalid_target: ?*bindings.IRawElementProviderFragment = fragment;
    try std.testing.expectEqual(errors.toBits(errors.invalidArg()), errors.toBits(raw_navigate(fragment, -1, &invalid_target)));
    try std.testing.expectEqual(@as(?*bindings.IRawElementProviderFragment, null), invalid_target);
    try std.testing.expectEqual(errors.toBits(errors.invalidArg()), errors.toBits(raw_navigate(fragment, 5, &invalid_target)));
    var rect: bindings.UiaRect = undefined;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(fragment.get_BoundingRectangle(&rect)));
    try std.testing.expectEqual(@as(f64, -115), rect.left);
    try std.testing.expectEqual(@as(f64, 54), rect.top);
    try std.testing.expectEqual(@as(f64, 10), rect.width);
    try std.testing.expectEqual(@as(f64, 10), rect.height);
    abi.window_present = false;
    try std.testing.expectEqual(errors.toBits(errors.elementNotAvailable()), errors.toBits(fragment.get_BoundingRectangle(&rect)));
    abi.window_present = true;
    var parent: ?*bindings.IRawElementProviderFragment = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(fragment.Navigate(.Parent, &parent)));
    defer testRelease(parent.?);
    var first: ?*bindings.IRawElementProviderFragment = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(parent.?.Navigate(.FirstChild, &first)));
    defer testRelease(first.?);
    var next: ?*bindings.IRawElementProviderFragment = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(first.?.Navigate(.NextSibling, &next)));
    defer testRelease(next.?);
    var words: ?*bindings.SafeArray = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(next.?.GetRuntimeId(&words)));
    try std.testing.expectEqual(@as(i32, 3), abi.array(words.?).ints[2]);
    try util.checkAutomationStatus(api.array_destroy(api.context, words.?));
    var root: ?*bindings.IRawElementProviderFragmentRoot = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(fragment.get_FragmentRoot(&root)));
    defer testRelease(root.?);
    var focus: ?*bindings.IRawElementProviderFragment = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(root.?.GetFocus(&focus)));
    defer testRelease(focus.?);
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(focus.?.GetRuntimeId(&words)));
    try std.testing.expectEqual(@as(i32, 2), abi.array(words.?).ints[2]);
    try util.checkAutomationStatus(api.array_destroy(api.context, words.?));
    var hit: ?*bindings.IRawElementProviderFragment = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(root.?.ElementProviderFromPoint(-110, 59, &hit)));
    defer testRelease(hit.?);
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(hit.?.GetRuntimeId(&words)));
    try std.testing.expectEqual(@as(i32, 2), abi.array(words.?).ints[2]);
    try util.checkAutomationStatus(api.array_destroy(api.context, words.?));
    const root_simple = try testProvider(owner, 1);
    defer testRelease(root_simple);
    abi.host_object = root_simple;
    var host: ?*bindings.IRawElementProviderSimple = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(root_simple.get_HostRawElementProvider(&host)));
    try std.testing.expect(host.? == root_simple);
    testRelease(host.?);
    host = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(provider.get_HostRawElementProvider(&host)));
    try std.testing.expectEqual(@as(?*bindings.IRawElementProviderSimple, null), host);
    abi.host_failure = 0x80070005;
    try std.testing.expectEqual(@as(u32, 0x80070005), errors.toBits(root_simple.get_HostRawElementProvider(&host)));
    abi.host_failure = 0;
    {
        var lease = try actions.weak.?.lease();
        defer lease.deinit();
        const node = lease.state().nodeById(FullNodeId.init(.{ .value = 1 }, .init(0))).?;
        schema.strings.clearLabel(&@constCast(node.state).data.properties);
    }
    abi.title = &.{ 'W', 0xd83d, 0xde00 };
    abi.title_length = abi.title.len;
    var root_value: bindings.Variant = undefined;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(root_simple.GetPropertyValue(.NamePropertyId, &root_value)));
    try std.testing.expectEqual(@as(u16, 8), util.variantType(&root_value));
    try std.testing.expectEqualSlices(u16, abi.title, abi.stringUnits(root_value.Anonymous.Anonymous.Anonymous.bstrVal.?));
    try util.checkAutomationStatus(api.variant_clear(api.context, &root_value));
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(root_simple.GetPropertyValue(.NativeWindowHandlePropertyId, &root_value)));
    try std.testing.expectEqual(@as(u16, 3), util.variantType(&root_value));
    try std.testing.expectEqual(@as(i32, 1), root_value.Anonymous.Anonymous.Anonymous.lVal);
    try util.checkAutomationStatus(api.variant_clear(api.context, &root_value));
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(provider.GetPropertyValue(.FrameworkIdPropertyId, &root_value)));
    try std.testing.expectEqualSlices(u16, &.{ 'A', 'c', 'c', 'e', 's', 's', 'K', 'i', 't' },
        abi.stringUnits(root_value.Anonymous.Anonymous.Anonymous.bstrVal.?));
    try util.checkAutomationStatus(api.variant_clear(api.context, &root_value));
    abi.fail_array = true;
    words = null;
    try std.testing.expectEqual(@as(u32, 0x8007000e), errors.toBits(fragment.GetRuntimeId(&words)));
    try std.testing.expectEqual(@as(?*bindings.SafeArray, null), words);
    abi.fail_array = false;
    abi.fail_string = true;
    var value: bindings.Variant = undefined;
    try std.testing.expectEqual(@as(u32, 0x8007000e), errors.toBits(provider.GetPropertyValue(.NamePropertyId, &value)));
    try std.testing.expectEqual(@as(u16, 0), util.variantType(&value));
    abi.fail_string = false;
    const placeholder = try create(gpa, owner.context.weak(), null);
    defer testRelease(placeholder);
    const placeholder_fragment = try testInterface(bindings.IRawElementProviderFragment, placeholder);
    defer testRelease(placeholder_fragment);
    try std.testing.expectEqual(errors.toBits(errors.notImplemented()), errors.toBits(placeholder_fragment.GetRuntimeId(&words)));
    const unknown: *bindings.IUnknown = @ptrCast(provider);
    inline for (PlatformNode.Descriptors) |descriptor| {
        var raw: *anyopaque = undefined;
        try std.testing.expectEqual(@as(u32, 0), errors.toBits(unknown.QueryInterface(descriptor.Iid, &raw)));
        testRelease(@as(*bindings.IUnknown, @ptrCast(@alignCast(raw))));
    }
    try std.testing.expectEqual(@as(u32, 0), abi.live_arrays);
    try std.testing.expectEqual(@as(u32, 0), abi.live_strings);
}

test "node real text document selection providers own weak ranges and preserve window unsupported operations" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var runtime = std.Io.Threaded.init(gpa, .{});
    defer runtime.deinit();
    var abi = util.AutomationTestAbi.init(gpa);
    const api = abi.api();
    var actions: NodeTestActions = .{};
    var update: schema.TreeUpdate = .{};
    var root_node = schema.Node.init(gpa, .dialog);
    try schema.ids_props.setChildren(&root_node.properties, &.{.{ .value = 2 }});
    var field = schema.Node.init(gpa, .text_input);
    try schema.ids_props.setChildren(&field.properties, &.{.{ .value = 3 }});
    try schema.option.setTextSelection(&field.properties, .{
        .anchor = .{ .node_id = .{ .value = 3 }, .character_index = 1 },
        .focus = .{ .node_id = .{ .value = 3 }, .character_index = 3 },
    });
    var run = schema.Node.init(gpa, .text_run);
    try schema.strings.setValue(&run.properties, "hello");
    try schema.vectors.setCharacterLengths(&run.properties, &.{ 1, 1, 1, 1, 1 });
    try update.pushNode(gpa, .{ .value = 1 }, root_node);
    try update.pushNode(gpa, .{ .value = 2 }, field);
    try update.pushNode(gpa, .{ .value = 3 }, run);
    update.tree = schema.TreeInfo.init(.{ .value = 1 });
    update.focus = .{ .value = 2 };
    const owner = try testOwner(runtime.io(), &api, &actions, update);
    var owner_live = true;
    defer if (owner_live) owner.deinit();
    defer actions.weak.?.deinit();
    const provider = try testProvider(owner, 2);
    defer testRelease(provider);
    var pattern: ?*bindings.IUnknown = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(provider.GetPatternProvider(.TextPatternId, &pattern)));
    const text: *bindings.ITextProvider = @ptrCast(pattern.?);
    defer testRelease(text);
    var supported: uia.SupportedTextSelection = .None;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(text.get_SupportedTextSelection(&supported)));
    try std.testing.expectEqual(uia.SupportedTextSelection.Single, supported);
    var selected: ?*bindings.SafeArray = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(text.GetSelection(&selected)));
    try std.testing.expectEqual(@as(usize, 1), abi.array(selected.?).objects.len);
    try util.checkAutomationStatus(api.array_destroy(api.context, selected.?));
    var document: ?*bindings.ITextRangeProvider = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(text.get_DocumentRange(&document)));
    defer testRelease(document.?);
    var content: ?bindings.Bstr = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(document.?.GetText(-1, &content)));
    try std.testing.expectEqualSlices(u16, &.{ 'h', 'e', 'l', 'l', 'o' }, abi.stringUnits(content.?));
    api.free_string(api.context, content.?);
    const value_provider = try testInterface(bindings.IValueProvider, provider);
    defer testRelease(value_provider);
    const unicode = [_:0]u16{ 0xe9, 0xd83d, 0xde42 };
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(value_provider.SetValue(&unicode)));
    try std.testing.expectEqualStrings("\xc3\xa9\xf0\x9f\x99\x82", actions.text[0..actions.text_len]);
    try std.testing.expectEqual(@as(?schema.Action, .set_value), actions.action);
    const invalid = [_:0]u16{0xd800};
    const action_count = actions.calls;
    try std.testing.expectEqual(errors.toBits(errors.invalidArg()), errors.toBits(value_provider.SetValue(&invalid)));
    try std.testing.expectEqual(action_count, actions.calls);
    var unsupported_range: ?*bindings.ITextRangeProvider = null;
    try std.testing.expectEqual(errors.toBits(errors.notImplemented()), errors.toBits(text.RangeFromChild(provider, &unsupported_range)));
    try std.testing.expectEqual(errors.toBits(errors.invalidArg()), errors.toBits(text.RangeFromChild(null, &unsupported_range)));
    var visible: ?*bindings.SafeArray = null;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(text.GetVisibleRanges(&visible)));
    try std.testing.expectEqual(@as(?*bindings.SafeArray, null), visible);
    const root_provider = try testProvider(owner, 1);
    defer testRelease(root_provider);
    const window = try testInterface(bindings.IWindowProvider, root_provider);
    defer testRelease(window);
    var interaction: uia.WindowInteractionState = .Running;
    try std.testing.expectEqual(@as(u32, 0), errors.toBits(window.get_WindowInteractionState(&interaction)));
    try std.testing.expectEqual(uia.WindowInteractionState.ReadyForUserInteraction, interaction);
    try std.testing.expectEqual(errors.toBits(errors.invalidOperation()), errors.toBits(window.SetVisualState(.Normal)));
    const RawVisual = *const fn (*const bindings.IWindowProvider, i32) callconv(.winapi) Hresult;
    const raw_visual: RawVisual = @ptrCast(window.vtable.SetVisualState);
    try std.testing.expectEqual(errors.toBits(errors.invalidArg()), errors.toBits(raw_visual(window, -1)));
    try std.testing.expectEqual(errors.toBits(errors.invalidArg()), errors.toBits(raw_visual(window, 3)));
    try std.testing.expectEqual(errors.toBits(errors.notSupported()), errors.toBits(window.Close()));
    var flag: bindings.Bool = 99;
    try std.testing.expectEqual(errors.toBits(errors.notSupported()), errors.toBits(window.WaitForInputIdle(0, &flag)));
    try std.testing.expectEqual(@as(bindings.Bool, 0), flag);
    owner.deinit();
    owner_live = false;
    content = null;
    try std.testing.expectEqual(errors.toBits(errors.elementNotAvailable()), errors.toBits(document.?.GetText(-1, &content)));
    try std.testing.expectEqual(@as(?bindings.Bstr, null), content);
    try std.testing.expectEqual(@as(u32, 0), abi.live_strings);
    try std.testing.expectEqual(@as(u32, 0), abi.live_arrays);
}

test "node common-pattern property events carry typed old new numeric values only while both nodes support pattern" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var runtime = std.Io.Threaded.init(gpa, .{});
    defer runtime.deinit();
    var abi = util.AutomationTestAbi.init(gpa);
    const api = abi.api();
    var actions: NodeTestActions = .{};
    const owner = try testOwner(runtime.io(), &api, &actions, try propertyTestUpdate("same", false));
    defer owner.deinit();
    defer actions.weak.?.deinit();
    var old_tree = try consumer.tree.Tree.init(gpa, try propertyTestUpdate("same", false), true);
    defer old_tree.deinit();
    const id = FullNodeId.init(.{ .value = 2 }, .init(0));
    try schema.numbers.setNumericValue(&old_tree.state.nodes.getPtr(id).?.data.properties, 1);
    var lease = try actions.weak.?.lease();
    defer lease.deinit();
    const new = lease.state().nodeById(id).?;
    try schema.numbers.setNumericValue(&@constCast(new.state).data.properties, 2);
    var queue = queued_events.QueuedEvents.init(gpa, &api);
    defer _ = queue.deinit(owner.platform);
    try enqueuePropertyChanges(gpa, owner.platform, &owner.registry, &queue,
        old_tree.state.nodeById(id).?, new);
    try std.testing.expectEqual(@as(usize, 1), queue.len());
    const event = queue.events.items[0].property_changed;
    try std.testing.expectEqual(@intFromEnum(bindings.PropertyId.RangeValueValuePropertyId), @intFromEnum(event.property_id));
    try std.testing.expectEqual(@as(u16, 5), util.variantType(&event.old.raw));
    try std.testing.expectEqual(@as(u16, 5), util.variantType(&event.new.raw));
    try std.testing.expectEqual(@as(f64, 1), event.old.raw.Anonymous.Anonymous.Anonymous.dblVal);
    try std.testing.expectEqual(@as(f64, 2), event.new.raw.Anonymous.Anonymous.Anonymous.dblVal);
    try std.testing.expectEqual(@as(?util.AutomationError, null), queue.deinit(owner.platform).first_error);
    schema.numbers.clearNumericValue(&old_tree.state.nodes.getPtr(id).?.data.properties);
    try enqueuePropertyChanges(gpa, owner.platform, &owner.registry, &queue,
        old_tree.state.nodeById(id).?, new);
    try std.testing.expectEqual(@as(usize, 0), queue.len());
}

test "node constructor allocation failure does not consume caller weak ownership or query guarded tree" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var runtime = std.Io.Threaded.init(gpa, .{});
    defer runtime.deinit();
    var abi = util.AutomationTestAbi.init(gpa);
    const api = abi.api();
    var actions: NodeTestActions = .{};
    const owner = try testOwner(runtime.io(), &api, &actions, try propertyTestUpdate("same", false));
    var owner_live = true;
    defer if (owner_live) owner.deinit();
    actions.weak.?.deinit();
    actions.weak = null;
    var weak = owner.context.weak();
    defer weak.deinit();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    {
        var lease = try weak.lease();
        defer lease.deinit();
        try std.testing.expectError(error.OutOfMemory,
            create(failing.allocator(), weak, FullNodeId.init(.{ .value = 2 }, .init(0))));
    }
    owner.deinit();
    owner_live = false;
    try std.testing.expectError(error.ElementNotAvailable, weak.lease());
    try std.testing.expectEqual(@as(u32, 0), abi.live_strings);
    try std.testing.expectEqual(@as(u32, 0), abi.live_arrays);
}

fn testReentrantHost(raw: ?*anyopaque, hwnd: bindings.Hwnd,
    out: *?*bindings.IRawElementProviderSimple) Hresult
{
    const abi: *util.AutomationTestAbi = @ptrCast(@alignCast(raw.?));
    if (abi.host_object) |provider| {
        const object = objectFrom(bindings.IRawElementProviderSimple, provider);
        // This real context acquisition would deadlock if HostRawElementProvider held its tree guard.
        var lease = object.state.weak.lease() catch |err| return status(err);
        lease.deinit();
    }
    const native = abi.api();
    return native.host_provider_from_hwnd(native.context, hwnd, out);
}
