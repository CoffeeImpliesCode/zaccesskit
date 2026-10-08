const std = @import("std");
const schema = @import("zaccesskit").schema;
const Allocator = std.mem.Allocator;
pub const Error = Allocator.Error;
pub const TextError = Allocator.Error || error{ InvalidUtf8, TextLimit, InvalidCaret };
pub const text_bytes_limit = 1024;

pub const Model = struct {
    revision: u32 = 0,
    reordered: bool = false,
    removed: bool = false,
    focus: u64 = 2,
    bad_geometry: bool = false,
    // The host owns these bytes and rebinds them when its cached run is replaced.
    text8: ?[]const u8 = null,
    caret8: ?u32 = null,
};

pub fn nodeId(value: u64) schema.NodeId {
    return .{ .value = value };
}
const roles = [_]schema.Role{
    .window, .button, .slider, .list_box, .list_box_option, .list_box_option,
    .text_input, .text_run, .root_web_area, .image, .link, .scroll_view, .label, .text_run, .label,
};
pub const node_count = roles.len;
const labels = [_][]const u8{
    "Probe window", "Save", "Gain", "Choices", "Alpha", "Beta", "Editor", "",
    "Probe document", "Diagram", "Help", "Viewport", "", "", "Combining sample",
};
const bounds = [_][4]f64{
    .{ 0, 0, 640, 480 }, .{ 20, 20, 120, 60 }, .{ 20, 80, 220, 110 },
    .{ 20, 130, 220, 210 }, .{ 30, 140, 210, 165 }, .{ 30, 170, 210, 195 },
    .{ 250, 20, 450, 60 }, .{ 260, 30, 310, 50 }, .{ 250, 80, 600, 200 },
    .{ 250, 220, 330, 280 }, .{ 350, 220, 450, 250 }, .{ 20, 240, 220, 400 },
    .{ 20, 215, 220, 235 }, .{ 260, 90, 270, 110 }, .{ 260, 90, 270, 110 },
};
fn focus(model: Model) schema.NodeId {
    return nodeId(if (model.removed and model.focus == 2) 1 else model.focus);
}

// This neutral fixture uses one selectable entry per Unicode scalar, not grapheme shaping.
// Its deterministic advances keep text, selection and geometry coherent after an edit.
const TextLayout = struct {
    lengths: [text_bytes_limit]u8,
    positions: [text_bytes_limit]f32,
    widths: [text_bytes_limit]f32,
    scalar_count: usize,
    width: u32,

    fn init(layout: *TextLayout, text: []const u8) TextError!void {
        if (text.len > text_bytes_limit) return error.TextLimit;
        const view = try std.unicode.Utf8View.init(text);
        var iterator = view.iterator();
        layout.scalar_count = 0;
        layout.width = 0;
        while (iterator.nextCodepointSlice()) |bytes| {
            // Utf8View has validated every scalar before this bounded iteration.
            const scalar = std.unicode.utf8Decode(bytes) catch unreachable;
            const width: u32 = if (scalar >= 0x0300 and scalar <= 0x036f)
                0
            else if (scalar > 0xffff)
                20
            else
                10;
            const index = layout.scalar_count;
            std.debug.assert(index < text_bytes_limit);
            layout.lengths[index] = @intCast(bytes.len);
            layout.positions[index] = @floatFromInt(layout.width);
            layout.widths[index] = @floatFromInt(width);
            layout.width += width;
            layout.scalar_count += 1;
        }
    }

    fn apply(layout: *const TextLayout, node: *schema.Node, text: []const u8) Error!void {
        const properties = &node.properties;
        try schema.strings.setValue(properties, text);
        try schema.vectors.setCharacterLengths(properties, layout.lengths[0..layout.scalar_count]);
        try schema.vectors.setCharacterPositions(
            properties, layout.positions[0..layout.scalar_count],
        );
        try schema.vectors.setCharacterWidths(properties, layout.widths[0..layout.scalar_count]);
        try schema.vectors.setWordStarts(properties, if (layout.scalar_count == 0) &.{} else &.{0});
        try schema.option.setBounds(properties, schema.rectInit(
            260, 30, 260 + @as(f64, @floatFromInt(layout.width)), 50,
        ));
    }
};

fn text8(model: Model) []const u8 {
    return model.text8 orelse if (model.revision == 0) "Aé😀B" else "Aé😀C";
}

fn setCaret(owner: *schema.Node, caret: u32) Error!void {
    const position: schema.TextPosition = .{ .node_id = nodeId(8), .character_index = caret };
    try schema.option.setTextSelection(&owner.properties, .{
        .anchor = position, .focus = position,
    });
}

pub const TextNodes = struct {
    owner: schema.Node,
    run: schema.Node,
};

// Both results own independent buffers. Install both or deinitialize both.
// Validation and all allocations finish before the caller can replace either source node.
pub fn prepareTextNodes(
    gpa: Allocator,
    old_owner: *const schema.Node,
    old_run: *const schema.Node,
    text: []const u8,
    caret: u32,
) TextError!TextNodes {
    var layout: TextLayout = undefined;
    try layout.init(text);
    if (caret > layout.scalar_count) return error.InvalidCaret;
    var owner = try schema.Node.clone(gpa, old_owner);
    errdefer owner.deinit();
    var run = try schema.Node.clone(gpa, old_run);
    errdefer run.deinit();
    try layout.apply(&run, text);
    try setCaret(&owner, caret);
    return .{ .owner = owner, .run = run };
}

// The update owns its nodes; metadata strings retain TreeInfo's borrowing contract.
pub fn buildFull(
    gpa: Allocator,
    model: Model,
    metadata: ?schema.TreeInfo,
) TextError!schema.TreeUpdate {
    var layout: TextLayout = undefined;
    try layout.init(text8(model));
    if (model.caret8) |caret| {
        if (caret > layout.scalar_count) return error.InvalidCaret;
    }
    var update: schema.TreeUpdate = .{
        .tree = metadata orelse .{
            .root = nodeId(1), .toolkit_name = "probe-zig", .toolkit_version = "1.0",
        },
        .focus = focus(model),
    };
    errdefer update.deinit(gpa);
    try update.nodes.ensureTotalCapacity(gpa, node_count);
    for (0..node_count) |index| {
        const id: u64 = @intCast(index + 1);
        if (model.removed and id == 2) continue;
        try update.pushNode(gpa, nodeId(id), try buildNode(gpa, model, index, &layout));
    }
    return update;
}

fn buildNode(
    gpa: Allocator,
    model: Model,
    index: usize,
    layout: *const TextLayout,
) Error!schema.Node {
    var node = schema.Node.init(gpa, roles[index]);
    errdefer node.deinit();
    const properties = &node.properties;
    const box: [4]f64 = if (model.bad_geometry and index == 2)
        .{ 3_000_000_000, 80, 3_000_000_200, 110 }
    else
        bounds[index];
    try schema.option.setBounds(properties, schema.rectInit(box[0], box[1], box[2], box[3]));
    if (labels[index].len != 0) {
        const label = if (index == 1 and model.revision != 0) "Saved" else labels[index];
        try schema.strings.setLabel(properties, label);
    }
    switch (index + 1) {
        1 => {
            const children = [_]schema.NodeId{
                nodeId(2), nodeId(3), nodeId(4), nodeId(7), nodeId(9),
                nodeId(10), nodeId(11), nodeId(12), nodeId(13),
            };
            try schema.ids_props.setChildren(properties, children[@intFromBool(model.removed)..]);
        },
        2 => {
            node.addAction(.click);
            node.addAction(.focus);
            node.addAction(.custom_action);
            try schema.strings.setDescription(properties, "Save current document");
            try schema.ids_props.setDescribedBy(properties, &.{nodeId(13)});
            try schema.ids_props.setControls(properties, &.{nodeId(12)});
            var negative = try schema.CustomAction.init(gpa, -7, "Inspect");
            defer negative.deinit(gpa);
            var positive = try schema.CustomAction.init(gpa, 42, "Reset");
            defer positive.deinit(gpa);
            try schema.vectors.setCustomActions(properties, &.{ negative, positive });
        },
        3 => {
            node.addAction(.focus);
            node.addAction(.set_value);
            node.addAction(.increment);
            node.addAction(.decrement);
            try schema.numbers.setNumericValue(properties, if (model.revision == 0) 0 else 1);
            try schema.numbers.setMinNumericValue(properties, 0);
            try schema.numbers.setMaxNumericValue(properties, 10);
            try schema.numbers.setNumericValueStep(properties, 0.5);
            try schema.ids_props.setLabelledBy(properties, &.{nodeId(13)});
        },
        4 => {
            const children = if (model.reordered)
                [_]schema.NodeId{ nodeId(6), nodeId(5) }
            else
                [_]schema.NodeId{ nodeId(5), nodeId(6) };
            try schema.ids_props.setChildren(properties, &children);
            schema.flags.setMultiselectable(&node.flags, true);
        },
        5, 6 => {
            try schema.enums.setSelected(properties, index == 5);
            node.addAction(.click);
            node.addAction(.focus);
        },
        7 => {
            try schema.ids_props.setChildren(properties, &.{nodeId(8)});
            try schema.strings.setPlaceholder(properties, "Type here");
            if (model.caret8) |caret| {
                try setCaret(&node, caret);
            } else if (layout.scalar_count == 0) {
                try setCaret(&node, 0);
            } else {
                try schema.option.setTextSelection(properties, .{
                    .anchor = .{ .node_id = nodeId(8), .character_index = 1 },
                    .focus = .{ .node_id = nodeId(8), .character_index = 3 },
                });
            }
            node.addAction(.focus);
            node.addAction(.set_value);
            node.addAction(.set_text_selection);
        },
        8, 14 => {
            if (index == 7) {
                try layout.apply(&node, text8(model));
            } else {
                try schema.strings.setValue(properties, "e\u{0301}");
                try schema.vectors.setCharacterLengths(properties, &.{ 1, 2 });
                try schema.vectors.setCharacterPositions(properties, &.{ 0, 10 });
                try schema.vectors.setCharacterWidths(properties, &.{ 10, 0 });
                try schema.vectors.setWordStarts(properties, &.{0});
            }
            try schema.enums.setTextDirection(properties, .left_to_right);
            try schema.strings.setFontFamily(properties, "Probe Sans");
            try schema.strings.setLanguage(properties, "en");
            try schema.numbers.setFontSize(properties, 16);
            try schema.numbers.setFontWeight(properties, 400);
        },
        9 => {
            try schema.ids_props.setChildren(properties, &.{nodeId(15)});
            try schema.strings.setUrl(properties, "https://example.test/document");
        },
        10 => {
            try schema.strings.setDescription(properties, "Blue square diagram");
            try schema.strings.setRoleDescription(properties, "diagram");
            try schema.strings.setUrl(properties, "https://example.test/image");
        },
        11 => {
            node.addAction(.click);
            try schema.strings.setDescription(properties, "Open help page");
            try schema.strings.setUrl(properties, "https://example.test/help");
        },
        12 => {
            node.addAction(.set_scroll_offset);
            node.addAction(.scroll_into_view);
            node.addAction(.scroll_to_point);
            try schema.numbers.setScrollX(properties, 10);
            try schema.numbers.setScrollXMin(properties, 0);
            try schema.numbers.setScrollXMax(properties, 100);
            try schema.numbers.setScrollY(properties, 20);
            try schema.numbers.setScrollYMin(properties, 0);
            try schema.numbers.setScrollYMax(properties, 200);
        },
        13 => try schema.strings.setValue(properties, "Gain label"),
        15 => try schema.ids_props.setChildren(properties, &.{nodeId(14)}),
        else => unreachable, // The caller walks the fifteen declared identities only.
    }
    return node;
}

// Nodes and their property buffers are copied; metadata bytes remain borrowed.
pub fn cloneUpdate(
    gpa: Allocator,
    source: *const schema.TreeUpdate,
    include_metadata: bool,
) Error!schema.TreeUpdate {
    var update: schema.TreeUpdate = .{
        .tree = if (include_metadata) source.tree else null,
        .tree_id = source.tree_id,
        .focus = source.focus,
    };
    errdefer update.deinit(gpa);
    try update.nodes.ensureTotalCapacity(gpa, source.nodes.items.len);
    for (source.nodes.items) |*entry| {
        try update.pushNode(gpa, entry.node_id, try schema.Node.clone(gpa, &entry.node));
    }
    return update;
}

fn digestTextVector(
    comptime T: type,
    writer: *std.Io.Writer,
    values: []const T,
) std.Io.Writer.Error!void {
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeByte(',');
        const integer: u32 = if (T == f32) @intFromFloat(value) else value;
        try writer.print("{d}", .{integer});
    }
}

// This is a canonical semantic transcript, independent of allocation and property ordering.
pub fn digest(
    writer: *std.Io.Writer,
    model: Model,
    metadata_name: []const u8,
    metadata_version: []const u8,
) std.Io.Writer.Error!void {
    var layout: TextLayout = undefined;
    // Only a successfully prepared cached model is recorded by the host.
    layout.init(text8(model)) catch unreachable;
    const caret: ?u32 = if (model.caret8) |value|
        value
    else if (layout.scalar_count == 0)
        0
    else
        null;
    try writer.print("DIGEST model revision={d} reordered={} removed={} focus={d}" ++
        " bad_geometry={}\n", .{
        model.revision, model.reordered, model.removed, focus(model).value, model.bad_geometry,
    });
    try writer.print("DIGEST tree root=1 toolkit={s} version={s}\n", .{
        metadata_name, metadata_version,
    });
    try writer.print("DIGEST root children={s} bounds=0,0,640,480 label=Probe window\n", .{
        if (model.removed) "3,4,7,9,10,11,12,13" else "2,3,4,7,9,10,11,12,13",
    });
    if (!model.removed) try writer.print(
        "DIGEST button id=2 label={s} bounds=20,20,120,60 description=Save current document" ++
        " actions=click,focus,custom_action described_by=13 controls=12 custom=-7:Inspect,42:Reset\n",
        .{if (model.revision == 0) "Save" else "Saved"},
    );
    try writer.print("DIGEST slider id=3 label=Gain bounds={s} value={d}" ++
        " min=0 max=10 step=0.5 labelled_by=13 actions=focus,set_value,increment,decrement\n", .{
        if (model.bad_geometry) "3000000000,80,3000000200,110" else "20,80,220,110",
        @as(u8, if (model.revision == 0) 0 else 1),
    });
    try writer.print("DIGEST list id=4 label=Choices bounds=20,130,220,210" ++
        " children={s} multiselectable=true selected=6\n", .{
        if (model.reordered) "6,5" else "5,6",
    });
    try writer.writeAll("DIGEST row id=5 role=list_box_option label=Alpha" ++
        " bounds=30,140,210,165 selected=false actions=click,focus\n" ++
        "DIGEST row id=6 role=list_box_option label=Beta" ++
        " bounds=30,170,210,195 selected=true actions=click,focus\n");
    try writer.print(
        "DIGEST editor id=7 label=Editor bounds=250,20,450,60 children=8 placeholder=Type here" ++
            " selection=8:{d},8:{d} actions=focus,set_value,set_text_selection\n",
        .{ caret orelse 1, caret orelse 3 },
    );
    try writer.writeAll("DIGEST text id=8 value=");
    if (model.text8) |text| {
        // JSON quoting keeps an edited newline inside a single semantic record.
        try std.json.Stringify.value(text, .{}, writer);
    } else {
        try writer.writeAll(text8(model));
    }
    try writer.print(" bounds=260,30,{d},50 lengths=", .{260 + layout.width});
    try digestTextVector(u8, writer, layout.lengths[0..layout.scalar_count]);
    try writer.writeAll(" positions=");
    try digestTextVector(f32, writer, layout.positions[0..layout.scalar_count]);
    try writer.writeAll(" widths=");
    try digestTextVector(f32, writer, layout.widths[0..layout.scalar_count]);
    try writer.print(" words={s} direction=left_to_right" ++
        " font=Probe Sans size=16 weight=400 language=en\n",
        .{if (layout.scalar_count == 0) "" else "0"});
    try writer.writeAll("DIGEST document id=9 role=root_web_area label=Probe document" ++
        " bounds=250,80,600,200 children=15 Title=Probe document URI=https://example.test/document\n" ++
        "DIGEST image id=10 label=Diagram bounds=250,220,330,280" ++
        " description=Blue square diagram role_description=diagram url=https://example.test/image\n" ++
        "DIGEST hyperlink id=11 label=Help bounds=350,220,450,250" ++
        " description=Open help page url=https://example.test/help actions=click\n" ++
        "DIGEST scroll id=12 label=Viewport bounds=20,240,220,400 x=10 xmin=0 xmax=100" ++
        " y=20 ymin=0 ymax=200 actions=set_scroll_offset,scroll_into_view,scroll_to_point\n" ++
        "DIGEST label id=13 value=Gain label bounds=20,215,220,235\n" ++
        "DIGEST text id=14 value=e\u{0301} bounds=260,90,270,110 lengths=1,2 positions=0,10" ++
        " widths=10,0 words=0 direction=left_to_right font=Probe Sans size=16 weight=400 language=en\n" ++
        "DIGEST combining id=15 role=label label=Combining sample" ++
        " bounds=260,90,270,110 children=14\n");
}
