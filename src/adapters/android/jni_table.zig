//! The JNI boundary, as a struct of function pointers the adapter calls
//! through, plus the binding that resolves it from a real `JNIEnv`.
//!
//! **What this module is.** The Java boundary is a C function table rather than
//! a set of linked symbols. `JNIEnv` is `const struct JNINativeInterface_ *`,
//! so one `JNIEnv *` points at a table of 229 function pointers in a fixed
//! order, and every JNI call loads one slot and calls through it.
//! `JniTable` is that table behind a typed struct: one function-pointer field
//! per entry point the adapter reaches, and one method per field that supplies
//! the environment. Everything above this module in the directory is ordinary
//! Zig that happens to talk to Java.
//!
//! **Why the table is an injectable value and not a global.**
//! `AGENTS.md` section 3 requires state to be a parameter, and
//! `docs/30-port-design.md` Record R3 requires the adapter to be constructible
//! twice in one process. So `JniTable` travels as an argument and every call
//! site receives one. A test fills the fields with recording functions and
//! drives the **real** adapter body through the **real** call sequence with no
//! JVM present, which is the only way anything above this seam is testable on
//! a host with no Android. `JniTable.real` builds the binding that reaches an
//! actual VM.
//!
//! **Where the slot numbers come from, and what is unverified.** The slots were
//! read in order from `struct JNINativeInterface_` in a JDK 7 `jni.h` on this
//! host, at
//! `/vol/tmp/spectra/spectra-2020/jdk1.7.0_79/include/jni.h:214-768`. That
//! struct declares `reserved0` through `reserved3` first, so a name at
//! position `n` of the declaration sits at slot `n + 4`.
//! `docs/42-native-adapter-build-map.md` section 2.4 records that the header the
//! port needs is the **NDK** header, that no NDK is installed on this host, and
//! that a JDK 7 header is what the earlier `translate-c` probe read.
//! **Unverified against the NDK header.** The JNI table is append-only and the
//! slots this module names all sit inside the first 216, which every
//! implementation must keep, but this host cannot show that the NDK header
//! orders them the same way. `zig translate-c` over the NDK header at
//! milestone M10 supersedes this file rather than supplementing it, and a test
//! here pins every slot number so the two can be diffed.
//!
//! **The call convention.** `JNICALL` is empty in `jni_md.h` on Linux, so every
//! slot is `callconv(.c)`. On 32-bit Windows `JNICALL` is `__stdcall` and the
//! five registered native thunks must be `callconv(.winapi)`; `docs/29`
//! section 4 records that exception and `injecting.zig` notes it where the
//! thunks live.
//!
//! **What this module deliberately does not do.** It does not raise, clear or
//! describe a pending Java exception. `exceptionCheck` reports that one is
//! pending and the caller decides, because `docs/29` section 3.3 records that
//! upstream unwraps the JNI error at each site, so a port that cleared the
//! exception and carried on would change what a failed lookup does to the
//! process. It also declares no `JNIInvokeInterface_` table, which is the
//! second table `JavaVM` reaches; `injecting.zig` records where that leaves the
//! thread handoff.
//!
//! **The environment is a `*const` pointer, and Zig 0.16.0 miscompiles it.**
//! `jni.h` spells `JNIEnv *` as a pointer to a *const* function table, and this
//! type is deliberately **not** `?*const anyopaque`.
//!
//! **Zig 0.16.0 miscompiles it.** The compiler emits the LLVM parameter
//! attribute `readonly` on a `*const T` parameter and then, in the body of that
//! same function, emits a store through that parameter. LLVM reads `readonly`
//! as the callee's promise never to write through the pointer, so the store is
//! undefined behaviour and the optimiser deletes it. Once the call is
//! devirtualised and inlined, the call goes too and the caller's load forwards
//! from the store that preceded it.
//!
//! It is not hypothetical: `overriding one field of the inert table leaves the
//! rest inert` expects 1 in Debug and observes 0 in ReleaseSafe, and the
//! optimiser reduces the whole test body to two instructions that print the
//! constant the test wrote itself. A twenty-line file with no adapter in it
//! reproduces it. `?*anyopaque` emits no `readonly` and passes in every mode.
//!
//! A substituted field therefore recovers a *mutable* context from `.env` with
//! `@constCast` and writes through it, which is what `withRecorder` and
//! `TestRecorder` below do.
//!
//! **The loop bound.** `jni_slot_names` holds `jni_named_slot_count` rows and
//! `slotOf` walks it once at comptime, so the bound is `jni_named_slot_count`.

const std = @import("std");

const testing = std.testing;

// --- the C types, from `jni.h` and the `jni_md.h` beside it ---------------
// Each is the spelling `jni.h` uses, with the width `jni_md.h` gives on this
// target. `docs/29` row 8 records the same four scalars and `docs/42` section
// 1.4.4 records the same use counts.

/// `jint`, `jni_md.h:33`, a C `int` and therefore 32 bits on every target the
/// port claims for Android.
pub const JInt = i32;

/// `jlong`, `jni_md.h:34-38`, 64 bits, `long` on an LP64 target and
/// `long long` elsewhere.
pub const JLong = i64;

/// `jfloat`, `jni.h:60`, a C `float` and therefore 32 bits.
pub const JFloat = f32;

/// `jboolean`, `jni.h:57`, an `unsigned char` and therefore one byte.
pub const JBoolean = u8;

/// `jsize`, `jni.h:63`, a typedef of `jint`.
pub const JSize = i32;

/// `jbyte`, `jni_md.h:40`, a `signed char`.
pub const JByte = i8;

/// `jchar`, `jni.h:58`, an `unsigned short`.
pub const JChar = u16;

/// `jshort`, `jni.h:59`, a `short`.
pub const JShort = i16;

/// `jdouble`, `jni.h:61`, a C `double`.
pub const JDouble = f64;

/// `jobject`, `jni.h:101`, a pointer to an opaque Java object. `jclass`,
/// `jstring`, `jarray`, `jintArray` and `jobjectArray` are all typedefs of it,
/// so one Zig type names the whole family.
///
/// This and `JniEnv`, `JInt` and `JFloat` are the four types
/// `src/capi/platform.zig` declares at `:154-165` for the same purpose. **The
/// integration pass moves all four to `src/capi/boundary.zig`,** which is the
/// leaf both sides import, and deletes the declarations in `platform.zig`. This
/// module keeps them because `platform.zig` must name them in its own
/// signatures until then, and a second copy of one of the four is a compile
/// error the integration pass has to remove.
pub const JObject = ?*anyopaque;

/// `jclass`, `jni.h:102`, a typedef of `jobject`.
pub const JClass = JObject;

/// `jstring`, `jni.h:104`, a typedef of `jobject`.
pub const JString = JObject;

/// `jmethodID`, `jni.h:134`, a pointer to an opaque method identifier.
pub const JMethodId = ?*anyopaque;

/// `jfieldID`, `jni.h:135`, a pointer to an opaque field identifier. The adapter
/// reads one static field, `ACTION_SET_PROGRESS`, through it.
pub const JFieldId = ?*anyopaque;

/// `JNIEnv *`, `jni.h:197` in C mode: a pointer to the function table, so an
/// opaque pointer is the whole contract.
pub const JniEnv = ?*anyopaque;

/// `jvalue`, `jni.h:120-130`. The union a JNI call passes its arguments in, and
/// 8 bytes on every target because the widest member is a pointer.
///
/// A JNI call takes a `const jvalue *` and reads as many members as the
/// descriptor names, so a wrapper here is given a `[]const JValue` and passes
/// its pointer through unchanged. **The slice length is the caller's contract
/// and no wrapper here checks it:** JNI reads the descriptor, not the slice, so
/// a short slice is a read past the end rather than a rejection. Every call site
/// in this directory builds the slice to match the descriptor it passes, and
/// `methods.zig` pins each of those descriptors.
pub const JValue = extern union {
    /// The `z` member, `jni.h:121`, a `jboolean`.
    z: JBoolean,
    /// The `b` member, `jni.h:122`, a `jbyte`.
    b: JByte,
    /// The `c` member, `jni.h:123`, a `jchar`.
    c: JChar,
    /// The `s` member, `jni.h:124`, a `jshort`.
    s: JShort,
    /// The `i` member, `jni.h:125`, a `jint`.
    i: JInt,
    /// The `j` member, `jni.h:126`, a `jlong`.
    j: JLong,
    /// The `f` member, `jni.h:127`, a `jfloat`.
    f: JFloat,
    /// The `d` member, `jni.h:128`, a `jdouble`.
    d: JDouble,
    /// The `l` member, `jni.h:129`, a `jobject`.
    l: JObject,
};

/// `JNINativeMethod`, `jni.h:180-184`, the triple `RegisterNatives` takes.
///
/// This is the one JNI **data structure** rather than a declaration, and it is
/// why `docs/29` section 4 says a `translate-c` binding cannot produce the
/// registration: the five rows are literals in `injecting.zig`.
pub const JNINativeMethod = extern struct {
    /// The Java method name, as a NUL-terminated C string.
    name: [*c]const u8,
    /// The JNI descriptor, as a NUL-terminated C string.
    signature: [*c]const u8,
    /// The function to call, untyped so the table does not have to know the
    /// signature the callee uses.
    function: ?*const anyopaque,
};

// --- the slot table ---------------------------------------------------------

/// How many slots the table has: 229 named entry points plus the four
/// `reserved` pointers `jni.h:215-219` puts at the front.
pub const jni_slot_count = 233;

/// How many named slots the table has, which is the count less the reserved
/// pointers.
pub const jni_named_slot_count = jni_slot_count - reserved_slots;

/// The four `reserved` pointers `jni.h:215-219` puts at the front of the table.
///
/// They are `void *` in the header and are never called, so this module names
/// their count rather than their type.
pub const reserved_slots = 4;

/// Every named slot, in declaration order.
///
/// Transcribed from the `jni.h` path the module doc names. **Unverified against
/// the NDK header**, as the module doc says. This array is the record a reader
/// checks the slot numbers against, and a test asserts both its length and the
/// slot number of each entry the adapter uses, so a name dropped or duplicated
/// here fails the build rather than shifting every slot after it.
pub const jni_slot_names = [jni_named_slot_count][:0]const u8{
    "GetVersion",
    "DefineClass",
    "FindClass",
    "FromReflectedMethod",
    "FromReflectedField",
    "ToReflectedMethod",
    "GetSuperclass",
    "IsAssignableFrom",
    "ToReflectedField",
    "Throw",
    "ThrowNew",
    "ExceptionOccurred",
    "ExceptionDescribe",
    "ExceptionClear",
    "FatalError",
    "PushLocalFrame",
    "PopLocalFrame",
    "NewGlobalRef",
    "DeleteGlobalRef",
    "DeleteLocalRef",
    "IsSameObject",
    "NewLocalRef",
    "EnsureLocalCapacity",
    "AllocObject",
    "NewObject",
    "NewObjectV",
    "NewObjectA",
    "GetObjectClass",
    "IsInstanceOf",
    "GetMethodID",
    "CallObjectMethod",
    "CallObjectMethodV",
    "CallObjectMethodA",
    "CallBooleanMethod",
    "CallBooleanMethodV",
    "CallBooleanMethodA",
    "CallByteMethod",
    "CallByteMethodV",
    "CallByteMethodA",
    "CallCharMethod",
    "CallCharMethodV",
    "CallCharMethodA",
    "CallShortMethod",
    "CallShortMethodV",
    "CallShortMethodA",
    "CallIntMethod",
    "CallIntMethodV",
    "CallIntMethodA",
    "CallLongMethod",
    "CallLongMethodV",
    "CallLongMethodA",
    "CallFloatMethod",
    "CallFloatMethodV",
    "CallFloatMethodA",
    "CallDoubleMethod",
    "CallDoubleMethodV",
    "CallDoubleMethodA",
    "CallVoidMethod",
    "CallVoidMethodV",
    "CallVoidMethodA",
    "CallNonvirtualObjectMethod",
    "CallNonvirtualObjectMethodV",
    "CallNonvirtualObjectMethodA",
    "CallNonvirtualBooleanMethod",
    "CallNonvirtualBooleanMethodV",
    "CallNonvirtualBooleanMethodA",
    "CallNonvirtualByteMethod",
    "CallNonvirtualByteMethodV",
    "CallNonvirtualByteMethodA",
    "CallNonvirtualCharMethod",
    "CallNonvirtualCharMethodV",
    "CallNonvirtualCharMethodA",
    "CallNonvirtualShortMethod",
    "CallNonvirtualShortMethodV",
    "CallNonvirtualShortMethodA",
    "CallNonvirtualIntMethod",
    "CallNonvirtualIntMethodV",
    "CallNonvirtualIntMethodA",
    "CallNonvirtualLongMethod",
    "CallNonvirtualLongMethodV",
    "CallNonvirtualLongMethodA",
    "CallNonvirtualFloatMethod",
    "CallNonvirtualFloatMethodV",
    "CallNonvirtualFloatMethodA",
    "CallNonvirtualDoubleMethod",
    "CallNonvirtualDoubleMethodV",
    "CallNonvirtualDoubleMethodA",
    "CallNonvirtualVoidMethod",
    "CallNonvirtualVoidMethodV",
    "CallNonvirtualVoidMethodA",
    "GetFieldID",
    "GetObjectField",
    "GetBooleanField",
    "GetByteField",
    "GetCharField",
    "GetShortField",
    "GetIntField",
    "GetLongField",
    "GetFloatField",
    "GetDoubleField",
    "SetObjectField",
    "SetBooleanField",
    "SetByteField",
    "SetCharField",
    "SetShortField",
    "SetIntField",
    "SetLongField",
    "SetFloatField",
    "SetDoubleField",
    "GetStaticMethodID",
    "CallStaticObjectMethod",
    "CallStaticObjectMethodV",
    "CallStaticObjectMethodA",
    "CallStaticBooleanMethod",
    "CallStaticBooleanMethodV",
    "CallStaticBooleanMethodA",
    "CallStaticByteMethod",
    "CallStaticByteMethodV",
    "CallStaticByteMethodA",
    "CallStaticCharMethod",
    "CallStaticCharMethodV",
    "CallStaticCharMethodA",
    "CallStaticShortMethod",
    "CallStaticShortMethodV",
    "CallStaticShortMethodA",
    "CallStaticIntMethod",
    "CallStaticIntMethodV",
    "CallStaticIntMethodA",
    "CallStaticLongMethod",
    "CallStaticLongMethodV",
    "CallStaticLongMethodA",
    "CallStaticFloatMethod",
    "CallStaticFloatMethodV",
    "CallStaticFloatMethodA",
    "CallStaticDoubleMethod",
    "CallStaticDoubleMethodV",
    "CallStaticDoubleMethodA",
    "CallStaticVoidMethod",
    "CallStaticVoidMethodV",
    "CallStaticVoidMethodA",
    "GetStaticFieldID",
    "GetStaticObjectField",
    "GetStaticBooleanField",
    "GetStaticByteField",
    "GetStaticCharField",
    "GetStaticShortField",
    "GetStaticIntField",
    "GetStaticLongField",
    "GetStaticFloatField",
    "GetStaticDoubleField",
    "SetStaticObjectField",
    "SetStaticBooleanField",
    "SetStaticByteField",
    "SetStaticCharField",
    "SetStaticShortField",
    "SetStaticIntField",
    "SetStaticLongField",
    "SetStaticFloatField",
    "SetStaticDoubleField",
    "NewString",
    "GetStringLength",
    "GetStringChars",
    "ReleaseStringChars",
    "NewStringUTF",
    "GetStringUTFLength",
    "GetStringUTFChars",
    "ReleaseStringUTFChars",
    "GetArrayLength",
    "NewObjectArray",
    "GetObjectArrayElement",
    "SetObjectArrayElement",
    "NewBooleanArray",
    "NewByteArray",
    "NewCharArray",
    "NewShortArray",
    "NewIntArray",
    "NewLongArray",
    "NewFloatArray",
    "NewDoubleArray",
    "GetBooleanArrayElements",
    "GetByteArrayElements",
    "GetCharArrayElements",
    "GetShortArrayElements",
    "GetIntArrayElements",
    "GetLongArrayElements",
    "GetFloatArrayElements",
    "GetDoubleArrayElements",
    "ReleaseBooleanArrayElements",
    "ReleaseByteArrayElements",
    "ReleaseCharArrayElements",
    "ReleaseShortArrayElements",
    "ReleaseIntArrayElements",
    "ReleaseLongArrayElements",
    "ReleaseFloatArrayElements",
    "ReleaseDoubleArrayElements",
    "GetBooleanArrayRegion",
    "GetByteArrayRegion",
    "GetCharArrayRegion",
    "GetShortArrayRegion",
    "GetIntArrayRegion",
    "GetLongArrayRegion",
    "GetFloatArrayRegion",
    "GetDoubleArrayRegion",
    "SetBooleanArrayRegion",
    "SetByteArrayRegion",
    "SetCharArrayRegion",
    "SetShortArrayRegion",
    "SetIntArrayRegion",
    "SetLongArrayRegion",
    "SetFloatArrayRegion",
    "SetDoubleArrayRegion",
    "RegisterNatives",
    "UnregisterNatives",
    "MonitorEnter",
    "MonitorExit",
    "GetJavaVM",
    "GetStringRegion",
    "GetStringUTFRegion",
    "GetPrimitiveArrayCritical",
    "ReleasePrimitiveArrayCritical",
    "GetStringCritical",
    "ReleaseStringCritical",
    "NewWeakGlobalRef",
    "DeleteWeakGlobalRef",
    "ExceptionCheck",
    "NewDirectByteBuffer",
    "GetDirectBufferAddress",
    "GetDirectBufferCapacity",
    "GetObjectRefType",
};

/// The slot of the named entry point, plus the four `reserved` pointers.
///
/// **Compile-time.** A name the table does not hold is a `@compileError` naming
/// it, and a name it holds twice is a second `@compileError`, so a misspelt or
/// duplicated slot name is a build failure and not a wrong call on a device.
pub fn slotOf(comptime name: [:0]const u8) comptime_int {
    comptime {
        // The walk below is 229 names, and this function is instantiated once
        // per slot the adapter reaches, so the 1000 backwards branches of one
        // walk are not enough once several are evaluated in one comptime pass.
        @setEvalBranchQuota(100_000);
        var found: ?usize = null;
        for (jni_slot_names, 0..) |candidate, index| {
            if (!std.mem.eql(u8, candidate, name)) continue;
            if (found != null) {
                @compileError(std.fmt.comptimePrint(
                    "the JNI table names {s} twice, so its slot is not unique",
                    .{name},
                ));
            }
            found = index;
        }
        if (found == null) {
            @compileError(std.fmt.comptimePrint("the JNI table has no slot named {s}", .{name}));
        }
        return found.? + reserved_slots;
    }
}

// --- the slots the adapter reaches -------------------------------------------

const slot_find_class = slotOf("FindClass");
const slot_push_local_frame = slotOf("PushLocalFrame");
const slot_pop_local_frame = slotOf("PopLocalFrame");
const slot_new_global_ref = slotOf("NewGlobalRef");
const slot_delete_global_ref = slotOf("DeleteGlobalRef");
const slot_delete_local_ref = slotOf("DeleteLocalRef");
const slot_new_object_a = slotOf("NewObjectA");
const slot_is_instance_of = slotOf("IsInstanceOf");
const slot_get_method_id = slotOf("GetMethodID");
const slot_call_object_method_a = slotOf("CallObjectMethodA");
const slot_call_boolean_method_a = slotOf("CallBooleanMethodA");
const slot_call_int_method_a = slotOf("CallIntMethodA");
const slot_call_float_method_a = slotOf("CallFloatMethodA");
const slot_call_void_method_a = slotOf("CallVoidMethodA");
const slot_call_static_object_method_a = slotOf("CallStaticObjectMethodA");
const slot_get_static_method_id = slotOf("GetStaticMethodID");
const slot_get_static_field_id = slotOf("GetStaticFieldID");
const slot_get_static_object_field = slotOf("GetStaticObjectField");
const slot_new_string = slotOf("NewString");
const slot_new_int_array = slotOf("NewIntArray");
const slot_get_int_array_region = slotOf("GetIntArrayRegion");
const slot_register_natives = slotOf("RegisterNatives");
const slot_new_weak_global_ref = slotOf("NewWeakGlobalRef");
const slot_exception_check = slotOf("ExceptionCheck");

// --- the table value --------------------------------------------------------

/// The JNI entry points the adapter calls, as one injectable value.
///
/// **`JniTable` owns nothing.** `env` is the `JNIEnv *` the VM gave one thread,
/// so it is valid only while that thread is attached and must not be shared
/// between threads; `docs/29` row 1 records that the upstream adapter threads it
/// through every entry point for the same reason. Every other field is a
/// function pointer, so a value built here allocates nothing and copying it
/// copies one pointer plus the environment.
///
/// A caller builds one with `JniTable.real` to reach a live VM, or fills the
/// fields with its own functions to stand one in. The methods take the table by
/// value and pass `self.env` as the first argument to the field, so a recording
/// function receives the environment and reads whatever context it parked there.
pub const JniTable = struct {
    /// The environment every field below is called with.
    env: JniEnv,

    /// Each field below is the entry point of the same name with an `Fn`
    /// suffix, so the field and the method that forwards to it are two
    /// declarations rather than one colliding name. Every method passes
    /// `self.env` as the first argument, which is what lets a substituted
    /// function recover its own context from the environment it is handed.

    /// Resolves a class by JNI name, `a/b/C` rather than `a.b.C`.
    findClassFn: *const fn (env: JniEnv, name: [:0]const u8) JClass,
    /// Resolves an instance method by name and JNI descriptor.
    getMethodIdFn: *const fn (
        env: JniEnv,
        class: JClass,
        name: [:0]const u8,
        signature: [:0]const u8,
    ) JMethodId,
    /// Resolves a static method by name and JNI descriptor.
    getStaticMethodIdFn: *const fn (
        env: JniEnv,
        class: JClass,
        name: [:0]const u8,
        signature: [:0]const u8,
    ) JMethodId,
    /// Resolves a static field by name and JNI descriptor.
    getStaticFieldIdFn: *const fn (
        env: JniEnv,
        class: JClass,
        name: [:0]const u8,
        signature: [:0]const u8,
    ) JFieldId,
    /// Reads a static field.
    getStaticObjectFieldFn: *const fn (env: JniEnv, class: JClass, field: JFieldId) JObject,
    /// Calls an instance method whose result is a reference.
    callObjectMethodFn: *const fn (
        env: JniEnv,
        obj: JObject,
        method: JMethodId,
        args: []const JValue,
    ) JObject,
    /// Calls a static method whose result is a reference.
    callStaticObjectMethodFn: *const fn (
        env: JniEnv,
        class: JClass,
        method: JMethodId,
        args: []const JValue,
    ) JObject,
    /// Calls an instance method whose result is a `jboolean`.
    callBooleanMethodFn: *const fn (
        env: JniEnv,
        obj: JObject,
        method: JMethodId,
        args: []const JValue,
    ) JBoolean,
    /// Calls an instance method whose result is a `jint`.
    callIntMethodFn: *const fn (
        env: JniEnv,
        obj: JObject,
        method: JMethodId,
        args: []const JValue,
    ) JInt,
    /// Calls an instance method whose result is a `jfloat`.
    callFloatMethodFn: *const fn (
        env: JniEnv,
        obj: JObject,
        method: JMethodId,
        args: []const JValue,
    ) JFloat,
    /// Calls an instance method whose result is `void`.
    callVoidMethodFn: *const fn (
        env: JniEnv,
        obj: JObject,
        method: JMethodId,
        args: []const JValue,
    ) void,
    /// Builds a Java string holding UTF-16 text.
    newStringFn: *const fn (env: JniEnv, text: []const u8) JString,
    /// Builds an object with a constructor.
    newObjectFn: *const fn (
        env: JniEnv,
        class: JClass,
        method: JMethodId,
        args: []const JValue,
    ) JObject,
    /// Builds a zero-filled Java `int[]`.
    newIntArrayFn: *const fn (env: JniEnv, len: usize) JObject,
    /// Copies elements out of a Java `int[]`.
    getIntArrayRegionFn: *const fn (
        env: JniEnv,
        array: JObject,
        start: usize,
        len: usize,
        out: []JInt,
    ) void,
    /// Takes a global reference that outlives its frame.
    newGlobalRefFn: *const fn (env: JniEnv, obj: JObject) JObject,
    /// Takes a weak global reference that does not keep its object alive.
    newWeakGlobalRefFn: *const fn (env: JniEnv, obj: JObject) JObject,
    /// Releases a global or weak global reference.
    deleteGlobalRefFn: *const fn (env: JniEnv, obj: JObject) void,
    /// Releases a local reference before its frame ends.
    deleteLocalRefFn: *const fn (env: JniEnv, obj: JObject) void,
    /// Whether an object is an instance of a class.
    isInstanceOfFn: *const fn (env: JniEnv, obj: JObject, class: JClass) bool,
    /// Whether a Java exception is pending on this thread.
    exceptionCheckFn: *const fn (env: JniEnv) bool,
    /// Opens a local frame of `capacity` elements and answers the JNI result.
    pushLocalFrameFn: *const fn (env: JniEnv, capacity: JInt) JInt,
    /// Closes the innermost local frame and keeps `result` in the frame below.
    popLocalFrameFn: *const fn (env: JniEnv, result: JObject) JObject,
    /// Binds a table of native methods to a class.
    registerNativeMethodsFn: *const fn (
        env: JniEnv,
        class: JClass,
        methods: []const JNINativeMethod,
    ) JInt,

    /// Resolves the class named `name`, or `null`.
    ///
    /// A `null` result means the class is not on the classpath and leaves a
    /// `NoClassDefFoundError` pending; see `exceptionCheck` and the module doc
    /// for why this module does not clear it.
    pub fn findClass(self: JniTable, name: [:0]const u8) JClass {
        return self.findClassFn(self.env, name);
    }

    /// Resolves the instance method `name` on `class`, or `null`.
    ///
    /// **A wrong name or descriptor here is the one failure no compiler
    /// catches**, because it is a string compared at run time on a device.
    /// `methods.zig` pins every descriptor the adapter sends and the tests in
    /// this directory assert each call site against it.
    pub fn getMethodId(
        self: JniTable,
        class: JClass,
        name: [:0]const u8,
        signature: [:0]const u8,
    ) JMethodId {
        return self.getMethodIdFn(self.env, class, name, signature);
    }

    /// Resolves the static method `name` on `class`, or `null`.
    pub fn getStaticMethodId(
        self: JniTable,
        class: JClass,
        name: [:0]const u8,
        signature: [:0]const u8,
    ) JMethodId {
        return self.getStaticMethodIdFn(self.env, class, name, signature);
    }

    /// Resolves the static field `name` on `class`, or `null`.
    pub fn getStaticFieldId(
        self: JniTable,
        class: JClass,
        name: [:0]const u8,
        signature: [:0]const u8,
    ) JFieldId {
        return self.getStaticFieldIdFn(self.env, class, name, signature);
    }

    /// Reads the static field `field`, or `null`.
    pub fn getStaticObjectField(self: JniTable, class: JClass, field: JFieldId) JObject {
        return self.getStaticObjectFieldFn(self.env, class, field);
    }

    /// Calls an instance method and answers its reference result, or `null`.
    ///
    /// `args` is the `jvalue` array the descriptor reads, and its length is the
    /// caller's contract: see `JValue`.
    pub fn callObjectMethod(
        self: JniTable,
        obj: JObject,
        method: JMethodId,
        args: []const JValue,
    ) JObject {
        return self.callObjectMethodFn(self.env, obj, method, args);
    }

    /// Calls a static method and answers its reference result, or `null`.
    pub fn callStaticObjectMethod(
        self: JniTable,
        class: JClass,
        method: JMethodId,
        args: []const JValue,
    ) JObject {
        return self.callStaticObjectMethodFn(self.env, class, method, args);
    }

    /// Calls an instance method and answers its `jboolean`, where `0` is
    /// `JNI_FALSE`.
    pub fn callBooleanMethod(
        self: JniTable,
        obj: JObject,
        method: JMethodId,
        args: []const JValue,
    ) JBoolean {
        return self.callBooleanMethodFn(self.env, obj, method, args);
    }

    /// Calls an instance method and answers its `jint`.
    pub fn callIntMethod(
        self: JniTable,
        obj: JObject,
        method: JMethodId,
        args: []const JValue,
    ) JInt {
        return self.callIntMethodFn(self.env, obj, method, args);
    }

    /// Calls an instance method and answers its `jfloat`.
    pub fn callFloatMethod(
        self: JniTable,
        obj: JObject,
        method: JMethodId,
        args: []const JValue,
    ) JFloat {
        return self.callFloatMethodFn(self.env, obj, method, args);
    }

    /// Calls an instance method and discards its `void` result.
    pub fn callVoidMethod(
        self: JniTable,
        obj: JObject,
        method: JMethodId,
        args: []const JValue,
    ) void {
        self.callVoidMethodFn(self.env, obj, method, args);
    }

    /// Builds a Java string holding `text`, encoded as UTF-16.
    ///
    /// **UTF-16 is the encoding `NewString` takes**, so it carries every
    /// character a `jstring` can hold. `NewStringUTF` would take modified
    /// UTF-8, which cannot represent a supplementary character and encodes a
    /// null byte as two bytes; `docs/29` row 13 records that upstream calls
    /// `new_string`, which is this slot.
    ///
    /// The result is a **local reference**, so it belongs to the frame that
    /// made it. The caller releases it with `deleteLocalRef` or lets the frame
    /// end take it, and a caller that keeps it past the frame takes a global
    /// reference with `newGlobalRef`.
    pub fn newString(self: JniTable, text: []const u8) JString {
        return self.newStringFn(self.env, text);
    }

    /// Builds the object `class` with the constructor `method`, or `null`.
    ///
    /// Upstream reaches `android.graphics.Rect` and `RangeInfo` this way, at
    /// `AK/android/src/node.rs:243` and `:116`.
    pub fn newObject(
        self: JniTable,
        class: JClass,
        method: JMethodId,
        args: []const JValue,
    ) JObject {
        return self.newObjectFn(self.env, class, method, args);
    }

    /// Builds a zero-filled Java `int[]` of `len` elements, or `null`.
    ///
    /// The result is a local reference.
    pub fn newIntArray(self: JniTable, len: usize) JObject {
        return self.newIntArrayFn(self.env, len);
    }

    /// Copies `len` elements of `array` from `start` into `out`.
    ///
    /// **The caller must give `out` room for `len` elements**, because the JNI
    /// call writes through a raw pointer and knows nothing of the buffer's size.
    /// A short buffer is a memory error rather than a rejection.
    pub fn getIntArrayRegion(
        self: JniTable,
        array: JObject,
        start: usize,
        len: usize,
        out: []JInt,
    ) void {
        self.getIntArrayRegionFn(self.env, array, start, len, out);
    }

    /// Takes a global reference to `obj`.
    ///
    /// A global reference outlives the frame that made it, so a caller that
    /// keeps a Java object past the call takes one here and releases it with
    /// `deleteGlobalRef`.
    pub fn newGlobalRef(self: JniTable, obj: JObject) JObject {
        return self.newGlobalRefFn(self.env, obj);
    }

    /// Takes a weak global reference to `obj`.
    ///
    /// A weak reference does not keep `obj` alive, so the VM may collect it and
    /// the reference then reads `null`. Upstream holds the host view this way,
    /// at `AK/android/src/inject.rs:386`, because the adapter must not keep the
    /// application's view alive.
    pub fn newWeakGlobalRef(self: JniTable, obj: JObject) JObject {
        return self.newWeakGlobalRefFn(self.env, obj);
    }

    /// Releases a reference taken by `newGlobalRef` or `newWeakGlobalRef`.
    pub fn deleteGlobalRef(self: JniTable, obj: JObject) void {
        self.deleteGlobalRefFn(self.env, obj);
    }

    /// Releases a local reference, so a long call need not wait for its frame to
    /// end.
    pub fn deleteLocalRef(self: JniTable, obj: JObject) void {
        self.deleteLocalRefFn(self.env, obj);
    }

    /// Whether `obj` is an instance of `class`.
    ///
    /// Upstream calls this once, at `AK/android/src/inject.rs:444`, to clear the
    /// delegate only when the installed one is this adapter's own.
    pub fn isInstanceOf(self: JniTable, obj: JObject, class: JClass) bool {
        return self.isInstanceOfFn(self.env, obj, class);
    }

    /// Whether a Java exception is pending on this thread.
    ///
    /// A failed `findClass`, `getMethodId` or call leaves one pending.
    /// `docs/29` section 3.3 records that upstream unwraps the JNI error at each
    /// site, so this module reports the exception and leaves the decision to the
    /// caller.
    pub fn exceptionCheck(self: JniTable) bool {
        return self.exceptionCheckFn(self.env);
    }

    /// Opens a local frame of `capacity` elements.
    ///
    /// A negative answer is the JNI failure result. `values.LOCAL_FRAME_CAPACITY`
    /// is the capacity upstream opens with, at `AK/android/src/inject.rs:99`.
    pub fn pushLocalFrame(self: JniTable, capacity: JInt) JInt {
        return self.pushLocalFrameFn(self.env, capacity);
    }

    /// Closes the innermost local frame, keeping `result` as a local reference
    /// in the frame beneath it.
    pub fn popLocalFrame(self: JniTable, result: JObject) JObject {
        return self.popLocalFrameFn(self.env, result);
    }

    /// Binds `methods` to `class`.
    ///
    /// The five rows are the registered natives of
    /// `dev.accesskit.android.Delegate`, at `AK/android/src/inject.rs:257-291`.
    /// A negative answer is the JNI failure result. **A wrong name or signature
    /// in `methods` leaves the Java method unbound, and the failure surfaces as
    /// an `UnsatisfiedLinkError` at the first call** rather than here, which is
    /// why `injecting.zig` asserts all five rows against `methods.zig`.
    pub fn registerNativeMethods(
        self: JniTable,
        class: JClass,
        methods: []const JNINativeMethod,
    ) JInt {
        return self.registerNativeMethodsFn(self.env, class, methods);
    }
};

// --- the real binding -------------------------------------------------------

/// The table that reaches the VM behind `env`.
///
/// Every field loads one slot of the `JNINativeInterface` table the pointer
/// names, so a live VM is the only thing this reaches. **A slot the table does
/// not hold, or a null `env`, answers the JNI default** rather than faulting: a
/// thread the VM has not attached is a state a caller can reach, and the JNI
/// default for each return type is the honest answer there.
///
/// The load is unchecked on purpose. A JNI table has no null slot in the first
/// 216 entries on any implementation, and a binding that rejected one would
/// replace a fault inside the VM with a Zig error path the C caller cannot act
/// on.
pub fn realTable(env: JniEnv) JniTable {
    return .{
        .env = env,
        .findClassFn = realFindClass,
        .getMethodIdFn = realGetMethodId,
        .getStaticMethodIdFn = realGetStaticMethodId,
        .getStaticFieldIdFn = realGetStaticFieldId,
        .getStaticObjectFieldFn = realGetStaticObjectField,
        .callObjectMethodFn = realCallObjectMethod,
        .callStaticObjectMethodFn = realCallStaticObjectMethod,
        .callBooleanMethodFn = realCallBooleanMethod,
        .callIntMethodFn = realCallIntMethod,
        .callFloatMethodFn = realCallFloatMethod,
        .callVoidMethodFn = realCallVoidMethod,
        .newStringFn = realNewString,
        .newObjectFn = realNewObject,
        .newIntArrayFn = realNewIntArray,
        .getIntArrayRegionFn = realGetIntArrayRegion,
        .newGlobalRefFn = realNewGlobalRef,
        .newWeakGlobalRefFn = realNewWeakGlobalRef,
        .deleteGlobalRefFn = realDeleteGlobalRef,
        .deleteLocalRefFn = realDeleteLocalRef,
        .isInstanceOfFn = realIsInstanceOf,
        .exceptionCheckFn = realExceptionCheck,
        .pushLocalFrameFn = realPushLocalFrame,
        .popLocalFrameFn = realPopLocalFrame,
        .registerNativeMethodsFn = realRegisterNativeMethods,
    };
}

/// The table that answers the JNI default from every entry point, carrying
/// `env` through untouched.
///
/// **This is the table a caller substitutes and a test builds on.** Every
/// method answers `null`, `0` or nothing without reading the environment, so a
/// test fills the few fields it asserts and leaves the rest harmless, and a
/// caller that has no VM yet holds one instead of a half-built table. Overwrite
/// a field by copy: `var table = inertTable(env); table.findClassFn = ...;`.
pub fn inertTable(env: JniEnv) JniTable {
    return .{
        .env = env,
        .findClassFn = inertClass,
        .getMethodIdFn = inertMethodId,
        .getStaticMethodIdFn = inertMethodId,
        .getStaticFieldIdFn = inertFieldId,
        .getStaticObjectFieldFn = inertStaticObjectField,
        .callObjectMethodFn = inertObject,
        .callStaticObjectMethodFn = inertObject,
        .callBooleanMethodFn = inertBoolean,
        .callIntMethodFn = inertCallInt,
        .callFloatMethodFn = inertFloat,
        .callVoidMethodFn = inertVoid,
        .newStringFn = inertString,
        .newObjectFn = inertObject,
        .newIntArrayFn = inertNewIntArray,
        .getIntArrayRegionFn = inertIntArrayRegion,
        .newGlobalRefFn = inertNewReference,
        .newWeakGlobalRefFn = inertNewReference,
        .deleteGlobalRefFn = inertVoidObject,
        .deleteLocalRefFn = inertVoidObject,
        .isInstanceOfFn = inertBool,
        .exceptionCheckFn = inertNoException,
        .pushLocalFrameFn = inertInt,
        .popLocalFrameFn = inertNewReference,
        .registerNativeMethodsFn = inertRegister,
    };
}

/// `inertTable` with `env` replaced, so one set of fields serves two recorders.
fn withRecorder(table: *const JniTable, env: anytype) JniTable {
    var copy = table.*;
    copy.env = @ptrCast(env);
    return copy;
}

fn inertClass(env: JniEnv, name: [:0]const u8) JClass {
    _ = env;
    _ = name;
    return null;
}

fn inertMethodId(env: JniEnv, class: JClass, name: [:0]const u8, signature: [:0]const u8) JMethodId {
    _ = env;
    _ = class;
    _ = name;
    _ = signature;
    return null;
}

fn inertFieldId(env: JniEnv, class: JClass, name: [:0]const u8, signature: [:0]const u8) JFieldId {
    _ = env;
    _ = class;
    _ = name;
    _ = signature;
    return null;
}

fn inertObject(env: JniEnv, a: JObject, b: JMethodId, args: []const JValue) JObject {
    _ = env;
    _ = a;
    _ = b;
    _ = args;
    return null;
}

fn inertBoolean(env: JniEnv, obj: JObject, method: JMethodId, args: []const JValue) JBoolean {
    _ = env;
    _ = obj;
    _ = method;
    _ = args;
    return 0;
}

fn inertInt(env: JniEnv, capacity: JInt) JInt {
    _ = env;
    _ = capacity;
    return 0;
}

fn inertFloat(env: JniEnv, obj: JObject, method: JMethodId, args: []const JValue) JFloat {
    _ = env;
    _ = obj;
    _ = method;
    _ = args;
    return 0;
}

fn inertVoid(env: JniEnv, obj: JObject, method: JMethodId, args: []const JValue) void {
    _ = env;
    _ = obj;
    _ = method;
    _ = args;
}

fn inertString(env: JniEnv, text: []const u8) JString {
    _ = env;
    _ = text;
    return null;
}

fn inertNewReference(env: JniEnv, obj: JObject) JObject {
    _ = env;
    _ = obj;
    return null;
}

fn inertNewIntArray(env: JniEnv, len: usize) JObject {
    _ = env;
    _ = len;
    return null;
}

fn inertIntArrayRegion(env: JniEnv, array: JObject, start: usize, len: usize, out: []JInt) void {
    _ = env;
    _ = array;
    _ = start;
    _ = len;
    _ = out;
}

fn inertVoidObject(env: JniEnv, obj: JObject) void {
    _ = env;
    _ = obj;
}

fn inertBool(env: JniEnv, obj: JObject, class: JClass) bool {
    _ = env;
    _ = obj;
    _ = class;
    return false;
}

fn inertNoException(env: JniEnv) bool {
    _ = env;
    return false;
}

fn inertRegister(env: JniEnv, class: JClass, methods: []const JNINativeMethod) JInt {
    _ = env;
    _ = class;
    _ = methods;
    return 0;
}

fn inertCallInt(env: JniEnv, obj: JObject, method: JMethodId, args: []const JValue) JInt {
    _ = env;
    _ = obj;
    _ = method;
    _ = args;
    return 0;
}

fn inertStaticObjectField(env: JniEnv, class: JClass, field: JFieldId) JObject {
    _ = env;
    _ = class;
    _ = field;
    return null;
}

/// The function pointer in the table at `index`, or `null`.
fn slotAt(env: JniEnv, index: usize) ?*const anyopaque {
    if (env == null) return null;
    const table: [*c]const ?*const anyopaque = @ptrCast(@alignCast(env.?));
    return table[index];
}

fn realFindClass(env: JniEnv, name: [:0]const u8) JClass {
    const F = *const fn (JniEnv, [*c]const u8) callconv(.c) JClass;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_find_class) orelse return null));
    return f(env, name.ptr);
}

fn realGetMethodId(
    env: JniEnv,
    class: JClass,
    name: [:0]const u8,
    signature: [:0]const u8,
) JMethodId {
    const F = *const fn (JniEnv, JClass, [*c]const u8, [*c]const u8) callconv(.c) JMethodId;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_get_method_id) orelse return null));
    return f(env, class, name.ptr, signature.ptr);
}

fn realGetStaticMethodId(
    env: JniEnv,
    class: JClass,
    name: [:0]const u8,
    signature: [:0]const u8,
) JMethodId {
    const F = *const fn (JniEnv, JClass, [*c]const u8, [*c]const u8) callconv(.c) JMethodId;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_get_static_method_id) orelse return null));
    return f(env, class, name.ptr, signature.ptr);
}

fn realGetStaticFieldId(
    env: JniEnv,
    class: JClass,
    name: [:0]const u8,
    signature: [:0]const u8,
) JFieldId {
    const F = *const fn (JniEnv, JClass, [*c]const u8, [*c]const u8) callconv(.c) JFieldId;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_get_static_field_id) orelse return null));
    return f(env, class, name.ptr, signature.ptr);
}

fn realGetStaticObjectField(env: JniEnv, class: JClass, field: JFieldId) JObject {
    const F = *const fn (JniEnv, JClass, JFieldId) callconv(.c) JObject;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_get_static_object_field) orelse return null));
    return f(env, class, field);
}

fn realCallObjectMethod(
    env: JniEnv,
    obj: JObject,
    method: JMethodId,
    args: []const JValue,
) JObject {
    const F = *const fn (JniEnv, JObject, JMethodId, [*c]const JValue) callconv(.c) JObject;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_call_object_method_a) orelse return null));
    return f(env, obj, method, args.ptr);
}

fn realCallStaticObjectMethod(
    env: JniEnv,
    class: JClass,
    method: JMethodId,
    args: []const JValue,
) JObject {
    const F = *const fn (JniEnv, JClass, JMethodId, [*c]const JValue) callconv(.c) JObject;
    const f: F = @ptrCast(@alignCast(
        slotAt(env, slot_call_static_object_method_a) orelse return null,
    ));
    return f(env, class, method, args.ptr);
}

fn realCallBooleanMethod(
    env: JniEnv,
    obj: JObject,
    method: JMethodId,
    args: []const JValue,
) JBoolean {
    const F = *const fn (JniEnv, JObject, JMethodId, [*c]const JValue) callconv(.c) JBoolean;
    const f: F = @ptrCast(@alignCast(
        slotAt(env, slot_call_boolean_method_a) orelse return 0,
    ));
    return f(env, obj, method, args.ptr);
}

fn realCallIntMethod(
    env: JniEnv,
    obj: JObject,
    method: JMethodId,
    args: []const JValue,
) JInt {
    const F = *const fn (JniEnv, JObject, JMethodId, [*c]const JValue) callconv(.c) JInt;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_call_int_method_a) orelse return 0));
    return f(env, obj, method, args.ptr);
}

fn realCallFloatMethod(
    env: JniEnv,
    obj: JObject,
    method: JMethodId,
    args: []const JValue,
) JFloat {
    const F = *const fn (JniEnv, JObject, JMethodId, [*c]const JValue) callconv(.c) JFloat;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_call_float_method_a) orelse return 0));
    return f(env, obj, method, args.ptr);
}

fn realCallVoidMethod(
    env: JniEnv,
    obj: JObject,
    method: JMethodId,
    args: []const JValue,
) void {
    const F = *const fn (JniEnv, JObject, JMethodId, [*c]const JValue) callconv(.c) void;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_call_void_method_a) orelse return));
    f(env, obj, method, args.ptr);
}

fn realNewString(env: JniEnv, text: []const u8) JString {
    const F = *const fn (JniEnv, [*c]const u16, JSize) callconv(.c) JString;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_new_string) orelse return null));
    // `NewString` takes UTF-16, so the text is encoded here rather than handed
    // over as bytes. `utf8ToUtf16Le` writes into its first buffer and reads its
    // second, and it answers the unit count. A string that does not fit the
    // buffer becomes a `null` here rather than a truncated string, which is why
    // `local_char_capacity` sits well above any label or class name.
    var stack: [local_char_capacity]u16 = undefined;
    const unit_count = std.unicode.utf8ToUtf16Le(&stack, text) catch return null;
    return f(env, &stack, @intCast(unit_count));
}

/// How many UTF-16 units the real `newString` encoding holds on the stack.
///
/// 512 units is 1024 bytes and covers every string a label, a class name or a
/// package name carries. A longer text answers `null` from `realNewString`, so
/// the figure is a limit the caller has to know rather than a silent
/// truncation.
pub const local_char_capacity = 512;

fn realNewObject(
    env: JniEnv,
    class: JClass,
    method: JMethodId,
    args: []const JValue,
) JObject {
    const F = *const fn (JniEnv, JClass, JMethodId, [*c]const JValue) callconv(.c) JObject;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_new_object_a) orelse return null));
    return f(env, class, method, args.ptr);
}

fn realNewIntArray(env: JniEnv, len: usize) JObject {
    const F = *const fn (JniEnv, JSize) callconv(.c) JObject;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_new_int_array) orelse return null));
    return f(env, @intCast(len));
}

fn realGetIntArrayRegion(
    env: JniEnv,
    array: JObject,
    start: usize,
    len: usize,
    out: []JInt,
) void {
    const F = *const fn (JniEnv, JObject, JSize, JSize, [*c]JInt) callconv(.c) void;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_get_int_array_region) orelse return));
    f(env, array, @intCast(start), @intCast(len), out.ptr);
}

fn realNewGlobalRef(env: JniEnv, obj: JObject) JObject {
    const F = *const fn (JniEnv, JObject) callconv(.c) JObject;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_new_global_ref) orelse return null));
    return f(env, obj);
}

fn realNewWeakGlobalRef(env: JniEnv, obj: JObject) JObject {
    const F = *const fn (JniEnv, JObject) callconv(.c) JObject;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_new_weak_global_ref) orelse return null));
    return f(env, obj);
}

fn realDeleteGlobalRef(env: JniEnv, obj: JObject) void {
    const F = *const fn (JniEnv, JObject) callconv(.c) void;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_delete_global_ref) orelse return));
    f(env, obj);
}

fn realDeleteLocalRef(env: JniEnv, obj: JObject) void {
    const F = *const fn (JniEnv, JObject) callconv(.c) void;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_delete_local_ref) orelse return));
    f(env, obj);
}

fn realIsInstanceOf(env: JniEnv, obj: JObject, class: JClass) bool {
    const F = *const fn (JniEnv, JObject, JClass) callconv(.c) JBoolean;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_is_instance_of) orelse return false));
    return f(env, obj, class) != 0;
}

fn realExceptionCheck(env: JniEnv) bool {
    const F = *const fn (JniEnv) callconv(.c) JBoolean;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_exception_check) orelse return false));
    return f(env) != 0;
}

fn realPushLocalFrame(env: JniEnv, capacity: JInt) JInt {
    const F = *const fn (JniEnv, JInt) callconv(.c) JInt;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_push_local_frame) orelse return 0));
    return f(env, capacity);
}

fn realPopLocalFrame(env: JniEnv, result: JObject) JObject {
    const F = *const fn (JniEnv, JObject) callconv(.c) JObject;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_pop_local_frame) orelse return null));
    return f(env, result);
}

fn realRegisterNativeMethods(
    env: JniEnv,
    class: JClass,
    methods: []const JNINativeMethod,
) JInt {
    const F = *const fn (JniEnv, JClass, [*c]const JNINativeMethod, JInt) callconv(.c) JInt;
    const f: F = @ptrCast(@alignCast(slotAt(env, slot_register_natives) orelse return 0));
    return f(env, class, methods.ptr, @intCast(methods.len));
}

comptime {
    // The duplicate walk below is 229 rows against the rows after each, so it is
    // about 26 thousand comparisons. The default budget of 1000 backwards
    // branches is far below that.
    @setEvalBranchQuota(100_000);
    if (jni_slot_names.len != jni_named_slot_count) {
        @compileError("the array length is the named slot count");
    }
    if (jni_named_slot_count + reserved_slots != jni_slot_count) {
        @compileError("the four reserved pointers sit in front of the named slots");
    }
    // Two slots cannot share a name, because `slotOf` would then have two
    // answers and a caller would not know which one it got.
    for (jni_slot_names, 0..) |a, i| {
        for (jni_slot_names[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a, b)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate slot name at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a },
                ));
            }
        }
    }
    // `jvalue` is 8 bytes because its widest member is a pointer, and every
    // wrapper passes a `[*c]const JValue` where the C table expects a
    // `const jvalue *`.
    if (@sizeOf(JValue) != 8) @compileError("jvalue is 8 bytes on every target");
    if (@sizeOf(JInt) != 4) @compileError("jint is 4 bytes");
    if (@sizeOf(JLong) != 8) @compileError("jlong is 8 bytes");
    if (@sizeOf(JFloat) != 4) @compileError("jfloat is 4 bytes");
    if (@sizeOf(JBoolean) != 1) @compileError("jboolean is 1 byte");
    if (@sizeOf(JClass) != @sizeOf(JObject)) @compileError("jclass is a typedef of jobject");
}

test "the table names 229 entry points and four reserved pointers sit in front" {
    try testing.expectEqual(@as(usize, 229), jni_slot_names.len);
    try testing.expectEqual(@as(usize, 4), reserved_slots);
    try testing.expectEqual(@as(usize, 233), jni_slot_count);
}

test "the slots the adapter reaches sit where the jni.h declaration puts them" {
    // Each row is a name and the position `jni.h` declares it at, counting the
    // four `reserved` pointers. A slot that moves is a wrong call on a device,
    // and nothing else on this host can see it.
    const expected = [_]struct { name: [:0]const u8, slot: usize }{
        .{ .name = "FindClass", .slot = 6 },
        .{ .name = "PushLocalFrame", .slot = 19 },
        .{ .name = "PopLocalFrame", .slot = 20 },
        .{ .name = "NewGlobalRef", .slot = 21 },
        .{ .name = "DeleteGlobalRef", .slot = 22 },
        .{ .name = "DeleteLocalRef", .slot = 23 },
        .{ .name = "NewObjectA", .slot = 30 },
        .{ .name = "IsInstanceOf", .slot = 32 },
        .{ .name = "GetMethodID", .slot = 33 },
        .{ .name = "CallObjectMethodA", .slot = 36 },
        .{ .name = "CallBooleanMethodA", .slot = 39 },
        .{ .name = "CallIntMethodA", .slot = 51 },
        .{ .name = "CallFloatMethodA", .slot = 57 },
        .{ .name = "CallVoidMethodA", .slot = 63 },
        .{ .name = "GetStaticMethodID", .slot = 113 },
        .{ .name = "CallStaticObjectMethodA", .slot = 116 },
        .{ .name = "GetStaticFieldID", .slot = 144 },
        .{ .name = "GetStaticObjectField", .slot = 145 },
        .{ .name = "NewString", .slot = 163 },
        .{ .name = "NewIntArray", .slot = 179 },
        .{ .name = "GetIntArrayRegion", .slot = 203 },
        .{ .name = "RegisterNatives", .slot = 215 },
        .{ .name = "NewWeakGlobalRef", .slot = 226 },
        .{ .name = "ExceptionCheck", .slot = 228 },
    };
    inline for (expected) |row| {
        try testing.expectEqual(row.slot, slotOf(row.name));
    }
    // `FindClass` is the third named slot and the seventh entry of the table,
    // which is the shape a reader checks against `jni.h:225`.
    try testing.expectEqualStrings(
        "FindClass",
        jni_slot_names[slot_find_class - reserved_slots],
    );
    try testing.expectEqualStrings(
        "RegisterNatives",
        jni_slot_names[slot_register_natives - reserved_slots],
    );
}

test "the first and last named slots are the ones jni.h declares first and last" {
    try testing.expectEqualStrings("GetVersion", jni_slot_names[0]);
    try testing.expectEqualStrings("GetObjectRefType", jni_slot_names[jni_named_slot_count - 1]);
    try testing.expectEqual(@as(usize, 0), slotOf("GetVersion") - reserved_slots);
    try testing.expectEqual(@as(usize, 232), slotOf("GetObjectRefType"));
}

test "the JNI scalars carry the widths jni_md.h gives" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(JInt));
    try testing.expectEqual(@as(usize, 8), @sizeOf(JLong));
    try testing.expectEqual(@as(usize, 4), @sizeOf(JFloat));
    try testing.expectEqual(@as(usize, 1), @sizeOf(JBoolean));
    try testing.expectEqual(@as(usize, 8), @sizeOf(JValue));
    try testing.expectEqual(@as(i32, 4), @sizeOf(JSize));
    try testing.expectEqual(@as(i32, 1), @sizeOf(JByte));
    try testing.expectEqual(@as(u16, 2), @sizeOf(JChar));
    try testing.expectEqual(@as(i16, 2), @sizeOf(JShort));
    try testing.expectEqual(@as(f64, 8), @sizeOf(JDouble));
    try testing.expectEqual(@sizeOf(JObject), @sizeOf(JValue));
}

test "a JValue carries each member at the width jni.h gives" {
    // `JObject` is `?*anyopaque`, so the expected value is a double optional and
    // the pointer needs its result type stated once.
    const pointer: JObject = @ptrFromInt(0x20);
    try testing.expectEqual(pointer, (JValue{ .l = pointer }).l);
    try testing.expectEqual(@as(JObject, null), (JValue{ .l = null }).l);
    try testing.expectEqual(@as(JInt, -7), (JValue{ .i = -7 }).i);
    try testing.expectEqual(@as(JLong, 1 << 40), (JValue{ .j = 1 << 40 }).j);
    try testing.expectEqual(@as(JFloat, 0.5), (JValue{ .f = 0.5 }).f);
    try testing.expectEqual(@as(JBoolean, 1), (JValue{ .z = 1 }).z);
    try testing.expectEqual(@as(JChar, 0x4e2d), (JValue{ .c = 0x4e2d }).c);
    try testing.expectEqual(@as(f64, 1.5), (JValue{ .d = 1.5 }).d);
    // The union is 8 bytes and its first byte is the narrow members' storage.
    const as_bytes: *const [8]u8 = @ptrCast(&JValue{ .i = 0 });
    try testing.expectEqual(@as(u8, 0), as_bytes[0]);
}

test "the real binding over a null environment answers the JNI default" {
    // A thread the VM has not attached is a state a caller can reach, so every
    // wrapper has to tolerate it rather than dereference the environment.
    const table = realTable(null);
    try testing.expectEqual(@as(JObject, null), table.findClass("android/view/View"));
    try testing.expectEqual(@as(JObject, null), table.getMethodId(null, "a", "()V"));
    try testing.expectEqual(@as(JObject, null), table.getStaticMethodId(null, "a", "()V"));
    try testing.expectEqual(@as(JObject, null), table.getStaticFieldId(null, "a", "Ljava/lang/String;"));
    try testing.expectEqual(@as(JObject, null), table.getStaticObjectField(null, null));
    try testing.expectEqual(@as(JObject, null), table.callObjectMethod(null, null, &.{}));
    try testing.expectEqual(@as(JObject, null), table.callStaticObjectMethod(null, null, &.{}));
    try testing.expectEqual(@as(JBoolean, 0), table.callBooleanMethod(null, null, &.{}));
    try testing.expectEqual(@as(JInt, 0), table.callIntMethod(null, null, &.{}));
    try testing.expectEqual(@as(JFloat, 0), table.callFloatMethod(null, null, &.{}));
    try testing.expectEqual(@as(JObject, null), table.newString("text"));
    try testing.expectEqual(@as(JObject, null), table.newObject(null, null, &.{}));
    try testing.expectEqual(@as(JObject, null), table.newIntArray(2));
    try testing.expectEqual(@as(JObject, null), table.newGlobalRef(null));
    try testing.expectEqual(@as(JObject, null), table.newWeakGlobalRef(null));
    try testing.expectEqual(@as(JInt, 0), table.pushLocalFrame(2));
    try testing.expectEqual(@as(JInt, 0), table.registerNativeMethods(null, &.{}));
    try testing.expectEqual(@as(JObject, null), table.popLocalFrame(null));
    try testing.expect(!table.isInstanceOf(null, null));
    try testing.expect(!table.exceptionCheck());
    // The five void wrappers must return rather than fault.
    table.callVoidMethod(null, null, &.{});
    table.deleteLocalRef(null);
    table.deleteGlobalRef(null);
    table.getIntArrayRegion(null, 0, 0, &.{});
}

test "the real binding over a null slot answers the JNI default too" {
    // `realTable` reads the environment as an array of function pointers, so a
    // zeroed array of the right length stands in for a VM whose slots are all
    // empty. Every field must answer its default rather than fault, because the
    // load is unchecked by design.
    const slots = try testing.allocator.alloc(?*const anyopaque, jni_slot_count);
    defer testing.allocator.free(slots);
    @memset(slots, null);

    const table = realTable(@ptrCast(slots.ptr));
    try testing.expectEqual(@as(JObject, null), table.findClass("android/view/View"));
    try testing.expectEqual(@as(JInt, 0), table.callIntMethod(null, null, &.{}));
    try testing.expectEqual(@as(JBoolean, 0), table.callBooleanMethod(null, null, &.{}));
    try testing.expectEqual(@as(JObject, null), table.newString("text"));
    try testing.expect(!table.exceptionCheck());
    table.callVoidMethod(null, null, &.{});
    table.deleteLocalRef(null);
}

/// Records the class names a substituted `findClass` is handed, so a test can
/// assert the exact spellings the adapter sends without a VM.
///
/// **Declared at file scope because a type declared inside a test cannot name
/// itself from within its own body**, and the recorder needs to cast the
/// environment back to its own type. Two recorders can be live at once, because
/// each reaches its own through `JniTable.env` and nothing here is global.
const TestRecorder = struct {
    /// How many times `findClass` was called.
    calls: usize = 0,
    /// The last class name handed over, as bytes.
    last_name: [128]u8 = @splat(0),
    /// How many bytes of `last_name` the last call wrote.
    last_name_len: usize = 0,

    fn findClass(env: JniEnv, name: [:0]const u8) JClass {
        const self: *TestRecorder = @constCast(@ptrCast(@alignCast(env.?)));
        self.calls += 1;
        @memcpy(self.last_name[0..name.len], name);
        self.last_name_len = name.len;
        return @ptrFromInt(0x1000);
    }
};

test "a substituted function reaches its own context through the environment" {
    // This is the whole reason the table is injectable: a test stands in a
    // JVM. The recorder is reached only because the method forwards `self.env`,
    // and it reads its context back out of that same value, so no global state
    // is involved and two recorders can run in one process.
    // One set of fields with the recorder swapped in, which is the shape a
    // caller fills when it records a call sequence. The sentinel is a typed
    // local because `JObject` is `?*anyopaque`.
    const sentinel: JObject = @ptrFromInt(0x1000);
    var template = inertTable(null);
    template.findClassFn = TestRecorder.findClass;

    var first = TestRecorder{};
    var second = TestRecorder{};
    const first_table = withRecorder(&template, &first);
    const second_table = withRecorder(&template, &second);

    const found = first_table.findClass("android/view/View");
    try testing.expectEqual(sentinel, found);
    try testing.expectEqual(@as(usize, 1), first.calls);
    try testing.expectEqualStrings(
        "android/view/View",
        first.last_name[0..first.last_name_len],
    );
    // A second table over the same fields reaches a different recorder, which
    // is what "no global state" has to mean in practice.
    try testing.expectEqual(sentinel, second_table.findClass("a/b/C"));
    try testing.expectEqual(@as(usize, 1), second.calls);
    try testing.expectEqual(@as(usize, 1), first.calls);
    try testing.expectEqualStrings("a/b/C", second.last_name[0..second.last_name_len]);
    // The fields the template left inert still answer the JNI default.
    try testing.expectEqual(@as(JObject, null), first_table.getMethodId(found, "getParent", "()V"));
    try testing.expectEqual(@as(JObject, null), first_table.newString("text"));
    try testing.expectEqual(@as(JBoolean, 0), first_table.callBooleanMethod(found, null, &.{}));
    try testing.expect(!first_table.isInstanceOf(found, null));
    try testing.expect(!first_table.exceptionCheck());
}

test "the real binding calls the function at the slot it indexes" {
    // `realTable` reads the environment as an array of 229 function pointers,
    // so filling one slot and leaving the rest empty exercises the slot
    // arithmetic with no VM present. A function reached through the real
    // binding cannot recover a context from the environment, because the
    // environment **is** the slot array; a caller that needs a context builds
    // the table as a literal instead, which is what the test above does.
    // The sentinel is a typed local because `JObject` is `?*anyopaque` and the
    // pointer needs its result type stated once.
    const sentinel: JObject = @ptrFromInt(0x2000);
    const Constant = struct {
        fn findClass(env: JniEnv, name: [:0]const u8) JClass {
            _ = env;
            _ = name;
            return sentinel;
        }
    };
    const slots = try testing.allocator.alloc(?*const anyopaque, jni_slot_count);
    defer testing.allocator.free(slots);
    @memset(slots, null);
    slots[slot_find_class] = @ptrCast(&Constant.findClass);

    const table = realTable(@ptrCast(slots.ptr));
    // The sentinel proves slot 6 was loaded and called through, because every
    // other slot is empty and answers `null`.
    try testing.expectEqual(sentinel, table.findClass("android/view/View"));
    // A slot one place either side of it is empty, so the index is exact.
    try testing.expectEqual(@as(JObject, null), table.getMethodId(null, "a", "()V"));
    try testing.expectEqual(@as(JInt, 0), table.callIntMethod(null, null, &.{}));
}

test "the inert table answers the JNI default without an environment" {
    // `inertTable` is what a caller holds before it has an environment, and
    // every method on it must answer a default rather than fault. It is the
    // documented way to stand in for a VM.
    const table = inertTable(@ptrFromInt(0x30));
    try testing.expectEqual(@as(JObject, null), table.findClass("android/view/View"));
    try testing.expectEqual(@as(JObject, null), table.getMethodId(null, "a", "()V"));
    try testing.expectEqual(@as(JObject, null), table.getStaticMethodId(null, "a", "()V"));
    try testing.expectEqual(@as(JObject, null), table.getStaticFieldId(null, "a", "Ljava/lang/String;"));
    try testing.expectEqual(@as(JObject, null), table.getStaticObjectField(null, null));
    try testing.expectEqual(@as(JObject, null), table.callObjectMethod(null, null, &.{}));
    try testing.expectEqual(@as(JObject, null), table.callStaticObjectMethod(null, null, &.{}));
    try testing.expectEqual(@as(JBoolean, 0), table.callBooleanMethod(null, null, &.{}));
    try testing.expectEqual(@as(JInt, 0), table.callIntMethod(null, null, &.{}));
    try testing.expectEqual(@as(JFloat, 0), table.callFloatMethod(null, null, &.{}));
    try testing.expectEqual(@as(JObject, null), table.newString("text"));
    try testing.expectEqual(@as(JObject, null), table.newObject(null, null, &.{}));
    try testing.expectEqual(@as(JObject, null), table.newIntArray(2));
    try testing.expectEqual(@as(JObject, null), table.newGlobalRef(null));
    try testing.expectEqual(@as(JObject, null), table.newWeakGlobalRef(null));
    try testing.expectEqual(@as(JInt, 0), table.pushLocalFrame(2));
    try testing.expectEqual(@as(JInt, 0), table.registerNativeMethods(null, &.{}));
    try testing.expectEqual(@as(JObject, null), table.popLocalFrame(null));
    try testing.expect(!table.isInstanceOf(null, null));
    try testing.expect(!table.exceptionCheck());
    table.callVoidMethod(null, null, &.{});
    table.deleteLocalRef(null);
    table.deleteGlobalRef(null);
    table.getIntArrayRegion(null, 0, 0, &.{});
}

test "a freshly allocated inert table answers the JNI default from every field" {
    // `inertTable` returns a value, so a caller may hold one on the heap as
    // easily as on the stack, and a heap table lands on storage nothing else in
    // this process has written. A field `inertTable` left `undefined` answers
    // whatever the allocator handed back rather than the JNI default, and the
    // default is the whole contract: only a field a caller substitutes may run,
    // and every other field must answer a value rather than fault. The test
    // above answers that contract from a stack table, so the two differ only in
    // where the table lives and that is what this one covers.
    const gpa = testing.allocator;
    const fresh = try gpa.create(JniTable);
    defer gpa.destroy(fresh);
    fresh.* = inertTable(@ptrFromInt(0x30));

    // One entry point per line, so a failure names one field.
    try testing.expectEqual(@as(JObject, null), fresh.findClass("android/view/View"));
    try testing.expectEqual(@as(JObject, null), fresh.getMethodId(null, "a", "()V"));
    try testing.expectEqual(@as(JObject, null), fresh.getStaticMethodId(null, "a", "()V"));
    try testing.expectEqual(
        @as(JObject, null),
        fresh.getStaticFieldId(null, "a", "Ljava/lang/String;"),
    );
    try testing.expectEqual(@as(JObject, null), fresh.getStaticObjectField(null, null));
    try testing.expectEqual(@as(JObject, null), fresh.callObjectMethod(null, null, &.{}));
    try testing.expectEqual(@as(JObject, null), fresh.callStaticObjectMethod(null, null, &.{}));
    try testing.expectEqual(@as(JBoolean, 0), fresh.callBooleanMethod(null, null, &.{}));
    try testing.expectEqual(@as(JInt, 0), fresh.callIntMethod(null, null, &.{}));
    try testing.expectEqual(@as(JFloat, 0), fresh.callFloatMethod(null, null, &.{}));
    try testing.expectEqual(@as(JObject, null), fresh.newString("text"));
    try testing.expectEqual(@as(JObject, null), fresh.newObject(null, null, &.{}));
    try testing.expectEqual(@as(JObject, null), fresh.newIntArray(2));
    try testing.expectEqual(@as(JObject, null), fresh.newGlobalRef(null));
    try testing.expectEqual(@as(JObject, null), fresh.newWeakGlobalRef(null));
    try testing.expectEqual(@as(JInt, 0), fresh.pushLocalFrame(2));
    try testing.expectEqual(@as(JInt, 0), fresh.registerNativeMethods(null, &.{}));
    try testing.expectEqual(@as(JObject, null), fresh.popLocalFrame(null));
    try testing.expect(!fresh.isInstanceOf(null, null));
    try testing.expect(!fresh.exceptionCheck());
    fresh.callVoidMethod(null, null, &.{});
    fresh.deleteLocalRef(null);
    fresh.deleteGlobalRef(null);
    fresh.getIntArrayRegion(null, 0, 0, &.{});
}

test "overriding one field of the inert table leaves the rest inert" {
    // This is the contract a test relies on when it records a call sequence:
    // it fills the fields it asserts and the others answer defaults rather
    // than faulting.
    // The recorder casts the environment straight to its counter rather than to
    // its own type, because a type declared inside this test cannot name itself
    // from within its own body. `calls` is therefore the first field, so the
    // cast lands on it.
    const Seen = struct {
        calls: usize = 0,

        fn callVoidMethod(env: JniEnv, obj: JObject, method: JMethodId, args: []const JValue) void {
            _ = obj;
            _ = method;
            _ = args;
            const counter: *usize = @constCast(@ptrCast(@alignCast(env.?)));
            counter.* += 1;
        }
    };
    var seen = Seen{};
    var table = inertTable(@ptrCast(&seen));
    table.callVoidMethodFn = Seen.callVoidMethod;
    table.callVoidMethod(null, null, &.{});
    try testing.expectEqual(@as(usize, 1), seen.calls);
    // The untouched field is still inert.
    try testing.expectEqual(@as(JObject, null), table.findClass("android/view/View"));
    try testing.expectEqual(@as(usize, 1), seen.calls);
}

test "the local frame capacity matches the value the census records" {
    const jni = @import("jni.zig");
    const values = @import("values.zig");
    try testing.expectEqual(jni.local_frame_capacity, values.LOCAL_FRAME_CAPACITY);
    try testing.expectEqual(@as(i32, 2), values.LOCAL_FRAME_CAPACITY);
    try testing.expectEqual(@as(usize, 512), local_char_capacity);
}

test "a JniNativeMethod is the C triple and nothing more" {
    // `jni.h:180-184` declares three pointers, and `registerNativeMethods`
    // takes a pointer and a count, so the row layout is fixed by the header.
    try testing.expectEqual(@as(usize, 24), @sizeOf(JNINativeMethod));
    const row = JNINativeMethod{
        .name = "runCallback",
        .signature = "(Landroid/view/View;J)V",
        .function = null,
    };
    try testing.expectEqualStrings("runCallback", std.mem.span(row.name));
    try testing.expectEqualStrings("(Landroid/view/View;J)V", std.mem.span(row.signature));
    try testing.expectEqual(@as(?*const anyopaque, null), row.function);
}