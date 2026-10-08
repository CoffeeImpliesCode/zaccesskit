//! The 21 string properties of `string_property_methods!`.
//!
//! Upstream: `accesskit/src/lib.rs:2097-2205`, the invocation
//! `string_property_methods!` at `:1447-1480`, which expands
//! `property_methods!` at `:1299-1317`. Those three arguments per property are
//! where the borrow, the owning setter and the clearer come from. The property
//! text below is upstream's own, carried from the doc comments that invocation
//! holds.
//!
//! **Not methods on `Node`.** Zig attaches a method to the container that
//! declares it, and `schema/node.zig` owns `Node`, so this module publishes one
//! function per accessor and takes the store as the first parameter.
//!
//! **The store owns its allocator.** `Properties` is created with one allocator
//! and every write here goes through it. No accessor in this file takes an
//! allocator, because a caller that passes a second one would let the store free
//! a payload it did not allocate. `props/table.zig` owns `Properties`, its
//! `get`, `set` and `clear`, and its `deinit`.
//!
//! **A setter copies, and never takes ownership.** Every setter here copies
//! `bytes` into a fresh array and hands that array to the store. The caller's
//! slice is not retained and not released, and the caller still owns it.
//! Upstream takes `impl Into<String>` at `accesskit/src/lib.rs:1451` and owns a
//! Rust `String`, so upstream does take ownership;
//! `docs/10-accesskit-core.md` section 2.4 rules that a borrowed slice says the
//! ownership where the name does not, and the slice is what the port takes. The
//! parameter is `bytes` rather than `value`, because `value` is already the
//! getter of the third property in this file.
//!
//! **A getter returns a borrow.** A slice from any of the 21 getters points
//! into the array the store owns. The setter for that same property frees that
//! array and the clearer frees it as well, so the next write to that property
//! invalidates the slice. A caller that needs the text after such a write copies
//! it first.
//!
//! **Absent is not empty.** `option_ref_type_getters` at
//! `accesskit/src/lib.rs:1225-1230` returns the stored string and `None` for
//! every other arm, so an empty string is stored as itself and reads back as
//! `Some("")`. The port keeps that: `null` is absent, `""` is present and
//! empty, and the two are different values. Whether an empty string is a
//! meaningful label is a caller decision, and this module does not make it.
//!
//! **Every owning write carries an `errdefer`.** Each setter copies the
//! caller's bytes into a fresh array and then hands that array to the store. A
//! `set` that reports `error.OutOfMemory` takes ownership of nothing, so the
//! guard releases the copy that no other name reaches. Without it the caller
//! gets a leak instead of an error.
//!
//! The shortest use is one set and one read:
//!
//! ```zig
//! var properties: Properties = .init(gpa);
//! defer properties.deinit();
//! try setLabel(&properties, "Save");
//! const text = label(&properties);
//! ```

const std = @import("std");

const table = @import("table.zig");
const Properties = table.Properties;
const PropertyId = table.PropertyId;
const PropertyValue = table.PropertyValue;

const testing = std.testing;

comptime {
    // The string arm is the only one these 21 accessors read, so a port that
    // retyped the payload fails here rather than in every getter.
    std.debug.assert(@hasField(PropertyValue, "string"));
    // Upstream numbers the string group 15 through 35
    // (`accesskit/src/lib.rs:913-934`), after eight list identifiers and seven
    // singleton identifiers. A variable-length encoding reads these numbers, so
    // the span is pinned rather than assumed.
    std.debug.assert(bindings.len == 21);
    std.debug.assert(@intFromEnum(bindings[0].id) == 15);
    std.debug.assert(@intFromEnum(bindings[bindings.len - 1].id) == 35);
    // The rows of `bindings` are the family's domain, so the reachability
    // claim is over the same rows rather than over a second list. A property
    // with a descriptor row and no binding here is a compile error.
    table.assertFamilyReachable(.strings, property_ids);
}

/// Copies `bytes` into a fresh array and then hands that array to the store,
/// which is what `owned_type_setters` at `accesskit/src/lib.rs:1264-1266` does
/// with `impl Into<String>`.
///
/// The copy is made before the write, so a `set` that fails leaves the stored
/// string exactly as it was. The `errdefer` releases the copy on that path
/// because the store took nothing.
fn writeString(
    properties: *Properties,
    id: PropertyId,
    bytes: []const u8,
) std.mem.Allocator.Error!void {
    var owned: std.ArrayList(u8) = try .initCapacity(properties.gpa, bytes.len);
    owned.appendSliceAssumeCapacity(bytes);
    errdefer owned.deinit(properties.gpa);
    try properties.set(id, table.propertyValueFrom(.string, owned));
}

/// Reads the string arm. `option_ref_type_getters` at
/// `accesskit/src/lib.rs:1225-1230` returns the stored string and `None` for
/// every other arm.
fn readString(properties: *const Properties, id: PropertyId) ?[]const u8 {
    const stored = properties.get(id) orelse return null;
    return switch (stored.*) {
        .string => |text| text.items,
        else => null,
    };
}

/// The label of this node. A node with the label role carries its text through
/// `value` instead. ARIA equivalent: `aria-label`.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setLabel` or `clearLabel` invalidates it.
pub fn label(properties: *const Properties) ?[]const u8 {
    return readString(properties, .label);
}

/// Copies `bytes` into the store as the label, and discards whatever the
/// property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the label as it was.
pub fn setLabel(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .label, bytes);
}

/// Makes the property read as one that was never set, so `label` answers `null`.
pub fn clearLabel(properties: *Properties) void {
    properties.clear(.label);
}

/// Information that supplements this node's label. ARIA 1.3 draft equivalent:
/// `aria-description`.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setDescription` or `clearDescription` invalidates it.
pub fn description(properties: *const Properties) ?[]const u8 {
    return readString(properties, .description);
}

/// Copies `bytes` into the store as the description, and discards whatever the
/// property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the description as it was.
pub fn setDescription(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .description, bytes);
}

/// Makes the property read as one that was never set, so `description` answers
/// `null`.
pub fn clearDescription(properties: *Properties) void {
    properties.clear(.description);
}

/// The text content or string value of this node. ARIA equivalent:
/// `aria-valuetext` for a range widget. Unlike that attribute, this property
/// also carries the text of a text control and the text content of the label
/// and text run roles.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setValue` or `clearValue` invalidates it.
pub fn value(properties: *const Properties) ?[]const u8 {
    return readString(properties, .value);
}

/// Copies `bytes` into the store as the value, and discards whatever the
/// property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the value as it was.
pub fn setValue(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .value, bytes);
}

/// Makes the property read as one that was never set, so `value` answers `null`.
pub fn clearValue(properties: *Properties) void {
    properties.clear(.value);
}

/// One character that performs this node's default action, usually together with
/// a platform modifier. For a menu item it is active only while the menu is
/// active, unlike `keyboardShortcut`, and one menu item may carry both.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setAccessKey` or `clearAccessKey` invalidates it.
pub fn accessKey(properties: *const Properties) ?[]const u8 {
    return readString(properties, .access_key);
}

/// Copies `bytes` into the store as the access key, and discards whatever the
/// property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the access key as it was.
pub fn setAccessKey(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .access_key, bytes);
}

/// Makes the property read as one that was never set, so `accessKey` answers
/// `null`.
pub fn clearAccessKey(properties: *Properties) void {
    properties.clear(.access_key);
}

/// An identifier for application authors, for use in automated testing. It must
/// be unique among this node's siblings.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setAuthorId` or `clearAuthorId` invalidates it.
pub fn authorId(properties: *const Properties) ?[]const u8 {
    return readString(properties, .author_id);
}

/// Copies `bytes` into the store as the author id, and discards whatever the
/// property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the author id as it was.
pub fn setAuthorId(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .author_id, bytes);
}

/// Makes the property read as one that was never set, so `authorId` answers
/// `null`.
pub fn clearAuthorId(properties: *Properties) void {
    properties.clear(.author_id);
}

/// The platform control class name for this node.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setClassName` or `clearClassName` invalidates it.
pub fn className(properties: *const Properties) ?[]const u8 {
    return readString(properties, .class_name);
}

/// Copies `bytes` into the store as the class name, and discards whatever the
/// property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the class name as it was.
pub fn setClassName(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .class_name, bytes);
}

/// Makes the property read as one that was never set, so `className` answers
/// `null`.
pub fn clearClassName(properties: *Properties) void {
    properties.clear(.class_name);
}

/// The font family used for this node's text. Set it only when it differs from
/// the parent.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setFontFamily` or `clearFontFamily` invalidates it.
pub fn fontFamily(properties: *const Properties) ?[]const u8 {
    return readString(properties, .font_family);
}

/// Copies `bytes` into the store as the font family, and discards whatever the
/// property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the font family as it was.
pub fn setFontFamily(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .font_family, bytes);
}

/// Makes the property read as one that was never set, so `fontFamily` answers
/// `null`.
pub fn clearFontFamily(properties: *Properties) void {
    properties.clear(.font_family);
}

/// The `id` of the HTML element this node represents. On a platform that maps
/// both this and `authorId` onto one platform property, this takes precedence.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setHtmlId` or `clearHtmlId` invalidates it.
pub fn htmlId(properties: *const Properties) ?[]const u8 {
    return readString(properties, .html_id);
}

/// Copies `bytes` into the store as the HTML id, and discards whatever the
/// property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the HTML id as it was.
pub fn setHtmlId(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .html_id, bytes);
}

/// Makes the property read as one that was never set, so `htmlId` answers
/// `null`.
pub fn clearHtmlId(properties: *Properties) void {
    properties.clear(.html_id);
}

/// The name of the HTML element this node represents.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setHtmlTag` or `clearHtmlTag` invalidates it.
pub fn htmlTag(properties: *const Properties) ?[]const u8 {
    return readString(properties, .html_tag);
}

/// Copies `bytes` into the store as the HTML tag name, and discards whatever
/// the property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the HTML tag as it was.
pub fn setHtmlTag(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .html_tag, bytes);
}

/// Makes the property read as one that was never set, so `htmlTag` answers
/// `null`.
pub fn clearHtmlTag(properties: *Properties) void {
    properties.clear(.html_tag);
}

/// Inner HTML of an element. Used only for a top-level math element, to support
/// third-party math accessibility products that parse MathML.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setInnerHtml` or `clearInnerHtml` invalidates it.
pub fn innerHtml(properties: *const Properties) ?[]const u8 {
    return readString(properties, .inner_html);
}

/// Copies `bytes` into the store as the inner HTML, and discards whatever the
/// property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the inner HTML as it was.
pub fn setInnerHtml(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .inner_html, bytes);
}

/// Makes the property read as one that was never set, so `innerHtml` answers
/// `null`.
pub fn clearInnerHtml(properties: *Properties) void {
    properties.clear(.inner_html);
}

/// A keystroke or sequence of keystrokes, with any required modifiers, that
/// performs this node's default action. The value should be in a human-friendly
/// format. ARIA equivalent: `aria-keyshortcuts`.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setKeyboardShortcut` or `clearKeyboardShortcut` invalidates it.
pub fn keyboardShortcut(properties: *const Properties) ?[]const u8 {
    return readString(properties, .keyboard_shortcut);
}

/// Copies `bytes` into the store as the keyboard shortcut, and discards whatever
/// the property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the keyboard shortcut as it was.
pub fn setKeyboardShortcut(
    properties: *Properties,
    bytes: []const u8,
) std.mem.Allocator.Error!void {
    try writeString(properties, .keyboard_shortcut, bytes);
}

/// Makes the property read as one that was never set, so `keyboardShortcut`
/// answers `null`.
pub fn clearKeyboardShortcut(properties: *Properties) void {
    properties.clear(.keyboard_shortcut);
}

/// An IETF language tag, per BCP 47. Set it only when it differs from the
/// parent.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setLanguage` or `clearLanguage` invalidates it.
pub fn language(properties: *const Properties) ?[]const u8 {
    return readString(properties, .language);
}

/// Copies `bytes` into the store as the language tag, and discards whatever the
/// property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the language as it was.
pub fn setLanguage(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .language, bytes);
}

/// Makes the property read as one that was never set, so `language` answers
/// `null`.
pub fn clearLanguage(properties: *Properties) void {
    properties.clear(.language);
}

/// A short hint that helps the user with data entry when the node has no value.
/// Do not use it instead of `label`. ARIA equivalent: `aria-placeholder`.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setPlaceholder` or `clearPlaceholder` invalidates it.
pub fn placeholder(properties: *const Properties) ?[]const u8 {
    return readString(properties, .placeholder);
}

/// Copies `bytes` into the store as the placeholder, and discards whatever the
/// property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the placeholder as it was.
pub fn setPlaceholder(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .placeholder, bytes);
}

/// Makes the property read as one that was never set, so `placeholder` answers
/// `null`.
pub fn clearPlaceholder(properties: *Properties) void {
    properties.clear(.placeholder);
}

/// A string that overrides the assistive technology's description of the node's
/// role. Supply it only for a custom control type, and localize it. ARIA
/// equivalent: `aria-roledescription`.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setRoleDescription` or `clearRoleDescription` invalidates it.
pub fn roleDescription(properties: *const Properties) ?[]const u8 {
    return readString(properties, .role_description);
}

/// Copies `bytes` into the store as the role description, and discards whatever
/// the property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the role description as it was.
pub fn setRoleDescription(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .role_description, bytes);
}

/// Makes the property read as one that was never set, so `roleDescription`
/// answers `null`.
pub fn clearRoleDescription(properties: *Properties) void {
    properties.clear(.role_description);
}

/// A string that overrides the assistive technology's description of the node's
/// state, replacing defaults such as "checked" or "selected". Most platform
/// accessibility APIs and assistive technologies do not support this.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setStateDescription` or `clearStateDescription` invalidates it.
pub fn stateDescription(properties: *const Properties) ?[]const u8 {
    return readString(properties, .state_description);
}

/// Copies `bytes` into the store as the state description, and discards whatever
/// the property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the state description as it was.
pub fn setStateDescription(
    properties: *Properties,
    bytes: []const u8,
) std.mem.Allocator.Error!void {
    try writeString(properties, .state_description, bytes);
}

/// Makes the property read as one that was never set, so `stateDescription`
/// answers `null`.
pub fn clearStateDescription(properties: *Properties) void {
    properties.clear(.state_description);
}

/// The tooltip of this node, for a node whose only label comes from the tooltip,
/// in place of `label`.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setTooltip` or `clearTooltip` invalidates it.
pub fn tooltip(properties: *const Properties) ?[]const u8 {
    return readString(properties, .tooltip);
}

/// Copies `bytes` into the store as the tooltip, and discards whatever the
/// property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the tooltip as it was.
pub fn setTooltip(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .tooltip, bytes);
}

/// Makes the property read as one that was never set, so `tooltip` answers
/// `null`.
pub fn clearTooltip(properties: *Properties) void {
    properties.clear(.tooltip);
}

/// The target URL of a link.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setUrl` or `clearUrl` invalidates it.
pub fn url(properties: *const Properties) ?[]const u8 {
    return readString(properties, .url);
}

/// Copies `bytes` into the store as the link target URL, and discards whatever
/// the property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the URL as it was.
pub fn setUrl(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .url, bytes);
}

/// Makes the property read as one that was never set, so `url` answers `null`.
pub fn clearUrl(properties: *Properties) void {
    properties.clear(.url);
}

/// A human-readable alternative to the numeric row index. ARIA 1.3 draft
/// equivalent: `aria-rowindextext`.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setRowIndexText` or `clearRowIndexText` invalidates it.
pub fn rowIndexText(properties: *const Properties) ?[]const u8 {
    return readString(properties, .row_index_text);
}

/// Copies `bytes` into the store as the row index text, and discards whatever
/// the property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the row index text as it was.
pub fn setRowIndexText(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .row_index_text, bytes);
}

/// Makes the property read as one that was never set, so `rowIndexText` answers
/// `null`.
pub fn clearRowIndexText(properties: *Properties) void {
    properties.clear(.row_index_text);
}

/// A human-readable alternative to the numeric column index. ARIA 1.3 draft
/// equivalent: `aria-colindextext`.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setColumnIndexText` or `clearColumnIndexText` invalidates it.
pub fn columnIndexText(properties: *const Properties) ?[]const u8 {
    return readString(properties, .column_index_text);
}

/// Copies `bytes` into the store as the column index text, and discards whatever
/// the property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the column index text as it was.
pub fn setColumnIndexText(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .column_index_text, bytes);
}

/// Makes the property read as one that was never set, so `columnIndexText`
/// answers `null`.
pub fn clearColumnIndexText(properties: *Properties) void {
    properties.clear(.column_index_text);
}

/// An alternative to `label` that assistive technologies may present on a
/// Braille display instead of speaking it. The value is ordinary text, not
/// Unicode Braille characters. ARIA 1.3 draft equivalent: `aria-braillelabel`.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setBrailleLabel` or `clearBrailleLabel` invalidates it.
pub fn brailleLabel(properties: *const Properties) ?[]const u8 {
    return readString(properties, .braille_label);
}

/// Copies `bytes` into the store as the Braille label, and discards whatever the
/// property held. The caller's slice is not retained and not released.
/// `error.OutOfMemory` leaves the Braille label as it was.
pub fn setBrailleLabel(properties: *Properties, bytes: []const u8) std.mem.Allocator.Error!void {
    try writeString(properties, .braille_label, bytes);
}

/// Makes the property read as one that was never set, so `brailleLabel` answers
/// `null`.
pub fn clearBrailleLabel(properties: *Properties) void {
    properties.clear(.braille_label);
}

/// An alternative to `roleDescription` that assistive technologies may present
/// on a Braille display instead of speaking it. The value is ordinary text, not
/// Unicode Braille characters. ARIA 1.3 draft equivalent:
/// `aria-brailleroledescription`.
///
/// `null` when the property is unset. The slice borrows `properties`, and
/// `setBrailleRoleDescription` or `clearBrailleRoleDescription` invalidates it.
pub fn brailleRoleDescription(properties: *const Properties) ?[]const u8 {
    return readString(properties, .braille_role_description);
}

/// Copies `bytes` into the store as the Braille role description, and discards
/// whatever the property held. The caller's slice is not retained and not
/// released. `error.OutOfMemory` leaves the value as it was.
pub fn setBrailleRoleDescription(
    properties: *Properties,
    bytes: []const u8,
) std.mem.Allocator.Error!void {
    try writeString(properties, .braille_role_description, bytes);
}

/// Makes the property read as one that was never set, so
/// `brailleRoleDescription` answers `null`.
pub fn clearBrailleRoleDescription(properties: *Properties) void {
    properties.clear(.braille_role_description);
}

/// The three functions one string property is reached through, bound to the
/// identifier they act on.
const Binding = struct {
    id: PropertyId,
    get: *const fn (*const Properties) ?[]const u8,
    set: *const fn (*Properties, []const u8) std.mem.Allocator.Error!void,
    clear: *const fn (*Properties) void,
};

/// Every property the string family declares, in upstream order, and the bound
/// for every loop over the family.
const bindings = [_]Binding{
    .{ .id = .label, .get = label, .set = setLabel, .clear = clearLabel },
    .{ .id = .description, .get = description, .set = setDescription, .clear = clearDescription },
    .{ .id = .value, .get = value, .set = setValue, .clear = clearValue },
    .{ .id = .access_key, .get = accessKey, .set = setAccessKey, .clear = clearAccessKey },
    .{ .id = .author_id, .get = authorId, .set = setAuthorId, .clear = clearAuthorId },
    .{ .id = .class_name, .get = className, .set = setClassName, .clear = clearClassName },
    .{ .id = .font_family, .get = fontFamily, .set = setFontFamily, .clear = clearFontFamily },
    .{ .id = .html_id, .get = htmlId, .set = setHtmlId, .clear = clearHtmlId },
    .{ .id = .html_tag, .get = htmlTag, .set = setHtmlTag, .clear = clearHtmlTag },
    .{ .id = .inner_html, .get = innerHtml, .set = setInnerHtml, .clear = clearInnerHtml },
    .{
        .id = .keyboard_shortcut,
        .get = keyboardShortcut,
        .set = setKeyboardShortcut,
        .clear = clearKeyboardShortcut,
    },
    .{ .id = .language, .get = language, .set = setLanguage, .clear = clearLanguage },
    .{ .id = .placeholder, .get = placeholder, .set = setPlaceholder, .clear = clearPlaceholder },
    .{
        .id = .role_description,
        .get = roleDescription,
        .set = setRoleDescription,
        .clear = clearRoleDescription,
    },
    .{
        .id = .state_description,
        .get = stateDescription,
        .set = setStateDescription,
        .clear = clearStateDescription,
    },
    .{ .id = .tooltip, .get = tooltip, .set = setTooltip, .clear = clearTooltip },
    .{ .id = .url, .get = url, .set = setUrl, .clear = clearUrl },
    .{
        .id = .row_index_text,
        .get = rowIndexText,
        .set = setRowIndexText,
        .clear = clearRowIndexText,
    },
    .{
        .id = .column_index_text,
        .get = columnIndexText,
        .set = setColumnIndexText,
        .clear = clearColumnIndexText,
    },
    .{
        .id = .braille_label,
        .get = brailleLabel,
        .set = setBrailleLabel,
        .clear = clearBrailleLabel,
    },
    .{
        .id = .braille_role_description,
        .get = brailleRoleDescription,
        .set = setBrailleRoleDescription,
        .clear = clearBrailleRoleDescription,
    },
};

/// The identifiers of the 21 rows above, projected out of `bindings`.
///
/// Derived rather than written out a second time, because a hand-kept second
/// list is a second source of truth for the same 21 properties and the two
/// could disagree. `assertFamilyReachable` takes this list, so the reachability
/// claim is made over the rows that carry the functions rather than over a
/// parallel declaration of them.
const property_ids: [bindings.len]PropertyId = blk: {
    var collected: [bindings.len]PropertyId = undefined;
    for (bindings, 0..) |binding, index| collected[index] = binding.id;
    break :blk collected;
};

test "every string property round trips through set then get, and clears" {
    var properties = Properties.init(testing.allocator);
    defer properties.deinit();

    for (bindings) |binding| {
        try testing.expectEqual(@as(?[]const u8, null), binding.get(&properties));

        try binding.set(&properties, "test");
        try testing.expect(binding.get(&properties) != null);
        try testing.expectEqualStrings("test", binding.get(&properties).?);

        binding.clear(&properties);
        try testing.expectEqual(@as(?[]const u8, null), binding.get(&properties));
    }
}

test "an empty string is present and empty, which is not the same as absent" {
    var properties = Properties.init(testing.allocator);
    defer properties.deinit();

    for (bindings) |binding| {
        try testing.expectEqual(@as(?[]const u8, null), binding.get(&properties));

        try binding.set(&properties, "");
        try testing.expect(binding.get(&properties) != null);
        try testing.expectEqual(@as(usize, 0), binding.get(&properties).?.len);

        binding.clear(&properties);
        try testing.expectEqual(@as(?[]const u8, null), binding.get(&properties));
    }
}

test "a setter copies the caller's buffer instead of retaining it" {
    const gpa = testing.allocator;
    var properties = Properties.init(gpa);
    defer properties.deinit();

    var source = try gpa.dupe(u8, "original");
    // The caller still owns `source`, so releasing it is this test's duty. A
    // setter that took ownership would fail twice over: this free would be the
    // second one, and the store would be reading the caller's buffer rather
    // than its own.
    defer gpa.free(source);

    try setLabel(&properties, source);
    source[0] = 'X';

    try testing.expect(label(&properties) != null);
    try testing.expectEqualStrings("original", label(&properties).?);
}

test "a failed allocation leaves the previous value intact and leaks nothing" {
    // The store owns the allocator every write goes through, so the failure is
    // injected when the store is created, not per call.
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var properties = Properties.init(failing.allocator());
    defer properties.deinit();

    try setLabel(&properties, "first");

    // The bound is how many allocations one setter can make: the copy of the
    // bytes, plus whatever the store grows to record the property. A larger
    // index means the path has no allocation left to fail, which is where the
    // sweep ends.
    const set_allocation_bound = 4;
    var attempt: usize = 0;
    while (attempt < set_allocation_bound) : (attempt += 1) {
        failing.alloc_index = 0;
        failing.fail_index = attempt;
        if (setLabel(&properties, "second")) |_| {
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(label(&properties) != null);
            try testing.expectEqualStrings("first", label(&properties).?);
        }
    }
    // A setter that never allocated could not be made to fail, and this test
    // would have proved nothing.
    try testing.expect(attempt > 0);
}
