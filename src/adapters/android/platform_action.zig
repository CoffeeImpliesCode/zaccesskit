//! One Java action call, decoded: `AndroidPlatformAction`.
//!
//! Upstream is `PlatformAction` at `AK/android/src/action.rs:33`, and
//! `docs/42-native-adapter-build-map.md` section 4.3 is what this module is
//! written against. That section names the five variants and the payload each
//! one carries, and it is the only document under `docs/` that does:
//!
//! | Variant | Payload | Reached by |
//! |---|---|---|
//! | `Simple` | one `jint` action id | any action with no arguments |
//! | `SetTextSelection` | two `jint` endpoints | `ACTION_SET_SELECTION`, both keys present |
//! | `CollapseTextSelection` | none | `ACTION_SET_SELECTION`, an endpoint absent |
//! | `TraverseText` | granularity, direction, extend flag | the two granularity actions |
//! | `SetProgress` | one `jfloat` | `ACTION_SET_PROGRESS` |
//!
//! **What this module decides and what it leaves alone.** It is a decoder, not
//! an interpreter. It turns `action` and `arguments` into one of the five
//! variants and stops. It never looks at a node, never asks whether the action
//! is supported and never builds an `ActionRequest`; `adapter.zig` does all
//! three, because the node is what makes the difference between an action that
//! applies and one that does not. `ACTION_SCROLL_FORWARD` is the clearest case:
//! it means "scroll down" on a vertical scroller and "scroll right" on a
//! horizontal one, and no decoder can tell which without the node.
//!
//! **Why a missing bundle key is not a failure.** Android sends `null` for
//! `arguments` when the action takes none, and sends a bundle without a given
//! key when the caller left it out. Both are ordinary. A missing key reads as
//! the action's default payload rather than as an error, and that is exactly how
//! `collapse_text_selection` is reached: `ACTION_SET_SELECTION` with no
//! endpoints is a request to collapse the selection.
//!
//! **Why every key is checked with `containsKey` first.** `Bundle.getInt`
//! answers `0` for an absent key and `0` is a legal caret position, so a
//! decoder that read the two endpoint keys unconditionally could not tell a
//! deliberate zero from a missing one. The `containsKey` gate is what makes the
//! collapse case distinguishable from a selection whose start is `0`.
//!
//! **The five JNI descriptors this module writes.** Four are on `Bundle` and one
//! is `FindClass` for the same class. `methods.zig` records no row for any of
//! them, because `docs/29` rows 24 to 46 do not cover the argument-reading half
//! of a `Bundle`. Each descriptor is a literal below and each is asserted by a
//! test, because `GetMethodID` compares it at run time on a device and nothing
//! on this host can.
//!
//! **The allocator.** `fromJava` is the entry point `src/capi/platform.zig`
//! calls and its signature carries no allocator, so it takes the C ABI's
//! declared one, `allocation.allocator()`. That is forced rather than chosen:
//! `accesskit_android_platform_action_free` also carries no allocator, so the two
//! must agree or the free is a mismatched release. The testable form, `decode`,
//! takes the table, so a test drives the real decoder through a table with no
//! JVM behind it.
//!
//! **The loop bound.** This file walks no domain outside its tests. The decoder
//! dispatches with a `switch`, which has no bound to derive, and the only walks
//! are the two in `Recorder` below: over `bundle_lookups`, whose length is
//! `bundle_lookup_count`, and over `read_keys`, whose length is `read_key_count`.

const std = @import("std");

const allocation = @import("../../capi/allocation.zig");
const classes = @import("classes.zig");
const jni = @import("jni_table.zig");
const values = @import("values.zig");

const JClass = jni.JClass;
const JFloat = jni.JFloat;
const JInt = values.JInt;
const JMethodId = jni.JMethodId;
const JniEnv = jni.JniEnv;
const JniTable = jni.JniTable;
const JObject = jni.JObject;
const JString = jni.JString;
const JValue = jni.JValue;

const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Everything a decode can fail with.
///
/// **`error.OutOfMemory` is the only tag a C caller sees as a `null` answer**,
/// because `include/zaccesskit.h:5716-5727` promises that a `null` means the
/// allocation failed. The two JNI tags mean the lookup failed, and `fromJava`
/// answers `null` for those with the error slot still at `Tag.none`, so a
/// failed lookup is never reported as a failed allocation.
///
/// The two JNI tags carry the same names `node.zig`'s `FillError` declares.
/// They are declared here rather than imported because this decoder reports no
/// tree query and no narrowing failure, and a wider set would be a promise the
/// module does not keep. `src/adapters/android/root.zig` asserts at comptime
/// that both tags are in `node.FillError`, so the two cannot drift apart.
pub const DecodeError = Allocator.Error || error{
    /// A JNI call left an exception pending on the calling thread. The exception
    /// is still pending, because nothing in this directory clears one, and every
    /// later JNI call on that thread fails until the caller clears it.
    JavaException,
    /// A `GetMethodID` answered `null` with no exception pending, so the class
    /// or the member is not on the classpath. On an older device this is the
    /// shape a missing method takes.
    JavaMemberMissing,
};

/// The two endpoints of a selection request, as Java states them.
///
/// Java counts characters from zero and AccessKit counts them the same way, so
/// both fields carry through unchanged. A `start` above `end` is a selection
/// that runs backwards, which Android allows and which `schema.TextSelection`
/// also allows, so no ordering is applied here.
pub const SelectionEndpoints = struct {
    /// `ACTION_ARGUMENT_SELECTION_START_INT`.
    start: JInt,
    /// `ACTION_ARGUMENT_SELECTION_END_INT`.
    end: JInt,
};

/// A movement through the text by one granularity.
///
/// `direction` is `1` for `ACTION_NEXT_AT_MOVEMENT_GRANULARITY` and `-1` for
/// `ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY`. It is a signed count rather than
/// an enum because the two Java actions are two separate action ids and the
/// bundle carries no direction of its own.
pub const TraverseText = struct {
    /// `ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT`, one of the four
    /// `MOVEMENT_GRANULARITY_*` values.
    granularity: JInt,
    /// `1` forward, `-1` backward.
    direction: JInt,
    /// `ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN`, so the move extends the
    /// selection instead of moving its focus alone.
    extend: bool,
};

/// What one Java action call asked for.
///
/// `simple` carries the raw action id rather than a narrower type on purpose.
/// The id is what the interpreter in `adapter.zig` dispatches on, and an id this
/// port has no action for is a request the interpreter declines rather than a
/// decode failure.
pub const PlatformAction = union(enum) {
    /// One of the ten action ids, with no arguments in the bundle.
    simple: JInt,
    /// `ACTION_SET_SELECTION` with both endpoints present.
    set_text_selection: SelectionEndpoints,
    /// `ACTION_SET_SELECTION` with at least one endpoint absent.
    collapse_text_selection: void,
    /// `ACTION_NEXT_AT_MOVEMENT_GRANULARITY` or
    /// `ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY`.
    traverse_text: TraverseText,
    /// `ACTION_SET_PROGRESS` with a progress value.
    set_progress: JFloat,
};

/// The handle `accesskit_android_platform_action_from_java` returns.
///
/// The caller owns one and releases it with
/// `accesskit_android_platform_action_free`, exactly once. The value holds the
/// allocator it was allocated in and one decoded action, and **nothing in it
/// points into Java**, because `include/zaccesskit.h:5723` promises the
/// `arguments` object belongs to the Java call and is not retained. That is why
/// the decode copies every number out of the bundle rather than borrowing it.
pub const AndroidPlatformAction = struct {
    /// The allocator that grew this value, which `free` reaches again.
    gpa: Allocator,
    /// The decoded action. Every member is two scalars or fewer, so a copy is
    /// the whole value and nothing here needs a `deinit` of its own.
    action: PlatformAction,

    /// The decoded action. It is never `null` for a handle `fromJava` returned,
    /// so the result type is a convenience rather than a real option.
    pub fn decoded(self: *const AndroidPlatformAction) *const PlatformAction {
        return &self.action;
    }
};

// --- the JNI surface this module writes -------------------------------------
//
// None of these four is in `methods.method_ids`, because `docs/29` rows 24 to 46
// do not record the `Bundle` accessors. They are literals here and a test pins
// each one against a literal written inside that test, because a wrong
// descriptor is a `null` from `GetMethodID` on a device and nothing else
// anywhere would show it.

/// One `Bundle` member lookup, as the three strings `GetMethodID` takes.
///
/// The class is not a field: all four rows share it, and a row that named it
/// four times would be four places to get it wrong.
const BundleLookup = struct {
    /// Borrowed from `methods.method_names`, so it has static lifetime.
    name: [:0]const u8,
    /// A literal below, so it has static lifetime.
    signature: [:0]const u8,
};

/// How many `Bundle` members this module reads.
pub const bundle_lookup_count = 4;

/// Every `Bundle` member this module reads, in the order `BundleReader` resolves
/// them. The array length is `bundle_lookup_count`, which is the bound every
/// test that walks it uses.
pub const bundle_lookups = [bundle_lookup_count]BundleLookup{
    .{ .name = "containsKey", .signature = "(Ljava/lang/String;)Z" },
    .{ .name = "getInt", .signature = "(Ljava/lang/String;)I" },
    .{ .name = "getBoolean", .signature = "(Ljava/lang/String;)Z" },
    .{ .name = "getFloat", .signature = "(Ljava/lang/String;)F" },
};

/// The descriptor of `android.os.Bundle`, which `classes.zig` already names.
const bundle_class: classes.ClassDescriptor = "Landroid/os/Bundle;";

/// The name `FindClass` takes for `android.os.Bundle`: the descriptor with the
/// `L` and the `;` removed and each package separator written as `/`.
const bundle_internal_name: [:0]const u8 = "android/os/Bundle";

// --- the decoder ------------------------------------------------------------

/// The four `Bundle` member ids, resolved once per decode.
///
/// Resolving four ids means four `FindClass` and four `GetMethodID` calls if
/// each read resolved its own, and a decode happens while a platform call is on
/// the stack. The class reference is released as soon as each id is read,
/// because a `jmethodID` stays valid while its class is loaded and the class
/// reference being local does not unload it.
const BundleReader = struct {
    /// The table every member is called through.
    table: JniTable,
    /// One id per row of `bundle_lookups`, in the same order.
    methods: [bundle_lookup_count]JMethodId,

    /// Resolves all four ids, or the failure the lookup produced.
    fn resolve(table: JniTable) DecodeError!BundleReader {
        const class = table.findClass(bundle_internal_name);
        if (table.exceptionCheck()) return error.JavaException;
        if (class == null) return error.JavaMemberMissing;
        defer table.deleteLocalRef(class);

        var reader: BundleReader = .{ .table = table, .methods = undefined };
        for (bundle_lookups, 0..) |lookup, index| {
            const method = table.getMethodId(class, lookup.name, lookup.signature);
            if (table.exceptionCheck()) return error.JavaException;
            if (method == null) return error.JavaMemberMissing;
            reader.methods[index] = method;
        }
        return reader;
    }

    /// Whether `bundle` carries `key`.
    fn contains(self: BundleReader, bundle: JObject, key: JString) DecodeError!bool {
        const answer = self.table.callBooleanMethod(
            bundle,
            self.methods[0],
            &.{.{ .l = key }},
        );
        if (self.table.exceptionCheck()) return error.JavaException;
        return answer != 0;
    }

    /// The `int` `key` names. A caller must have asked `contains` first, because
    /// a bundle that does not carry the key answers `0` here as well.
    fn readInt(self: BundleReader, bundle: JObject, key: JString) DecodeError!JInt {
        const answer = self.table.callIntMethod(bundle, self.methods[1], &.{.{ .l = key }});
        if (self.table.exceptionCheck()) return error.JavaException;
        return answer;
    }

    /// The `boolean` `key` names. An absent key answers `false`, which is the
    /// value the extend flag takes when the caller did not extend.
    fn readBoolean(self: BundleReader, bundle: JObject, key: JString) DecodeError!bool {
        const answer = self.table.callBooleanMethod(
            bundle,
            self.methods[2],
            &.{.{ .l = key }},
        );
        if (self.table.exceptionCheck()) return error.JavaException;
        return answer != 0;
    }

    /// The `float` `key` names.
    fn readFloat(self: BundleReader, bundle: JObject, key: JString) DecodeError!JFloat {
        const answer = self.table.callFloatMethod(bundle, self.methods[3], &.{.{ .l = key }});
        if (self.table.exceptionCheck()) return error.JavaException;
        return answer;
    }
};

/// Decodes `action` and `arguments` into one `PlatformAction`.
///
/// `arguments` may be `null`, which is how Android says "this action takes no
/// arguments". The decode copies every number out of the bundle and keeps no
/// reference into it, so the result survives the Java call it came from.
///
/// **`error.OutOfMemory` is the only tag a C caller sees as a `null` answer.**
/// The two JNI tags mean the lookup itself failed, and `fromJava` leaves the
/// error slot at `Tag.none` for both.
pub fn decode(
    jni_table: JniTable,
    action: JInt,
    arguments: JObject,
) DecodeError!PlatformAction {
    const simple: PlatformAction = .{ .simple = action };
    if (arguments == null) return simple;

    switch (action) {
        values.ACTION_SET_SELECTION => return decodeSelection(jni_table, arguments),
        values.ACTION_NEXT_AT_MOVEMENT_GRANULARITY,
        values.ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY,
        => return decodeTraversal(jni_table, arguments, action),
        values.ACTION_SET_PROGRESS => return decodeProgress(jni_table, arguments),
        else => return simple,
    }
}

/// Reads both selection endpoints, or reports that the bundle has none.
///
/// The keys are read in one pass: a missing start short-circuits, so a bundle
/// with neither endpoint makes one `containsKey` call and no getter calls at
/// all. That is the cheapest honest path and the one a collapse request takes.
fn decodeSelection(
    jni_table: JniTable,
    arguments: JObject,
) DecodeError!PlatformAction {
    const reader = try BundleReader.resolve(jni_table);

    const start_key = try newString(jni_table, values.ACTION_ARGUMENT_SELECTION_START_INT);
    defer jni_table.deleteLocalRef(start_key);
    if (!try reader.contains(arguments, start_key)) {
        return .{ .collapse_text_selection = {} };
    }

    const end_key = try newString(jni_table, values.ACTION_ARGUMENT_SELECTION_END_INT);
    defer jni_table.deleteLocalRef(end_key);
    if (!try reader.contains(arguments, end_key)) {
        return .{ .collapse_text_selection = {} };
    }

    return .{ .set_text_selection = .{
        .start = try reader.readInt(arguments, start_key),
        .end = try reader.readInt(arguments, end_key),
    } };
}

/// Reads the granularity, the direction and the extend flag.
///
/// `direction` comes from which of the two Java action ids arrived, because
/// neither key in the bundle carries it.
fn decodeTraversal(
    jni_table: JniTable,
    arguments: JObject,
    action: JInt,
) DecodeError!PlatformAction {
    const reader = try BundleReader.resolve(jni_table);

    const granularity_key = try newString(
        jni_table,
        values.ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT,
    );
    defer jni_table.deleteLocalRef(granularity_key);
    const extend_key = try newString(
        jni_table,
        values.ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN,
    );
    defer jni_table.deleteLocalRef(extend_key);

    const forward: JInt = values.ACTION_NEXT_AT_MOVEMENT_GRANULARITY;
    return .{ .traverse_text = .{
        .granularity = try reader.readInt(arguments, granularity_key),
        .direction = if (action == forward) 1 else -1,
        .extend = try reader.readBoolean(arguments, extend_key),
    } };
}

/// Reads the progress value out of the bundle.
fn decodeProgress(jni_table: JniTable, arguments: JObject) DecodeError!PlatformAction {
    const reader = try BundleReader.resolve(jni_table);
    const progress_key = try newString(jni_table, values.ACTION_ARGUMENT_PROGRESS_VALUE);
    defer jni_table.deleteLocalRef(progress_key);
    return .{ .set_progress = try reader.readFloat(arguments, progress_key) };
}

/// A Java string holding `text`, or the failure the construction produced.
fn newString(jni_table: JniTable, text: [:0]const u8) DecodeError!JString {
    const value = jni_table.newString(text);
    if (jni_table.exceptionCheck()) return error.JavaException;
    if (value == null) return error.JavaMemberMissing;
    return value;
}

/// Builds one handle from the Java object an action callback supplied.
///
/// This is `accesskit_android_platform_action_from_java`, and the signature is
/// the one `src/capi/platform.zig:508` writes. `env` becomes a real JNI table
/// because the C caller hands over an environment and nothing else, and the
/// handle is allocated from `allocation.allocator()` because
/// `accesskit_android_platform_action_free` releases it through the same
/// declared allocator.
///
/// **`null` means the allocation failed.** A JNI lookup that fails answers
/// `null` too and leaves `accesskit_last_error` at `ACCESSKIT_ERROR_NONE`,
/// because the header's promise is about the allocation and nothing else. The
/// exception is left pending: `docs/29` section 3.3 records that upstream
/// unwraps at each site, and this module reports rather than clears so a caller
/// can see what happened.
pub fn fromJava(env: JniEnv, action: JInt, arguments: JObject) ?*AndroidPlatformAction {
    const gpa = allocation.allocator();
    const decoded = decode(jni.realTable(env), action, arguments) catch |err| switch (err) {
        error.OutOfMemory => {
            allocation.failWith(.out_of_memory);
            return null;
        },
        error.JavaException, error.JavaMemberMissing => return null,
    };
    const handle = allocation.create(AndroidPlatformAction) catch {
        allocation.failWith(.out_of_memory);
        return null;
    };
    handle.* = .{ .gpa = gpa, .action = decoded };
    return handle;
}

/// Releases one handle, exactly once.
///
/// This is `accesskit_android_platform_action_free`. The node the action names
/// is not held by the handle, so nothing else is released here. `self` is
/// unusable afterwards and a second call is a double free.
pub fn free(handle: *AndroidPlatformAction) void {
    allocation.release(@ptrCast(@alignCast(handle)));
}

// --- Tests --------------------------------------------------------------------

/// The first fabricated handle, so a fabricated handle is never the JNI null.
const handle_base = 0x2000;

/// A fabricated bundle object. No decode dereferences it.
fn fakeBundle() JObject {
    return @ptrFromInt(handle_base + 4);
}

/// Which `Bundle` keys the recorder answers for.
const ReadKey = enum {
    selection_start,
    selection_end,
    granularity,
    progress,
    extend,

    /// The bundle key this one names, as Android spells it in the bundle.
    fn bundleKey(self: ReadKey) [:0]const u8 {
        return switch (self) {
            .selection_start => values.ACTION_ARGUMENT_SELECTION_START_INT,
            .selection_end => values.ACTION_ARGUMENT_SELECTION_END_INT,
            .granularity => values.ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT,
            .progress => values.ACTION_ARGUMENT_PROGRESS_VALUE,
            .extend => values.ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN,
        };
    }

    /// The fabricated handle address a `newString` call for this key answers.
    ///
    /// One past the last row is the "no such key" answer, so a decoder that
    /// asked for a key the recorder does not know is visible rather than
    /// silently reading row zero.
    fn handle(self: ReadKey) JString {
        return @ptrFromInt(@as(usize, handle_base + 100) + @intFromEnum(self));
    }
};

/// How many keys `ReadKey` declares, which is the bound every walk over it uses.
const read_key_count = @typeInfo(ReadKey).@"enum".fields.len;

/// The key a fabricated string handle carries, or `null` when it names none.
fn readKeyOf(key: JString) ?ReadKey {
    if (key == null) return null;
    const offset = @intFromPtr(key.?);
    if (offset < handle_base + 100) return null;
    const index = offset - (handle_base + 100);
    if (index >= read_key_count) return null;
    return @enumFromInt(index);
}

/// What one decode reads back, kept where a test can read it.
///
/// The recorder owns no memory and returns no error, so a test drives the whole
/// decoder with no failing allocator in the middle of a recorded call. The
/// table is built by value around this one value, so no test shares it.
const Recorder = struct {
    /// Which keys `containsKey` reports present.
    present: [read_key_count]bool = .{false} ** read_key_count,
    /// What each getter answers, indexed by `ReadKey`.
    ints: [read_key_count]JInt = .{0} ** read_key_count,
    booleans: [read_key_count]bool = .{false} ** read_key_count,
    /// How many getter calls arrived, so a test can see that a read was skipped.
    reads: usize = 0,
    /// What `exceptionCheck` answers.
    exception_pending: bool = false,
    /// Whether `getMethodId` answers `null`, standing in for a `Bundle` whose
    /// member is absent on the device.
    method_missing: bool = false,
    /// Whether `findClass` answers `null`, standing in for a `Bundle` class that
    /// is not on the classpath at all.
    class_missing: bool = false,

    /// Marks `key` present.
    fn withPresent(self: *Recorder, key: ReadKey) void {
        self.present[@intFromEnum(key)] = true;
    }

    /// Sets the integer `key` answers and marks it present.
    fn withInt(self: *Recorder, key: ReadKey, value: JInt) void {
        self.ints[@intFromEnum(key)] = value;
        self.withPresent(key);
    }

    /// Sets the boolean `key` answers and marks it present.
    fn withBool(self: *Recorder, key: ReadKey, value: bool) void {
        self.booleans[@intFromEnum(key)] = value;
        self.withPresent(key);
    }
};

/// The recorder the table parks in its `env`, or `null` when there is none.
fn recorderOf(env: JniEnv) ?*Recorder {
    const handle = env orelse return null;
    // SAFETY: the table parks the recorder as `.env`, which is
    // `?*const anyopaque`, so the const belongs to the table and not to the
    // recorder, and the alignment is the one the recorder was declared with.
    return @alignCast(@constCast(@ptrCast(handle)));
}

fn answeredFindClass(env: JniEnv, _: [:0]const u8) JClass {
    const recorder = recorderOf(env) orelse return null;
    if (recorder.class_missing) return null;
    return @ptrFromInt(handle_base + 1);
}

fn answeredGetMethodId(
    env: JniEnv,
    class: JClass,
    name: [:0]const u8,
    signature: [:0]const u8,
) JMethodId {
    _ = signature;
    if (class == null) return null;
    const recorder = recorderOf(env) orelse return null;
    if (recorder.method_missing) return null;
    // The id encodes which row was resolved, so a call can be traced back to
    // its name without a second table.
    for (bundle_lookups, 0..) |lookup, index| {
        if (std.mem.eql(u8, lookup.name, name)) return @ptrFromInt(handle_base + 10 + index);
    }
    return null;
}

/// The row whose id `method` carries, or `bundle_lookup_count` for none.
fn lookupRowOf(method: JMethodId) usize {
    if (method == null) return bundle_lookup_count;
    const address = @intFromPtr(method.?);
    if (address < handle_base + 10) return bundle_lookup_count;
    const index = address - (handle_base + 10);
    if (index >= bundle_lookup_count) return bundle_lookup_count;
    return index;
}

fn answeredNewString(env: JniEnv, text: []const u8) JString {
    const recorder = recorderOf(env) orelse return @ptrFromInt(handle_base + 3);
    _ = recorder;
    // The walk is over the five `ReadKey` rows, so `read_key_count` is the
    // bound and the loop ends by exhausting it.
    for (std.enums.values(ReadKey)) |key| {
        if (std.mem.eql(u8, key.bundleKey(), text)) return key.handle();
    }
    return @ptrFromInt(handle_base + 3);
}

/// The one boolean slot, which serves `containsKey` and `getBoolean`.
///
/// A JNI table has a single `CallBooleanMethod` entry point and the two members
/// differ only in their method id, so the recorder reads the id to tell them
/// apart. A row the decoder never reaches answers `false`.
fn answeredBooleanCall(
    env: JniEnv,
    _: JObject,
    method: JMethodId,
    args: []const JValue,
) u8 {
    const recorder = recorderOf(env) orelse return 0;
    if (recorder.exception_pending) return 0;
    const key = readKeyOf(args[0].l) orelse return 0;
    switch (lookupRowOf(method)) {
        0 => return @intFromBool(recorder.present[@intFromEnum(key)]),
        2 => {
            recorder.reads += 1;
            return @intFromBool(recorder.booleans[@intFromEnum(key)]);
        },
        else => return 0,
    }
}

fn answeredGetInt(env: JniEnv, _: JObject, method: JMethodId, args: []const JValue) JInt {
    const recorder = recorderOf(env) orelse return 0;
    if (recorder.exception_pending) return 0;
    if (lookupRowOf(method) != 1) return 0;
    recorder.reads += 1;
    const key = readKeyOf(args[0].l) orelse return 0;
    return recorder.ints[@intFromEnum(key)];
}

fn answeredGetFloat(env: JniEnv, _: JObject, method: JMethodId, args: []const JValue) JFloat {
    const recorder = recorderOf(env) orelse return 0;
    if (recorder.exception_pending) return 0;
    if (lookupRowOf(method) != 3) return 0;
    recorder.reads += 1;
    const key = readKeyOf(args[0].l) orelse return 0;
    return @floatFromInt(recorder.ints[@intFromEnum(key)]);
}

fn answeredExceptionCheck(env: JniEnv) bool {
    const recorder = recorderOf(env) orelse return false;
    return recorder.exception_pending;
}

fn answeredDeleteLocalRef(env: JniEnv, _: JObject) void {
    _ = env;
}

fn answeredVoidCall(env: JniEnv, _: JObject, _: JMethodId, _: []const JValue) void {
    _ = env;
}

fn answeredNullObject(env: JniEnv, _: JObject, _: JMethodId, _: []const JValue) JObject {
    _ = env;
    return null;
}

fn answeredNullStatic(env: JniEnv, _: JClass, _: JMethodId, _: []const JValue) JObject {
    _ = env;
    return null;
}

fn answeredIntZero(env: JniEnv, _: JInt) JInt {
    _ = env;
    return 0;
}

fn answeredReferenceBack(env: JniEnv, value: JObject) JObject {
    _ = env;
    return value;
}

fn answeredIsInstanceOf(env: JniEnv, _: JObject, _: JClass) bool {
    _ = env;
    return false;
}

fn answeredRegister(env: JniEnv, _: JClass, _: []const jni.JNINativeMethod) JInt {
    _ = env;
    return 0;
}

/// The table that answers from `recorder`, with every other slot inert.
fn recordingTable(recorder: *Recorder) JniTable {
    var table = jni.inertTable(@ptrCast(recorder));
    table.findClassFn = answeredFindClass;
    table.getMethodIdFn = answeredGetMethodId;
    table.newStringFn = answeredNewString;
    table.callBooleanMethodFn = answeredBooleanCall;
    table.callIntMethodFn = answeredGetInt;
    table.callFloatMethodFn = answeredGetFloat;
    table.deleteLocalRefFn = answeredDeleteLocalRef;
    table.callVoidMethodFn = answeredVoidCall;
    table.callObjectMethodFn = answeredNullObject;
    table.callStaticObjectMethodFn = answeredNullStatic;
    table.deleteGlobalRefFn = answeredDeleteLocalRef;
    table.isInstanceOfFn = answeredIsInstanceOf;
    table.exceptionCheckFn = answeredExceptionCheck;
    table.pushLocalFrameFn = answeredIntZero;
    table.popLocalFrameFn = answeredReferenceBack;
    table.registerNativeMethodsFn = answeredRegister;
    return table;
}

test "an action with no arguments decodes to the simple form" {
    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);

    const decoded = try decode(table, values.ACTION_CLICK, null);
    try testing.expectEqual(@as(JInt, values.ACTION_CLICK), decoded.simple);
    try testing.expectEqual(@as(usize, 0), recorder.reads);
}

test "an action id this port does not name still decodes to the simple form" {
    // The id carries through untouched, so the interpreter in `adapter.zig` is
    // the one place that decides an action is unsupported. A decoder that
    // rejected it here would make every unlisted id a failure instead of a
    // request the application declines.
    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);

    const decoded = try decode(table, 0x4242, fakeBundle());
    try testing.expectEqual(@as(JInt, 0x4242), decoded.simple);
    try testing.expectEqual(@as(usize, 0), recorder.reads);
}

test "a selection with both endpoints decodes to the endpoints" {
    var recorder: Recorder = .{};
    recorder.withInt(.selection_start, 3);
    recorder.withInt(.selection_end, 7);
    const table = recordingTable(&recorder);

    const decoded = try decode(table, values.ACTION_SET_SELECTION, fakeBundle());
    try testing.expectEqual(@as(JInt, 3), decoded.set_text_selection.start);
    try testing.expectEqual(@as(JInt, 7), decoded.set_text_selection.end);
}

test "a selection that runs backwards keeps its order" {
    var recorder: Recorder = .{};
    recorder.withInt(.selection_start, 9);
    recorder.withInt(.selection_end, 2);
    const table = recordingTable(&recorder);

    const decoded = try decode(table, values.ACTION_SET_SELECTION, fakeBundle());
    try testing.expectEqual(@as(JInt, 9), decoded.set_text_selection.start);
    try testing.expectEqual(@as(JInt, 2), decoded.set_text_selection.end);
}

test "a selection with no endpoints decodes to a collapse and reads nothing" {
    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);

    const decoded = try decode(table, values.ACTION_SET_SELECTION, fakeBundle());
    try testing.expectEqual(PlatformAction.collapse_text_selection, decoded);
    try testing.expectEqual(@as(usize, 0), recorder.reads);
}

test "a selection with only a start decodes to a collapse, not a zero end" {
    // `Bundle.getInt` answers zero for an absent key and zero is a legal caret
    // position, so a decoder that read both keys unconditionally would report
    // `start` to `0` and the caret would jump to the beginning of the document.
    var recorder: Recorder = .{};
    recorder.withInt(.selection_start, 5);
    const table = recordingTable(&recorder);

    const decoded = try decode(table, values.ACTION_SET_SELECTION, fakeBundle());
    try testing.expectEqual(PlatformAction.collapse_text_selection, decoded);
    try testing.expectEqual(@as(usize, 0), recorder.reads);
}

test "a selection with only an end decodes to a collapse, not a zero start" {
    var recorder: Recorder = .{};
    recorder.withInt(.selection_end, 11);
    const table = recordingTable(&recorder);

    const decoded = try decode(table, values.ACTION_SET_SELECTION, fakeBundle());
    try testing.expectEqual(PlatformAction.collapse_text_selection, decoded);
}

test "the next-granularity action decodes to a forward traversal" {
    var recorder: Recorder = .{};
    recorder.withInt(.granularity, values.MOVEMENT_GRANULARITY_WORD);
    recorder.withBool(.extend, true);
    const table = recordingTable(&recorder);

    const decoded = try decode(
        table,
        values.ACTION_NEXT_AT_MOVEMENT_GRANULARITY,
        fakeBundle(),
    );
    try testing.expectEqual(
        values.MOVEMENT_GRANULARITY_WORD,
        decoded.traverse_text.granularity,
    );
    try testing.expectEqual(@as(JInt, 1), decoded.traverse_text.direction);
    try testing.expect(decoded.traverse_text.extend);
}

test "the previous-granularity action decodes to a backward traversal" {
    var recorder: Recorder = .{};
    recorder.withInt(.granularity, values.MOVEMENT_GRANULARITY_LINE);
    const table = recordingTable(&recorder);

    const decoded = try decode(
        table,
        values.ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY,
        fakeBundle(),
    );
    try testing.expectEqual(
        values.MOVEMENT_GRANULARITY_LINE,
        decoded.traverse_text.granularity,
    );
    try testing.expectEqual(@as(JInt, -1), decoded.traverse_text.direction);
    try testing.expect(!decoded.traverse_text.extend);
}

test "an extend flag the caller left out reads as no extension" {
    var recorder: Recorder = .{};
    recorder.withInt(.granularity, values.MOVEMENT_GRANULARITY_CHARACTER);
    const table = recordingTable(&recorder);

    const decoded = try decode(
        table,
        values.ACTION_NEXT_AT_MOVEMENT_GRANULARITY,
        fakeBundle(),
    );
    try testing.expect(!decoded.traverse_text.extend);
}

test "the set-progress action decodes to the progress value" {
    var recorder: Recorder = .{};
    recorder.withInt(.progress, 42);
    const table = recordingTable(&recorder);

    const decoded = try decode(table, values.ACTION_SET_PROGRESS, fakeBundle());
    try testing.expectEqual(@as(JFloat, 42), decoded.set_progress);
}

test "a pending Java exception stops the decode and is reported" {
    var recorder: Recorder = .{ .exception_pending = true };
    const table = recordingTable(&recorder);

    try testing.expectError(
        error.JavaException,
        decode(table, values.ACTION_SET_SELECTION, fakeBundle()),
    );
}

test "a bundle member the device does not carry stops the decode" {
    // This is the `NoSuchMethodError` shape: `GetMethodID` answers `null` and
    // leaves one pending. The port reports it and does not clear it, which is
    // what `docs/29` section 3.3 records upstream doing at each site.
    var recorder: Recorder = .{ .method_missing = true };
    const table = recordingTable(&recorder);

    try testing.expectError(
        error.JavaMemberMissing,
        decode(table, values.ACTION_SET_SELECTION, fakeBundle()),
    );
}

test "a bundle class the device does not carry stops the decode before any read" {
    var recorder: Recorder = .{ .class_missing = true };
    const table = recordingTable(&recorder);

    try testing.expectError(
        error.JavaMemberMissing,
        decode(table, values.ACTION_SET_SELECTION, fakeBundle()),
    );
    try testing.expectEqual(@as(usize, 0), recorder.reads);
}

test "every Bundle descriptor is the one Android declares" {
    // The expected rows are literals in this test on purpose: reading them out
    // of `bundle_lookups` would compare the table with itself. The walk is over
    // the four rows, so `bundle_lookup_count` is the bound.
    const expected = [_][2][]const u8{
        .{ "containsKey", "(Ljava/lang/String;)Z" },
        .{ "getInt", "(Ljava/lang/String;)I" },
        .{ "getBoolean", "(Ljava/lang/String;)Z" },
        .{ "getFloat", "(Ljava/lang/String;)F" },
    };
    try testing.expectEqual(expected.len, bundle_lookups.len);
    for (bundle_lookups, expected) |lookup, row| {
        try testing.expectEqualStrings(row[0], lookup.name);
        try testing.expectEqualStrings(row[1], lookup.signature);
    }
}

test "every Bundle member name is one of the 68 Java method names" {
    const methods = @import("methods.zig");
    // The walk is over the four rows, so `bundle_lookup_count` is the bound.
    var checked: usize = 0;
    for (bundle_lookups) |lookup| {
        try testing.expect(methods.hasName(lookup.name));
        checked += 1;
    }
    try testing.expectEqual(@as(usize, 4), checked);
}

test "the bundle class is the descriptor classes.zig names" {
    try testing.expect(classes.find(bundle_class) != null);
    // `FindClass` takes the internal name, which is the descriptor with the `L`
    // and the `;` removed and each package separator written as `/`.
    try testing.expectEqualStrings("android/os/Bundle", bundle_internal_name);
}

test "every ReadKey names the bundle key Android puts in the bundle" {
    // The walk is over the five rows, so `read_key_count` is the bound.
    for (std.enums.values(ReadKey)) |key| {
        try testing.expectEqual(key.bundleKey(), readKeyHandleKey(key));
    }
    try testing.expectEqual(@as(usize, 5), read_key_count);
}

/// The key `key.handle()` resolves back to, which must be `key` itself.
///
/// Round-tripping the fabricated handle is what proves the two agree; a decoder
/// that asked for the wrong key would read the wrong row and this would not
/// notice.
fn readKeyHandleKey(key: ReadKey) [:0]const u8 {
    const found = readKeyOf(key.handle()) orelse return "";
    return found.bundleKey();
}

test "fromJava over an unattached environment answers the simple form" {
    // A `null` environment is a thread the VM has not attached, and every slot
    // of the real table answers the JNI default there. The decode reads no
    // argument, so the whole action survives.
    allocation.clearError();
    const handle = fromJava(null, values.ACTION_FOCUS, null) orelse
        return error.NoHandleBuilt;
    defer free(handle);
    try testing.expectEqual(@as(JInt, values.ACTION_FOCUS), handle.decoded().simple);
    try testing.expectEqual(allocation.Tag.none, allocation.lastError());
}

test "fromJava over an unattached environment reports a lookup failure as no error" {
    // With a bundle but no environment, `BundleReader.resolve` cannot resolve a
    // class. The header promises `null` for a failed allocation only, so the
    // error slot must stay clear: reporting `ACCESSKIT_ERROR_OUT_OF_MEMORY` here
    // would tell a C caller to retry an allocation that never happened.
    allocation.clearError();
    const handle = fromJava(null, values.ACTION_SET_SELECTION, fakeBundle());
    try testing.expect(handle == null);
    try testing.expectEqual(allocation.Tag.none, allocation.lastError());
}