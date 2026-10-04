//! The number properties: 11 `f64`, 2 `f32` and 9 `usize`.
//!
//! Upstream: `accesskit/src/lib.rs:2207-2314`, the three invocations
//! `f64_property_methods!` at `:2207`, `f32_property_methods!` at `:2243` and
//! `usize_property_methods!` at `:2251`. Each expands through
//! `property_methods!` at `:1299`, which is where the three methods per
//! property come from.
//!
//! **The store is the receiver, not `Node`.** Upstream hangs the accessor on
//! `impl Node`, because Rust inherent methods and traits both live on the type.
//! Zig has neither, and `schema/node.zig` owns `Node`, so each accessor here is
//! a module-level function whose first parameter is the `Properties` that holds
//! the property. A caller reaches one through `numbers.numericValue(&node.properties)`.
//! `Node` keeps its five fields, its constructor, its `deinit` and the eleven
//! written methods in its own upstream range, and no property forwarder.
//!
//! **No allocator parameter.** `Properties` is a handle: it is built with
//! `Properties.init(gpa)` and it stores that allocator, so every write and the
//! `deinit` go through it. Passing a second allocator to a setter would let a
//! caller grow the store through one and free it through the other.
//!
//! **No `errdefer` here, and that is not a gap.** Upstream's `owned_type_setters`
//! family needed a guard because it took ownership of a `Box`, a `String` or a
//! `Vec` and could fail partway while holding the replacement. Every payload in
//! this file is an inline number with nothing to release, so there is nothing to
//! guard. `props/strings.zig` and `props/vectors.zig` own an allocation each and
//! do carry the guard.
//!
//! **Three payload widths, never one.** `PropertyValue` carries an `f64` arm, an
//! `f32` arm and a `usize` arm (`accesskit/src/lib.rs:861-863`). Each family
//! below reads and writes the arm upstream declared it with. A value round trip
//! cannot tell two of these widths apart, because every `f32` is exact in `f64`,
//! so the two float families differ in the stored arm and the stored payload
//! width. Widening the f32 family to f64 changes both.
//!
//! **A negative number is a value.** `copy_type_setters!`
//! (`accesskit/src/lib.rs:1271-1279`) stores whatever the setter is given. A
//! `scroll_x` below zero is a container scrolled away from its origin, so no
//! setter here refuses a value, and none reports the value as a fault. Upstream
//! states no non-negative range on any of the 22, so this file states none.
//!
//! **No narrowing.** `copy_type_getters!` binds `usize` to `usize` at
//! `accesskit/src/lib.rs:1993` and `copy_type_setters!` does the same at
//! `:2013`. Neither macro holds a cast, so no property in this range narrows and
//! this module declares no narrowing helper and no error tag for one. The `f64`
//! to `i32` narrowing that `docs/19` section 8.4 records belongs to two
//! adapters, not to this file.
//!
//! The shortest use is one setter and one getter:
//!
//! ```zig
//! var properties = Properties.init(gpa);
//! defer properties.deinit();
//! try setNumericValue(&properties, 0.5);
//! const value = numericValue(&properties);
//! ```
//!
//! Every getter answers `null` when the property is unset. `props/table.zig`
//! owns `Properties`, its generic `get`, `set` and `clear`, and its `deinit`.

const std = @import("std");

const table = @import("table.zig");
const Properties = table.Properties;
const PropertyId = table.PropertyId;
const PropertyValueTag = table.PropertyValueTag;
const propertyValueFrom = table.propertyValueFrom;

const testing = std.testing;

comptime {
    // `PropertyValueTag` is the domain these accessors read. A port that
    // folded the f32 family into the f64 arm drops `f32_` here, and the store
    // then carries one payload where upstream carries three.
    std.debug.assert(@hasField(PropertyValueTag, "f64_"));
    std.debug.assert(@hasField(PropertyValueTag, "f32_"));
    std.debug.assert(@hasField(PropertyValueTag, "usize_"));
}

/// Reads the `f64` arm. A store holding another arm answers `null`, which is what
/// `get_f64_property` does when the `PropertyValue::F64` match fails
/// (`accesskit/src/lib.rs:1251-1255`).
fn readF64(properties: *const Properties, id: PropertyId) ?f64 {
    return switch ((properties.get(id) orelse return null).*) {
        .f64_ => |number| number,
        else => null,
    };
}

/// Reads the `f32` arm. `accesskit/src/lib.rs:1251-1255`.
fn readF32(properties: *const Properties, id: PropertyId) ?f32 {
    return switch ((properties.get(id) orelse return null).*) {
        .f32_ => |number| number,
        else => null,
    };
}

/// Reads the `usize` arm. `accesskit/src/lib.rs:1251-1255`.
fn readUsize(properties: *const Properties, id: PropertyId) ?usize {
    return switch ((properties.get(id) orelse return null).*) {
        .usize_ => |number| number,
        else => null,
    };
}

/// Writes the `f64` arm through the allocator the store was built with.
/// `accesskit/src/lib.rs:1271-1279`.
fn writeF64(properties: *Properties, id: PropertyId, value: f64) std.mem.Allocator.Error!void {
    try properties.set(id, propertyValueFrom(.f64_, value));
}

/// Writes the `f32` arm through the allocator the store was built with.
/// `accesskit/src/lib.rs:1271-1279`.
fn writeF32(properties: *Properties, id: PropertyId, value: f32) std.mem.Allocator.Error!void {
    try properties.set(id, propertyValueFrom(.f32_, value));
}

/// Writes the `usize` arm through the allocator the store was built with.
/// `accesskit/src/lib.rs:1271-1279`.
fn writeUsize(properties: *Properties, id: PropertyId, value: usize) std.mem.Allocator.Error!void {
    try properties.set(id, propertyValueFrom(.usize_, value));
}

// -- f64: 11 properties, `accesskit/src/lib.rs:2207-2241` --

/// The current horizontal scroll position of this scrollable container.
pub fn scrollX(properties: *const Properties) ?f64 {
    return readF64(properties, .scroll_x);
}

/// Stores `value` as the horizontal scroll position. `error.OutOfMemory` leaves
/// the property as it was.
pub fn setScrollX(properties: *Properties, value: f64) std.mem.Allocator.Error!void {
    try writeF64(properties, .scroll_x, value);
}

/// Makes the property read as one that was never set.
pub fn clearScrollX(properties: *Properties) void {
    properties.clear(.scroll_x);
}

/// The minimum horizontal scroll position of this scrollable container.
pub fn scrollXMin(properties: *const Properties) ?f64 {
    return readF64(properties, .scroll_x_min);
}

/// Stores `value` as the minimum horizontal scroll position. `error.OutOfMemory`
/// leaves the property as it was.
pub fn setScrollXMin(properties: *Properties, value: f64) std.mem.Allocator.Error!void {
    try writeF64(properties, .scroll_x_min, value);
}

/// Makes the property read as one that was never set.
pub fn clearScrollXMin(properties: *Properties) void {
    properties.clear(.scroll_x_min);
}

/// The maximum horizontal scroll position of this scrollable container.
pub fn scrollXMax(properties: *const Properties) ?f64 {
    return readF64(properties, .scroll_x_max);
}

/// Stores `value` as the maximum horizontal scroll position. `error.OutOfMemory`
/// leaves the property as it was.
pub fn setScrollXMax(properties: *Properties, value: f64) std.mem.Allocator.Error!void {
    try writeF64(properties, .scroll_x_max, value);
}

/// Makes the property read as one that was never set.
pub fn clearScrollXMax(properties: *Properties) void {
    properties.clear(.scroll_x_max);
}

/// The current vertical scroll position of this scrollable container.
pub fn scrollY(properties: *const Properties) ?f64 {
    return readF64(properties, .scroll_y);
}

/// Stores `value` as the vertical scroll position. `error.OutOfMemory` leaves the
/// property as it was.
pub fn setScrollY(properties: *Properties, value: f64) std.mem.Allocator.Error!void {
    try writeF64(properties, .scroll_y, value);
}

/// Makes the property read as one that was never set.
pub fn clearScrollY(properties: *Properties) void {
    properties.clear(.scroll_y);
}

/// The minimum vertical scroll position of this scrollable container.
pub fn scrollYMin(properties: *const Properties) ?f64 {
    return readF64(properties, .scroll_y_min);
}

/// Stores `value` as the minimum vertical scroll position. `error.OutOfMemory`
/// leaves the property as it was.
pub fn setScrollYMin(properties: *Properties, value: f64) std.mem.Allocator.Error!void {
    try writeF64(properties, .scroll_y_min, value);
}

/// Makes the property read as one that was never set.
pub fn clearScrollYMin(properties: *Properties) void {
    properties.clear(.scroll_y_min);
}

/// The maximum vertical scroll position of this scrollable container.
pub fn scrollYMax(properties: *const Properties) ?f64 {
    return readF64(properties, .scroll_y_max);
}

/// Stores `value` as the maximum vertical scroll position. `error.OutOfMemory`
/// leaves the property as it was.
pub fn setScrollYMax(properties: *Properties, value: f64) std.mem.Allocator.Error!void {
    try writeF64(properties, .scroll_y_max, value);
}

/// Makes the property read as one that was never set.
pub fn clearScrollYMax(properties: *Properties) void {
    properties.clear(.scroll_y_max);
}

/// The current numeric value of this range widget. ARIA equivalent:
/// [`aria-valuenow`](https://www.w3.org/TR/wai-aria-1.2/#aria-valuenow).
pub fn numericValue(properties: *const Properties) ?f64 {
    return readF64(properties, .numeric_value);
}

/// Stores `value` as the current numeric value. `error.OutOfMemory` leaves the
/// property as it was.
pub fn setNumericValue(properties: *Properties, value: f64) std.mem.Allocator.Error!void {
    try writeF64(properties, .numeric_value, value);
}

/// Makes the property read as one that was never set.
pub fn clearNumericValue(properties: *Properties) void {
    properties.clear(.numeric_value);
}

/// The minimum allowed numeric value of this range widget. ARIA equivalent:
/// [`aria-valuemin`](https://www.w3.org/TR/wai-aria-1.2/#aria-valuemin).
pub fn minNumericValue(properties: *const Properties) ?f64 {
    return readF64(properties, .min_numeric_value);
}

/// Stores `value` as the minimum allowed numeric value. `error.OutOfMemory`
/// leaves the property as it was.
pub fn setMinNumericValue(properties: *Properties, value: f64) std.mem.Allocator.Error!void {
    try writeF64(properties, .min_numeric_value, value);
}

/// Makes the property read as one that was never set.
pub fn clearMinNumericValue(properties: *Properties) void {
    properties.clear(.min_numeric_value);
}

/// The maximum allowed numeric value of this range widget. ARIA equivalent:
/// [`aria-valuemax`](https://www.w3.org/TR/wai-aria-1.2/#aria-valuemax).
pub fn maxNumericValue(properties: *const Properties) ?f64 {
    return readF64(properties, .max_numeric_value);
}

/// Stores `value` as the maximum allowed numeric value. `error.OutOfMemory`
/// leaves the property as it was.
pub fn setMaxNumericValue(properties: *Properties, value: f64) std.mem.Allocator.Error!void {
    try writeF64(properties, .max_numeric_value, value);
}

/// Makes the property read as one that was never set.
pub fn clearMaxNumericValue(properties: *Properties) void {
    properties.clear(.max_numeric_value);
}

/// The amount by which the numeric value changes when it is incremented or
/// decremented by one step.
pub fn numericValueStep(properties: *const Properties) ?f64 {
    return readF64(properties, .numeric_value_step);
}

/// Stores `value` as the numeric value step. `error.OutOfMemory` leaves the
/// property as it was.
pub fn setNumericValueStep(properties: *Properties, value: f64) std.mem.Allocator.Error!void {
    try writeF64(properties, .numeric_value_step, value);
}

/// Makes the property read as one that was never set.
pub fn clearNumericValueStep(properties: *Properties) void {
    properties.clear(.numeric_value_step);
}

/// The amount by which the numeric value changes for a large increment or
/// decrement.
pub fn numericValueJump(properties: *const Properties) ?f64 {
    return readF64(properties, .numeric_value_jump);
}

/// Stores `value` as the numeric value jump. `error.OutOfMemory` leaves the
/// property as it was.
pub fn setNumericValueJump(properties: *Properties, value: f64) std.mem.Allocator.Error!void {
    try writeF64(properties, .numeric_value_jump, value);
}

/// Makes the property read as one that was never set.
pub fn clearNumericValueJump(properties: *Properties) void {
    properties.clear(.numeric_value_jump);
}

// -- f32: 2 properties, `accesskit/src/lib.rs:2243-2249` --

/// The font size in pixels.
pub fn fontSize(properties: *const Properties) ?f32 {
    return readF32(properties, .font_size);
}

/// Stores `value` as the font size in pixels. `error.OutOfMemory` leaves the
/// property as it was.
pub fn setFontSize(properties: *Properties, value: f32) std.mem.Allocator.Error!void {
    try writeF32(properties, .font_size, value);
}

/// Makes the property read as one that was never set.
pub fn clearFontSize(properties: *Properties) void {
    properties.clear(.font_size);
}

/// The font weight, which takes any numeric value. Increments of 100 in the
/// range `[0, 900]` name keywords such as light, normal and bold.
pub fn fontWeight(properties: *const Properties) ?f32 {
    return readF32(properties, .font_weight);
}

/// Stores `value` as the font weight. `error.OutOfMemory` leaves the property as
/// it was.
pub fn setFontWeight(properties: *Properties, value: f32) std.mem.Allocator.Error!void {
    try writeF32(properties, .font_weight, value);
}

/// Makes the property read as one that was never set.
pub fn clearFontWeight(properties: *Properties) void {
    properties.clear(.font_weight);
}

// -- usize: 9 properties, `accesskit/src/lib.rs:2251-2314` --

/// The total number of rows in a table, grid or tree grid. ARIA equivalent:
/// [`aria-rowcount`](https://www.w3.org/TR/wai-aria-1.2/#aria-rowcount).
pub fn rowCount(properties: *const Properties) ?usize {
    return readUsize(properties, .row_count);
}

/// Stores `value` as the total number of rows. `error.OutOfMemory` leaves the
/// property as it was.
pub fn setRowCount(properties: *Properties, value: usize) std.mem.Allocator.Error!void {
    try writeUsize(properties, .row_count, value);
}

/// Makes the property read as one that was never set.
pub fn clearRowCount(properties: *Properties) void {
    properties.clear(.row_count);
}

/// The total number of columns in a table, grid or tree grid. ARIA equivalent:
/// [`aria-colcount`](https://www.w3.org/TR/wai-aria-1.2/#aria-colcount).
pub fn columnCount(properties: *const Properties) ?usize {
    return readUsize(properties, .column_count);
}

/// Stores `value` as the total number of columns. `error.OutOfMemory` leaves the
/// property as it was.
pub fn setColumnCount(properties: *Properties, value: usize) std.mem.Allocator.Error!void {
    try writeUsize(properties, .column_count, value);
}

/// Makes the property read as one that was never set.
pub fn clearColumnCount(properties: *Properties) void {
    properties.clear(.column_count);
}

/// The row index of this node within a table, grid or tree grid, counted from
/// zero. ARIA equivalent:
/// [`aria-rowindex`](https://www.w3.org/TR/wai-aria-1.2/#aria-rowindex), which
/// counts from one.
pub fn rowIndex(properties: *const Properties) ?usize {
    return readUsize(properties, .row_index);
}

/// Stores `value` as the row index. `error.OutOfMemory` leaves the property as
/// it was.
pub fn setRowIndex(properties: *Properties, value: usize) std.mem.Allocator.Error!void {
    try writeUsize(properties, .row_index, value);
}

/// Makes the property read as one that was never set.
pub fn clearRowIndex(properties: *Properties) void {
    properties.clear(.row_index);
}

/// The column index of this node within a table, grid or tree grid, counted from
/// zero. ARIA equivalent:
/// [`aria-colindex`](https://www.w3.org/TR/wai-aria-1.2/#aria-colindex), which
/// counts from one.
pub fn columnIndex(properties: *const Properties) ?usize {
    return readUsize(properties, .column_index);
}

/// Stores `value` as the column index. `error.OutOfMemory` leaves the property as
/// it was.
pub fn setColumnIndex(properties: *Properties, value: usize) std.mem.Allocator.Error!void {
    try writeUsize(properties, .column_index, value);
}

/// Makes the property read as one that was never set.
pub fn clearColumnIndex(properties: *Properties) void {
    properties.clear(.column_index);
}

/// The number of rows spanned by a cell or grid cell. ARIA equivalent:
/// [`aria-rowspan`](https://www.w3.org/TR/wai-aria-1.2/#aria-rowspan).
pub fn rowSpan(properties: *const Properties) ?usize {
    return readUsize(properties, .row_span);
}

/// Stores `value` as the number of spanned rows. `error.OutOfMemory` leaves the
/// property as it was.
pub fn setRowSpan(properties: *Properties, value: usize) std.mem.Allocator.Error!void {
    try writeUsize(properties, .row_span, value);
}

/// Makes the property read as one that was never set.
pub fn clearRowSpan(properties: *Properties) void {
    properties.clear(.row_span);
}

/// The number of columns spanned by a cell or grid cell. ARIA equivalent:
/// [`aria-colspan`](https://www.w3.org/TR/wai-aria-1.2/#aria-colspan).
pub fn columnSpan(properties: *const Properties) ?usize {
    return readUsize(properties, .column_span);
}

/// Stores `value` as the number of spanned columns. `error.OutOfMemory` leaves
/// the property as it was.
pub fn setColumnSpan(properties: *Properties, value: usize) std.mem.Allocator.Error!void {
    try writeUsize(properties, .column_span, value);
}

/// Makes the property read as one that was never set.
pub fn clearColumnSpan(properties: *Properties) void {
    properties.clear(.column_span);
}

/// The hierarchical level of this node within a structure, counted from zero.
/// ARIA equivalent: [`aria-level`](https://www.w3.org/TR/wai-aria-1.2/#aria-level),
/// which counts from one.
pub fn level(properties: *const Properties) ?usize {
    return readUsize(properties, .level);
}

/// Stores `value` as the hierarchical level. `error.OutOfMemory` leaves the
/// property as it was.
pub fn setLevel(properties: *Properties, value: usize) std.mem.Allocator.Error!void {
    try writeUsize(properties, .level, value);
}

/// Makes the property read as one that was never set.
pub fn clearLevel(properties: *Properties) void {
    properties.clear(.level);
}

/// For a container such as `Role.list_box`, the total number of items. ARIA
/// equivalent: [`aria-setsize`](https://www.w3.org/TR/wai-aria-1.2/#aria-setsize),
/// which is set on each item rather than on the container.
pub fn sizeOfSet(properties: *const Properties) ?usize {
    return readUsize(properties, .size_of_set);
}

/// Stores `value` as the total number of items in the set. `error.OutOfMemory`
/// leaves the property as it was.
pub fn setSizeOfSet(properties: *Properties, value: usize) std.mem.Allocator.Error!void {
    try writeUsize(properties, .size_of_set, value);
}

/// Makes the property read as one that was never set.
pub fn clearSizeOfSet(properties: *Properties) void {
    properties.clear(.size_of_set);
}

/// For an item such as `Role.list_box_option`, its index in the item list. The
/// value must be below the `sizeOfSet` the container holds. ARIA equivalent:
/// [`aria-posinset`](https://www.w3.org/TR/wai-aria-1.2/#aria-posinset), which
/// counts from one.
pub fn positionInSet(properties: *const Properties) ?usize {
    return readUsize(properties, .position_in_set);
}

/// Stores `value` as the index in the item list. `error.OutOfMemory` leaves the
/// property as it was.
pub fn setPositionInSet(properties: *Properties, value: usize) std.mem.Allocator.Error!void {
    try writeUsize(properties, .position_in_set, value);
}

/// Makes the property read as one that was never set.
pub fn clearPositionInSet(properties: *Properties) void {
    properties.clear(.position_in_set);
}

const Clearer = *const fn (properties: *Properties) void;

/// Stores `value`, reads it back, then clears the property and reads it again.
///
/// `T` is the width the getter returns, which is the width the accessor was
/// declared with. `get` and `clear` are comptime, so a property declared at the
/// wrong width, or one missing a clearer, fails to coerce here and the compiler
/// names that property rather than the body of this helper.
fn roundTrip(
    comptime T: type,
    comptime get: *const fn (properties: *const Properties) ?T,
    comptime clear: Clearer,
    comptime set: anytype,
    value: T,
) !void {
    var properties = Properties.init(testing.allocator);
    defer properties.deinit();

    try set(&properties, value);
    try testing.expectEqual(value, get(&properties).?);
    clear(&properties);
    try testing.expect(get(&properties) == null);
}

test "scroll_x" {
    try roundTrip(f64, scrollX, clearScrollX, setScrollX, 12.5);
}

test "scroll_x_min" {
    try roundTrip(f64, scrollXMin, clearScrollXMin, setScrollXMin, -12.5);
}

test "scroll_x_max" {
    try roundTrip(f64, scrollXMax, clearScrollXMax, setScrollXMax, 480.25);
}

test "scroll_y" {
    try roundTrip(f64, scrollY, clearScrollY, setScrollY, 0.0);
}

test "scroll_y_min" {
    try roundTrip(f64, scrollYMin, clearScrollYMin, setScrollYMin, -960.5);
}

test "scroll_y_max" {
    try roundTrip(f64, scrollYMax, clearScrollYMax, setScrollYMax, 1.0e6);
}

test "numeric_value" {
    try roundTrip(f64, numericValue, clearNumericValue, setNumericValue, 42.5);
}

test "min_numeric_value" {
    try roundTrip(f64, minNumericValue, clearMinNumericValue, setMinNumericValue, -1.0);
}

test "max_numeric_value" {
    try roundTrip(f64, maxNumericValue, clearMaxNumericValue, setMaxNumericValue, 100.0);
}

test "numeric_value_step" {
    try roundTrip(f64, numericValueStep, clearNumericValueStep, setNumericValueStep, 0.25);
}

test "numeric_value_jump" {
    try roundTrip(f64, numericValueJump, clearNumericValueJump, setNumericValueJump, 10.0);
}

test "font_size" {
    try roundTrip(f32, fontSize, clearFontSize, setFontSize, 14.5);
}

test "font_weight" {
    try roundTrip(f32, fontWeight, clearFontWeight, setFontWeight, 400.0);
}

test "row_count" {
    try roundTrip(usize, rowCount, clearRowCount, setRowCount, 1000);
}

test "column_count" {
    try roundTrip(usize, columnCount, clearColumnCount, setColumnCount, 7);
}

test "row_index" {
    try roundTrip(usize, rowIndex, clearRowIndex, setRowIndex, 3);
}

test "column_index" {
    try roundTrip(usize, columnIndex, clearColumnIndex, setColumnIndex, 5);
}

test "row_span" {
    try roundTrip(usize, rowSpan, clearRowSpan, setRowSpan, 2);
}

test "column_span" {
    try roundTrip(usize, columnSpan, clearColumnSpan, setColumnSpan, 4);
}

test "level" {
    try roundTrip(usize, level, clearLevel, setLevel, 6);
}

test "size_of_set" {
    try roundTrip(usize, sizeOfSet, clearSizeOfSet, setSizeOfSet, 250);
}

test "position_in_set" {
    try roundTrip(usize, positionInSet, clearPositionInSet, setPositionInSet, 9);
}

test "each number property stores the arm and the width upstream declared" {
    // `PropertyValue` at `accesskit/src/lib.rs:861-863` carries `F64(f64)`,
    // `F32(f32)` and `Usize(usize)`. A value round trip cannot separate the
    // widths, because every f32 is exact in f64, so what a port that unified
    // them changes is the stored arm and the stored payload width.
    var properties = Properties.init(testing.allocator);
    defer properties.deinit();

    try setNumericValue(&properties, 14.5);
    try setFontSize(&properties, 14.5);
    try setRowCount(&properties, 7);

    const wide = properties.get(.numeric_value) orelse return error.NumericValueAbsent;
    try testing.expectEqual(PropertyValueTag.f64_, std.meta.activeTag(wide.*));
    switch (wide.*) {
        .f64_ => |payload| try testing.expectEqual(@as(usize, 8), @sizeOf(@TypeOf(payload))),
        else => return error.NumericValueStoredInAnotherArm,
    }

    const small = properties.get(.font_size) orelse return error.FontSizeAbsent;
    try testing.expectEqual(PropertyValueTag.f32_, std.meta.activeTag(small.*));
    switch (small.*) {
        .f32_ => |payload| try testing.expectEqual(@as(usize, 4), @sizeOf(@TypeOf(payload))),
        else => return error.FontSizeStoredInAnotherArm,
    }

    const count = properties.get(.row_count) orelse return error.RowCountAbsent;
    try testing.expectEqual(PropertyValueTag.usize_, std.meta.activeTag(count.*));
    // Rust `usize` is a machine word, so the port takes the target's own width.
    switch (count.*) {
        .usize_ => |payload| try testing.expectEqual(
            @sizeOf(*anyopaque),
            @sizeOf(@TypeOf(payload)),
        ),
        else => return error.RowCountStoredInAnotherArm,
    }
}

test "an f64 property does not round-trip through the f32 arm" {
    // 1 + 2^-52 is exact in f64 and rounds to 1.0 in f32. A port that put the
    // eleven f64 properties in the f32 arm answers 1.0 here.
    var properties = Properties.init(testing.allocator);
    defer properties.deinit();

    const exact: f64 = 1.0 + std.math.floatEps(f64);
    try setNumericValue(&properties, exact);
    try testing.expectEqual(exact, numericValue(&properties).?);
}

test "a negative number is stored, not refused" {
    // Upstream has no range check on any of the 22 setters, and a scrolled
    // container reaches negative positions on both axes.
    var properties = Properties.init(testing.allocator);
    defer properties.deinit();

    try setScrollX(&properties, -1.0e9);
    try testing.expectEqual(@as(f64, -1.0e9), scrollX(&properties).?);
    try setScrollYMin(&properties, -1.0e9);
    try testing.expectEqual(@as(f64, -1.0e9), scrollYMin(&properties).?);
    try setMinNumericValue(&properties, -1.0);
    try testing.expectEqual(@as(f64, -1.0), minNumericValue(&properties).?);
}

test "the widest value each width holds survives the store" {
    // A store whose float arms were truncated to f32, or whose integral arm was
    // cut to 32 bits, answers a smaller number on each of the four lines.
    var properties = Properties.init(testing.allocator);
    defer properties.deinit();

    try setScrollXMax(&properties, std.math.floatMax(f64));
    try testing.expectEqual(std.math.floatMax(f64), scrollXMax(&properties).?);
    try setScrollXMin(&properties, -std.math.floatMax(f64));
    try testing.expectEqual(-std.math.floatMax(f64), scrollXMin(&properties).?);
    try setFontWeight(&properties, std.math.floatMax(f32));
    try testing.expectEqual(std.math.floatMax(f32), fontWeight(&properties).?);
    try setRowCount(&properties, std.math.maxInt(usize));
    try testing.expectEqual(std.math.maxInt(usize), rowCount(&properties).?);
}

test "an untouched store answers null for all 22" {
    // A port that initialised a property to a default, or that read an absent
    // entry out of range, answers a number here instead of `null`.
    var properties = Properties.init(testing.allocator);
    defer properties.deinit();

    try testing.expect(scrollX(&properties) == null);
    try testing.expect(scrollXMin(&properties) == null);
    try testing.expect(scrollXMax(&properties) == null);
    try testing.expect(scrollY(&properties) == null);
    try testing.expect(scrollYMin(&properties) == null);
    try testing.expect(scrollYMax(&properties) == null);
    try testing.expect(numericValue(&properties) == null);
    try testing.expect(minNumericValue(&properties) == null);
    try testing.expect(maxNumericValue(&properties) == null);
    try testing.expect(numericValueStep(&properties) == null);
    try testing.expect(numericValueJump(&properties) == null);
    try testing.expect(fontSize(&properties) == null);
    try testing.expect(fontWeight(&properties) == null);
    try testing.expect(rowCount(&properties) == null);
    try testing.expect(columnCount(&properties) == null);
    try testing.expect(rowIndex(&properties) == null);
    try testing.expect(columnIndex(&properties) == null);
    try testing.expect(rowSpan(&properties) == null);
    try testing.expect(columnSpan(&properties) == null);
    try testing.expect(level(&properties) == null);
    try testing.expect(sizeOfSet(&properties) == null);
    try testing.expect(positionInSet(&properties) == null);
}

test "clearing one property leaves the others in the store" {
    // Upstream's clearer is `properties.clear(id)`
    // (`accesskit/src/lib.rs:1148-1153`), which touches one entry. A port that
    // cleared the whole store still passes every round trip above.
    var properties = Properties.init(testing.allocator);
    defer properties.deinit();

    try setScrollX(&properties, 1.0);
    try setScrollY(&properties, 2.0);
    clearScrollX(&properties);

    try testing.expect(scrollX(&properties) == null);
    try testing.expectEqual(@as(f64, 2.0), scrollY(&properties).?);
}

test "one property reads back under its own id after a second write" {
    // Upstream reuses the entry a property already owns
    // (`accesskit/src/lib.rs:1138-1146`). A port that appended a second entry
    // per write, or that looked the property up by insertion position, answers
    // the first value here.
    var properties = Properties.init(testing.allocator);
    defer properties.deinit();

    try setRowIndex(&properties, 1);
    try setScrollY(&properties, 9.0);
    try setRowIndex(&properties, 3);

    try testing.expectEqual(@as(usize, 3), rowIndex(&properties).?);
    try testing.expectEqual(@as(f64, 9.0), scrollY(&properties).?);
}
