//! The platform-neutral value types: roles, actions, identifiers, geometry, the
//! property model and the tree update.
//!
//! This module is the `zaccesskit.schema` namespace. It holds the vocabulary a
//! consumer names in a signature: the types, the module-level constants and the
//! conversions between them. It holds **no I/O, no clock, no environment and no
//! socket**; the whole layer is pure data plus arithmetic over it, so it is
//! testable without a platform.
//!
//! **Why this is a flat index and the property accessors are not.** The types
//! here are the vocabulary, and a vocabulary wants one short spelling:
//! `schema.Role`, not `schema.role_module.Role`. The eight property-accessor
//! modules are a different thing. They contribute roughly 270 functions whose
//! names are the property names, and several of those names collide across
//! families — a getter and a setter pair, a property and its clearer. Flattening
//! them buys no reader anything and creates a resolution order a reader has to
//! know. So each is a namespace:
//!
//! ```zig
//! const schema = @import("zaccesskit").schema;
//! var node = schema.Node.init(gpa, .button);
//! try schema.strings.setLabel(&node.properties, "Save");
//! if (schema.strings.label(&node.properties)) |text| { ... }
//! ```
//!
//! **What this layer deliberately does not do.** It does not reach for a runtime:
//! nothing here names `zio`, and `std.Io` appears only as `std.Io.Writer` in the
//! three `format` methods, which is a sink a caller supplies rather than a
//! capability the layer acquires. It does not read a clock, because
//! `docs/30-port-design.md` section 8 records that time is a parameter and zio
//! has no virtual clock to substitute. It holds no global state; every constant
//! is `const`.
//!
//! **Layout.** Every type whose byte offsets are part of the C contract is an
//! `extern struct`, and every one of them asserts its measured size, alignment
//! and offsets in a container-level `comptime` block, so a field added to any of
//! them is a build failure rather than a silent ABI change.

const std = @import("std");
// --- Geometry -----------------------------------------------------------------
// Five `extern struct`s, measured: `Point` and `Vec2` and `Size` are 16 bytes at
// alignment 8, `Rect` is 32 at 8, `Affine` is 48 at 8. `packed struct` does not
// work on this compiler for `Affine`, which rejects it with "packed structs
// cannot contain fields of type '[6]f64'".

const affine_mod = @import("geometry/affine.zig");
const point_mod = @import("geometry/point.zig");
const rect_mod = @import("geometry/rect.zig");
const size_mod = @import("geometry/size.zig");
const vec2_mod = @import("geometry/vec2.zig");

pub const Affine = affine_mod.Affine;
pub const ScaleAxes = affine_mod.ScaleAxes;
pub const affine_identity = affine_mod.affine_identity;
pub const affine_flip_y = affine_mod.affine_flip_y;
pub const affine_flip_x = affine_mod.affine_flip_x;
pub const affineNew = affine_mod.affineNew;
pub const affineScale = affine_mod.affineScale;
pub const affineScaleNonUniform = affine_mod.affineScaleNonUniform;
pub const affineTranslate = affine_mod.affineTranslate;
pub const affineMapUnitSquare = affine_mod.affineMapUnitSquare;

pub const Point = point_mod.Point;
pub const point_origin = point_mod.point_origin;
pub const pointInit = point_mod.pointInit;
pub const pointToVec2 = point_mod.pointToVec2;

pub const Vec2 = vec2_mod.Vec2;
pub const vec2_zero = vec2_mod.vec2_zero;
pub const vec2Init = vec2_mod.vec2Init;
pub const vec2ToPoint = vec2_mod.vec2ToPoint;
pub const vec2ToSize = vec2_mod.vec2ToSize;

pub const Size = size_mod.Size;
pub const size_zero = size_mod.size_zero;
pub const sizeInit = size_mod.sizeInit;
pub const sizeToVec2 = size_mod.sizeToVec2;

pub const Rect = rect_mod.Rect;
pub const rect_zero = rect_mod.rect_zero;
pub const rectInit = rect_mod.rectInit;
pub const rectFromPoints = rect_mod.rectFromPoints;
pub const rectFromOriginSize = rect_mod.rectFromOriginSize;
pub const rectSize = rect_mod.rectSize;

/// The one checked `f64`-to-integer narrowing in the geometry family.
/// Upstream casts bare at `adapters/atspi-common/src/rect.rs:31-34` and
/// `adapters/android/src/node.rs:247-250`; a port that copies a bare cast ships
/// a saturation bug.
pub const NarrowError = rect_mod.NarrowError;
pub const toI32Checked = rect_mod.toI32Checked;

// --- The wire enums -----------------------------------------------------------
// Discriminants are copied unchanged from upstream and the declaration order is
// the wire format: upstream orders `Role` by expected usage frequency rather
// than alphabetically, so sorting the tags silently renumbers every value.

const role_mod = @import("role.zig");
const action_mod = @import("action.zig");

pub const Role = role_mod.Role;
pub const Action = action_mod.Action;
pub const actionCount = action_mod.actionCount;
pub const actionFromInt = action_mod.actionFromInt;
pub const actionMask = action_mod.actionMask;
pub const actionSetContains = action_mod.actionSetContains;
pub const actionSetUnion = action_mod.actionSetUnion;
pub const actionSetDifference = action_mod.actionSetDifference;
pub const actionSetMembers = action_mod.actionSetMembers;

// --- Identifiers --------------------------------------------------------------

const ids_mod = @import("ids.zig");

pub const NodeId = ids_mod.NodeId;
pub const NodeIdContent = ids_mod.NodeIdContent;
pub const TreeId = ids_mod.TreeId;
pub const nodeIdFromContent = ids_mod.nodeIdFromContent;
pub const nodeIdToContent = ids_mod.nodeIdToContent;
pub const nodeIdFormat = ids_mod.nodeIdFormat;
pub const tree_id_root = ids_mod.tree_id_root;
pub const treeIdFromBytes = ids_mod.treeIdFromBytes;
pub const treeIdToBytes = ids_mod.treeIdToBytes;

// --- The small value types ----------------------------------------------------

const values_mod = @import("values.zig");

pub const CustomAction = values_mod.CustomAction;
pub const TextPosition = values_mod.TextPosition;
pub const TextSelection = values_mod.TextSelection;
pub const Color = values_mod.Color;
pub const TextDecoration = values_mod.TextDecoration;

// --- The property model -------------------------------------------------------
// 87 properties and no sentinel. Upstream declares an 88th variant whose own
// doc comment reads "This MUST be last" because its `PropertyIndices` byte array
// needs a zero; a sorted slice does not, so absence is a `null` from `get` and
// an out-of-range id is a compile error rather than a run-time rejection.

const table_mod = @import("props/table.zig");

pub const PropertyId = table_mod.PropertyId;
pub const propertyIdCount = table_mod.propertyIdCount;
pub const propertyIdTagCount = table_mod.propertyIdTagCount;
pub const propertyIdFromInt = table_mod.propertyIdFromInt;
pub const PropertyValue = table_mod.PropertyValue;
pub const PropertyValueTag = table_mod.PropertyValueTag;
pub const Property = table_mod.Property;
pub const PropertyDescriptor = table_mod.PropertyDescriptor;
pub const property_descriptors = table_mod.property_descriptors;
pub const propertyDescriptorCount = table_mod.propertyDescriptorCount;
pub const propertyDescriptor = table_mod.propertyDescriptor;
pub const PropertyPayloadType = table_mod.PropertyPayloadType;
pub const propertyValueFrom = table_mod.propertyValueFrom;
pub const PropertyValuePayloadType = table_mod.PropertyValuePayloadType;
pub const propertyValueTagOf = table_mod.propertyValueTagOf;
pub const property_value_tags_by_id = table_mod.property_value_tags_by_id;
pub const propertyValueClone = table_mod.propertyValueClone;
pub const propertyValueCloneInto = table_mod.propertyValueCloneInto;
pub const Properties = table_mod.Properties;
pub const Flag = table_mod.Flag;
pub const flagCount = table_mod.flagCount;
pub const flagMask = table_mod.flagMask;
pub const flagSetContains = table_mod.flagSetContains;
pub const flagSetUnion = table_mod.flagSetUnion;
pub const flagSetDifference = table_mod.flagSetDifference;
pub const flagSetMembers = table_mod.flagSetMembers;

// The eight accessor families, namespaced. Each function's first parameter is the
// store, so a call reads `strings.setLabel(&node.properties, value)`. The
// families are siblings of the table and none imports `node.zig`, so the graph
// stays acyclic.
pub const strings = @import("props/strings.zig");
pub const ids_props = @import("props/ids.zig");
pub const numbers = @import("props/numbers.zig");
pub const enums = @import("props/enums.zig");
pub const colors = @import("props/colors.zig");
pub const vectors = @import("props/vectors.zig");
pub const option = @import("props/option.zig");
pub const flags = @import("props/flags.zig");

// --- The property value enums -------------------------------------------------
// Thirteen small enums, each with a checked byte-to-tag gate. The gate exists
// because `@enumFromInt` and `std.meta.intToEnum` are unchecked in ReleaseFast,
// so an invalid discriminant off the C boundary would be undefined behaviour
// rather than a `null`. The gates are the boundary's safe decode.

const node_enums_mod = @import("node_enums.zig");
const scroll_enums_mod = @import("scroll_enums.zig");

pub const Orientation = node_enums_mod.Orientation;
pub const TextDirection = node_enums_mod.TextDirection;
pub const Invalid = node_enums_mod.Invalid;
pub const Toggled = node_enums_mod.Toggled;
pub const SortDirection = node_enums_mod.SortDirection;
pub const AriaCurrent = node_enums_mod.AriaCurrent;
pub const AutoComplete = node_enums_mod.AutoComplete;
pub const Live = node_enums_mod.Live;
pub const HasPopup = node_enums_mod.HasPopup;
pub const ListStyle = node_enums_mod.ListStyle;
pub const TextAlign = node_enums_mod.TextAlign;
pub const VerticalOffset = node_enums_mod.VerticalOffset;
pub const TextDecorationStyle = node_enums_mod.TextDecorationStyle;

pub const orientationFromInt = node_enums_mod.orientationFromInt;
pub const textDirectionFromInt = node_enums_mod.textDirectionFromInt;
pub const invalidFromInt = node_enums_mod.invalidFromInt;
pub const toggledFromInt = node_enums_mod.toggledFromInt;
pub const sortDirectionFromInt = node_enums_mod.sortDirectionFromInt;
pub const ariaCurrentFromInt = node_enums_mod.ariaCurrentFromInt;
pub const autoCompleteFromInt = node_enums_mod.autoCompleteFromInt;
pub const liveFromInt = node_enums_mod.liveFromInt;
pub const hasPopupFromInt = node_enums_mod.hasPopupFromInt;
pub const listStyleFromInt = node_enums_mod.listStyleFromInt;
pub const textAlignFromInt = node_enums_mod.textAlignFromInt;
pub const verticalOffsetFromInt = node_enums_mod.verticalOffsetFromInt;
pub const textDecorationStyleFromInt = node_enums_mod.textDecorationStyleFromInt;
pub const toggledFromBool = node_enums_mod.toggledFromBool;

pub const ScrollUnit = scroll_enums_mod.ScrollUnit;
pub const ScrollHint = scroll_enums_mod.ScrollHint;
pub const scrollUnitToStaticStr = scroll_enums_mod.scrollUnitToStaticStr;
pub const scrollUnitFromInt = scroll_enums_mod.scrollUnitFromInt;
pub const scrollHintToStaticStr = scroll_enums_mod.scrollHintToStaticStr;
pub const scrollHintFromInt = scroll_enums_mod.scrollHintFromInt;

// --- The node and the tree update ---------------------------------------------

const node_mod = @import("node.zig");
const update_mod = @import("update.zig");

pub const Node = node_mod.Node;

pub const TreeInfo = update_mod.TreeInfo;
pub const TreeUpdate = update_mod.TreeUpdate;
pub const NodeEntry = update_mod.NodeEntry;
pub const ActionData = update_mod.ActionData;
pub const ActionDataTag = update_mod.ActionDataTag;
pub const ActionDataPayload = update_mod.ActionDataPayload;
pub const ActionDataToCError = update_mod.ActionDataToCError;
pub const ActionRequest = update_mod.ActionRequest;

/// The C boundary forms. A `C` prefix means "this is the layout the C header
/// describes"; an unprefixed name is the ergonomic Zig type. Only the three that
/// would otherwise collide with a core name carry the prefix.
pub const CActionData = update_mod.CActionData;
pub const COptActionData = update_mod.COptActionData;
pub const CActionRequest = update_mod.CActionRequest;
pub const actionDataToC = update_mod.actionDataToC;
pub const actionDataFromC = update_mod.actionDataFromC;
pub const actionDataDeinit = update_mod.actionDataDeinit;
pub const cActionDataDeinit = update_mod.cActionDataDeinit;
pub const cActionRequestDeinit = update_mod.cActionRequestDeinit;

// --- The seam -----------------------------------------------------------------

pub const ActivationHandler = @import("handlers.zig").ActivationHandler;
pub const ActionHandler = @import("handlers.zig").ActionHandler;
pub const DeactivationHandler = @import("handlers.zig").DeactivationHandler;

test "every re-export above names a declaration that exists" {
    // A re-export on its own is analysed only as far as a reached path refers
    // to it, so a broken declaration in a module nothing calls would go
    // uncompiled. Forcing every declaration to be referenced is what makes this
    // file a real check of the whole layer rather than of the few names a
    // consumer happens to use.
    std.testing.refAllDecls(@This());
}
