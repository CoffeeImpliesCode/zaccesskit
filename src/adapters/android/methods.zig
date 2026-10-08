//! The Android adapter's 68 Java method names and 38 lookup triples.
//!
//! `docs/42-native-adapter-build-map.md` section 1.4.2 records the name list.
//! The original API map provides 27 lookup rows. This census adds eleven documented
//! gate, package, and scroll lookups from ledger rows 476 and 520.
//! The documented ViewParent send signature replaces its former name-only row.
//! There are 34 signature-bearing rows, four name-only rows, and 33 covered names.
//!
//! **A name alone does not identify a method here.** `GetMethodID` takes three
//! strings, and three names in this set are shared: `obtain`, which names a
//! factory on `AccessibilityEvent`, on `AccessibilityNodeInfo` and on
//! `RangeInfo`; `setParent`, which is overloaded on one class; and `<init>`,
//! which names a constructor on `android.graphics.Rect` and another on
//! `AccessibilityAction`.
//!
//! | Name | Rows | Why one name is not enough |
//! |---|---|---|
//! | `obtain` | 3 | Three unrelated classes take it |
//! | `setParent` | 2 | One class takes two overloads |
//! | `<init>` | 2 | Two classes take a constructor |
//!
//! So `findByName` is ambiguous by construction and exists only to say so, and
//! `findById` takes the whole triple.
//!
//! **What the map's grouping table leaves out.** Section 1.4.2 also groups the
//! 68 by the Java type each name is sent to. That grouping partitions **63** of
//! the 68: `add`, `getPackageName`, `post`, `setFromIndex` and `setToIndex`
//! appear in no row of it, although all five are in the flat list. The flat
//! list is the one the map calls verified, because it is the one that adds up,
//! so this module follows the flat list and records the grouping gap.
//!
//! Each census walk is bounded by its array length.

const std = @import("std");

const classes = @import("classes.zig");

const testing = std.testing;

/// One Java method, as the name the adapter passes to `GetMethodID`.
pub const MethodName = [:0]const u8;

/// How many names `method_names` holds.
pub const method_name_count = 68;

/// The 68 distinct Java method names, in the map's sorted order.
pub const method_names = [method_name_count]MethodName{
    "add",
    "addAction",
    "addChild",
    "containsKey",
    "createAccessibilityNodeInfo",
    "findFocus",
    "getAccessibilityDelegate",
    "getBoolean",
    "getContext",
    "getExtras",
    "getFloat",
    "getInt",
    "getLocationOnScreen",
    "getPackageName",
    "getParent",
    "getSystemService",
    "getText",
    "invalidate",
    "isEnabled",
    "loadClass",
    "newCallback",
    "obtain",
    "onHoverEvent",
    "performAction",
    "post",
    "putString",
    "requestSendAccessibilityEvent",
    "runCallback",
    "setAccessibilityDelegate",
    "setAccessibilityFocused",
    "setAction",
    "setAddedCount",
    "setBeforeText",
    "setBoundsInScreen",
    "setCheckable",
    "setChecked",
    "setClassName",
    "setContentChangeTypes",
    "setContentDescription",
    "setCurrentItemIndex",
    "setEditable",
    "setEnabled",
    "setFocusable",
    "setFocused",
    "setFromIndex",
    "setItemCount",
    "setLiveRegion",
    "setMaxScrollX",
    "setMaxScrollY",
    "setMovementGranularities",
    "setMovementGranularity",
    "setOnHoverListener",
    "setPackageName",
    "setParent",
    "setPassword",
    "setRangeInfo",
    "setRemovedCount",
    "setScrollable",
    "setScrollDeltaX",
    "setScrollDeltaY",
    "setScrollX",
    "setScrollY",
    "setSelected",
    "setSource",
    "setText",
    "setTextSelection",
    "setToIndex",
    "setVisibleToUser",
};

/// Why a row of `method_ids` is in the table.
pub const MethodKind = enum {
    /// One of the five methods `AK/android/src/inject.rs:257-291` registers on
    /// the delegate class.
    registered_native,
    /// A member with a JNI descriptor from the API map or pinned source.
    called_member,
    /// A named lookup whose JNI descriptor is not pinned. `signature` is null.
    reached_by_name,
};

/// One Java method lookup, as the three strings `GetMethodID` takes.
///
/// `signature = null` identifies one of the four name-only lookup rows.
pub const MethodId = struct {
    kind: MethodKind,
    class: classes.ClassDescriptor,
    name: MethodName,
    signature: ?[:0]const u8,
};

/// How many rows `method_ids` holds.
pub const method_id_count = 38;

/// How many rows of `method_ids` carry a JNI descriptor.
pub const pinned_signature_count = 34;

/// Method names absent from the lookup table, not signature rows.
pub const unpinned_name_count = 35;

/// Unique names with at least one lookup row, including name-only rows.
/// Constructors are not in the 68-name inventory and do not count here.
pub const pinned_name_count = 33;

/// Every Java method lookup the adapter builds, grouped by kind.
pub const method_ids = [method_id_count]MethodId{
    // 5 registered native methods on the delegate class.
    .{
        .kind = .registered_native,
        .class = classes.delegate_class_descriptor,
        .name = "runCallback",
        .signature = "(Landroid/view/View;J)V",
    },
    .{
        .kind = .registered_native,
        .class = classes.delegate_class_descriptor,
        .name = "createAccessibilityNodeInfo",
        .signature = "(JLandroid/view/View;I)Landroid/view/accessibility/AccessibilityNodeInfo;",
    },
    .{
        .kind = .registered_native,
        .class = classes.delegate_class_descriptor,
        .name = "findFocus",
        .signature = "(JLandroid/view/View;I)Landroid/view/accessibility/AccessibilityNodeInfo;",
    },
    .{
        .kind = .registered_native,
        .class = classes.delegate_class_descriptor,
        .name = "performAction",
        .signature = "(JLandroid/view/View;IILandroid/os/Bundle;)Z",
    },
    .{
        .kind = .registered_native,
        .class = classes.delegate_class_descriptor,
        .name = "onHoverEvent",
        .signature = "(JLandroid/view/View;IFF)Z",
    },
    // 17 members with a JNI descriptor, `docs/29` rows 29 to 46.
    .{
        .kind = .called_member,
        .class = "Landroid/view/View;",
        .name = "getAccessibilityDelegate",
        .signature = "()Landroid/view/View$AccessibilityDelegate;",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/View;",
        .name = "setAccessibilityDelegate",
        .signature = "(Landroid/view/View$AccessibilityDelegate;)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/View;",
        .name = "setOnHoverListener",
        .signature = "(Landroid/view/View$OnHoverListener;)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/View;",
        .name = "post",
        .signature = "(Ljava/lang/Runnable;)Z",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/View;",
        .name = "getParent",
        .signature = "()Landroid/view/ViewParent;",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/View;",
        .name = "getLocationOnScreen",
        .signature = "([I)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityEvent;",
        .name = "obtain",
        .signature = "(I)Landroid/view/accessibility/AccessibilityEvent;",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityEvent;",
        .name = "setPackageName",
        .signature = "(Ljava/lang/CharSequence;)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityEvent;",
        .name = "setSource",
        .signature = "(Landroid/view/View;I)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityEvent;",
        .name = "setContentChangeTypes",
        .signature = "(I)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
        .name = "obtain",
        .signature = "(Landroid/view/View;I)Landroid/view/accessibility/AccessibilityNodeInfo;",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
        .name = "addChild",
        .signature = "(Landroid/view/View;I)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
        .name = "setParent",
        .signature = "(Landroid/view/View;)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
        .name = "setParent",
        .signature = "(Landroid/view/View;I)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
        .name = "addAction",
        .signature = "(I)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityNodeInfo$RangeInfo;",
        .name = "obtain",
        .signature = "(IFFF)Landroid/view/accessibility/AccessibilityNodeInfo$RangeInfo;",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/graphics/Rect;",
        .name = "<init>",
        .signature = "(IIII)V",
    },
    // Gate sources: pinned util.rs:208-250 and documented manager API, ledger row 520.
    .{
        .kind = .called_member,
        .class = "Landroid/view/View;",
        .name = "getContext",
        .signature = "()Landroid/content/Context;",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/content/Context;",
        .name = "getSystemService",
        .signature = "(Ljava/lang/String;)Ljava/lang/Object;",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityManager;",
        .name = "isEnabled",
        .signature = "()Z",
    },
    // Pinned util.rs:215-224 supplies the package-name descriptor.
    .{
        .kind = .called_member,
        .class = "Landroid/content/Context;",
        .name = "getPackageName",
        .signature = "()Ljava/lang/String;",
    },
    // Scroll sources: pinned event.rs:270-287, ledger row 476.
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityEvent;",
        .name = "setScrollable",
        .signature = "(Z)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityEvent;",
        .name = "setScrollX",
        .signature = "(I)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityEvent;",
        .name = "setScrollDeltaX",
        .signature = "(I)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityEvent;",
        .name = "setMaxScrollX",
        .signature = "(I)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityEvent;",
        .name = "setScrollY",
        .signature = "(I)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityEvent;",
        .name = "setScrollDeltaY",
        .signature = "(I)V",
    },
    .{
        .kind = .called_member,
        .class = "Landroid/view/accessibility/AccessibilityEvent;",
        .name = "setMaxScrollY",
        .signature = "(I)V",
    },
    // Pinned event.rs:52-70 and Android ViewParent API specify boolean(host, event).
    .{
        .kind = .called_member,
        .class = "Landroid/view/ViewParent;",
        .name = "requestSendAccessibilityEvent",
        .signature = "(Landroid/view/View;Landroid/view/accessibility/AccessibilityEvent;)Z",
    },
    // Four name-only rows remain.
    .{
        .kind = .reached_by_name,
        .class = "Landroid/view/accessibility/AccessibilityNodeInfo;",
        .name = "invalidate",
        .signature = null,
    },
    .{
        .kind = .reached_by_name,
        .class = "Ljava/util/List;",
        .name = "add",
        .signature = null,
    },
    .{
        .kind = .reached_by_name,
        .class = classes.delegate_class_descriptor,
        .name = "newCallback",
        .signature = null,
    },
    .{
        .kind = .reached_by_name,
        .class = "Landroid/view/accessibility/AccessibilityNodeInfo$AccessibilityAction;",
        .name = "<init>",
        .signature = null,
    },
};

comptime {
    @setEvalBranchQuota(200_000);
    if (method_names.len != method_name_count) @compileError("the array length is the count");
    for (method_names, 0..) |a, i| {
        for (method_names[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a, b)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate method name at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a },
                ));
            }
        }
    }
    // The map's list is sorted, so the sort order is part of the pinned shape.
    // That sort ignores case: the map prints `setScrollable` before
    // `setScrollDeltaX`, and a byte order puts `D` of `Delta` first. The index
    // capture of `for (a, start..)` starts at `start` while the value still
    // comes from the front of `a`, so the walk is over the tail.
    for (method_names[1..], 1..) |b, i| {
        if (std.ascii.orderIgnoreCase(method_names[i - 1], b) != .lt) {
            @compileError(std.fmt.comptimePrint(
                "method names are out of order at {d}: {s} then {s}",
                .{ i, method_names[i - 1], b },
            ));
        }
    }
    if (method_ids.len != method_id_count) @compileError("the array length is the count");
    var pinned: usize = 0;
    for (method_ids, 0..) |a, i| {
        for (method_ids[i + 1 ..], 0..) |b, j| {
            if (!std.mem.eql(u8, a.class, b.class)) continue;
            if (!std.mem.eql(u8, a.name, b.name)) continue;
            if (a.signature == null and b.signature == null) {
                @compileError("two rows share a class and a name with no signature");
            }
            if (std.mem.eql(u8, a.signature orelse "", b.signature orelse "")) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate lookup at {d} and {d}: {s}.{s}",
                    .{ i, i + 1 + j, a.class, a.name },
                ));
            }
        }
        if (a.signature != null) pinned += 1;
        if (a.kind == .reached_by_name and a.signature != null) {
            @compileError("a reached_by_name row must not carry a signature");
        }
        if (a.kind != .reached_by_name and a.signature == null) {
            @compileError("a pinned row must carry a signature");
        }
    }
    if (pinned != pinned_signature_count) @compileError("signature census count differs");
    var covered: usize = 0;
    for (method_names) |name| {
        var seen: usize = 0;
        for (method_ids) |row| {
            if (std.mem.eql(u8, row.name, name)) seen += 1;
        }
        if (seen != 0) covered += 1;
    }
    if (covered != pinned_name_count) @compileError("covered-name census count differs");
    if (method_name_count - covered != unpinned_name_count) {
        @compileError("uncovered-name census count differs");
    }
}

/// How many rows of `method_ids` carry `name`, which is how many Java types
/// the adapter sends that one name to.
///
/// `obtain` answers 3 and `setParent` answers 2, so a caller that keys on the
/// name alone cannot pick a lookup.
pub fn rowCountForName(name: []const u8) usize {
    var total: usize = 0;
    for (method_ids) |row| {
        if (std.mem.eql(u8, row.name, name)) total += 1;
    }
    return total;
}

/// The row equal to all three of `class`, `name` and `signature`, or `null`
/// when the table holds no such row.
pub fn findById(class: []const u8, name: []const u8, signature: []const u8) ?MethodId {
    for (method_ids) |row| {
        if (!std.mem.eql(u8, row.class, class)) continue;
        if (!std.mem.eql(u8, row.name, name)) continue;
        const row_signature = row.signature orelse continue;
        if (std.mem.eql(u8, row_signature, signature)) return row;
    }
    return null;
}

/// The first row spelled `name`, or `null`.
///
/// Ambiguous for the three shared names, so use it to count rows rather than
/// to pick one.
pub fn findByName(name: []const u8) ?MethodId {
    for (method_ids) |row| {
        if (std.mem.eql(u8, row.name, name)) return row;
    }
    return null;
}

/// Whether `name` is one of the 68 method names the adapter writes.
pub fn hasName(name: []const u8) bool {
    for (method_names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

test "the table holds exactly the 68 method names of map section 1.4.2" {
    try testing.expectEqual(@as(usize, 68), method_names.len);
    try testing.expectEqual(@as(usize, 38), method_ids.len);
    try testing.expectEqual(@as(usize, 34), pinned_signature_count);
    try testing.expectEqual(@as(usize, 35), unpinned_name_count);
}

test "the first 34 method names are the a to l half of the map's list" {
    try expectNames(0, 34, &.{
        "add",
        "addAction",
        "addChild",
        "containsKey",
        "createAccessibilityNodeInfo",
        "findFocus",
        "getAccessibilityDelegate",
        "getBoolean",
        "getContext",
        "getExtras",
        "getFloat",
        "getInt",
        "getLocationOnScreen",
        "getPackageName",
        "getParent",
        "getSystemService",
        "getText",
        "invalidate",
        "isEnabled",
        "loadClass",
        "newCallback",
        "obtain",
        "onHoverEvent",
        "performAction",
        "post",
        "putString",
        "requestSendAccessibilityEvent",
        "runCallback",
        "setAccessibilityDelegate",
        "setAccessibilityFocused",
        "setAction",
        "setAddedCount",
        "setBeforeText",
        "setBoundsInScreen",
    });
}

test "the last 34 method names are the s half of the map's list" {
    try expectNames(34, 34, &.{
        "setCheckable",
        "setChecked",
        "setClassName",
        "setContentChangeTypes",
        "setContentDescription",
        "setCurrentItemIndex",
        "setEditable",
        "setEnabled",
        "setFocusable",
        "setFocused",
        "setFromIndex",
        "setItemCount",
        "setLiveRegion",
        "setMaxScrollX",
        "setMaxScrollY",
        "setMovementGranularities",
        "setMovementGranularity",
        "setOnHoverListener",
        "setPackageName",
        "setParent",
        "setPassword",
        "setRangeInfo",
        "setRemovedCount",
        "setScrollable",
        "setScrollDeltaX",
        "setScrollDeltaY",
        "setScrollX",
        "setScrollY",
        "setSelected",
        "setSource",
        "setText",
        "setTextSelection",
        "setToIndex",
        "setVisibleToUser",
    });
}

test "the five names the map's grouping table leaves out are all in the list" {
    // Section 1.4.2 partitions 63 of the 68 by receiver. These five appear in
    // no row of that grouping and in all of the flat list.
    for ([_][]const u8{
        "add",
        "getPackageName",
        "post",
        "setFromIndex",
        "setToIndex",
    }) |name| {
        try testing.expect(hasName(name));
    }
    try testing.expectEqual(@as(usize, 63), method_name_count - 5);
}

test "every registered native method carries the signature the map records" {
    const expected = [_]struct { name: []const u8, signature: []const u8 }{
        .{ .name = "runCallback", .signature = "(Landroid/view/View;J)V" },
        .{
            .name = "createAccessibilityNodeInfo",
            .signature = "(JLandroid/view/View;I)" ++
                "Landroid/view/accessibility/AccessibilityNodeInfo;",
        },
        .{
            .name = "findFocus",
            .signature = "(JLandroid/view/View;I)" ++
                "Landroid/view/accessibility/AccessibilityNodeInfo;",
        },
        .{
            .name = "performAction",
            .signature = "(JLandroid/view/View;IILandroid/os/Bundle;)Z",
        },
        .{ .name = "onHoverEvent", .signature = "(JLandroid/view/View;IFF)Z" },
    };
    var checked: usize = 0;
    for (method_ids) |row| {
        if (row.kind != .registered_native) continue;
        try testing.expectEqualStrings("Ldev/accesskit/android/Delegate;", row.class);
        try testing.expectEqualStrings(expected[checked].name, row.name);
        try testing.expectEqualStrings(expected[checked].signature, row.signature.?);
        checked += 1;
    }
    try testing.expectEqual(expected.len, checked);
}

test "obtain is three unrelated factories and setParent is two overloads" {
    try testing.expectEqual(@as(usize, 3), rowCountForName("obtain"));
    try testing.expectEqual(@as(usize, 2), rowCountForName("setParent"));
    try testing.expectEqual(@as(usize, 2), rowCountForName("<init>"));
    try testing.expectEqual(@as(usize, 1), rowCountForName("setSource"));
    // The triple resolves each of them and a wrong signature resolves none.
    try testing.expect(findById(
        "Landroid/view/accessibility/AccessibilityEvent;",
        "obtain",
        "(I)Landroid/view/accessibility/AccessibilityEvent;",
    ) != null);
    try testing.expectEqual(@as(?MethodId, null), findById(
        "Landroid/view/accessibility/AccessibilityEvent;",
        "obtain",
        "()V",
    ));
    try testing.expect(findById(
        "Landroid/view/accessibility/AccessibilityNodeInfo;",
        "setParent",
        "(Landroid/view/View;I)V",
    ) != null);
}

test "each of the four reached-by-name rows has no signature" {
    const expected = [_]struct { class: []const u8, name: []const u8 }{
        .{ .class = "Landroid/view/accessibility/AccessibilityNodeInfo;", .name = "invalidate" },
        .{ .class = "Ljava/util/List;", .name = "add" },
        .{ .class = "Ldev/accesskit/android/Delegate;", .name = "newCallback" },
        .{
            .class = "Landroid/view/accessibility/AccessibilityNodeInfo$AccessibilityAction;",
            .name = "<init>",
        },
    };
    var checked: usize = 0;
    for (method_ids) |row| {
        if (row.kind != .reached_by_name) continue;
        try testing.expectEqualStrings(expected[checked].class, row.class);
        try testing.expectEqualStrings(expected[checked].name, row.name);
        try testing.expectEqual(@as(?[:0]const u8, null), row.signature);
        checked += 1;
    }
    try testing.expectEqual(expected.len, checked);
}

test "every class a lookup names is one the adapter reaches" {
    for (method_ids) |row| {
        const known = classes.find(row.class) != null or
            std.mem.eql(u8, row.class, classes.delegate_class_descriptor);
        try testing.expect(known);
    }
    try testing.expect(!hasName("noSuchMethod"));
    try testing.expectEqual(@as(usize, 0), rowCountForName("noSuchMethod"));
    try testing.expectEqual(@as(?MethodId, null), findByName("noSuchMethod"));
}

/// Checks that `method_names[start .. start + len]` is exactly `expected`.
fn expectNames(start: usize, len: usize, expected: []const []const u8) !void {
    try testing.expectEqual(len, expected.len);
    for (method_names[start .. start + len], expected) |actual, want| {
        try testing.expectEqualStrings(want, actual);
    }
}

test "gate and scroll lookups carry documented JNI descriptors" {
    const event_class = "Landroid/view/accessibility/AccessibilityEvent;";
    try testing.expect(findById("Landroid/view/View;", "getContext", "()Landroid/content/Context;") != null);
    try testing.expect(findById(
        "Landroid/content/Context;",
        "getSystemService",
        "(Ljava/lang/String;)Ljava/lang/Object;",
    ) != null);
    try testing.expect(findById("Landroid/view/accessibility/AccessibilityManager;", "isEnabled", "()Z") != null);
    try testing.expect(findById(event_class, "setScrollable", "(Z)V") != null);
    for ([_][]const u8{
        "setScrollX", "setScrollDeltaX", "setMaxScrollX",
        "setScrollY", "setScrollDeltaY", "setMaxScrollY",
    }) |name| {
        try testing.expect(findById(event_class, name, "(I)V") != null);
    }
    try testing.expect(findById(
        "Landroid/view/ViewParent;",
        "requestSendAccessibilityEvent",
        "(Landroid/view/View;Landroid/view/accessibility/AccessibilityEvent;)Z",
    ) != null);
}
