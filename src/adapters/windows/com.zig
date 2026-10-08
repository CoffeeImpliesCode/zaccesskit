//! The COM object base the Windows adapter is built on.
//!
//! **What this file is.** The 120-odd lines of new Zig that
//! `docs/42-native-adapter-build-map.md` section 2.1.4 says have no upstream
//! counterpart. Upstream writes `#[implement(IRawElementProviderSimple, …)]`
//! and `windows::core::ComObject<T>` and gets refcounting, a vtable pointer,
//! three `IUnknown` thunks and a `QueryInterface` for free. Zig 0.16.0 ships
//! no `std.com`, so the port writes them.
//!
//! **Why this is the only new code on Windows.** The other three adapters'
//! extra code is three `extern` declarations, a table of constants and a JNI
//! wrapper. Windows is the only one that needs an object model, and this file
//! is that object model. It has no Windows dependency once the vtable types
//! come from zigwin32, so it is testable on this host, and `docs/42` section
//! 5.4 says so.
//!
//! **The layout, and why it is that shape.** COM gives a caller one pointer
//! per interface, and the first word of that pointer is the vtable. A COM
//! object that answers thirteen interfaces therefore holds thirteen vtable
//! words, one per interface, at consecutive offsets. This file stores them in
//! `words`, a tuple of interface pointers, and gives interface `i` the word
//! at offset `i * @sizeOf(usize)`. The words are distinct addresses, so a
//! caller holding interface `i` dispatches through interface `i`'s vtable and
//! a caller holding interface `j` through `j`'s, which is what COM requires.
//!
//! **The `IUnknown` thunks are generated per word.** `Release` arrives
//! through whichever interface pointer the caller holds, and it must get back
//! to the object. The object is the address `i * @sizeOf(usize)` below word
//! `i`, and the thunk has no way to learn `i` from the pointer alone, so
//! `baseVTable` emits one set of three thunks per word with `i` written into
//! each. A single shared set would need a backward scan, and a backward scan
//! over a pointer of no known provenance is the kind of guess this port does
//! not make.
//!
//! **What this file does not do.** It does not implement any of the thirteen
//! interfaces. `node.zig` writes those vtables, using `baseVTable` for the
//! `base` field of each.

const std = @import("std");
const bindings = @import("bindings.zig");

const win32 = bindings.win32;

/// The 128-bit identifier `QueryInterface` compares against.
pub const Guid = win32.zig.Guid;

/// The status a COM call returns.
pub const Hresult = bindings.Hresult;

/// The base interface every other interface starts with.
pub const IUnknown = bindings.IUnknown;

/// The identifier `QueryInterface` matches for `IUnknown` itself.
pub const iid_unknown = win32.system.com.IID_IUnknown;

/// One interface a `Object` answers for.
pub const Descriptor = struct {
    /// The interface type. Its `VTable` holds the methods, and the first
    /// field of that `VTable`, named `base`, holds the three `IUnknown`
    /// slots.
    Interface: type,

    /// The identifier `QueryInterface` matches for this interface. Take it
    /// from the binding, for example
    /// `win32.ui.accessibility.IID_IRawElementProviderSimple`.
    Iid: *const Guid,
};

/// A COM object: `Descriptors.len` vtable words, a reference count, an
/// allocator, and the state the thunks read.
///
/// `interfaces` is a tuple of `Descriptor` **values**, one per implemented
/// interface, in the order the words are laid out. Word `i` holds
/// `Descriptors[i]`, so the tuple order is the ABI order and a caller that
/// reorders it silently re-points every interface. The parameter takes the
/// tuple by value rather than its type because Zig 0.16.0 builds an
/// anonymous struct literal into a value: a tuple *type* carries no `.len`
/// and cannot be indexed, so a type parameter could not read a single
/// descriptor.
///
/// **The allocator.** Final Release calls the state's optional `deinit` method
/// and frees the object through `gpa`. The allocator must outlive all clients.
/// State cleanup must be infallible. Construction transfers state only on
/// success, so the caller releases its state if allocation fails.
///
/// **The reference count.** It starts at one. `addRef` and `release` are the
/// only two ways it changes, so a count that is not one after `create` means
/// a caller reached the object without holding a reference.
pub fn Object(comptime StateType: type, comptime interfaces: anytype) type {
    // An object that answers for nothing has no word to hang the three
    // `IUnknown` thunks on, so the count is checked before the type is
    // formed. The bound itself is declared on the returned struct, as
    // `interface_count`, which is the name every use in the struct and every
    // caller outside it reads. There is one declaration of it, so no use in
    // the struct can pick up a second, different count.
    comptime std.debug.assert(interfaces.len > 0);
    comptime {
        const info = @typeInfo(@TypeOf(interfaces)).@"struct";
        std.debug.assert(info.is_tuple);
        for (0..interfaces.len) |index| {
            std.debug.assert(@TypeOf(interfaces[index]) == Descriptor);
        }
    }

    return struct {
        const Self = @This();

        /// The type of the state the thunks read. It is whatever the caller
        /// needs and nothing more.
        pub const State = StateType;

        /// The descriptor tuple this object was formed from. A caller reads
        /// it to find the index of the interface it holds.
        pub const Descriptors = interfaces;

        /// How many interfaces this object answers for, and the bound every
        /// walk over `Descriptors` uses.
        ///
        /// The derivation is one word per interface of `Descriptors`, and
        /// `Descriptors` is a tuple literal, so the count is its length. The
        /// type is formed once, so the count is a `comptime` value and never
        /// a run-time one.
        pub const interface_count = interfaces.len;

        /// The vtable words, one per interface, at consecutive offsets. Word
        /// zero is at offset zero, so the object address and the first
        /// interface pointer are the same word.
        words: [interface_count]IUnknown,

        /// How many holders there are. Starts at one.
        ref_count: std.atomic.Value(u32),

        /// The allocator that grew this object.
        gpa: std.mem.Allocator,

        /// The state the thunks read. Written once at construction and never
        /// changed, so a thunk that holds it observes one value for the whole
        /// life of the object.
        state: State,

        /// Allocates an object whose interface `i` dispatches through
        /// `vtables[i]`.
        ///
        /// `vtables[i]` must be a `*const T` for `Descriptors[i].Interface`,
        /// and its `base` field must be `baseVTable(i)`. The caller writes
        /// both, because the method slots belong to the caller's interface.
        ///
        /// The object starts with one holder. The caller releases that holder
        /// once. A caller that hands the object to a platform call hands over
        /// that holder and does not release it again.
        ///
        /// The state is moved into the object. Nothing is copied.
        ///
        /// Fails with `error.OutOfMemory` only when the allocator refuses.
        /// There is no other fallible step, so `errdefer` runs only on that
        /// path.
        pub fn create(
            gpa: std.mem.Allocator,
            vtables: [interface_count]*const anyopaque,
            state: State,
        ) std.mem.Allocator.Error!*Self {
            const object = try gpa.create(Self);
            for (&object.words, 0..) |*word, index| {
                word.* = .{ .vtable = @ptrCast(@alignCast(vtables[index])) };
            }
            object.ref_count = .init(1);
            object.gpa = gpa;
            object.state = state;
            return object;
        }

        /// The `IUnknown` vtable for word `index`.
        ///
        /// The caller puts this in the `base` field of the interface vtable
        /// at the same index, so `Release` arriving through that interface
        /// reaches the object by the one route that does not have to guess.
        ///
        /// Each call answers a fresh value holding the same three function
        /// pointers, so two vtables may share one base and neither becomes
        /// writable through the other.
        pub fn baseVTable(comptime index: comptime_int) IUnknown.VTable {
            comptime std.debug.assert(index >= 0);
            comptime std.debug.assert(index < interface_count);
            return .{
                .QueryInterface = queryInterfaceThunkFor(index),
                .AddRef = addRefThunkFor(index),
                .Release = releaseThunkFor(index),
            };
        }

        /// The index of `Interface` in the descriptor tuple, or `null` when
        /// the object does not answer for it.
        ///
        /// The tuple is fixed when the type is formed, so a `null` answer is a
        /// caller error rather than a run-time state.
        pub fn indexOf(comptime Interface: type) ?comptime_int {
            comptime {
                var found: ?comptime_int = null;
                for (Descriptors, 0..) |descriptor, candidate| {
                    if (descriptor.Interface == Interface) found = candidate;
                }
                return found;
            }
        }

        /// One more holder. Answers the count after the change.
        ///
        /// The count is a `u32` and is not bounded. An `addRef` on a count
        /// that has reached `std.math.maxInt(u32)` is a caller error this port
        /// does not police, because COM does not police it either.
        pub fn addRef(self: *Self) u32 {
            return self.ref_count.fetchAdd(1, .acq_rel) + 1;
        }

        /// Releases one reference. Final Release destroys state and object.
        /// The caller must not read the object after a zero result.
        pub fn release(self: *Self) u32 {
            const previous = self.ref_count.fetchSub(1, .acq_rel);
            std.debug.assert(previous > 0);
            if (previous != 1) return previous - 1;
            const gpa = self.gpa;
            if (@hasDecl(State, "deinit")) self.state.deinit();
            gpa.destroy(self);
            return 0;
        }

        /// The interface pointer for word `index`. For word zero it is also
        /// the object address.
        ///
        /// The result is `*const`, because a caller may dispatch through the
        /// interface but must not write the vtable word.
        pub fn iface(self: *Self, comptime index: comptime_int) *const IUnknown {
            comptime std.debug.assert(index >= 0);
            comptime std.debug.assert(index < interface_count);
            return &self.words[index];
        }

        /// The object behind an interface pointer.
        ///
        /// `Interface` must be one of the descriptors, because the index is
        /// how the address is recovered. Any other type fails to compile
        /// rather than reading a wrong address.
        pub fn fromIface(comptime Interface: type, pointer: *const IUnknown) *Self {
            const index = comptime indexOf(Interface) orelse
                @compileError("the object does not implement " ++ @typeName(Interface));
            comptime std.debug.assert(index >= 0);
            comptime std.debug.assert(index < interface_count);
            return objectAt(index, pointer);
        }

        /// The object that holds word `index`.
        ///
        /// `words` is the first field of the object, so the object address is
        /// `index` words below the word a caller holds. `index` is a
        /// compile-time constant, so the offset costs nothing at run time and
        /// no scan of unknown memory is needed: this is the one place the
        /// address is recovered, and `fromIface` and the three thunks all
        /// call it.
        fn objectAt(comptime index: comptime_int, word: *const IUnknown) *Self {
            comptime std.debug.assert(index >= 0);
            comptime std.debug.assert(index < interface_count);
            const bytes: [*]u8 = @ptrCast(@constCast(word));
            return @ptrCast(@alignCast(bytes - index * @sizeOf(IUnknown)));
        }

        /// The answer to `QueryInterface` arriving at word `index`.
        ///
        /// Compares `riid` against every identifier the object answers for,
        /// including `IID_IUnknown`. A match writes the interface pointer
        /// through `ppv` and adds a holder, which is what COM requires of a
        /// success. A miss answers `E_NOINTERFACE` and writes nothing at all,
        /// which is what COM requires of a miss, so the caller's out-parameter
        /// is left as it found it and must not be read.
        ///
        /// A `null` `ppv` answers `E_INVALIDARG` and writes nothing.
        ///
        /// `ppv` is optional because COM lets a caller pass `NULL` there.
        /// The binding's slot type is `**anyopaque`
        /// (`zigwin32/win32/system/com.zig:5241`), which is not optional, so
        /// the thunk coerces the ABI value into this parameter. A caller that
        /// holds the ABI value therefore cannot hand this function a `null`,
        /// and that is the one case the `E_INVALIDARG` branch does not reach.
        pub fn queryInterface(
            self: *Self,
            comptime index: comptime_int,
            riid: *const Guid,
            ppv: ?**anyopaque,
        ) Hresult {
            comptime std.debug.assert(index >= 0);
            comptime std.debug.assert(index < interface_count);
            const slot = ppv orelse return e_invalidarg();
            const requested = guidBytes(riid);
            if (std.mem.eql(u8, requested, guidBytes(iid_unknown))) {
                slot.* = @ptrCast(@constCast(self.iface(0)));
                _ = self.addRef();
                return s_ok();
            }
            inline for (Descriptors, 0..) |descriptor, candidate| {
                if (std.mem.eql(u8, requested, guidBytes(descriptor.Iid))) {
                    slot.* = @ptrCast(@constCast(self.iface(candidate)));
                    _ = self.addRef();
                    return s_ok();
                }
            }
            return e_nointerface();
        }

        /// `QueryInterface` as word `index` receives it.
        fn queryInterfaceThunkFor(comptime index: comptime_int) *const fn (
            *const IUnknown,
            *const Guid,
            **anyopaque,
        ) callconv(.winapi) Hresult {
            comptime std.debug.assert(index >= 0);
            comptime std.debug.assert(index < interface_count);
            const Outer = Self;
            return struct {
                fn thunk(
                    word: *const IUnknown,
                    riid: *const Guid,
                    ppv: **anyopaque,
                ) callconv(.winapi) Hresult {
                    return Outer.objectAt(index, word).queryInterface(index, riid, ppv);
                }
            }.thunk;
        }

        /// `AddRef` as word `index` receives it.
        fn addRefThunkFor(
            comptime index: comptime_int,
        ) *const fn (*const IUnknown) callconv(.winapi) u32 {
            comptime std.debug.assert(index >= 0);
            comptime std.debug.assert(index < interface_count);
            const Outer = Self;
            return struct {
                fn thunk(word: *const IUnknown) callconv(.winapi) u32 {
                    return Outer.objectAt(index, word).addRef();
                }
            }.thunk;
        }

        /// `Release` as word `index` receives it.
        fn releaseThunkFor(
            comptime index: comptime_int,
        ) *const fn (*const IUnknown) callconv(.winapi) u32 {
            comptime std.debug.assert(index >= 0);
            comptime std.debug.assert(index < interface_count);
            const Outer = Self;
            return struct {
                fn thunk(word: *const IUnknown) callconv(.winapi) u32 {
                    return Outer.objectAt(index, word).release();
                }
            }.thunk;
        }

        /// The identifier bytes, so two identifiers compare with `mem.eql`
        /// rather than with `==` on a union that declares no equality.
        fn guidBytes(identifier: *const Guid) *const [16]u8 {
            return &identifier.Bytes;
        }

        /// `S_OK`, the status a successful COM call returns.
        fn s_ok() Hresult {
            return @bitCast(@as(u32, @bitCast(win32.foundation.S_OK)));
        }

        /// `E_INVALIDARG`, the status for an absent out-parameter.
        fn e_invalidarg() Hresult {
            return @bitCast(@as(u32, @bitCast(win32.foundation.E_INVALIDARG)));
        }

        /// `E_NOINTERFACE`, the status for an identifier this object does not
        /// answer.
        fn e_nointerface() Hresult {
            return @bitCast(@as(u32, @bitCast(win32.foundation.E_NOINTERFACE)));
        }
    };
}

// --- Tests -----------------------------------------------------------------

// Every test below releases its holders on the success path and frees the
// object on the failure path. The release is the assertion that the count
// reached zero, and a `defer` body may not `try`, so it cannot live in a
// `defer`. This is the shape "add and release move the count" already uses.

// The elements are spelled `Descriptor{...}` and not `.{}`: a bare `.{}` with
// named fields builds a new anonymous struct type, so a bare `.{}` element
// would not be a `Descriptor` and the check in `Object` would refuse it.
const test_interfaces = .{
    Descriptor{
        .Interface = bindings.IRawElementProviderSimple,
        .Iid = win32.ui.accessibility.IID_IRawElementProviderSimple,
    },
    Descriptor{
        .Interface = bindings.IToggleProvider,
        .Iid = win32.ui.accessibility.IID_IToggleProvider,
    },
    Descriptor{
        .Interface = bindings.IInvokeProvider,
        .Iid = win32.ui.accessibility.IID_IInvokeProvider,
    },
};

const TestNode = Object(TestState, test_interfaces);

const TestState = struct {
    tree_id: u64,
    node_id: struct { value: u64 },
};

/// The thirteen vtables a real `PlatformNode` would pass to `create`. The
/// tests need one set per descriptor and the methods are irrelevant here, so
/// each word gets the `IUnknown` vtable for its index, which is a valid
/// `*const anyopaque`.
fn testVTables(comptime Type: type) [Type.interface_count]*const anyopaque {
    comptime var tables: [Type.interface_count]*const anyopaque = undefined;
    comptime {
        var index: usize = 0;
        while (index < tables.len) : (index += 1) {
            tables[index] = @ptrCast(&com_test_base_vtables[index]);
        }
    }
    return tables;
}

const com_test_base_vtables = blk: {
    var out: [test_interfaces.len]IUnknown.VTable = undefined;
    for (&out, 0..) |*slot, index| {
        slot.* = TestNode.baseVTable(index);
    }
    break :blk out;
};

fn releaseTestReferences(object: *TestNode) void {
    const count = object.ref_count.load(.monotonic);
    std.debug.assert(count <= TestNode.interface_count + 1);
    for (0..count) |_| _ = object.release();
}

test "the words sit one pointer apart and the first word is the object" {
    // The design needs two things and no third: the words begin at offset
    // zero, and each word is one pointer wide. Nothing needs `ref_count` to
    // follow the words, and a plain `struct` reorders its fields, so the
    // earlier assertion that the two were adjacent tested the field order
    // rather than the layout this object depends on.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(TestNode, "words"));
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(IUnknown));
    try std.testing.expectEqual(
        TestNode.interface_count * @sizeOf(usize),
        @sizeOf(@FieldType(TestNode, "words")),
    );
}

test "a fresh object holds one reference and reads back the state it was given" {
    if (comptime bindings.winapi_resolves) {
        const object = try TestNode.create(std.testing.allocator, testVTables(TestNode), .{
            .tree_id = 3,
            .node_id = .{ .value = 9 },
        });
        var held = true;
        defer if (held) releaseTestReferences(object);
        try std.testing.expectEqual(@as(u32, 1), object.ref_count.load(.monotonic));
        try std.testing.expectEqual(@as(u64, 3), object.state.tree_id);
        try std.testing.expectEqual(@as(u64, 9), object.state.node_id.value);

        held = false;
        try std.testing.expectEqual(@as(u32, 0), object.release());
    } else return error.SkipZigTest;
}

test "add and release move the count and stop at one" {
    if (comptime bindings.winapi_resolves) {
        const object = try TestNode.create(std.testing.allocator, testVTables(TestNode), .{
            .tree_id = 1,
            .node_id = .{ .value = 2 },
        });
        var held = true;
        defer if (held) releaseTestReferences(object);

        try std.testing.expectEqual(@as(u32, 2), object.addRef());
        try std.testing.expectEqual(@as(u32, 3), object.addRef());
        try std.testing.expectEqual(@as(u32, 2), object.release());
        try std.testing.expectEqual(@as(u32, 1), object.release());
        held = false;
        try std.testing.expectEqual(@as(u32, 0), object.release());
    } else return error.SkipZigTest;
}

test "an interface pointer reads back to the object that holds it" {
    if (comptime bindings.winapi_resolves) {
        const object = try TestNode.create(std.testing.allocator, testVTables(TestNode), .{
            .tree_id = 7,
            .node_id = .{ .value = 8 },
        });
        var held = true;
        defer if (held) releaseTestReferences(object);

        inline for (test_interfaces, 0..) |descriptor, index| {
            const word = object.iface(index);
            const found = TestNode.fromIface(descriptor.Interface, word);
            try std.testing.expectEqual(object, found);
            try std.testing.expectEqual(word, found.iface(index));
        }

        held = false;
        try std.testing.expectEqual(@as(u32, 0), object.release());
    } else return error.SkipZigTest;
}

test "QueryInterface answers each implemented identifier and holds a reference" {
    if (comptime bindings.winapi_resolves) {
        const object = try TestNode.create(std.testing.allocator, testVTables(TestNode), .{
            .tree_id = 5,
            .node_id = .{ .value = 6 },
        });
        var held = true;
        defer if (held) releaseTestReferences(object);

        var out: ?*anyopaque = null;
        const status = object.queryInterface(0, iid_unknown, @ptrCast(&out));
        try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(status)));
        try std.testing.expectEqual(@as(u32, 2), object.ref_count.load(.monotonic));
        const first: *anyopaque = @ptrCast(@constCast(object.iface(0)));
        try std.testing.expect(out.? == first);

        out = null;
        const second = object.queryInterface(0, test_interfaces[1].Iid, @ptrCast(&out));
        try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(second)));
        try std.testing.expectEqual(@as(u32, 3), object.ref_count.load(.monotonic));
        const toggle: *anyopaque = @ptrCast(@constCast(object.iface(1)));
        try std.testing.expect(out.? == toggle);

        // Each match added a holder, so the count drops back to zero in three
        // steps: the two `QueryInterface` successes and the one `create`
        // handed out.
        try std.testing.expectEqual(@as(u32, 2), object.release());
        try std.testing.expectEqual(@as(u32, 1), object.release());
        held = false;
        try std.testing.expectEqual(@as(u32, 0), object.release());
    } else return error.SkipZigTest;
}

test "QueryInterface refuses an identifier the object does not answer" {
    if (comptime bindings.winapi_resolves) {
        const object = try TestNode.create(std.testing.allocator, testVTables(TestNode), .{
            .tree_id = 2,
            .node_id = .{ .value = 1 },
        });
        var held = true;
        defer if (held) releaseTestReferences(object);

        var out: ?*anyopaque = @ptrFromInt(0xdead);
        const asked = win32.ui.accessibility.IID_ISelectionProvider;
        const status = object.queryInterface(0, asked, @ptrCast(&out));
        try std.testing.expectEqual(@as(u32, 0x80004002), @as(u32, @bitCast(status)));
        try std.testing.expect(out.? == @as(*anyopaque, @ptrFromInt(0xdead)));
        try std.testing.expectEqual(@as(u32, 1), object.ref_count.load(.monotonic));

        held = false;
        try std.testing.expectEqual(@as(u32, 0), object.release());
    } else return error.SkipZigTest;
}

test "the base vtable of each word reaches the object through that word" {
    // The three thunks are generated per word. This drives them through a
    // function pointer the way a COM caller would, so a thunk that recovered
    // the wrong word would move a different object's count.
    if (comptime bindings.winapi_resolves) {
        const object = try TestNode.create(std.testing.allocator, testVTables(TestNode), .{
            .tree_id = 11,
            .node_id = .{ .value = 12 },
        });
        var held = true;
        defer if (held) releaseTestReferences(object);

        const second = com_test_base_vtables[1];
        try std.testing.expectEqual(@as(u32, 2), second.AddRef(object.iface(1)));
        try std.testing.expectEqual(@as(u32, 1), second.Release(object.iface(1)));

        const first = com_test_base_vtables[0];
        try std.testing.expectEqual(@as(u32, 2), first.AddRef(object.iface(0)));
        try std.testing.expectEqual(@as(u32, 1), first.Release(object.iface(0)));

        held = false;
        try std.testing.expectEqual(@as(u32, 0), object.release());
    } else return error.SkipZigTest;
}

test "the descriptor tuple fixes the word order" {
    try std.testing.expectEqual(
        @as(?comptime_int, 0),
        TestNode.indexOf(bindings.IRawElementProviderSimple),
    );
    try std.testing.expectEqual(@as(?comptime_int, 1), TestNode.indexOf(bindings.IToggleProvider));
    try std.testing.expectEqual(@as(?comptime_int, 2), TestNode.indexOf(bindings.IInvokeProvider));
    try std.testing.expect(TestNode.indexOf(bindings.ISelectionProvider) == null);
}

test "final COM Release destroys owned state exactly once" {
    if (comptime bindings.winapi_resolves) {
        const OwnedState = struct {
            drops: *u32,

            pub fn deinit(self: *@This()) void {
                self.drops.* += 1;
            }
        };
        const OwnedObject = Object(OwnedState, .{test_interfaces[0]});
        const table = OwnedObject.baseVTable(0);
        var drops: u32 = 0;
        const object = try OwnedObject.create(std.testing.allocator, .{&table}, .{
            .drops = &drops,
        });
        // On the old implementation only, free the still-live object after the
        // assertion fails. The fixed implementation owns final destruction.
        defer if (drops == 0) std.testing.allocator.destroy(object);
        const client = object.iface(0);
        try std.testing.expectEqual(@as(u32, 2), client.vtable.AddRef(client));
        try std.testing.expectEqual(@as(u32, 1), client.vtable.Release(client));
        try std.testing.expectEqual(@as(u32, 0), drops);
        try std.testing.expectEqual(@as(u32, 0), client.vtable.Release(client));
        try std.testing.expectEqual(@as(u32, 1), drops);
    } else return error.SkipZigTest;
}
