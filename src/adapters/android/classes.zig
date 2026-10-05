//! The Java class descriptors the Android adapter passes to `GetMethodID` and
//! `FindClass`.
//!
//! `docs/42-native-adapter-build-map.md` section 1.4.3 heads this table
//! "Java classes, 19" and then lists **20** descriptors: 11 rows one by one, a
//! row of 6 standard types, a row of 2 marshalling types and
//! `Ldalvik/system/InMemoryDexClassLoader;`. The map applies the same rule to
//! `docs/16` in its correction C1, where it takes the table over the heading
//! the table because the heading contradicts the table, so this module declares the 20
//! the table lists and records the disagreement. `map_descriptor_count` is 19,
//! the heading's figure, and the array length is 20.
//!
//! One more class is named outside the table. The five native methods of
//! `dev.accesskit.android.Delegate` are registered on the delegate class, and
//! `delegate_class_descriptor` gives its descriptor, so the adapter names 21
//! class descriptors in total.
//!
//! **Why a descriptor is pinned.** `GetMethodID` takes the class, the name and
//! the signature as three separate strings, and every one of them has to be
//! exact. A wrong descriptor is not a compile error anywhere and is not a
//! runtime error until the lookup happens on a device, which is why each row is
//! asserted here.
//!
//! **What is a fact and what is not.** The 20 spellings come from the map.
//! `delegate_class_descriptor` is not one of the 20: it is derived, and its doc
//! comment gives the derivation.
//!
//! **The loop bound.** Every loop over `descriptors` walks the array, whose
//! length is 20.

const std = @import("std");

const testing = std.testing;

/// One Java class, as the descriptor `JNIEnv` spells it.
///
/// The spelling is the JVM's internal form: `L`, the binary name with `/` for
/// each package separator, and `;`. A nested class keeps its `$`.
pub const ClassDescriptor = [:0]const u8;

/// The class descriptor `AK/android/src/inject.rs:256` reaches with
/// `find_class("dev/accesskit/android/Delegate")`.
///
/// The map's `find_class` argument uses `/` where a JNI descriptor uses `.`
/// between package components, and the map records no descriptor for this
/// class. JNI mangles a class internal name by replacing every `.` with `/`,
/// wrapping the result in `L` and `;`, so the descriptor is the derivation
/// below. **Unverified**: no Java class file is on this host, so the mangling
/// was not checked against one.
pub const delegate_class_descriptor: ClassDescriptor = "Ldev/accesskit/android/Delegate;";

/// The class descriptor `AK/android/src/inject.rs:225-254` hands to the
/// `InMemoryDexClassLoader` constructor in the `embedded-dex` build mode.
pub const in_memory_dex_class_loader_descriptor: ClassDescriptor =
    "Ldalvik/system/InMemoryDexClassLoader;";

/// How many descriptors `docs/42` section 1.4.3 counts in its heading.
///
/// The table below holds one more. The `comptime` block states the difference
/// rather than hiding it.
pub const map_descriptor_count = 19;

/// How many descriptors `descriptors` holds.
pub const descriptor_count = 20;

/// Every Java class descriptor the Android adapter names, in the map's row
/// order.
pub const descriptors = [descriptor_count]ClassDescriptor{
    // 11 rows the map lists one by one.
    "Landroid/view/View;",
    "Landroid/view/View$AccessibilityDelegate;",
    "Landroid/view/View$OnHoverListener;",
    "Landroid/view/ViewParent;",
    "Landroid/view/accessibility/AccessibilityNodeInfo;",
    "Landroid/view/accessibility/AccessibilityNodeInfo$AccessibilityAction;",
    "Landroid/view/accessibility/AccessibilityNodeInfo$RangeInfo;",
    "Landroid/view/accessibility/AccessibilityEvent;",
    "Landroid/content/Context;",
    "Landroid/graphics/Rect;",
    "Landroid/os/Bundle;",
    // The 6 standard types of one row.
    "Ljava/lang/String;",
    "Ljava/lang/CharSequence;",
    "Ljava/lang/Object;",
    "Ljava/lang/Class;",
    "Ljava/lang/ClassLoader;",
    "Ljava/lang/Runnable;",
    // The 2 marshalling types of one row.
    "Ljava/util/List;",
    "Ljava/nio/ByteBuffer;",
    // The embedded-dex loader of the last row.
    "Ldalvik/system/InMemoryDexClassLoader;",
};

comptime {
    for (descriptors, 0..) |a, i| {
        for (descriptors[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a, b)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate descriptor at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a },
                ));
            }
        }
        if (a.len < 3 or a[0] != 'L' or a[a.len - 1] != ';') {
            @compileError(std.fmt.comptimePrint("malformed descriptor: {s}", .{a}));
        }
    }
}

/// The descriptor equal to `name`, or `null` when the table holds no such
/// spelling.
pub fn find(name: []const u8) ?ClassDescriptor {
    for (descriptors) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return candidate;
    }
    return null;
}

test "the table holds the 20 descriptors the map lists under a heading of 19" {
    try testing.expectEqual(@as(usize, 20), descriptors.len);
    try testing.expectEqual(@as(usize, 19), map_descriptor_count);
}

test "every Android platform descriptor is spelled as the map spells it" {
    for ([_][]const u8{
        "Landroid/view/View;",
        "Landroid/view/View$AccessibilityDelegate;",
        "Landroid/view/View$OnHoverListener;",
        "Landroid/view/ViewParent;",
        "Landroid/view/accessibility/AccessibilityNodeInfo;",
        "Landroid/view/accessibility/AccessibilityNodeInfo$AccessibilityAction;",
        "Landroid/view/accessibility/AccessibilityNodeInfo$RangeInfo;",
        "Landroid/view/accessibility/AccessibilityEvent;",
        "Landroid/content/Context;",
        "Landroid/graphics/Rect;",
        "Landroid/os/Bundle;",
    }) |name| {
        try testing.expect(find(name) != null);
    }
}

test "every standard and marshalling descriptor is spelled as the map spells it" {
    for ([_][]const u8{
        "Ljava/lang/String;",
        "Ljava/lang/CharSequence;",
        "Ljava/lang/Object;",
        "Ljava/lang/Class;",
        "Ljava/lang/ClassLoader;",
        "Ljava/lang/Runnable;",
        "Ljava/util/List;",
        "Ljava/nio/ByteBuffer;",
        "Ldalvik/system/InMemoryDexClassLoader;",
    }) |name| {
        try testing.expect(find(name) != null);
    }
}

test "every descriptor is a well-formed object descriptor" {
    // The walk is over the 20 rows, so the bound is `descriptor_count`.
    for (descriptors) |candidate| {
        try testing.expect(candidate.len > 2);
        try testing.expectEqual(@as(u8, 'L'), candidate[0]);
        try testing.expectEqual(@as(u8, ';'), candidate[candidate.len - 1]);
        try testing.expect(std.mem.indexOfScalar(u8, candidate, '.') == null);
        try testing.expect(std.mem.endsWith(u8, candidate, ";"));
    }
}

test "the delegate class is named outside the map's table" {
    // `AK/android/src/inject.rs:256` passes `dev/accesskit/android/Delegate` to
    // `find_class`, and JNI mangles a class internal name by replacing each
    // `.` with `/` and wrapping the result in `L` and `;`.
    try testing.expectEqualStrings("Ldev/accesskit/android/Delegate;", delegate_class_descriptor);
    try testing.expectEqual(
        @as(?ClassDescriptor, null),
        find(delegate_class_descriptor),
    );
    try testing.expectEqualStrings(
        "Ldalvik/system/InMemoryDexClassLoader;",
        in_memory_dex_class_loader_descriptor,
    );
    try testing.expect(std.mem.eql(
        u8,
        in_memory_dex_class_loader_descriptor,
        descriptors[descriptor_count - 1],
    ));
}
