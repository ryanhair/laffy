//! Float helpers whose behaviour differs from the Zig builtins.
const std = @import("std");

/// Rounds to the nearest whole number.
///
/// This is `floor(value + 0.5)`, exactly as upstream (with `std` enabled). It is NOT the same as
/// `@round`, which rounds halfway cases away from zero.
pub inline fn round(value: f32) f32 {
    return @floor(value + 0.5);
}

/// Copies the sign of another value
pub inline fn copysign(value: f32, sign: f32) f32 {
    const value_bits: u32 = @bitCast(value);
    const sign_bits: u32 = @bitCast(sign);
    return @bitCast((value_bits & 0x7fff_ffff) | (sign_bits & 0x8000_0000));
}

test "float sign helpers preserve bits" {
    const values = [_]u32{ 0, 0x8000_0000, 0x3fc0_0000, 0xbfc0_0000, 0x7f80_0000, 0xff80_0000, 0x7fc0_1234, 0xffc0_1234 };
    const signs = [_]u32{ 0, 0x8000_0000, 0x3f80_0000, 0xbf80_0000, 0x7fc0_1234, 0xffc0_1234 };
    for (values) |bits| {
        // Use runtime values so that the operations are not constant-folded
        var value: f32 = @bitCast(bits);
        _ = &value;
        try std.testing.expectEqual(bits & 0x7fff_ffff, @as(u32, @bitCast(@abs(value))));
        for (signs) |sign_bits| {
            var sign: f32 = @bitCast(sign_bits);
            _ = &sign;
            try std.testing.expectEqual((bits & 0x7fff_ffff) | (sign_bits & 0x8000_0000), @as(u32, @bitCast(copysign(value, sign))));
        }
    }
}

test "round is floor(value + 0.5)" {
    var half: f32 = -0.5;
    _ = &half;
    // @round(-0.5) would be -1.0; taffy's round gives 0.0
    try std.testing.expectEqual(@as(f32, 0.0), round(half));
    var two_and_half: f32 = 2.5;
    _ = &two_and_half;
    try std.testing.expectEqual(@as(f32, 3.0), round(two_and_half));
    var neg: f32 = -2.5;
    _ = &neg;
    try std.testing.expectEqual(@as(f32, -2.0), round(neg));
}
