//! The native NSAccessibilityElement provider from pinned macOS `node.rs:396-1367`.
//! `attributes.selectors` maps each selector index to its upstream declaration.
//! The object owns an id and a weak context anchor. Each query holds a context lease.
//! Object queries return +0 references. The factory returns a separate +1 reference.
//! `platform_text.zig` implements the thirteen text selectors from `node.rs:755-1046`.

const std = @import("std");
const builtin = @import("builtin");
const schema = @import("../../schema/root.zig");
const consumer = @import("../../consumer/root.zig");
const objc = @import("objc.zig");
const foundation = @import("foundation.zig");
const context = @import("context.zig");
const pure_node = @import("node.zig");
const roles = @import("roles.zig");
const attributes = @import("attributes.zig");
const platform_text = @import("platform_text.zig");
const native = @import("native.zig");
const NodeRef = consumer.node_id.NodeRef;
const FullNodeId = consumer.tree_index.FullNodeId;
const NativeError = context.NativeError;
const ContextLease = context.ContextLease;

const properties = consumer.node_ref.properties;
const predicates = consumer.node_ref.predicates;
const hierarchy = consumer.node_ref.hierarchy;
const containers = consumer.node_ref.containers;
const strings = consumer.node_ref.strings;
const set_state = consumer.node_ref.set_state;
const text_query = consumer.text.query;
const class_name: [:0]const u8 = "ZAccessKitPlatformNode";
const state_ivar: [:0]const u8 = "_zaccesskitState";
const zero_range: objc.NSRange = .{ .location = 0, .length = 0 };
const zero_rect: objc.NSRect = .{
    .origin = .{ .x = 0, .y = 0 },
    .size = .{ .width = 0, .height = 0 },
};

const State = struct {
    gpa: std.mem.Allocator,
    weak: context.WeakContext,
    id: FullNodeId,
};

pub fn create(
    gpa: std.mem.Allocator,
    weak: context.WeakContext,
    id: FullNodeId,
) NativeError!objc.Object {
    if (builtin.os.tag != .macos) return error.NativeUnsupported;
    if (!foundation.isMainThread()) return error.WrongThread;
    const class = try nodeClass();
    const owned = try gpa.create(State);
    errdefer gpa.destroy(owned);
    const allocated = objc.send(?objc.Object, class, "alloc", .{}) orelse
        return error.NativeObjectCreationFailed;
    const object = objc.send(?objc.Object, allocated, "init", .{}) orelse
        return error.NativeObjectCreationFailed;
    owned.* = .{ .gpa = gpa, .weak = weak, .id = id };
    stateSlot(object).* = owned;
    return object;
}

fn stateSlot(object: objc.Object) *?*State {
    const class = objc.object_getClass(object).?;
    const ivar = objc.class_getInstanceVariable(class, state_ivar.ptr).?;
    const offset: usize = @intCast(objc.ivar_getOffset(ivar));
    const bytes: [*]u8 = @ptrCast(object);
    return @ptrCast(@alignCast(bytes + offset));
}

fn dealloc(object: objc.Object, _: objc.Sel) callconv(.c) void {
    if (stateSlot(object).*) |owned| {
        stateSlot(object).* = null;
        const gpa = owned.gpa;
        var weak = owned.weak;
        gpa.destroy(owned);
        // The last weak release can reclaim the allocator and its I/O runtime.
        weak.deinit();
    }
    const superclass = objc.class_getSuperclass(objc.object_getClass(object).?).?;
    objc.sendSuper(void, object, superclass, "dealloc", .{});
}

fn nodeClass() NativeError!objc.Class {
    const superclass = objc.getClass("NSAccessibilityElement") orelse
        return error.ObjectiveCUnavailable;
    if (objc.getClass(class_name)) |existing| {
        if (objc.class_getSuperclass(existing) != superclass or
            objc.class_getInstanceVariable(existing, state_ivar.ptr) == null)
            return error.ClassRegistrationFailed;
        const method = objc.class_getInstanceMethod(existing, objc.sel("dealloc")) orelse
            return error.ClassRegistrationFailed;
        if (objc.method_getImplementation(method) != @as(objc.IMP, @ptrCast(&dealloc)))
            return error.ClassRegistrationFailed;
        return existing;
    }
    const class = objc.objc_allocateClassPair(superclass, class_name.ptr, 0) orelse
        return error.ClassRegistrationFailed;
    errdefer objc.objc_disposeClassPair(class);
    if (objc.class_addIvar(
        class,
        state_ivar.ptr,
        @sizeOf(?*State),
        @intCast(@ctz(@as(usize, @alignOf(?*State)))),
        "^v",
    ) == 0) return error.ClassRegistrationFailed;
    if (objc.class_addMethod(class, objc.sel("dealloc"), @ptrCast(&dealloc), "v@:") == 0)
        return error.MethodRegistrationFailed;
    inline for (attributes.selectors, 0..) |entry, index| {
        if (objc.class_addMethod(
            class,
            objc.sel(entry.name),
            implementation(index),
            encoding(index).ptr,
        ) == 0) return error.MethodRegistrationFailed;
    }
    objc.objc_registerClassPair(class);
    return class;
}

pub fn Result(comptime index: usize) type {
    return switch (attributes.selectors[index].returns) {
        .bool_ => objc.BOOL,
        .integer, .orientation => isize,
        .range => objc.NSRange,
        .rect => objc.NSRect,
        .void_ => void,
        else => ?objc.Object,
    };
}

fn Argument(comptime index: usize) type {
    return switch (index) {
        15, 44, 52 => ?objc.Object,
        23, 43 => objc.BOOL,
        32, 37, 38, 39 => isize,
        33 => objc.NSPoint,
        34, 35, 36, 40 => objc.NSRange,
        53 => objc.Sel,
        else => void,
    };
}

fn implementation(comptime index: usize) objc.IMP {
    const Method = struct {
        fn withoutArgument(object: objc.Object, _: objc.Sel) callconv(.c) Result(index) {
            return invoke(index, object, {});
        }
        fn withArgument(
            object: objc.Object,
            _: objc.Sel,
            arg: Argument(index),
        ) callconv(.c) Result(index) {
            return invoke(index, object, arg);
        }
    };
    return if (Argument(index) == void) @ptrCast(&Method.withoutArgument) else @ptrCast(&Method.withArgument);
}

const bool_encoding = if (builtin.cpu.arch == .aarch64) "B" else "c";

// BOOL is Objective-C's one-byte type; NSInteger and NSUInteger are 64-bit
// on both supported macOS architectures. SDK proof is owned by integration.
pub fn encoding(comptime index: usize) [:0]const u8 {
    const result = switch (attributes.selectors[index].returns) {
        .void_ => "v",
        .bool_ => bool_encoding,
        .integer, .orientation => "q",
        .range => "{_NSRange=QQ}",
        .rect => "{CGRect={CGPoint=dd}{CGSize=dd}}",
        else => "@",
    };
    const arg = switch (index) {
        15, 44, 52 => "@",
        23, 43 => bool_encoding,
        32, 37, 38, 39 => "q",
        33 => "{CGPoint=dd}",
        34, 35, 36, 40 => "{_NSRange=QQ}",
        53 => ":",
        else => "",
    };
    return result ++ "@:" ++ arg;
}

fn defunct(comptime index: usize) Result(index) {
    if (Result(index) == void) return;
    if (Result(index) == objc.BOOL) return if (index == 27) 1 else 0;
    if (Result(index) == isize) return 0;
    if (Result(index) == objc.NSRange) return zero_range;
    if (Result(index) == objc.NSRect) return zero_rect;
    if (index == 7)
        return objc.autoreleaseReturn(foundation.string("AXUnknown") catch return null);
    if (index == 51)
        return objc.autoreleaseReturn(foundation.array(&.{}) catch return null);
    return null;
}

fn invoke(comptime index: usize, object: objc.Object, arg: Argument(index)) Result(index) {
    if (index == 27) return 1;
    const owned = stateSlot(object).* orelse return defunct(index);
    var lease = owned.weak.lease() catch |err| {
        owned.weak.control.recordSelectorError(err);
        return defunct(index);
    };
    defer lease.deinit();
    const node = lease.resolve(owned.id) orelse return defunct(index);
    const answer = query(index, object, &lease, node, arg) catch |err| {
        owned.weak.control.recordSelectorError(err);
        return defunct(index);
    };
    if (Result(index) == ?objc.Object) {
        return if (answer) |value| objc.autoreleaseReturn(value) else null;
    }
    return answer;
}

const filter: consumer.filter.FilterFn = .{ .context = null, .filter = filterNode };
fn filterNode(_: ?*anyopaque, node: NodeRef) consumer.tree_state.QueryError!consumer.filter.FilterResult {
    return consumer.filter.commonFilter(node);
}

pub fn selectorAllowed(node: NodeRef, name: []const u8) NativeError!bool {
    for (attributes.answer_groups) |group| {
        for (group.selectors) |selector| {
            if (!std.mem.eql(u8, name, selector)) continue;
            return switch (group.answer) {
                .is_focusable => predicates.isFocusable(node, filter),
                .is_clickable => predicates.isClickable(node, filter),
                .supports_increment => predicates.supportsIncrement(node, filter),
                .supports_decrement => predicates.supportsDecrement(node, filter),
                .supports_text_ranges => text_query.supportsTextRanges(node),
                .set_value => ((try text_query.supportsTextRanges(node)) and
                    !predicates.isReadOnly(node)) or
                    (try predicates.supportsAction(node, .set_value, filter)),
                .is_item_like => itemLike(node),
                .is_container_with_selectable_children => selectableContainer(node),
                .selectable_item => (try predicates.isClickable(node, filter)) and
                    itemLike(node) and predicates.isSelectable(node),
                .is_tab_list => properties.role(node) == .tab_list,
                .is_dialog => predicates.isDialog(node),
                .has_any_attribute => properties.hasBrailleLabel(node) or
                    properties.hasBrailleRoleDescription(node) or set_state.hasHtmlId(node),
                .supports_url => strings.supportsUrl(node),
                .always => true,
                .unlisted => false,
            };
        }
    }
    return false;
}

fn itemLike(node: NodeRef) bool {
    return containers.isItemLike(node) and properties.role(node) != .tab;
}
fn selectableContainer(node: NodeRef) bool {
    return containers.isContainerWithSelectableChildren(node) and
        properties.role(node) != .tab_list;
}

pub fn valueRequest(
    gpa: std.mem.Allocator,
    state: *const consumer.tree_state.TreeState,
    id: FullNodeId,
    bytes: []const u8,
) NativeError!?schema.ActionRequest {
    const target = state.locateNode(id) orelse return null;
    return .{
        .action = .set_value,
        .target_node = target.local_id,
        .target_tree = target.tree_id,
        .data = .{ .value = try gpa.dupe(u8, bytes) },
    };
}

fn dispatch(
    lease: *ContextLease,
    id: FullNodeId,
    action: schema.Action,
    data: ?schema.ActionData,
) NativeError!void {
    const state = lease.state() orelse {
        releasePayload(lease.allocator(), data);
        return error.Closed;
    };
    const target = state.locateNode(id) orelse {
        releasePayload(lease.allocator(), data);
        return error.NoSuchNode;
    };
    try lease.dispatch(.{
        .action = action,
        .target_node = target.local_id,
        .target_tree = target.tree_id,
        .data = data,
    });
}

fn releasePayload(gpa: std.mem.Allocator, data: ?schema.ActionData) void {
    if (data) |payload| {
        var owned = payload;
        schema.actionDataDeinit(gpa, &owned);
    }
}

fn optionalString(bytes: ?[]const u8) NativeError!?objc.Object {
    return if (bytes) |value| try foundation.string(value) else null;
}

fn parentOfView(lease: *ContextLease) ?objc.Object {
    const view = lease.view() orelse return null;
    lease.releaseGuard();
    const answer = objc.send(?objc.Object, view, "accessibilityParent", .{}) orelse return null;
    return objc.retain(answer);
}

fn resolveAfterForeign(lease: *ContextLease, id: FullNodeId) NativeError!NodeRef {
    try lease.reacquireGuard();
    return lease.resolve(id) orelse error.NoSuchNode;
}

const Relation = enum { children, selected, rows, selected_rows, linked, tabs };
fn relation(
    lease: *ContextLease,
    node: NodeRef,
    kind: Relation,
) NativeError!?objc.Object {
    if (kind == .selected or kind == .rows or kind == .selected_rows) {
        if (!selectableContainer(node)) return null;
    }
    if (kind == .tabs and properties.role(node) != .tab_list) return null;
    const gpa = lease.allocator();
    var objects: std.ArrayList(objc.Object) = .empty;
    defer objects.deinit(gpa);
    defer for (objects.items) |owned| objc.release(owned);
    if (kind == .selected or kind == .rows or kind == .selected_rows) {
        var nodes = try containers.items(gpa, node, filter);
        defer nodes.deinit(gpa);
        for (nodes.items) |child| {
            if (kind != .rows and !(properties.isSelected(child) orelse false)) continue;
            try appendProvider(lease, &objects, child.id());
        }
    } else if (kind == .linked) {
        var nodes = set_state.controls(node);
        const bound = schema.ids_props.controls(&node.data().properties).len;
        var count: usize = 0;
        while (nodes.next()) |child| {
            if (count == bound) return error.TreeCycle;
            count += 1;
            if (try filter.call(child) != .include) continue;
            try appendProvider(lease, &objects, child.id());
        }
        if (objects.items.len == 0) return null;
    } else {
        var nodes = try hierarchy.filteredChildren(node, filter);
        const bound = consumer.tree_state.treeWalkStepBound(node.tree_state.nodes.count());
        var count: usize = 0;
        while (try nodes.next()) |child| {
            if (count == bound) return error.TreeCycle;
            count += 1;
            if (kind == .tabs and properties.role(child) != .tab) continue;
            try appendProvider(lease, &objects, child.id());
        }
    }
    const array = try foundation.array(objects.items);
    return array;
}

fn appendProvider(
    lease: *ContextLease,
    objects: *std.ArrayList(objc.Object),
    id: FullNodeId,
) NativeError!void {
    const owned = try lease.provider(id);
    errdefer objc.release(owned);
    try objects.append(lease.allocator(), owned);
}

fn query(
    comptime index: usize,
    object: objc.Object,
    lease: *ContextLease,
    node: NodeRef,
    arg: Argument(index),
) NativeError!Result(index) {
    const gpa = lease.allocator();
    const wrapper = pure_node.NodeWrapper.init(gpa, node);
    switch (index) {
        0 => {
            if (try hierarchy.filteredParent(node, filter)) |parent|
                return try lease.provider(parent.id());
            return parentOfView(lease);
        },
        1, 2 => return try lease.window(),
        3, 4 => return relation(lease, node, .children),
        5 => return relation(lease, node, .selected),
        6 => {
            const view = lease.view() orelse return zero_rect;
            if (try consumer.node_ref.geometry.boundingBox(node)) |rect| {
                lease.releaseGuard();
                return foundation.toScreenRect(view, rect);
            }
            if (hierarchy.isRoot(node)) {
                lease.releaseGuard();
                return objc.send(objc.NSRect, view, "accessibilityFrame", .{});
            }
            return zero_rect;
        },
        7 => return try foundation.string(roles.nsRole(properties.role(node), properties.toggled(node))),
        8 => return optionalString(roles.nsSubRole(properties.role(node), properties.toggled(node))),
        9 => {
            if (properties.roleDescription(node)) |description|
                return try foundation.string(description);
            const superclass = objc.class_getSuperclass(objc.object_getClass(object).?).?;
            // AppKit can reenter role and subrole getters. Keep only the owner pin.
            lease.releaseGuard();
            const answer = objc.sendSuper(
                ?objc.Object,
                object,
                superclass,
                "accessibilityRoleDescription",
                .{},
            ) orelse return null;
            return objc.retain(answer);
        },
        10 => return optionalString(set_state.authorId(node)),
        11, 12 => {
            const bytes = if (index == 11) try wrapper.title() else try wrapper.description();
            defer pure_node.releaseText(gpa, bytes);
            return if (bytes) |value| try foundation.string(value.items) else null;
        },
        13 => return optionalString(try wrapper.placeholder()),
        14 => {
            const value = try wrapper.value() orelse return null;
            defer value.deinit(gpa);
            return switch (value) {
                .boolean => |boolean| try foundation.boolean(boolean),
                .number => |number| try foundation.number(number),
                .string => |bytes| try foundation.string(bytes.items),
            };
        },
        15 => {
            const value = arg orelse return;
            const id = node.id();
            lease.releaseGuard();
            var payload: ?schema.ActionData = null;
            if (objc.getClass("NSString")) |class| {
                if (objc.send(objc.BOOL, value, "isKindOfClass:", .{class}) != 0) {
                    const bytes = try foundation.utf8(value);
                    payload = .{ .value = try gpa.dupe(u8, bytes) };
                }
            }
            if (payload == null) {
                if (objc.getClass("NSNumber")) |class| {
                    if (objc.send(objc.BOOL, value, "isKindOfClass:", .{class}) != 0)
                        payload = .{ .numeric_value = objc.send(f64, value, "doubleValue", .{}) };
                }
            }
            var owned = payload orelse return;
            const fresh = resolveAfterForeign(lease, id) catch |err| {
                schema.actionDataDeinit(gpa, &owned);
                return err;
            };
            try dispatch(lease, fresh.id(), .set_value, owned);
        },
        16, 17 => {
            const value = if (index == 16) properties.minNumericValue(node) else properties.maxNumericValue(node);
            return if (value) |number| try foundation.number(number) else null;
        },
        18 => {
            if (!strings.supportsUrl(node)) return null;
            return if (strings.url(node)) |bytes| try foundation.url(bytes) else null;
        },
        19 => return if (predicates.orientation(node)) |value|
            switch (value) {
                .horizontal => 2,
                .vertical => 1,
            }
        else
            0,
        20 => return @intFromBool(try filter.call(node) == .include),
        21 => return @intFromBool(predicates.isFocused(node) and
            (try filter.call(node) == .include) and properties.role(node) != .window),
        22 => return @intFromBool(!properties.isDisabled(node)),
        23 => {
            const target = if (arg != 0) node else (lease.state() orelse return error.Closed).root();
            if (try predicates.isFocusable(target, filter))
                try dispatch(lease, target.id(), .focus, null);
        },
        24, 25, 26, 47 => {
            const supported = switch (index) {
                24 => try predicates.isClickable(node, filter),
                25 => try predicates.supportsIncrement(node, filter),
                26 => try predicates.supportsDecrement(node, filter),
                47 => (try predicates.isClickable(node, filter)) and
                    itemLike(node) and predicates.isSelectable(node),
                // The outer switch admits only 24, 25, 26, and 47, all covered above.
                else => unreachable,
            };
            if (!supported) return 0;
            const action: schema.Action = switch (index) {
                25 => .increment,
                26 => .decrement,
                else => .click,
            };
            try dispatch(lease, node.id(), action, null);
            return 1;
        },
        27 => return 1,
        28...40 => return platform_text.query(index, lease, node, arg),
        41 => return @intFromBool(set_state.isRequired(node)),
        42 => return @intFromBool(itemLike(node) and predicates.isSelectable(node) and
            (properties.isSelected(node) orelse false)),
        43 => {
            if (!(try predicates.isClickable(node, filter)) or !itemLike(node) or
                !predicates.isSelectable(node)) return;
            if (properties.isSelected(node)) |selected| {
                if (selected == (arg != 0)) return;
            }
            try dispatch(lease, node.id(), .click, null);
        },
        44 => {
            const value = arg orelse return null;
            const id = node.id();
            lease.releaseGuard();
            const name = try foundation.utf8(value);
            const Attribute = enum { braille_label, braille_role, html_id };
            const attribute: Attribute = if (std.mem.eql(u8, name, "AXBrailleLabel"))
                .braille_label
            else if (std.mem.eql(u8, name, "AXBrailleRoleDescription"))
                .braille_role
            else if (std.mem.eql(u8, name, "AXDOMIdentifier"))
                .html_id
            else
                return null;
            const fresh = try resolveAfterForeign(lease, id);
            return optionalString(switch (attribute) {
                .braille_label => properties.brailleLabel(fresh),
                .braille_role => properties.brailleRoleDescription(fresh),
                .html_id => set_state.htmlId(fresh),
            });
        },
        45 => return relation(lease, node, .rows),
        46 => return relation(lease, node, .selected_rows),
        48 => return relation(lease, node, .linked),
        49 => return relation(lease, node, .tabs),
        50 => return @intFromBool(predicates.isModal(node)),
        51 => {
            if (try predicates.supportsAction(node, .scroll_into_view, filter)) {
                const name = try foundation.string("AXScrollToVisible");
                defer objc.release(name);
                return try foundation.array(&.{name});
            }
            return try foundation.array(&.{});
        },
        52 => {
            const action = arg orelse return;
            const id = node.id();
            lease.releaseGuard();
            if (!std.mem.eql(u8, try foundation.utf8(action), "AXScrollToVisible")) return;
            const fresh = try resolveAfterForeign(lease, id);
            try dispatch(lease, fresh.id(), .scroll_into_view, null);
        },
        53 => {
            inline for (attributes.selectors) |entry| {
                if (arg == objc.sel(entry.name))
                    return @intFromBool(try selectorAllowed(node, entry.name));
            }
            return 0;
        },
        else => @compileError("Selector lacks native behavior"),
    }
}

test "native selector admission distinguishes tabs items and unsupported action" {
    const gpa = std.testing.allocator;
    var update: schema.TreeUpdate = .{};
    errdefer update.deinit(gpa);
    var root = schema.Node.init(gpa, .tab_list);
    try schema.ids_props.setChildren(&root.properties, &.{.{ .value = 2 }});
    try update.pushNode(gpa, .{ .value = 1 }, root);
    var tab = schema.Node.init(gpa, .tab);
    try schema.enums.setSelected(&tab.properties, true);
    try update.pushNode(gpa, .{ .value = 2 }, tab);
    update.tree = schema.TreeInfo.init(.{ .value = 1 });
    update.focus = .{ .value = 1 };
    const built = consumer.tree.Tree.init(gpa, update, true);
    update = .{};
    var tree = try built;
    defer tree.deinit();
    const state = tree.stateOf();
    const root_ref = state.root();
    const tab_ref = state.nodeById(root_ref.id().withSameTree(.{ .value = 2 })).?;
    try std.testing.expect(try selectorAllowed(root_ref, "accessibilityTabs"));
    try std.testing.expect(!try selectorAllowed(root_ref, "accessibilityRows"));
    try std.testing.expect(!try selectorAllowed(tab_ref, "isAccessibilitySelected"));
    try std.testing.expect(!try selectorAllowed(tab_ref, "accessibilityPerformPress"));
    try std.testing.expect(try selectorAllowed(tab_ref, "accessibilityRole"));
    try std.testing.expect(!try selectorAllowed(tab_ref, "unrecognizedSelector"));
}

test "native action request retains embedded NUL and resolves full node identity" {
    const gpa = std.testing.allocator;
    var update: schema.TreeUpdate = .{};
    errdefer update.deinit(gpa);
    try update.pushNode(gpa, .{ .value = 73 }, schema.Node.init(gpa, .text_input));
    update.tree = schema.TreeInfo.init(.{ .value = 73 });
    update.focus = .{ .value = 73 };
    const built = consumer.tree.Tree.init(gpa, update, true);
    update = .{};
    var tree = try built;
    defer tree.deinit();
    var request = (try valueRequest(gpa, tree.stateOf(), tree.stateOf().rootId(), "a\x00b")).?;
    defer request.deinit(gpa);
    try std.testing.expectEqual(schema.Action.set_value, request.action);
    try std.testing.expectEqual(@as(u64, 73), request.target_node.value);
    try std.testing.expectEqualSlices(u8, "a\x00b", request.data.?.value);
    try std.testing.expect(try valueRequest(
        gpa,
        tree.stateOf(),
        tree.stateOf().rootId().withSameTree(.{ .value = 99 }),
        "unused",
    ) == null);
}

test "native class registers complete protocol and defunct objects answer upstream sentinels" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const Handler = struct {
        fn action(raw: ?*anyopaque, _: *const schema.ActionRequest) void {
            const count: *usize = @ptrCast(@alignCast(raw.?));
            count.* += 1;
        }
        fn activate(_: ?*anyopaque) void {}
    };
    var calls: usize = 0;
    const adapter = try native.NativeAdapter.create(std.testing.allocator, std.testing.io, .{
        .action_handler = Handler.action,
        .userdata = &calls,
        .activation_sink = .{ .native = .{ .callback = Handler.activate, .userdata = null } },
    });
    var adapter_live = true;
    defer if (adapter_live) {
        adapter.close() catch @panic("Defunct fixture close failed");
        adapter.deinit();
    };
    var weak = adapter.context.weak();
    const object = create(std.testing.allocator, weak, .{
        .local = .{ .value = 1 },
        .tree_index = @fromBackingInt(@intCast(0)),
    }) catch |err| {
        weak.deinit();
        return err;
    };
    defer objc.release(object);
    try adapter.close();
    adapter.deinit();
    adapter_live = false;
    inline for (attributes.selectors, 0..) |entry, index| {
        const answer = if (Argument(index) == void)
            objc.send(Result(index), object, entry.name, .{})
        else if (Argument(index) == objc.NSRange)
            objc.send(Result(index), object, entry.name, .{zero_range})
        else if (Argument(index) == objc.NSPoint)
            objc.send(Result(index), object, entry.name, .{objc.NSPoint{ .x = 0, .y = 0 }})
        else if (Argument(index) == objc.Sel)
            objc.send(Result(index), object, entry.name, .{objc.sel("accessibilityRole")})
        else if (Argument(index) == ?objc.Object)
            objc.send(Result(index), object, entry.name, .{@as(?objc.Object, null)})
        else
            objc.send(Result(index), object, entry.name, .{@as(Argument(index), 0)});
        if (Result(index) == void) {
            // A defunct setter must not dispatch an application action.
        } else if (Result(index) == objc.BOOL) {
            try std.testing.expectEqual(@as(objc.BOOL, if (index == 27) 1 else 0), answer);
        } else if (Result(index) == isize) {
            try std.testing.expectEqual(@as(isize, 0), answer);
        } else if (Result(index) == objc.NSRange) {
            try std.testing.expectEqual(zero_range, answer);
        } else if (Result(index) == objc.NSRect) {
            try std.testing.expectEqual(zero_rect, answer);
        } else if (index == 7) {
            try std.testing.expectEqualStrings("AXUnknown", try foundation.utf8(answer.?));
        } else if (index == 51) {
            try std.testing.expectEqual(@as(usize, 0), objc.send(usize, answer.?, "count", .{}));
        } else {
            try std.testing.expectEqual(@as(?objc.Object, null), answer);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), calls);
}

test "native value request allocation refusal leaves the input tree readable" {
    const gpa = std.testing.allocator;
    var update: schema.TreeUpdate = .{};
    errdefer update.deinit(gpa);
    try update.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .text_input));
    update.tree = schema.TreeInfo.init(.{ .value = 1 });
    update.focus = .{ .value = 1 };
    const built = consumer.tree.Tree.init(gpa, update, true);
    update = .{};
    var tree = try built;
    defer tree.deinit();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        valueRequest(failing.allocator(), tree.stateOf(), tree.stateOf().rootId(), "a\x00b"),
    );
    try std.testing.expectEqual(schema.Role.text_input, properties.role(tree.stateOf().root()));
}

test "native setters dispatch values and inherited role description permits reentry and close" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const application_class = objc.getClass("NSApplication") orelse return error.ObjectiveCUnavailable;
    const application = objc.send(?objc.Object, application_class, "sharedApplication", .{}) orelse
        return error.NativeObjectCreationFailed;
    _ = application;
    const window_class = objc.getClass("NSWindow") orelse return error.ObjectiveCUnavailable;
    const window_allocated = objc.send(?objc.Object, window_class, "alloc", .{}) orelse
        return error.NativeObjectCreationFailed;
    const window = objc.send(?objc.Object, window_allocated, "initWithContentRect:styleMask:backing:defer:", .{
        objc.NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 400, .height = 400 } },
        @as(usize, 0),
        @as(usize, 2),
        @as(objc.BOOL, 0),
    }) orelse return error.NativeObjectCreationFailed;
    defer objc.release(window);
    var probe: ForeignQueryProbe = .{};
    const Capture = struct {
        const Self = @This();

        object: ?objc.Object = null,
        calls: usize = 0,
        action: ?schema.Action = null,
        target: u64 = 0,
        numeric: ?f64 = null,
        selection: ?schema.TextSelection = null,
        bytes: [8]u8 = @splat(0),
        byte_count: usize = 0,
        role_reentry: bool = false,
        fn actionCallback(raw: ?*anyopaque, request: *const schema.ActionRequest) void {
            const self: *Self = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            self.action = request.action;
            self.target = request.target_node.value;
            if (request.data) |payload| switch (payload) {
                .value => |bytes| {
                    std.debug.assert(bytes.len <= self.bytes.len);
                    @memcpy(self.bytes[0..bytes.len], bytes);
                    self.byte_count = bytes.len;
                },
                .numeric_value => |number| self.numeric = number,
                .set_text_selection => |selection| self.selection = selection,
                else => {},
            };
            const role = objc.send(?objc.Object, self.object.?, "accessibilityRole", .{});
            self.role_reentry = role != null;
        }
        fn activate(_: ?*anyopaque) void {}
        fn full(raw: ?*anyopaque) *const schema.TreeUpdate {
            return @ptrCast(@alignCast(raw.?));
        }
    };
    var capture: Capture = .{};
    const adapter = try native.NativeAdapter.create(gpa, std.testing.io, .{
        .action_handler = Capture.actionCallback,
        .userdata = &capture,
        .activation_sink = .{ .native = .{ .callback = Capture.activate, .userdata = null } },
    });
    defer {
        adapter.close() catch @panic("Native fixture close failed");
        adapter.deinit();
    }
    const view_class = try ForeignQueryProbe.register(false);
    const view = objc.send(?objc.Object, view_class, "alloc", .{}) orelse
        return error.NativeObjectCreationFailed;
    const initialized = objc.send(?objc.Object, view, "initWithFrame:", .{zero_rect}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(initialized);
    ForeignQueryProbe.slot(initialized).* = &probe;
    defer ForeignQueryProbe.slot(initialized).* = null;
    probe.view = initialized;
    objc.send(void, window, "setContentView:", .{initialized});
    try adapter.attach(.{ .view = initialized }, true);
    const initial = objc.send(?objc.Object, initialized, "accessibilityChildren", .{});
    try std.testing.expect(initial != null);
    try std.testing.expect(adapter.isActive());
    var update: schema.TreeUpdate = .{};
    defer update.deinit(gpa);
    var root = schema.Node.init(gpa, .window);
    try schema.ids_props.setChildren(&root.properties, &.{ .{ .value = 2 }, .{ .value = 3 } });
    try schema.option.setBounds(&root.properties, schema.rectInit(0, 0, 300, 200));
    try update.pushNode(gpa, .{ .value = 1 }, root);
    var child = schema.Node.init(gpa, .text_input);
    child.addAction(.set_value);
    child.addAction(.click);
    child.addAction(.focus);
    child.addAction(.increment);
    child.addAction(.decrement);
    child.addAction(.scroll_into_view);
    try schema.strings.setLabel(&child.properties, "name");
    try schema.strings.setDescription(&child.properties, "help");
    try schema.strings.setValue(&child.properties, "old\x00value");
    try schema.strings.setAuthorId(&child.properties, "author");
    try schema.strings.setPlaceholder(&child.properties, "hint");
    try schema.strings.setRoleDescription(&child.properties, "custom role");
    try schema.strings.setBrailleLabel(&child.properties, "braille");
    try schema.strings.setBrailleRoleDescription(&child.properties, "braille role");
    try schema.strings.setHtmlId(&child.properties, "html");
    try schema.numbers.setMinNumericValue(&child.properties, -1);
    try schema.numbers.setMaxNumericValue(&child.properties, 100);
    try update.pushNode(gpa, .{ .value = 2 }, child);
    var editor = schema.Node.init(gpa, .multiline_text_input);
    try schema.ids_props.setChildren(&editor.properties, &.{.{ .value = 4 }});
    try schema.option.setTextSelection(&editor.properties, .{
        .anchor = .{ .node_id = .{ .value = 4 }, .character_index = 1 },
        .focus = .{ .node_id = .{ .value = 4 }, .character_index = 3 },
    });
    try update.pushNode(gpa, .{ .value = 3 }, editor);
    var run = schema.Node.init(gpa, .text_run);
    try schema.strings.setValue(&run.properties, "a\u{1f642}é\x00b");
    try schema.vectors.setCharacterLengths(&run.properties, &.{ 1, 4, 2, 1, 1 });
    try schema.vectors.setCharacterPositions(&run.properties, &.{ 0, 10, 20, 30, 40 });
    try schema.vectors.setCharacterWidths(&run.properties, &.{ 10, 10, 10, 10, 10 });
    try schema.option.setBounds(&run.properties, schema.rectInit(0, 0, 50, 10));
    try schema.enums.setTextDirection(&run.properties, .left_to_right);
    try update.pushNode(gpa, .{ .value = 4 }, run);
    update.tree = schema.TreeInfo.init(.{ .value = 1 });
    update.focus = .{ .value = 2 };
    switch (adapter.updateIfActiveBorrowedChecked(&update, .{
        .context = &update,
        .get = Capture.full,
    })) {
        .committed => |receipt| {
            if (receipt.notification_error) |err| return err;
        },
        .rejected => |err| return err,
        .inactive => return error.TestUnexpectedResult,
    }
    var weak = adapter.context.weak();
    defer weak.deinit();
    var lease = try weak.lease();
    defer lease.deinit();
    const state = lease.state().?;
    const object = try lease.provider(state.rootId().withSameTree(.{ .value = 2 }));
    defer objc.release(object);
    const text_object = try lease.provider(state.rootId().withSameTree(.{ .value = 3 }));
    defer objc.release(text_object);
    lease.deinit();
    capture.object = object;
    inline for (.{
        .{ "accessibilityRole", "AXTextField" },
        .{ "accessibilityRoleDescription", "custom role" },
        .{ "accessibilityIdentifier", "author" },
        .{ "accessibilityTitle", "name" },
        .{ "accessibilityHelp", "help" },
        .{ "accessibilityPlaceholderValue", "hint" },
        .{ "accessibilityValue", "old\x00value" },
    }) |step| {
        const value = objc.send(?objc.Object, object, step[0], .{}).?;
        try std.testing.expectEqualStrings(step[1], try foundation.utf8(value));
    }
    inline for (.{
        .{ "AXBrailleLabel", "braille" },
        .{ "AXBrailleRoleDescription", "braille role" },
        .{ "AXDOMIdentifier", "html" },
    }) |step| {
        const attribute = try foundation.string(step[0]);
        defer objc.release(attribute);
        const value = objc.send(?objc.Object, object, "accessibilityAttributeValue:", .{attribute}).?;
        try std.testing.expectEqualStrings(step[1], try foundation.utf8(value));
    }
    const minimum = objc.send(?objc.Object, object, "accessibilityMinValue", .{}).?;
    const maximum = objc.send(?objc.Object, object, "accessibilityMaxValue", .{}).?;
    try std.testing.expectEqual(@as(f64, -1), objc.send(f64, minimum, "doubleValue", .{}));
    try std.testing.expectEqual(@as(f64, 100), objc.send(f64, maximum, "doubleValue", .{}));
    const parent = objc.send(?objc.Object, object, "accessibilityParent", .{}).?;
    const children = objc.send(?objc.Object, parent, "accessibilityChildren", .{}).?;
    try std.testing.expectEqual(@as(usize, 2), objc.send(usize, children, "count", .{}));
    try std.testing.expectEqual(object, objc.send(objc.Object, children, "objectAtIndex:", .{@as(usize, 0)}));
    const expected_frame = try foundation.toScreenRect(initialized, schema.rectInit(0, 0, 300, 200));
    probe.host_reads = 0;
    probe.root = null;
    const actual_frame = objc.send(objc.NSRect, parent, "accessibilityFrame", .{});
    try std.testing.expectEqualDeep(expected_frame, actual_frame);
    try std.testing.expect(probe.host_reads >= 2);
    try std.testing.expectEqual(@as(usize, 1), probe.child_count);
    try std.testing.expectEqual(@as(?objc.Object, parent), probe.root);
    try std.testing.expectEqual(@as(?objc.Object, window), objc.send(?objc.Object, object, "accessibilityWindow", .{}));
    try std.testing.expectEqual(
        @as(?objc.Object, window),
        objc.send(?objc.Object, object, "accessibilityTopLevelUIElement", .{}),
    );
    try std.testing.expect(objc.send(objc.BOOL, object, "isAccessibilityElement", .{}) != 0);
    try std.testing.expect(objc.send(objc.BOOL, object, "isAccessibilityEnabled", .{}) != 0);
    try std.testing.expect(objc.send(objc.BOOL, object, "isAccessibilityFocused", .{}) != 0);
    const string = try foundation.string("a\x00b");
    defer objc.release(string);
    objc.send(void, object, "setAccessibilityValue:", .{string});
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(schema.Action.set_value, capture.action.?);
    try std.testing.expectEqual(@as(u64, 2), capture.target);
    try std.testing.expectEqualSlices(u8, "a\x00b", capture.bytes[0..capture.byte_count]);
    try std.testing.expect(capture.role_reentry);
    const number = try foundation.number(42.25);
    defer objc.release(number);
    objc.send(void, object, "setAccessibilityValue:", .{number});
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(@as(f64, 42.25), capture.numeric.?);
    inline for (.{
        .{ "accessibilityPerformPress", schema.Action.click },
        .{ "accessibilityPerformIncrement", schema.Action.increment },
        .{ "accessibilityPerformDecrement", schema.Action.decrement },
    }, 3..) |step, count| {
        try std.testing.expect(objc.send(objc.BOOL, object, step[0], .{}) != 0);
        try std.testing.expectEqual(@as(usize, count), capture.calls);
        try std.testing.expectEqual(step[1], capture.action.?);
    }
    objc.send(void, object, "setAccessibilityFocused:", .{@as(objc.BOOL, 1)});
    try std.testing.expectEqual(@as(usize, 6), capture.calls);
    try std.testing.expectEqual(schema.Action.focus, capture.action.?);
    const scroll = try foundation.string("AXScrollToVisible");
    defer objc.release(scroll);
    const names = objc.send(?objc.Object, object, "accessibilityActionNames", .{}).?;
    try std.testing.expectEqual(@as(usize, 1), objc.send(usize, names, "count", .{}));
    const name = objc.send(objc.Object, names, "objectAtIndex:", .{@as(usize, 0)});
    try std.testing.expectEqualStrings("AXScrollToVisible", try foundation.utf8(name));
    objc.send(void, object, "accessibilityPerformAction:", .{scroll});
    try std.testing.expectEqual(@as(usize, 7), capture.calls);
    try std.testing.expectEqual(schema.Action.scroll_into_view, capture.action.?);
    // The editor has no custom description. AppKit derives it through role getters.
    const text_role = objc.send(objc.Object, text_object, "accessibilityRole", .{});
    const text_subrole = objc.send(?objc.Object, text_object, "accessibilitySubrole", .{});
    try std.testing.expectEqual(@as(?objc.Object, null), text_subrole);
    const element_class = objc.getClass("NSAccessibilityElement") orelse return error.ObjectiveCUnavailable;
    const baseline = objc.send(?objc.Object, element_class, "accessibilityElementWithRole:frame:label:parent:", .{
        text_role, zero_rect, @as(?objc.Object, null), @as(?objc.Object, null),
    }) orelse return error.NativeObjectCreationFailed;
    const expected_description = objc.send(?objc.Object, baseline, "accessibilityRoleDescription", .{}) orelse
        return error.TestUnexpectedResult;
    const default_description = objc.send(?objc.Object, text_object, "accessibilityRoleDescription", .{}) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        try foundation.utf8(expected_description),
        try foundation.utf8(default_description),
    );
    const role_after_reentry = objc.send(objc.Object, text_object, "accessibilityRole", .{});
    try std.testing.expectEqualStrings("AXTextArea", try foundation.utf8(role_after_reentry));
    try std.testing.expectEqual(@as(isize, 6), objc.send(isize, text_object, "accessibilityNumberOfCharacters", .{}));
    const selected = objc.send(?objc.Object, text_object, "accessibilitySelectedText", .{}).?;
    try std.testing.expectEqualStrings("\u{1f642}é", try foundation.utf8(selected));
    try std.testing.expectEqualDeep(
        objc.NSRange{ .location = 1, .length = 3 },
        objc.send(objc.NSRange, text_object, "accessibilitySelectedTextRange", .{}),
    );
    const string_range = objc.send(?objc.Object, text_object, "accessibilityStringForRange:", .{
        objc.NSRange{ .location = 0, .length = 6 },
    }).?;
    try std.testing.expectEqualStrings("a\u{1f642}é\x00b", try foundation.utf8(string_range));
    const styled = objc.send(?objc.Object, text_object, "accessibilityAttributedStringForRange:", .{
        objc.NSRange{ .location = 1, .length = 3 },
    }).?;
    const styled_string = objc.send(objc.Object, styled, "string", .{});
    try std.testing.expectEqualStrings("\u{1f642}é", try foundation.utf8(styled_string));
    objc.send(void, text_object, "setAccessibilitySelectedTextRange:", .{objc.NSRange{ .location = 4, .length = 1 }});
    try std.testing.expectEqual(@as(usize, 8), capture.calls);
    try std.testing.expectEqual(schema.Action.set_text_selection, capture.action.?);
    try std.testing.expectEqual(@as(u64, 3), capture.target);
    try std.testing.expectEqual(@as(u64, 4), capture.selection.?.anchor.node_id.value);
    try std.testing.expectEqual(@as(usize, 3), capture.selection.?.anchor.character_index);
    try std.testing.expectEqual(@as(usize, 4), capture.selection.?.focus.character_index);
    const expected_text_frame = try foundation.toScreenRect(initialized, schema.rectInit(10, 0, 30, 10));
    probe.host_reads = 0;
    try std.testing.expectEqualDeep(
        expected_text_frame,
        objc.send(objc.NSRect, text_object, "accessibilityFrameForRange:", .{
            objc.NSRange{ .location = 1, .length = 3 },
        }),
    );
    try std.testing.expect(probe.host_reads >= 2);
    try std.testing.expectEqual(@as(?objc.Object, parent), probe.root);
    const screen_box = try foundation.toScreenRect(initialized, schema.rectInit(14, 4, 16, 6));
    const screen_point: objc.NSPoint = .{
        .x = screen_box.origin.x + screen_box.size.width / 2,
        .y = screen_box.origin.y + screen_box.size.height / 2,
    };
    probe.host_reads = 0;
    try std.testing.expectEqualDeep(
        objc.NSRange{ .location = 1, .length = 2 },
        objc.send(objc.NSRange, text_object, "accessibilityRangeForPosition:", .{screen_point}),
    );
    try std.testing.expect(probe.host_reads >= 2);
    try std.testing.expectEqual(@as(?objc.Object, parent), probe.root);
    const input_backing = try foundation.string("r\x00s");
    defer objc.release(input_backing);
    probe.backing = input_backing;
    const foreign_input = try probe.input();
    defer objc.release(foreign_input);
    defer ForeignQueryProbe.slot(foreign_input).* = null;
    probe.input_reads = 0;
    // Exercise the registered Objective-C trampoline, not a synthetic error echo.
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    adapter.context.gpa = failing.allocator();
    defer adapter.context.gpa = gpa;
    const before_failure = capture.calls;
    objc.send(void, object, "setAccessibilityValue:", .{input_backing});
    try std.testing.expectEqual(before_failure, capture.calls);
    try std.testing.expectEqual(error.OutOfMemory, adapter.context.takeSelectorError().?);
    try std.testing.expectEqual(@as(?NativeError, null), adapter.context.takeSelectorError());
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    adapter.context.gpa = gpa;
    objc.send(void, object, "setAccessibilityValue:", .{input_backing});
    try std.testing.expectEqual(before_failure + 1, capture.calls);
    try std.testing.expectEqual(@as(?NativeError, null), adapter.context.takeSelectorError());
    objc.send(void, object, "setAccessibilityValue:", .{foreign_input});
    try std.testing.expectEqual(@as(usize, 10), capture.calls);
    try std.testing.expectEqual(schema.Action.set_value, capture.action.?);
    try std.testing.expectEqualSlices(u8, "r\x00s", capture.bytes[0..capture.byte_count]);
    try std.testing.expect(probe.input_reads >= 2);
    try std.testing.expectEqual(@as(?objc.Object, parent), probe.root);
    const attribute_backing = try foundation.string("AXBrailleLabel");
    defer objc.release(attribute_backing);
    probe.backing = attribute_backing;
    const foreign_attribute = objc.send(?objc.Object, object, "accessibilityAttributeValue:", .{foreign_input}) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("braille", try foundation.utf8(foreign_attribute));
    probe.backing = scroll;
    objc.send(void, object, "accessibilityPerformAction:", .{foreign_input});
    try std.testing.expectEqual(@as(usize, 11), capture.calls);
    try std.testing.expectEqual(schema.Action.scroll_into_view, capture.action.?);
}

test "native node factory allocation refusal preserves caller weak ownership" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const Handler = struct {
        fn action(_: ?*anyopaque, _: *const schema.ActionRequest) void {}
        fn activate(_: ?*anyopaque) void {}
    };
    const adapter = try native.NativeAdapter.create(std.testing.allocator, std.testing.io, .{
        .action_handler = Handler.action,
        .activation_sink = .{ .native = .{ .callback = Handler.activate, .userdata = null } },
    });
    defer {
        adapter.close() catch @panic("Native allocation fixture close failed");
        adapter.deinit();
    }
    var refused = adapter.context.weak();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        create(failing.allocator(), refused, .{
            .local = .{ .value = 1 },
            .tree_index = @fromBackingInt(@intCast(0)),
        }),
    );
    // The failure did not consume this anchor. A real lease remains admissible.
    var lease = try refused.lease();
    lease.deinit();
    refused.deinit();
    var succeeded = adapter.context.weak();
    var succeeding = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const object = create(succeeding.allocator(), succeeded, .{
        .local = .{ .value = 1 },
        .tree_index = @fromBackingInt(@intCast(0)),
    }) catch |err| {
        succeeded.deinit();
        return err;
    };
    objc.release(object);
}

test "native final weak authority observes the node payload already released" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const Handler = struct {
        fn action(_: ?*anyopaque, _: *const schema.ActionRequest) void {}
        fn activate(_: ?*anyopaque) void {}
    };
    const Observer = struct {
        const Self = @This();

        allocator: *std.testing.FailingAllocator,
        calls: usize = 0,
        released_before_authority: bool = false,
        fn release(raw: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            self.released_before_authority = self.allocator.allocations == 1 and
                self.allocator.deallocations == 1;
        }
    };
    var tracked = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var observer: Observer = .{ .allocator = &tracked };
    const adapter = try native.NativeAdapter.create(std.testing.allocator, std.testing.io, .{
        .action_handler = Handler.action,
        .activation_sink = .{ .native = .{ .callback = Handler.activate, .userdata = null } },
    });
    var adapter_live = true;
    defer if (adapter_live) {
        adapter.close() catch @panic("Native authority fixture close failed");
        adapter.deinit();
    };
    adapter.context.setRuntimeRelease(.{ .userdata = &observer, .release = Observer.release });
    var weak = adapter.context.weak();
    const object = create(tracked.allocator(), weak, .{
        .local = .{ .value = 1 },
        .tree_index = @fromBackingInt(@intCast(0)),
    }) catch |err| {
        weak.deinit();
        // The adapter cleanup below releases its original context reference.
        return err;
    };
    var object_live = true;
    defer if (object_live) objc.release(object);
    try adapter.close();
    adapter.deinit();
    adapter_live = false;
    try std.testing.expectEqual(@as(usize, 0), observer.calls);
    objc.release(object);
    object_live = false;
    try std.testing.expectEqual(@as(usize, 1), observer.calls);
    try std.testing.expect(observer.released_before_authority);
}

// These native probes use actual subclasses. Their state borrows the test scope.
const ForeignQueryProbe = struct {
    view: ?objc.Object = null,
    backing: ?objc.Object = null,
    host_reads: usize = 0,
    input_reads: usize = 0,
    child_count: usize = 0,
    root: ?objc.Object = null,
    const ivar_name: [:0]const u8 = "_zaccesskitForeignQueryProbe";

    fn slot(object: objc.Object) *?*ForeignQueryProbe {
        const ivar = objc.class_getInstanceVariable(objc.object_getClass(object).?, ivar_name.ptr).?;
        const bytes: [*]u8 = @ptrCast(object);
        const offset: usize = @intCast(objc.ivar_getOffset(ivar));
        return @ptrCast(@alignCast(bytes + offset));
    }

    fn queryChildren(self: *ForeignQueryProbe, view: objc.Object) void {
        const children = objc.send(?objc.Object, view, "accessibilityChildren", .{}) orelse return;
        self.child_count = objc.send(usize, children, "count", .{});
        self.root = if (self.child_count == 0)
            null
        else
            objc.send(objc.Object, children, "objectAtIndex:", .{@as(usize, 0)});
    }

    fn flipped(object: objc.Object, _: objc.Sel) callconv(.c) objc.BOOL {
        if (slot(object).*) |probe| {
            probe.host_reads += 1;
            probe.queryChildren(object);
        }
        return 0;
    }

    fn bounds(object: objc.Object, _: objc.Sel) callconv(.c) objc.NSRect {
        if (slot(object).*) |probe| {
            probe.host_reads += 1;
            probe.queryChildren(object);
        }
        const superclass = objc.getClass("NSView").?;
        return objc.sendSuper(objc.NSRect, object, superclass, "bounds", .{});
    }

    fn stringLength(object: objc.Object, _: objc.Sel) callconv(.c) usize {
        const probe = slot(object).* orelse return 0;
        return objc.send(usize, probe.backing.?, "length", .{});
    }

    fn character(
        object: objc.Object,
        _: objc.Sel,
        index: usize,
    ) callconv(.c) u16 {
        const probe = slot(object).* orelse return 0;
        return objc.send(u16, probe.backing.?, "characterAtIndex:", .{index});
    }

    fn utf8(object: objc.Object, _: objc.Sel) callconv(.c) ?[*:0]const u8 {
        const probe = slot(object).* orelse return null;
        probe.input_reads += 1;
        probe.queryChildren(probe.view.?);
        return objc.send(?[*:0]const u8, probe.backing.?, "UTF8String", .{});
    }

    fn byteLength(
        object: objc.Object,
        _: objc.Sel,
        string_encoding: usize,
    ) callconv(.c) usize {
        const probe = slot(object).* orelse return 0;
        probe.input_reads += 1;
        probe.queryChildren(probe.view.?);
        return objc.send(usize, probe.backing.?, "lengthOfBytesUsingEncoding:", .{string_encoding});
    }

    fn register(comptime is_input: bool) NativeError!objc.Class {
        const name: [:0]const u8 = if (is_input)
            "ZAccessKitReentrantInputFixture"
        else
            "ZAccessKitReentrantViewFixture";
        if (objc.getClass(name)) |existing| return existing;
        const superclass = objc.getClass(if (is_input) "NSString" else "NSView") orelse
            return error.ObjectiveCUnavailable;
        const class = objc.objc_allocateClassPair(superclass, name.ptr, 0) orelse
            return error.ClassRegistrationFailed;
        errdefer objc.objc_disposeClassPair(class);
        if (objc.class_addIvar(
            class,
            ivar_name.ptr,
            @sizeOf(?*ForeignQueryProbe),
            @intCast(@ctz(@as(usize, @alignOf(?*ForeignQueryProbe)))),
            "^v",
        ) == 0)
            return error.ClassRegistrationFailed;
        if (is_input) {
            if (objc.class_addMethod(class, objc.sel("length"), @ptrCast(&stringLength), "Q@:") == 0)
                return error.MethodRegistrationFailed;
            if (objc.class_addMethod(class, objc.sel("characterAtIndex:"), @ptrCast(&character), "S@:Q") == 0)
                return error.MethodRegistrationFailed;
            if (objc.class_addMethod(class, objc.sel("UTF8String"), @ptrCast(&utf8), "r*@:") == 0)
                return error.MethodRegistrationFailed;
            if (objc.class_addMethod(
                class,
                objc.sel("lengthOfBytesUsingEncoding:"),
                @ptrCast(&byteLength),
                "Q@:Q",
            ) == 0)
                return error.MethodRegistrationFailed;
        } else {
            if (objc.class_addMethod(class, objc.sel("isFlipped"), @ptrCast(&flipped), encoding(20).ptr) == 0)
                return error.MethodRegistrationFailed;
            if (objc.class_addMethod(class, objc.sel("bounds"), @ptrCast(&bounds), encoding(6).ptr) == 0)
                return error.MethodRegistrationFailed;
        }
        objc.objc_registerClassPair(class);
        return class;
    }

    fn input(self: *ForeignQueryProbe) NativeError!objc.Object {
        const class = try register(true);
        const superclass = objc.getClass("NSObject").?;
        const metaclass = objc.object_getClass(superclass).?;
        // Bypass NSString's class cluster and allocate this concrete subclass.
        const allocated = objc.sendSuper(?objc.Object, class, metaclass, "alloc", .{}) orelse
            return error.NativeObjectCreationFailed;
        // This concrete NSString stores its backing in the test-owned state.
        const initialized = objc.sendSuper(?objc.Object, allocated, objc.getClass("NSObject").?, "init", .{}) orelse
            return error.NativeObjectCreationFailed;
        slot(initialized).* = self;
        return initialized;
    }
};
