//! The checked JNI lookups and calls the three adapter-body modules share.
//!
//! **Why this file exists.** Reaching a Java member is four steps and three of
//! them can fail: `FindClass`, `GetMethodID`, the call itself and an
//! `ExceptionCheck`. Each failure has a distinct meaning — the class is absent,
//! the member is absent, or the call threw — and a caller that collapses them
//! cannot answer a C consumer honestly. `queued_events.zig`, `adapter.zig` and
//! `injecting.zig` all need the same four steps, so the steps live here once.
//!
//! **Why a failure is an error and not a `null`.** `jni_table.zig` answers the
//! JNI default for every slot, because a binding that turned a missing class into
//! a Zig error would replace a fault inside the VM with a path a C caller cannot
//! act on. This file is the layer above that: it is the place where "the class
//! is not on the classpath" becomes a named error the adapter can record, report
//! and recover from. `node.zig` has the same policy in its own private helpers,
//! keyed to its own `lookups` table, and the two sets agree tag for tag.
//!
//! **The `NoSuchMethodError` answer.** Upstream's own example declares
//! `minSdk = 30`, and a method added after that API level fails `GetMethodID`
//! with `null` and leaves `NoSuchMethodError` pending. The rule this file
//! enforces is the one `docs/29` section 3.3 records upstream using: report the
//! lookup failure, **do not clear the exception**. The caller then stops making
//! calls on that thread and answers `null`, which is what the header promises
//! for a failed fill, and the device sees a node with that one property absent
//! rather than a crashed process.
//!
//! **The allocator.** Nothing here allocates, so nothing here takes one. Every
//! value it returns is a local reference the caller releases.
//!
//! **The loop bound.** No walk over a domain. `resolve` and `releaseAll` walk
//! fixed-size arrays whose lengths are `member_count` and the caller's own.

const std = @import("std");

const jni = @import("jni_table.zig");
const values = @import("values.zig");

const JClass = jni.JClass;
const JFieldId = jni.JFieldId;
const JFloat = jni.JFloat;
const JInt = values.JInt;
const JMethodId = jni.JMethodId;
const JObject = jni.JObject;
const JString = jni.JString;
const JValue = jni.JValue;
const JniTable = jni.JniTable;

const Allocator = std.mem.Allocator;

const testing = std.testing;

/// Every failure a checked JNI call can report.
///
/// The first tag comes from `std.mem.Allocator` for the two calls that build an
/// object. The other two are the failure modes above: a lookup that answered
/// `null` and a call that threw.
pub const CallError = Allocator.Error || error{
    /// A JNI call left an exception pending on the calling thread. **Nothing
    /// here clears one**, so the exception is still pending and every later JNI
    /// call on that thread fails until the caller clears it.
    JavaException,
    /// A `FindClass` or a `GetMethodID` answered `null` with no exception
    /// pending, so the class or the member is not on the classpath.
    JavaMemberMissing,
};

/// One Java class, as the two spellings the JNI takes.
///
/// `descriptor` is the form `GetMethodID` rows and `methods.zig` use, and
/// `internal_name` is the form `FindClass` takes: the same string with the `L`
/// and the `;` removed and each `.` written as `/`. Both are asserted against
/// each other by a test, because `FindClass` compares one at run time on a
/// device.
pub const Class = struct {
    /// `L` + the binary name with `/` for each package separator + `;`.
    descriptor: [:0]const u8,
    /// The same name with the `L` and the `;` removed.
    internal_name: [:0]const u8,
};

/// One Java member lookup, as the three strings `GetMethodID` takes.
pub const Member = struct {
    /// The class the member is on.
    class: Class,
    /// The method name.
    name: [:0]const u8,
    /// The JNI descriptor.
    signature: [:0]const u8,
};

/// The class `class` names, or the failure the lookup produced.
///
/// The answer is a local reference and the caller releases it with
/// `deleteLocalRef` before the end of the frame.
/// A pending exception prevents lookup. A failed acquisition releases its result.
pub fn findClassChecked(table: JniTable, class: Class) CallError!JClass {
    if (table.exceptionCheck()) return error.JavaException;
    const found = table.findClass(class.internal_name);
    errdefer if (found != null) table.deleteLocalRef(found);
    if (table.exceptionCheck()) return error.JavaException;
    if (found == null) return error.JavaMemberMissing;
    return found;
}

/// The id of `member`, or the failure the lookup produced.
///
/// The class reference is released before the id is answered. That is safe: a
/// `jmethodID` stays valid while the class it came from is loaded, and releasing
/// a local reference does not unload the class.
pub fn methodIdChecked(table: JniTable, member: Member) CallError!JMethodId {
    const class = try findClassChecked(table, member.class);
    defer table.deleteLocalRef(class);
    const method = table.getMethodId(class, member.name, member.signature);
    if (table.exceptionCheck()) return error.JavaException;
    if (method == null) return error.JavaMemberMissing;
    return method;
}

/// Calls `member` on `object` and discards its `void` result.
///
/// `object` belongs to the caller and is not released here. A call that throws
/// reports `error.JavaException` without reading what the call would have
/// produced.
pub fn callVoidChecked(
    table: JniTable,
    object: JObject,
    member: Member,
    args: []const JValue,
) CallError!void {
    if (object == null) return error.JavaMemberMissing;
    const method = try methodIdChecked(table, member);
    table.callVoidMethod(object, method, args);
    if (table.exceptionCheck()) return error.JavaException;
}

/// Calls `member` on `object` and answers its reference.
///
/// The answer is a local reference and the caller releases it.
/// A failed call releases any result reference before it reports the exception.
pub fn callObjectChecked(
    table: JniTable,
    object: JObject,
    member: Member,
    args: []const JValue,
) CallError!JObject {
    if (object == null) return error.JavaMemberMissing;
    const method = try methodIdChecked(table, member);
    const answer = table.callObjectMethod(object, method, args);
    errdefer if (answer != null) table.deleteLocalRef(answer);
    if (table.exceptionCheck()) return error.JavaException;
    if (answer == null) return error.JavaMemberMissing;
    return answer;
}

/// Calls the static `member` on its own class and answers its reference.
///
/// The caller releases the answer. This helper releases its class and any failed result.
/// The class is resolved once here rather than through `methodIdChecked`, which
/// would resolve it a second time: a static call needs the class both for the
/// id and for the call itself, so one lookup serves both.
pub fn callStaticObjectChecked(
    table: JniTable,
    member: Member,
    args: []const JValue,
) CallError!JObject {
    const class = try findClassChecked(table, member.class);
    defer table.deleteLocalRef(class);
    const method = table.getStaticMethodId(class, member.name, member.signature);
    if (table.exceptionCheck()) return error.JavaException;
    if (method == null) return error.JavaMemberMissing;
    const answer = table.callStaticObjectMethod(class, method, args);
    errdefer if (answer != null) table.deleteLocalRef(answer);
    if (table.exceptionCheck()) return error.JavaException;
    if (answer == null) return error.JavaMemberMissing;
    return answer;
}

/// Calls `member` on `object` and answers its `jint`.
pub fn callIntChecked(
    table: JniTable,
    object: JObject,
    member: Member,
    args: []const JValue,
) CallError!JInt {
    if (object == null) return error.JavaMemberMissing;
    const method = try methodIdChecked(table, member);
    const answer = table.callIntMethod(object, method, args);
    if (table.exceptionCheck()) return error.JavaException;
    return answer;
}

/// Calls `member` on `object` and answers its `jboolean`, where `0` is
/// `JNI_FALSE`.
pub fn callBooleanChecked(
    table: JniTable,
    object: JObject,
    member: Member,
    args: []const JValue,
) CallError!bool {
    if (object == null) return error.JavaMemberMissing;
    const method = try methodIdChecked(table, member);
    const answer = table.callBooleanMethod(object, method, args);
    if (table.exceptionCheck()) return error.JavaException;
    return answer != 0;
}

/// Calls `member` on `object` and answers its `jfloat`.
pub fn callFloatChecked(
    table: JniTable,
    object: JObject,
    member: Member,
    args: []const JValue,
) CallError!JFloat {
    if (object == null) return error.JavaMemberMissing;
    const method = try methodIdChecked(table, member);
    const answer = table.callFloatMethod(object, method, args);
    if (table.exceptionCheck()) return error.JavaException;
    return answer;
}

/// Reads the static field `member`, whose value is a reference.
///
/// Both the class and the answer are local references and the caller releases
/// both. The adapter reads one static field, `ACTION_SET_PROGRESS`, and
/// `node.zig` reads it too.
pub fn staticObjectFieldChecked(
    table: JniTable,
    member: Member,
) CallError!JObject {
    const class = try findClassChecked(table, member.class);
    defer table.deleteLocalRef(class);
    const field = table.getStaticFieldId(class, member.name, member.signature);
    if (table.exceptionCheck()) return error.JavaException;
    if (field == null) return error.JavaMemberMissing;
    return table.getStaticObjectField(class, field);
}

/// A Java string holding `text`, or the failure the construction produced.
///
/// The answer is a local reference and the caller releases it. `text` is encoded
/// as UTF-16, which is what a `jstring` holds.
pub fn newStringChecked(table: JniTable, text: []const u8) CallError!JString {
    const answer = table.newString(text);
    if (table.exceptionCheck()) return error.JavaException;
    if (answer == null) return error.JavaMemberMissing;
    return answer;
}

/// The object `member` builds on its own class from `args`.
///
/// The class and the answer are local references and the caller releases both.
/// As with `callStaticObjectChecked`, the class is resolved once because a
/// constructor needs it for both the id and the construction.
pub fn newObjectChecked(
    table: JniTable,
    member: Member,
    args: []const JValue,
) CallError!JObject {
    const class = try findClassChecked(table, member.class);
    defer table.deleteLocalRef(class);
    const constructor = table.getMethodId(class, member.name, member.signature);
    if (table.exceptionCheck()) return error.JavaException;
    if (constructor == null) return error.JavaMemberMissing;
    const answer = table.newObject(class, constructor, args);
    if (table.exceptionCheck()) return error.JavaException;
    if (answer == null) return error.JavaMemberMissing;
    return answer;
}

/// A zero-filled Java `int[]` of `len` elements, or the failure.
///
/// The answer is a local reference and the caller releases it.
pub fn newIntArrayChecked(table: JniTable, len: usize) CallError!JObject {
    const answer = table.newIntArray(len);
    if (table.exceptionCheck()) return error.JavaException;
    if (answer == null) return error.JavaMemberMissing;
    return answer;
}

// --- Tests --------------------------------------------------------------------

/// The first fabricated handle, so a fabricated handle is never the JNI null.
const handle_base = 0x3000;

/// One Java class, in both spellings.
const view_class: Class = .{
    .descriptor = "Landroid/view/View;",
    .internal_name = "android/view/View",
};

/// One member of it, with a descriptor no document records.
const test_member: Member = .{
    .class = view_class,
    .name = "setAccessibilityFocused",
    .signature = "(Z)V",
};

/// What one table answered, kept where a test reads it.
const Recorder = struct {
    /// What `findClass` answers.
    class_missing: bool = false,
    /// What `getMethodId` answers.
    method_missing: bool = false,
    /// What `callObjectMethod` answers.
    object_answer: JObject = @ptrFromInt(handle_base + 1),
    /// What `callVoidMethod`, `callIntMethod`, `callFloatMethod` and
    /// `callBooleanMethod` answer.
    int_answer: JInt = 7,
    float_answer: JFloat = 1.5,
    bool_answer: bool = true,
    /// What `newObject` and `newString` answer.
    built_answer: JObject = @ptrFromInt(handle_base + 2),
    /// How many times each slot was reached, so a test can see a skipped step.
    find_class_calls: usize = 0,
    void_calls: usize = 0,
    /// What `exceptionCheck` answers.
    exception_pending: bool = false,
    /// Whether an object call leaves an exception beside its nonnull result.
    throw_object: bool = false,
    throw_class: bool = false,
    released_class: usize = 0,
    released_object: usize = 0,
    /// How many local references were released.
    released: usize = 0,
};

fn recorderOf(env: jni.JniEnv) ?*Recorder {
    const handle = env orelse return null;
    // SAFETY: the table parks the recorder as `.env`, which is
    // `?*const anyopaque`, so the const belongs to the table and not to the
    // recorder, and the alignment is the one the recorder was declared with.
    return @ptrCast(@alignCast(@constCast(handle)));
}

fn answeredFindClass(env: jni.JniEnv, _: [:0]const u8) JClass {
    const recorder = recorderOf(env) orelse return null;
    recorder.find_class_calls += 1;
    if (recorder.class_missing) return null;
    if (recorder.throw_class) recorder.exception_pending = true;
    return @ptrFromInt(handle_base + 3);
}

fn answeredGetMethodId(
    env: jni.JniEnv,
    _: JClass,
    _: [:0]const u8,
    _: [:0]const u8,
) JMethodId {
    const recorder = recorderOf(env) orelse return null;
    if (recorder.method_missing) return null;
    return @ptrFromInt(handle_base + 4);
}

fn answeredStaticMethodId(
    env: jni.JniEnv,
    _: JClass,
    _: [:0]const u8,
    _: [:0]const u8,
) JMethodId {
    return answeredGetMethodId(env, null, "", "");
}

fn answeredStaticFieldId(
    env: jni.JniEnv,
    _: JClass,
    _: [:0]const u8,
    _: [:0]const u8,
) JFieldId {
    return answeredGetMethodId(env, null, "", "");
}

fn answeredStaticObjectField(env: jni.JniEnv, _: JClass, _: JFieldId) JObject {
    const recorder = recorderOf(env) orelse return null;
    return recorder.built_answer;
}

fn answeredCallObject(
    env: jni.JniEnv,
    _: JObject,
    _: JMethodId,
    _: []const JValue,
) JObject {
    const recorder = recorderOf(env) orelse return null;
    if (recorder.throw_object) recorder.exception_pending = true;
    return recorder.object_answer;
}

fn answeredCallStaticObject(
    env: jni.JniEnv,
    _: JClass,
    _: JMethodId,
    _: []const JValue,
) JObject {
    return answeredCallObject(env, null, null, &.{});
}

fn answeredCallVoid(
    env: jni.JniEnv,
    _: JObject,
    _: JMethodId,
    _: []const JValue,
) void {
    const recorder = recorderOf(env) orelse return;
    recorder.void_calls += 1;
}

fn answeredCallInt(env: jni.JniEnv, _: JObject, _: JMethodId, _: []const JValue) JInt {
    const recorder = recorderOf(env) orelse return 0;
    return recorder.int_answer;
}

fn answeredCallFloat(env: jni.JniEnv, _: JObject, _: JMethodId, _: []const JValue) JFloat {
    const recorder = recorderOf(env) orelse return 0;
    return recorder.float_answer;
}

fn answeredCallBoolean(
    env: jni.JniEnv,
    _: JObject,
    _: JMethodId,
    _: []const JValue,
) u8 {
    const recorder = recorderOf(env) orelse return 0;
    return @intFromBool(recorder.bool_answer);
}

fn answeredNewString(env: jni.JniEnv, _: []const u8) JString {
    const recorder = recorderOf(env) orelse return null;
    return recorder.built_answer;
}

fn answeredNewObject(
    env: jni.JniEnv,
    _: JClass,
    _: JMethodId,
    _: []const JValue,
) JObject {
    const recorder = recorderOf(env) orelse return null;
    return recorder.built_answer;
}

fn answeredNewIntArray(env: jni.JniEnv, _: usize) JObject {
    const recorder = recorderOf(env) orelse return null;
    return recorder.built_answer;
}

fn answeredDeleteLocalRef(env: jni.JniEnv, object: JObject) void {
    const recorder = recorderOf(env) orelse return;
    recorder.released += 1;
    if (object == @as(JObject, @ptrFromInt(handle_base + 3))) recorder.released_class += 1;
    if (object == recorder.object_answer) recorder.released_object += 1;
}

fn answeredExceptionCheck(env: jni.JniEnv) bool {
    const recorder = recorderOf(env) orelse return false;
    return recorder.exception_pending;
}

fn answeredBoolFalse(env: jni.JniEnv, _: JObject, _: JClass) bool {
    _ = env;
    return false;
}

fn answeredIntZero(env: jni.JniEnv, _: JInt) JInt {
    _ = env;
    return 0;
}

fn answeredReferenceBack(env: jni.JniEnv, answer: JObject) JObject {
    _ = env;
    return answer;
}

fn answeredRegister(env: jni.JniEnv, _: JClass, _: []const jni.JNINativeMethod) JInt {
    _ = env;
    return 0;
}

/// The table that answers from `recorder`, with every other slot inert.
fn recordingTable(recorder: *Recorder) JniTable {
    var table = jni.inertTable(@ptrCast(recorder));
    table.findClassFn = answeredFindClass;
    table.getMethodIdFn = answeredGetMethodId;
    table.getStaticMethodIdFn = answeredStaticMethodId;
    table.getStaticFieldIdFn = answeredStaticFieldId;
    table.getStaticObjectFieldFn = answeredStaticObjectField;
    table.callObjectMethodFn = answeredCallObject;
    table.callStaticObjectMethodFn = answeredCallStaticObject;
    table.callVoidMethodFn = answeredCallVoid;
    table.callIntMethodFn = answeredCallInt;
    table.callFloatMethodFn = answeredCallFloat;
    table.callBooleanMethodFn = answeredCallBoolean;
    table.newStringFn = answeredNewString;
    table.newObjectFn = answeredNewObject;
    table.newIntArrayFn = answeredNewIntArray;
    table.deleteLocalRefFn = answeredDeleteLocalRef;
    table.isInstanceOfFn = answeredBoolFalse;
    table.exceptionCheckFn = answeredExceptionCheck;
    table.pushLocalFrameFn = answeredIntZero;
    table.popLocalFrameFn = answeredReferenceBack;
    table.registerNativeMethodsFn = answeredRegister;
    return table;
}

/// A fabricated object no helper ever dereferences.
fn fakeObject() JObject {
    return @ptrFromInt(handle_base + 5);
}

test "a class the device carries is resolved and the class reference is released" {
    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);

    const class = try findClassChecked(table, view_class);
    try testing.expect(class != null);
    try testing.expectEqual(@as(usize, 1), recorder.find_class_calls);
}

test "a class the device does not carry is reported and nothing is released" {
    var recorder: Recorder = .{ .class_missing = true };
    const table = recordingTable(&recorder);

    try testing.expectError(error.JavaMemberMissing, findClassChecked(table, view_class));
}

test "a member id is resolved with one class lookup and one release" {
    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);

    const method = try methodIdChecked(table, test_member);
    try testing.expect(method != null);
    try testing.expectEqual(@as(usize, 1), recorder.find_class_calls);
    // The class reference is gone before the id is answered, which is what keeps
    // a long call inside one local frame.
    try testing.expectEqual(@as(usize, 1), recorder.released);
}

test "a member the device does not carry is the NoSuchMethodError shape" {
    var recorder: Recorder = .{ .method_missing = true };
    const table = recordingTable(&recorder);

    try testing.expectError(error.JavaMemberMissing, methodIdChecked(table, test_member));
}

test "a pending exception stops the lookup before the member is read" {
    var recorder: Recorder = .{ .exception_pending = true };
    const table = recordingTable(&recorder);

    try testing.expectError(error.JavaException, methodIdChecked(table, test_member));
}

test "a void call reaches the slot and discards its result" {
    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);

    try callVoidChecked(table, fakeObject(), test_member, &.{});
    try testing.expectEqual(@as(usize, 1), recorder.void_calls);
}

test "a null object is refused before any lookup is made" {
    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);

    try testing.expectError(
        error.JavaMemberMissing,
        callVoidChecked(table, null, test_member, &.{}),
    );
    try testing.expectEqual(@as(usize, 0), recorder.find_class_calls);
}

test "a reference call answers the recorder's object" {
    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);

    const answer = try callObjectChecked(table, fakeObject(), test_member, &.{});
    try testing.expectEqual(@as(?*anyopaque, recorder.object_answer), answer);
}

test "a reference call that answers null is reported, not returned" {
    // A method that legitimately returns `null` would be indistinguishable from
    // a failed one, so the helper reports it and the caller answers `null` to
    // the platform itself. That is the shape the header promises for
    // `create_accessibility_node_info`.
    var recorder: Recorder = .{ .object_answer = null };
    const table = recordingTable(&recorder);

    try testing.expectError(
        error.JavaMemberMissing,
        callObjectChecked(table, fakeObject(), test_member, &.{}),
    );
}

test "the scalar calls answer the recorder's own values" {
    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);

    try testing.expectEqual(
        @as(JInt, 7),
        try callIntChecked(table, fakeObject(), test_member, &.{}),
    );
    try testing.expectEqual(
        @as(JFloat, 1.5),
        try callFloatChecked(table, fakeObject(), test_member, &.{}),
    );
    try testing.expect(try callBooleanChecked(table, fakeObject(), test_member, &.{}));
}

test "a static call resolves its own class and answers its reference" {
    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);

    const answer = try callStaticObjectChecked(table, test_member, &.{});
    try testing.expectEqual(@as(?*anyopaque, recorder.object_answer), answer);
    try testing.expectEqual(@as(usize, 1), recorder.released);
}

test "a static field read answers the recorder's object" {
    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);

    const answer = try staticObjectFieldChecked(table, test_member);
    try testing.expectEqual(@as(?*anyopaque, recorder.built_answer), answer);
}

test "the building calls answer the recorder's object" {
    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);

    try testing.expectEqual(
        @as(?*anyopaque, recorder.built_answer),
        try newStringChecked(table, "package"),
    );
    try testing.expectEqual(
        @as(?*anyopaque, recorder.built_answer),
        try newObjectChecked(table, test_member, &.{}),
    );
    try testing.expectEqual(
        @as(?*anyopaque, recorder.built_answer),
        try newIntArrayChecked(table, 2),
    );
}

test "a builder that answers null is reported rather than handed on" {
    var recorder: Recorder = .{ .built_answer = null };
    const table = recordingTable(&recorder);

    try testing.expectError(error.JavaMemberMissing, newStringChecked(table, "package"));
    try testing.expectError(error.JavaMemberMissing, newObjectChecked(table, test_member, &.{}));
    try testing.expectError(error.JavaMemberMissing, newIntArrayChecked(table, 2));
}

test "every Class spells its two names the way the JNI takes them" {
    const classes = @import("classes.zig");
    try testing.expect(classes.find(view_class.descriptor) != null);
    // `FindClass` takes the internal name, which is the descriptor with the `L`
    // and the `;` removed and each package separator written as `/`.
    try testing.expectEqualStrings("android/view/View", view_class.internal_name);
}

test "every failure the helpers report is named" {
    // The walk is over the three members of `CallError`, so the error set's own
    // field count is the bound.
    const errors = @typeInfo(CallError).error_set.?;
    try testing.expectEqual(@as(usize, 3), errors.len);
    try testing.expectEqualStrings("OutOfMemory", errors[0].name);
    try testing.expectEqualStrings("JavaException", errors[1].name);
    try testing.expectEqualStrings("JavaMemberMissing", errors[2].name);
}

test "checked class acquisition releases a nonnull result beside an exception" {
    var recorder: Recorder = .{ .throw_class = true };
    try testing.expectError(error.JavaException,
        findClassChecked(recordingTable(&recorder), view_class));
    try testing.expectEqual(@as(usize, 1), recorder.released);
    try testing.expectEqual(@as(usize, 1), recorder.released_class);
}

test "checked instance acquisition releases a nonnull result beside an exception" {
    var recorder: Recorder = .{ .throw_object = true };
    try testing.expectError(error.JavaException,
        callObjectChecked(recordingTable(&recorder), fakeObject(), test_member, &.{}));
    try testing.expectEqual(@as(usize, 2), recorder.released);
    try testing.expectEqual(@as(usize, 1), recorder.released_class);
    try testing.expectEqual(@as(usize, 1), recorder.released_object);
}

test "checked static acquisition releases a nonnull result beside an exception" {
    var recorder: Recorder = .{ .throw_object = true };
    try testing.expectError(error.JavaException,
        callStaticObjectChecked(recordingTable(&recorder), test_member, &.{}));
    try testing.expectEqual(@as(usize, 2), recorder.released);
    try testing.expectEqual(@as(usize, 1), recorder.released_class);
    try testing.expectEqual(@as(usize, 1), recorder.released_object);
}
