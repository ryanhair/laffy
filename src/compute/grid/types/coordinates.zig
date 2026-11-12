//! laffy uses two coordinate systems to refer to grid lines (the gaps/gutters between rows/columns).
//!
//! Ported ahead of the rest of `compute/grid` because the grid style types (`style/grid.zig`)
//! depend on `GridLine`, `OriginZeroLine` and `MAX_GRID_TRACKS`.
//!
//! The upstream `GridCoordinate` marker trait has no equivalent: `GenericGridPlacement(LineType)`
//! accepts either `GridLine` or `OriginZeroLine`.
const std = @import("std");
const Line = @import("../../../geometry.zig").Line;

/// The maximum number of tracks in each direction from the start of the explicit grid (line 0 in
/// OriginZero coordinates), and the maximum span of a single grid item. This limits the grid to
/// `2 * MAX_GRID_TRACKS` total tracks in each axis (including explicit tracks, which count against
/// the positive limit). Grids larger than this limit are clamped.
///
/// See: <https://www.w3.org/TR/css-grid-1/#overlarge-grids>
pub const max_grid_tracks: u16 = 10_000;

/// The lowest valid grid line in OriginZero coordinates
pub const min_oz_line: i16 = -@as(i16, @intCast(max_grid_tracks));

/// The highest valid grid line in OriginZero coordinates
pub const max_oz_line: i16 = @intCast(max_grid_tracks);

/// Represents a grid line position in "CSS Grid Line" coordinates
///
/// "CSS Grid Line" coordinates are those used in grid-row/grid-column in the CSS grid spec:
///   - The line at left hand (or top) edge of the explicit grid is line 1
///     (and counts up from there)
///   - The line at the right hand (or bottom) edge of the explicit grid is -1
///     (and counts down from there)
///   - 0 is not a valid index
pub const GridLine = packed struct(i16) {
    inner: i16,

    /// Upstream `From<i16>`
    pub fn from(value: i16) GridLine {
        return .{ .inner = value };
    }

    /// Returns the underlying i16
    pub fn asI16(self: GridLine) i16 {
        return self.inner;
    }

    /// Convert into OriginZero coordinates using the specified explicit track count.
    ///
    /// The result is clamped into the limited grid `[-MAX_GRID_TRACKS, MAX_GRID_TRACKS]`
    pub fn intoOriginZeroLine(self: GridLine, explicit_track_count: u16) OriginZeroLine {
        const explicit_line_count: i32 = @as(i32, explicit_track_count) + 1;
        const oz_line: i32 = if (self.inner > 0)
            @as(i32, self.inner) - 1
        else if (self.inner < 0)
            @as(i32, self.inner) + explicit_line_count
        else
            @panic("Grid line of zero is invalid");
        return OriginZeroLine.clamped(oz_line);
    }
};

/// Represents a grid line position in "OriginZero" coordinates
///
/// "OriginZero" coordinates are a normalized form:
///   - The line at left hand (or top) edge of the explicit grid is line 0
///   - The next line to the right (or down) is 1, and so on
///   - The next line to the left (or up) is -1, and so on
pub const OriginZeroLine = packed struct(i16) {
    inner: i16,

    /// Create from a raw i16 (upstream tuple constructor `OriginZeroLine(x)`)
    pub fn from(value: i16) OriginZeroLine {
        return .{ .inner = value };
    }

    /// Upstream `Add<OriginZeroLine>` and `Add<u16>`. `rhs` may be an `OriginZeroLine` or a
    /// `u16` (which is reinterpreted as `i16`, like upstream's `as i16`).
    pub fn add(self: OriginZeroLine, rhs: anytype) OriginZeroLine {
        return .{ .inner = self.inner + rhsToI16(rhs) };
    }

    /// Upstream `Sub<OriginZeroLine>` and `Sub<u16>`. `rhs` may be an `OriginZeroLine` or a `u16`.
    pub fn sub(self: OriginZeroLine, rhs: anytype) OriginZeroLine {
        return .{ .inner = self.inner - rhsToI16(rhs) };
    }

    /// Upstream `AddAssign<u16>`
    pub fn addAssign(self: *OriginZeroLine, rhs: u16) void {
        self.inner += @as(i16, @bitCast(rhs));
    }

    fn rhsToI16(rhs: anytype) i16 {
        const T = @TypeOf(rhs);
        if (T == OriginZeroLine) {
            return rhs.inner;
        } else if (T == u16) {
            return @bitCast(rhs);
        } else if (T == comptime_int) {
            return @bitCast(@as(u16, rhs));
        } else {
            @compileError("expected OriginZeroLine or u16, found " ++ @typeName(T));
        }
    }

    /// Ordering helpers (upstream derives `Ord`)
    pub fn lessThan(self: OriginZeroLine, other: OriginZeroLine) bool {
        return self.inner < other.inner;
    }

    /// Upstream `core::cmp::min` for `OriginZeroLine`
    pub fn min(a: OriginZeroLine, b: OriginZeroLine) OriginZeroLine {
        // `Ord::min` returns the first argument when the two are equal
        return if (b.inner < a.inner) b else a;
    }

    /// Upstream `core::cmp::max` for `OriginZeroLine`
    pub fn max(a: OriginZeroLine, b: OriginZeroLine) OriginZeroLine {
        // `Ord::max` returns the second argument when the two are equal
        return if (b.inner >= a.inner) b else a;
    }

    /// Create an `OriginZeroLine`, clamping the line into the limited grid `[-MAX_GRID_TRACKS, MAX_GRID_TRACKS]`
    pub fn clamped(line: i32) OriginZeroLine {
        return .{ .inner = @intCast(std.math.clamp(line, @as(i32, min_oz_line), @as(i32, max_oz_line))) };
    }

    /// Convert into "CSS Grid Line" coordinates using the specified explicit track count.
    ///
    /// The inverse of `GridLine.intoOriginZeroLine`
    pub fn intoGridLine(self: OriginZeroLine, explicit_track_count: u16) GridLine {
        const explicit_line_count = explicit_track_count + 1;
        if (self.inner >= 0) {
            return .{ .inner = self.inner + 1 };
        } else {
            return .{ .inner = self.inner - @as(i16, @bitCast(explicit_line_count)) };
        }
    }

    /// Converts a grid line in OriginZero coordinates into the index of that same grid line in the GridTrackVec.
    ///
    /// `track_counts` is a `TrackCounts` (fields `negative_implicit`, `explicit`, `positive_implicit`, all `u16`).
    pub fn intoTrackVecIndex(self: OriginZeroLine, track_counts: anytype) usize {
        return self.tryIntoTrackVecIndex(track_counts) orelse {
            if (self.inner > 0) {
                @panic("OriginZero grid line cannot be more than the number of positive grid lines");
            } else {
                @panic("OriginZero grid line cannot be less than the number of negative grid lines");
            }
        };
    }

    /// Converts a grid line in OriginZero coordinates into the index of that same grid line in the GridTrackVec.
    ///
    /// This fallible version is used for the placement of absolutely positioned grid items:
    ///
    ///    If a grid-placement property refers to a non-existent line either by explicitly specifying such a line or by
    ///    spanning outside of the existing implicit grid, it is instead treated as specifying auto (instead of creating
    ///    new implicit grid lines).
    ///
    /// The infallible version above if used when placing regular in-flow grid items.
    pub fn tryIntoTrackVecIndex(self: OriginZeroLine, track_counts: anytype) ?usize {
        const negative_implicit: i16 = @bitCast(@as(u16, track_counts.negative_implicit));
        // OriginZero grid line cannot be less than the number of negative grid lines
        if (self.inner < -negative_implicit) {
            return null;
        }
        // OriginZero grid line cannot be more than the number of positive grid lines
        const positive: u16 = @as(u16, track_counts.explicit) + @as(u16, track_counts.positive_implicit);
        if (self.inner > @as(i16, @bitCast(positive))) {
            return null;
        }

        return 2 * @as(usize, @intCast(self.inner + negative_implicit));
    }

    /// The minimum number of negative implicit track there must be if a grid item starts at this line.
    pub fn impliedNegativeImplicitTracks(self: OriginZeroLine) u16 {
        if (self.inner < 0) {
            return @abs(self.inner);
        } else {
            return 0;
        }
    }

    /// The minimum number of positive implicit track there must be if a grid item end at this line.
    pub fn impliedPositiveImplicitTracks(self: OriginZeroLine, explicit_track_count: u16) u16 {
        if (self.inner > @as(i16, @bitCast(explicit_track_count))) {
            return @as(u16, @bitCast(self.inner)) - explicit_track_count;
        } else {
            return 0;
        }
    }

    /// The number of tracks between the start and end lines (upstream `Line<OriginZeroLine>::span`).
    /// Called via `Line(OriginZeroLine).span`.
    pub fn lineSpan(line: Line(OriginZeroLine)) u16 {
        return @intCast(@max(line.end.inner - line.start.inner, 0));
    }
};

const testing = std.testing;

test "grid line conversions" {
    try testing.expectEqual(OriginZeroLine.from(0), GridLine.from(1).intoOriginZeroLine(3));
    try testing.expectEqual(OriginZeroLine.from(3), GridLine.from(-1).intoOriginZeroLine(3));
    try testing.expectEqual(OriginZeroLine.from(-1), GridLine.from(-5).intoOriginZeroLine(3));
    try testing.expectEqual(OriginZeroLine.from(max_oz_line), GridLine.from(std.math.maxInt(i16)).intoOriginZeroLine(3));
    try testing.expectEqual(GridLine.from(1), OriginZeroLine.from(0).intoGridLine(3));
    try testing.expectEqual(GridLine.from(-5), OriginZeroLine.from(-1).intoGridLine(3));
}

test "origin zero line arithmetic and helpers" {
    const a = OriginZeroLine.from(2);
    try testing.expectEqual(OriginZeroLine.from(5), a.add(@as(u16, 3)));
    try testing.expectEqual(OriginZeroLine.from(-1), a.sub(@as(u16, 3)));
    try testing.expectEqual(OriginZeroLine.from(4), a.add(a));
    var b = a;
    b.addAssign(4);
    try testing.expectEqual(OriginZeroLine.from(6), b);
    try testing.expectEqual(@as(u16, 3), OriginZeroLine.from(-3).impliedNegativeImplicitTracks());
    try testing.expectEqual(@as(u16, 0), OriginZeroLine.from(3).impliedNegativeImplicitTracks());
    try testing.expectEqual(@as(u16, 2), OriginZeroLine.from(5).impliedPositiveImplicitTracks(3));
    try testing.expectEqual(@as(u16, 0), OriginZeroLine.from(2).impliedPositiveImplicitTracks(3));
    const counts = .{ .negative_implicit = @as(u16, 1), .explicit = @as(u16, 3), .positive_implicit = @as(u16, 1) };
    try testing.expectEqual(@as(?usize, 0), OriginZeroLine.from(-1).tryIntoTrackVecIndex(counts));
    try testing.expectEqual(@as(?usize, null), OriginZeroLine.from(-2).tryIntoTrackVecIndex(counts));
    try testing.expectEqual(@as(?usize, 10), OriginZeroLine.from(4).tryIntoTrackVecIndex(counts));
    try testing.expectEqual(@as(?usize, null), OriginZeroLine.from(5).tryIntoTrackVecIndex(counts));
    try testing.expectEqual(@as(usize, 2), OriginZeroLine.from(0).intoTrackVecIndex(counts));
    const line: Line(OriginZeroLine) = .{ .start = OriginZeroLine.from(-1), .end = OriginZeroLine.from(3) };
    try testing.expectEqual(@as(u16, 4), line.span());
    const backwards: Line(OriginZeroLine) = .{ .start = OriginZeroLine.from(3), .end = OriginZeroLine.from(1) };
    try testing.expectEqual(@as(u16, 0), backwards.span());
}
