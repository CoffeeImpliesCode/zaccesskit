//! The deterministic generator every harness case draws from.
//!
//! **Why a generator and not the standard library's.** `std.testing.fuzz` owns
//! its own entropy and a replay needs the exact byte string the fuzzer
//! produced. The seeded sweeps in this harness need the opposite: the same
//! sequence on every run and on every host, so that a case number names the
//! same inputs everywhere and a failure is reproducible from the seed alone.
//! `SplitMix64` is the generator because it is 12 lines, has no state beyond
//! one `u64`, and is specified exactly, so the sequence is reproducible from
//! this file and not from a library version.
//!
//! **What it is not.** This module reads no clock, holds no file-scope
//! variable, and allocates nothing. The seed is a parameter and the state
//! travels in the `Random` value.
//!
//! **Reproducing a case.** The sweeps print the seed they used. Start the
//! same run with that seed and the same case number reaches the same inputs,
//! because `Random.below` and `Random.atMost` are pure functions of the state
//! and the case index chooses how many draws precede them.
//!
//! **Bounds.** Every walk over a domain in this module is bounded by the
//! caller-named `bound` parameter, and `below` and `atMost` reject a zero
//! bound with an assertion instead of dividing by it. The walk that discards
//! a biased draw is bounded by `rejection_limit`, and spending that budget is
//! `error.TooManyRejectedDraws`.

const std = @import("std");

const assert = std.debug.assert;

/// The seed every sweep starts from unless the caller names another.
///
/// The value is fixed in the file so that the default run is reproducible from
/// the source alone. A caller that wants a different sequence names it.
pub const default_seed: u64 = 0x5eed_0f7e_5eed_0f7e;

/// The golden ratio constant of `SplitMix64`, from `std.math` of the standard
/// library. It is written here rather than imported so that the sequence does
/// not move when the standard library renames a constant.
const golden_gamma: u64 = 0x9e37_79b9_7f4a_7c15;

/// The draws `below` may discard before it names `error.TooManyRejectedDraws`.
///
/// A domain of `n` members discards one draw in about `2^64 / n`, so the widest
/// domain this harness walks discards one draw in about `2^57`. The budget is
/// a name for the walk and not a safety claim, because a caller that wants a
/// different budget names its own at `Random.belowWithin`.
const rejection_limit: usize = 128;

/// The failures a draw served by a `Random` can name.
///
/// **`error.TooManyRejectedDraws`** is the exhaustion of the bounded walk in
/// `Random.belowWithin`: every attempt landed in the remainder `2^64 mod bound`,
/// so the walk served no member. `below` hands that walk `rejection_limit`
/// attempts, which a domain of the size this harness admits cannot spend, and
/// a caller that wants to reach the error names its own budget.
pub const DrawError = error{
    /// The walk spent every attempt it was given and served no member.
    TooManyRejectedDraws,
};

/// A seeded source of 64-bit draws.
///
/// One value carries the state. Two values with the same seed produce the same
/// sequence, and a copy of a value continues the sequence of its source.
pub const Random = struct {
    /// The `SplitMix64` state. Every draw replaces it.
    state: u64,
    /// How many draws this value has served. A case number is this counter,
    /// so it names the position in the sequence rather than the inputs.
    drawn: u64,

    /// The sequence that starts at `seed`.
    pub fn init(seed: u64) Random {
        return .{ .state = seed, .drawn = 0 };
    }

    /// The next 64 bits, and the state one step on.
    ///
    /// The step is the `SplitMix64` increment and the output is the Weyl
    /// sequence applied to the incremented state, then the output is advanced
    /// once more. The arithmetic wraps on purpose: a generator that trapped on
    /// overflow would not be a generator.
    pub fn next(self: *Random) u64 {
        self.state +%= golden_gamma;
        self.drawn += 1;
        var word = self.state;
        word = (word ^ (word >> 30)) *% 0xbf58_476d_1ce4_e5b9;
        word = (word ^ (word >> 27)) *% 0x94d0_49bb_1331_11eb;
        return word ^ (word >> 31);
    }

    /// A draw in `0..bound`.
    ///
    /// `bound` is the caller's name for the size of the domain it is walking,
    /// so the assertion on a zero bound names the caller that lost it. The
    /// result carries no modulo bias: the 64 bits of a draw are multiplied by
    /// `bound`, and the high half of that product is the member, because the
    /// product scales every member of the range into the same number of
    /// draws. `2^64` is not a multiple of `bound`, so the first
    /// `2^64 mod bound` members are each served one draw too many. A product
    /// whose low half lands inside that remainder is one of those extra draws,
    /// so it is thrown away and another is taken. The walk is bounded by
    /// `rejection_limit`, and spending that budget is
    /// `error.TooManyRejectedDraws` rather than a hang.
    pub fn below(self: *Random, bound: usize) DrawError!usize {
        return self.belowWithin(bound, rejection_limit);
    }

    /// A draw in `0..bound` that discards at most `limit` draws.
    ///
    /// `limit` is a comptime parameter so a caller names the budget on its own
    /// walk rather than taking the module's. A sweep that wants to see the
    /// exhaustion names `1`, which a domain of `2^63 + 1` members reaches on
    /// its first discarded draw, so `error.TooManyRejectedDraws` is a value a
    /// test reaches rather than a claim one makes.
    pub fn belowWithin(self: *Random, bound: usize, comptime limit: usize) DrawError!usize {
        assert(bound > 0);
        // `2^64 mod bound` without a 128-bit division: `(2^64 - 1) mod bound`
        // plus one, folded back when that lands on `bound` itself.
        const modulus: usize = ((~@as(usize, 0)) % bound +% 1) % bound;
        var attempt: usize = 0;
        while (attempt < limit) : (attempt += 1) {
            const draw: usize = self.next();
            const product: u128 = @as(u128, draw) * @as(u128, bound);
            const low: usize = @truncate(product);
            if (low >= modulus) return @intCast(product >> 64);
        }
        return error.TooManyRejectedDraws;
    }

    /// A draw in `0..=bound`, where `bound` is a member of the domain.
    ///
    /// The walk over the domain is `bound + 1` wide, which is the name the
    /// caller uses for the count of members it is choosing from.
    /// `error.TooManyRejectedDraws` means what it means in `below`.
    pub fn atMost(self: *Random, bound: u32) DrawError!u32 {
        return @intCast(try self.below(@as(usize, bound) + 1));
    }

    /// One bit.
    pub fn flag(self: *Random) bool {
        return self.next() & 1 == 1;
    }

    /// A `f64` from the generator's bits, cast from the whole range.
    ///
    /// The cast can produce a NaN or an infinity, and both are legal payloads:
    /// `Affine.inverse` answers NaN for a singular map and no operation in the
    /// schema layer rejects a non-finite coefficient.
    pub fn real(self: *Random) f64 {
        const bits: u64 = self.next();
        return @as(f64, @floatFromInt(bits >> 11)) * 0x1p-53;
    }

    /// A `u8` that is not one of the members of a domain `size` wide.
    ///
    /// The domain here is a byte, so the draw is in `size..256`, and the walk
    /// is bounded by `256 - size`. A `size` of 256 leaves no byte and is an
    /// assertion, because every byte would then be a member.
    /// `error.TooManyRejectedDraws` means what it means in `below`.
    pub fn above(self: *Random, size: u16) DrawError!u8 {
        assert(size < 256);
        const span: usize = 256 - @as(usize, size);
        return @intCast(@as(usize, size) + try self.below(span));
    }
};

test "the same seed serves the same sequence" {
    var one = Random.init(default_seed);
    var two = Random.init(default_seed);
    var step: usize = 0;
    while (step < 64) : (step += 1) {
        try std.testing.expectEqual(one.next(), two.next());
    }
    try std.testing.expectEqual(@as(u64, 64), one.drawn);
}

test "two seeds serve two sequences" {
    var one = Random.init(default_seed);
    var two = Random.init(default_seed +% 1);
    try std.testing.expect(one.next() != two.next());
}

test "a draw reaches both ends of the domain and stays inside it" {
    var source = Random.init(default_seed);
    var seen_low = false;
    var seen_high = false;
    var step: usize = 0;
    while (step < 4096) : (step += 1) {
        const draw = try source.below(87);
        try std.testing.expect(draw < 87);
        if (draw == 0) seen_low = true;
        if (draw == 86) seen_high = true;
    }
    try std.testing.expect(seen_low);
    try std.testing.expect(seen_high);
}

test "a draw above a domain names no member of it" {
    var source = Random.init(default_seed);
    var step: usize = 0;
    while (step < 4096) : (step += 1) {
        const draw = try source.above(87);
        try std.testing.expect(draw >= 87);
    }
}

test "a walk that discards every draw it is given names its exhaustion" {
    // `2^63 + 1` is the widest domain a `usize` carries whose remainder
    // `2^64 mod bound` is widest too, at `2^63 - 1`, so half of the draws land
    // inside it. The first draw from seed 0 is one of them, so a budget of one
    // attempt spends itself on that draw and serves no member.
    var source = Random.init(0);
    try std.testing.expectError(
        error.TooManyRejectedDraws,
        source.belowWithin((@as(usize, 1) << 63) + 1, 1),
    );
    // A discarded draw is a draw the state served, so the counter names it
    // even though no member came back.
    try std.testing.expectEqual(@as(u64, 1), source.drawn);
}

test "every DrawError member is the exhaustion the bounded walk names" {
    const members = @typeInfo(DrawError).error_set.?;
    try std.testing.expectEqual(@as(usize, 1), members.len);
    inline for (members) |member| {
        try std.testing.expectEqualStrings("TooManyRejectedDraws", member.name);
    }
}

test "real draws stay in the half-open unit interval" {
    var source = Random.init(default_seed);
    var step: usize = 0;
    while (step < 4096) : (step += 1) {
        const draw = source.real();
        try std.testing.expect(draw >= 0.0);
        try std.testing.expect(draw < 1.0);
    }
}
