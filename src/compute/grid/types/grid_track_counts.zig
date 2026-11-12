//! Contains TrackCounts used to keep track of the number of tracks in the explicit and implicit grids.
//! Also contains coordinate conversion functions which depend on those counts
//!
//! laffy uses two coordinate systems to refer to grid lines (the gaps/gutters between rows/columns):
//!
//!   "CSS Grid Line" coordinates are those used in grid-row/grid-column in the CSS grid spec:
//!     - 0 is not a valid index
//!     - The line at left hand (or top) edge of the explicit grid is line 1
//!       (and counts up from there)
//!     - The line at the right hand (or bottom) edge of the explicit grid in -1
//!       (and counts down from there)
//!
//!   "OriginZero" coordinates are a normalized form:
//!     - The line at left hand (or top) edge of the explicit grid is line 0
//!     - The next line to the right (or down) is 1, and so on
//!     - The next line to the left (or up) is -1, and so on
//!
//! laffy also uses two coordinate systems to refer to grid tracks (rows/columns):
//!
//!   Both of these systems represent the entire implicit grid, not just the explicit grid.
//!
//!   "CellOccupancyMatrix track indices":
//!       - These are indexes into the CellOccupancyMatrix
//!       - The CellOccupancyMatrix stores only tracks
//!       - 0 is the leftmost track of the implicit grid, and indexes count up there
//!
//!   "GridTrackVec track indices":
//!       - The GridTrackVecs store both lines and tracks, so:
//!           - even indices (0, 2, 4, etc) represent lines
//!           - odd indices (1, 3, 5, etc) represent tracks
//!           - These is always an odd number of
//!       - Index 1 is the leftmost track of the implicit grid. Index 3 is the second leftmost track, etc.
//!       - Index 0 is the leftmost grid line. Index 2 is the second leftmost line, etc.
//!
const std = @import("std");
const Line = @import("../../../geometry.zig").Line;
const OriginZeroLine = @import("coordinates.zig").OriginZeroLine;

/// A half-open range `start..end` (upstream `core::ops::Range`)
pub fn Range(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The (inclusive) start of the range
        start: T,
        /// The (exclusive) end of the range
        end: T,

        /// Whether `value` lies within the range
        pub fn contains(self: Self, value: T) bool {
            return self.start <= value and value < self.end;
        }
    };
}

/// Stores the number of tracks in a given dimension.
/// Stores separately the number of tracks in the implicit and explicit grids
pub const TrackCounts = struct {
    /// The number of track in the implicit grid before the explicit grid
    negative_implicit: u16 = 0,
    /// The number of tracks in the explicit grid
    explicit: u16 = 0,
    /// The number of tracks in the implicit grid after the explicit grid
    positive_implicit: u16 = 0,

    /// Create a TrackCounts instance from raw track count numbers
    pub fn fromRaw(negative_implicit: u16, explicit: u16, positive_implicit: u16) TrackCounts {
        return .{ .negative_implicit = negative_implicit, .explicit = explicit, .positive_implicit = positive_implicit };
    }

    /// Count the total number of tracks in the axis
    pub fn len(self: TrackCounts) usize {
        return @as(usize, self.negative_implicit + self.explicit + self.positive_implicit);
    }

    /// The OriginZeroLine representing the start of the implicit grid
    pub fn implicitStartLine(self: TrackCounts) OriginZeroLine {
        return OriginZeroLine.from(-@as(i16, @bitCast(self.negative_implicit)));
    }

    /// The OriginZeroLine representing the end of the implicit grid
    pub fn implicitEndLine(self: TrackCounts) OriginZeroLine {
        return OriginZeroLine.from(@bitCast(self.explicit + self.positive_implicit));
    }

    // Conversion functions between OriginZero coordinates and CellOccupancyMatrix track indexes

    /// Converts a grid line in OriginZero coordinates into the track immediately
    /// following that grid line as an index into the CellOccupancyMatrix.
    pub fn ozLineToNextTrack(self: TrackCounts, index: OriginZeroLine) i16 {
        return index.inner + @as(i16, @bitCast(self.negative_implicit));
    }

    /// Converts start and end grid lines in OriginZero coordinates into a range of tracks
    /// as indexes into the CellOccupancyMatrix
    pub fn ozLineRangeToTrackRange(self: TrackCounts, input: Line(OriginZeroLine)) Range(i16) {
        const start = self.ozLineToNextTrack(input.start);
        const end = self.ozLineToNextTrack(input.end); // Don't subtract 1 as output range is exclusive
        return .{ .start = start, .end = end };
    }

    /// Converts a track as an index into the CellOccupancyMatrix into the grid line immediately
    /// preceding that track in OriginZero coordinates.
    pub fn trackToPrevOzLine(self: TrackCounts, index: u16) OriginZeroLine {
        return OriginZeroLine.from(@as(i16, @bitCast(index)) - @as(i16, @bitCast(self.negative_implicit)));
    }

    /// Converts a range of tracks as indexes into the CellOccupancyMatrix into
    /// start and end grid lines in OriginZero coordinates
    pub fn trackRangeToOzLineRange(self: TrackCounts, input: Range(i16)) Line(OriginZeroLine) {
        const start = self.trackToPrevOzLine(@bitCast(input.start));
        const end = self.trackToPrevOzLine(@bitCast(input.end)); // Don't add 1 as input range is exclusive
        return .{ .start = start, .end = end };
    }
};

test "track counts conversions" {
    const counts = TrackCounts.fromRaw(2, 3, 1);
    try std.testing.expectEqual(@as(usize, 6), counts.len());
    try std.testing.expectEqual(OriginZeroLine.from(-2), counts.implicitStartLine());
    try std.testing.expectEqual(OriginZeroLine.from(4), counts.implicitEndLine());
    try std.testing.expectEqual(@as(i16, 2), counts.ozLineToNextTrack(OriginZeroLine.from(0)));
    try std.testing.expectEqual(OriginZeroLine.from(-2), counts.trackToPrevOzLine(0));
    const range = counts.ozLineRangeToTrackRange(.{ .start = OriginZeroLine.from(-1), .end = OriginZeroLine.from(2) });
    try std.testing.expectEqual(Range(i16){ .start = 1, .end = 4 }, range);
    try std.testing.expectEqual(Line(OriginZeroLine){ .start = OriginZeroLine.from(-1), .end = OriginZeroLine.from(2) }, counts.trackRangeToOzLineRange(range));
    try std.testing.expect(range.contains(3));
    try std.testing.expect(!range.contains(4));
}
