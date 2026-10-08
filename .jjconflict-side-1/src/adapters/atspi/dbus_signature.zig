//! Bounded D-Bus signature grammar, independent of the message codec.
//! The parser accepts Unix-fd type codes. The message codec decides whether it supports their values.

const std = @import("std");

pub const Error = error{ InvalidSignature, LimitExceeded };

const signature_size_max = 255;

/// Checks zero or more complete types. Dict entries must be direct array elements.
/// `max_depth` counts arrays, structs, and dict entries. Basic types and variants use no depth.
/// Returns `LimitExceeded` for a signature above 255 bytes or a container above the depth limit.
/// Returns `InvalidSignature` for malformed grammar.
pub fn validate(signature: []const u8, max_depth: usize) Error!void {
    try checkLength(signature);
    var position: usize = 0;
    while (position < signature.len) {
        position = try parseType(signature, position, max_depth, false, 0, 0);
    }
}

/// Checks exactly one complete type, with the same limits and dict rules as `validate`.
pub fn single(signature: []const u8, max_depth: usize) Error!void {
    const end = try typeEnd(signature, 0, max_depth);
    if (end != signature.len) return error.InvalidSignature;
}

/// Returns the exclusive end of one type at `start`. It does not check the remaining suffix.
/// The entire input must fit in 255 bytes. An invalid start returns `InvalidSignature`.
/// Dict entries are only valid as direct array elements within the parsed type.
pub fn typeEnd(signature: []const u8, start: usize, max_depth: usize) Error!usize {
    try checkLength(signature);
    return parseType(signature, start, max_depth, false, 0, 0);
}

/// Uses the `typeEnd` contract, but also accepts a dict entry at the parsed type's root.
/// Array encoders use this when they parse an element signature without its array prefix.
/// A root dict entry still uses one level of depth.
pub fn elementEnd(signature: []const u8, start: usize, max_depth: usize) Error!usize {
    try checkLength(signature);
    return parseType(signature, start, max_depth, true, 0, 0);
}

/// Returns wire alignment for a type code, or `InvalidSignature` for an unknown code.
/// Structs and dict entries use their opening delimiters, not the reserved `r` and `e` codes.
pub fn alignment(code: u8) Error!usize {
    return switch (code) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 's', 'o', 'h', 'a' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => error.InvalidSignature,
    };
}

/// Reports whether a code is a basic type and thus valid as a dict key.
pub fn basic(code: u8) bool {
    return switch (code) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h' => true,
        else => false,
    };
}

fn checkLength(signature: []const u8) Error!void {
    if (signature.len > signature_size_max) return error.LimitExceeded;
}

// Each recursive call consumes a token and container depth. The 255-byte bound also limits recursion.
fn parseType(
    signature: []const u8,
    start: usize,
    depth_left: usize,
    allow_dict: bool,
    array_depth: usize,
    struct_depth: usize,
) Error!usize {
    if (start >= signature.len) return error.InvalidSignature;
    const code = signature[start];
    if (basic(code)) return start + 1;
    switch (code) {
        'v' => return start + 1,
        'a' => {
            if (depth_left == 0 or array_depth == 32) return error.LimitExceeded;
            return parseType(signature, start + 1, depth_left - 1, true, array_depth + 1, struct_depth);
        },
        '(' => {
            if (depth_left == 0 or struct_depth == 32) return error.LimitExceeded;
            var position = start + 1;
            if (position >= signature.len) return error.InvalidSignature;
            if (signature[position] == ')') return error.InvalidSignature;
            while (position < signature.len) {
                if (signature[position] == ')') return position + 1;
                position = try parseType(signature, position, depth_left - 1, false, array_depth, struct_depth + 1);
            }
            return error.InvalidSignature;
        },
        '{' => {
            if (!allow_dict) return error.InvalidSignature;
            if (depth_left == 0 or struct_depth == 32) return error.LimitExceeded;
            const key_position = start + 1;
            if (key_position >= signature.len) return error.InvalidSignature;
            if (!basic(signature[key_position])) return error.InvalidSignature;
            const end = try parseType(
                signature,
                key_position + 1,
                depth_left - 1,
                false,
                array_depth,
                struct_depth + 1,
            );
            if (end >= signature.len) return error.InvalidSignature;
            if (signature[end] != '}') return error.InvalidSignature;
            return end + 1;
        },
        else => return error.InvalidSignature,
    }
}

// These fixtures distinguish complete signatures from a single complete type.
test "signature accepts all basic types variant and valid containers" {
    const signatures = [_][]const u8{
        "",      "ybnqiuxtdsoghv", "ay",        "av",        "(i)",           "(isv)",
        "a{sv}", "a{hv}",          "a{sa{sv}}", "a{sa(is)}", "(a{sv}(ii)av)", "aa{sv}",
        "a(is)", "a{g(ia{sv})}",
    };
    for (signatures) |signature| try validate(signature, 16);
    for ("ybnqiuxtdsoghv") |code| {
        const signature = [_]u8{code};
        try single(&signature, 0);
    }
    const complete_types = [_][]const u8{
        "ay",        "av",        "(i)",           "(isv)",  "a{sv}", "a{hv}",
        "a{sa{sv}}", "a{sa(is)}", "(a{sv}(ii)av)", "aa{sv}",
    };
    for (complete_types) |signature| try single(signature, 16);
}

// Malformed delimiters and misplaced dict entries must never become complete types.
test "signature rejects malformed grammar" {
    const signatures = [_][]const u8{
        "a",       "aa",       "()",       "(",       "(i",     "i)",      ")",      "(i))",  "(())",
        "{sv}",    "i{sv}",    "({sv})",   "a({sv})", "a{}",    "a{s}",    "a{sss}", "a{vs}", "a{asv}",
        "a{(i)v}", "a{{sv}v}", "a{s{sv}}", "a{sv",    "a{sv}}", "a{sv)i}", "a}",     "a()",   "r",
        "e",       "m",        "*",        "?",       "z",      " ",       "i\x00",  "\xff",
    };
    for (signatures) |signature| {
        try std.testing.expectError(error.InvalidSignature, validate(signature, 16));
        try std.testing.expectError(error.InvalidSignature, single(signature, 16));
    }
}

// A variant occupies one grammar token, regardless of the value it later carries.
test "signature depth counts arrays structs and dictionary entries" {
    try validate("", 0);
    try validate("iv", 0);
    try single("av", 1);
    try single("(v)", 1);
    try single("a{sv}", 2);
    try single("(a{sv})", 3);
    try single("a{sa{sv}}", 4);
    try std.testing.expectError(error.LimitExceeded, single("av", 0));
    try std.testing.expectError(error.LimitExceeded, single("(v)", 0));
    try std.testing.expectError(error.LimitExceeded, single("a{sv}", 1));
    try std.testing.expectError(error.LimitExceeded, single("(a{sv})", 2));
    try std.testing.expectError(error.LimitExceeded, single("a{sa{sv}}", 3));
    try std.testing.expectEqual(@as(usize, 4), try elementEnd("{sv}", 0, 1));
    try std.testing.expectError(error.LimitExceeded, elementEnd("{sv}", 0, 0));
}

// The parser reports a local boundary, without consuming the next complete type.
test "signature typeEnd returns exact boundaries and rejects invalid starts" {
    const signature = "(is)ua{sv}h";
    try std.testing.expectEqual(@as(usize, 4), try typeEnd(signature, 0, 2));
    try std.testing.expectEqual(@as(usize, 5), try typeEnd(signature, 4, 0));
    try std.testing.expectEqual(@as(usize, 10), try typeEnd(signature, 5, 2));
    try std.testing.expectEqual(@as(usize, 11), try typeEnd(signature, 10, 0));
    try std.testing.expectEqual(@as(usize, 1), try typeEnd("i?", 0, 0));
    try std.testing.expectError(error.InvalidSignature, typeEnd("", 0, 16));
    try std.testing.expectError(error.InvalidSignature, typeEnd("i", 1, 16));
    try std.testing.expectError(error.InvalidSignature, typeEnd("i", 2, 16));
    try std.testing.expectError(
        error.InvalidSignature,
        typeEnd("i", std.math.maxInt(usize), 16),
    );
    try std.testing.expectError(error.InvalidSignature, typeEnd("{sv}", 0, 16));
    try std.testing.expectError(error.InvalidSignature, typeEnd(signature, 6, 16));
}

// Array encoders parse an element separately; only its root may be a dict entry.
test "signature elementEnd allows only root or direct array dictionary entries" {
    try std.testing.expectEqual(@as(usize, 8), try elementEnd("{sa{sv}}u", 0, 3));
    try std.testing.expectEqual(@as(usize, 5), try elementEnd("i{sv}u", 1, 1));
    try std.testing.expectEqual(@as(usize, 3), try elementEnd("(i)u", 0, 1));
    try std.testing.expectEqual(@as(usize, 1), try elementEnd("v", 0, 0));
    const invalid = [_][]const u8{
        "{vs}",   "{asv}",   "{}",      "{s}", "{svv}", "{s{sv}}",
        "({sv})", "a({sv})", "{{sv}v}", "{sv", "{sv)",
    };
    for (invalid) |signature| {
        try std.testing.expectError(error.InvalidSignature, elementEnd(signature, 0, 16));
    }
}

// Empty and multi-type signatures are valid body signatures, not variant signatures.
test "signature single requires exactly one full type" {
    try std.testing.expectError(error.InvalidSignature, single("", 16));
    try std.testing.expectError(error.InvalidSignature, single("ii", 16));
    try std.testing.expectError(error.InvalidSignature, single("a{sv}i", 16));
    try std.testing.expectError(error.InvalidSignature, single("(i)(s)", 16));
}

// Length applies to every entry point, even when parsing only the first type.
test "signature enforces 255 byte bound" {
    const longest = [_]u8{'y'} ** 255;
    const oversized = [_]u8{'y'} ** 256;
    try validate(&longest, 0);
    try std.testing.expectEqual(@as(usize, 1), try typeEnd(&longest, 0, 0));
    try std.testing.expectEqual(@as(usize, 1), try elementEnd(&longest, 0, 0));
    try std.testing.expectError(error.LimitExceeded, validate(&oversized, 16));
    try std.testing.expectError(error.LimitExceeded, single(&oversized, 16));
    try std.testing.expectError(error.LimitExceeded, typeEnd(&oversized, 0, 16));
    try std.testing.expectError(error.LimitExceeded, elementEnd(&oversized, 0, 16));
    const longest_type = [_]u8{'('} ++ ([_]u8{'y'} ** 253) ++ [_]u8{')'};
    try single(&longest_type, 1);
    const array_chain = ([_]u8{'a'} ** 32) ++ [_]u8{'y'};
    try single(&array_chain, 32);
    try std.testing.expectError(error.LimitExceeded, single(&array_chain, 31));
}

// Exhaust all byte codes so unknown codes cannot accidentally acquire an alignment.
test "signature basic classification and alignment cover every byte" {
    for (0..256) |value| {
        const code: u8 = @intCast(value);
        const expected_basic = std.mem.indexOfScalar(u8, "ybnqiuxtdsogh", code) != null;
        try std.testing.expectEqual(expected_basic, basic(code));
        const expected_alignment: ?usize = switch (code) {
            'y', 'g', 'v' => 1,
            'n', 'q' => 2,
            'b', 'i', 'u', 's', 'o', 'h', 'a' => 4,
            'x', 't', 'd', '(', '{' => 8,
            else => null,
        };
        if (expected_alignment) |expected| {
            try std.testing.expectEqual(expected, try alignment(code));
        } else {
            try std.testing.expectError(error.InvalidSignature, alignment(code));
        }
    }
}

test "signature enforces independent specification nesting ceilings" {
    const arrays = ([_]u8{'a'} ** 33) ++ [_]u8{'u'};
    const structures = ([_]u8{'('} ** 33) ++ [_]u8{'u'} ++ ([_]u8{')'} ** 33);
    try std.testing.expectError(error.LimitExceeded, single(&arrays, 64));
    try std.testing.expectError(error.LimitExceeded, single(&structures, 64));
    const deepest = ([_]u8{'a'} ** 32) ++ ([_]u8{'('} ** 32) ++
        [_]u8{'u'} ++ ([_]u8{')'} ** 32);
    try single(&deepest, 64);
}
