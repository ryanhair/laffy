//! Contains CellOccupancyMatrix used to track occupied cells during grid placement
const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("../../../geometry.zig");
const AbsoluteAxis = geometry.AbsoluteAxis;
const Line = geometry.Line;
const LayoutError = @import("../../../tree/layout.zig").LayoutError;
const OriginZeroLine = @import("coordinates.zig").OriginZeroLine;
const grid_track_counts = @import("grid_track_counts.zig");
const Range = grid_track_counts.Range;
const TrackCounts = grid_track_counts.TrackCounts;

/// The occupancy state of a single grid cell
pub const CellOccupancyState = enum {
    /// Indicates that a grid cell is unoccupied
    unoccupied,
    /// Indicates that a grid cell is occupied by a definitely placed item
    definitely_placed,
    /// Indicates that a grid cell is occupied by an item that was placed by the auto placement algorithm
    auto_placed,
};

/// A run of occupied cells within a single track. The range is in OriginZero line coordinates
/// along the track (so for a row track, the range spans column lines and vice versa).
const OccupiedInterval = struct {
    /// The range of cells covered by this interval (start line..end line in OriginZero coordinates)
    range: Range(i16),
    /// The occupancy state of every cell within this interval
    state: CellOccupancyState,

    /// Whether this interval overlaps the given range
    fn overlaps(self: OccupiedInterval, range: Range(i16)) bool {
        return self.range.start < range.end and self.range.end > range.start;
    }
};

/// The occupied cells of a single track, stored as a sorted list of disjoint intervals in
/// OriginZero line coordinates. Gaps between intervals are unoccupied. Touching intervals
/// with the same state are merged.
const TrackIntervals = struct {
    /// The sorted, disjoint list of occupied intervals within the track
    intervals: std.ArrayList(OccupiedInterval) = .empty,
    /// The furthest end line of an auto-placed item starting in this secondary-axis track
    auto_placement_cursor: ?OriginZeroLine = null,

    fn deinit(self: *TrackIntervals, gpa: Allocator) void {
        self.intervals.deinit(gpa);
    }

    /// Whether the track contains any occupied cells
    fn isEmpty(self: *const TrackIntervals) bool {
        return self.intervals.items.len == 0;
    }

    /// The occupancy state of the cell whose start line is at `coordinate`
    fn stateAt(self: *const TrackIntervals, coordinate: i16) CellOccupancyState {
        for (self.intervals.items) |interval| {
            if (interval.range.start <= coordinate and coordinate < interval.range.end) return interval.state;
        }
        return .unoccupied;
    }

    /// Set the cells covered by `range` to `state`, overwriting the state of any already-occupied
    /// cells within the range (matching the overwrite semantics of a dense matrix of cells)
    fn paint(self: *TrackIntervals, gpa: Allocator, range: Range(i16), state: CellOccupancyState) LayoutError!void {
        if (range.start >= range.end) {
            return;
        }

        // Fast path: the painted range lies entirely after all existing intervals
        // (the common case, as placement queries and inserts mostly advance forwards)
        if (self.intervals.items.len == 0) {
            try self.intervals.append(gpa, .{ .range = range, .state = state });
            return;
        }
        const last = &self.intervals.items[self.intervals.items.len - 1];
        if (last.range.end <= range.start) {
            if (last.state == state and last.range.end == range.start) {
                last.range.end = range.end;
            } else {
                try self.intervals.append(gpa, .{ .range = range, .state = state });
            }
            return;
        }

        var result: std.ArrayList(OccupiedInterval) = .empty;
        errdefer result.deinit(gpa);

        // Intervals (or partial intervals) entirely before the painted range
        for (self.intervals.items) |interval| {
            if (interval.range.end <= range.start) {
                try result.append(gpa, interval);
            } else if (interval.range.start < range.start) {
                try result.append(gpa, .{ .range = .{ .start = interval.range.start, .end = range.start }, .state = interval.state });
            }
        }

        // The painted range, merged with the preceding interval if it touches and has the same state
        if (result.items.len > 0 and result.items[result.items.len - 1].state == state and result.items[result.items.len - 1].range.end == range.start) {
            result.items[result.items.len - 1].range.end = range.end;
        } else {
            try result.append(gpa, .{ .range = range, .state = state });
        }

        // Intervals (or partial intervals) entirely after the painted range
        for (self.intervals.items) |interval| {
            const trimmed: OccupiedInterval = if (interval.range.start >= range.end)
                interval
            else if (interval.range.end > range.end)
                .{ .range = .{ .start = range.end, .end = interval.range.end }, .state = interval.state }
            else
                continue;
            if (result.items.len > 0 and result.items[result.items.len - 1].state == trimmed.state and result.items[result.items.len - 1].range.end == trimmed.range.start) {
                result.items[result.items.len - 1].range.end = trimmed.range.end;
            } else {
                try result.append(gpa, trimmed);
            }
        }

        self.intervals.deinit(gpa);
        self.intervals = result;
    }

    /// Find the extent of the occupied interval which an auto-placement search along the track
    /// would collide with last: the end of the last overlapping interval. Returns the extremal
    /// occupied cell of that interval (which may lie outside `range`: every search position
    /// before the returned extent also collides with the interval), or `null` if the range is
    /// entirely unoccupied.
    fn collisionExtent(self: *const TrackIntervals, range: Range(i16)) ?i16 {
        var i = self.intervals.items.len;
        while (i > 0) {
            i -= 1;
            const interval = self.intervals.items[i];
            if (!(interval.range.end > range.start)) break;
            if (interval.overlaps(range)) return interval.range.end - 1;
        }
        return null;
    }
};

/// A dynamically sized matrix (2d grid) which tracks the occupancy of each grid cell during auto-placement.
/// It also keeps tabs on how many tracks there are and which tracks are implicit and which are explicit.
///
/// Occupancy is stored sparsely as per-track interval lists (in both orientations), so memory usage
/// is proportional to the number of placed items rather than the total number of grid cells.
pub const CellOccupancyMatrix = struct {
    /// The counts of implicit and explicit columns
    columns: TrackCounts,
    /// The counts of implicit and explicit rows
    rows: TrackCounts,
    /// For each row track: the occupied intervals within that row (in column coordinates)
    row_intervals: std.ArrayList(TrackIntervals),
    /// For each column track: the occupied intervals within that column (in row coordinates)
    column_intervals: std.ArrayList(TrackIntervals),

    /// Create a CellOccupancyMatrix given a set of provisional track counts. The grid can expand as needed to fit more tracks,
    /// the provisional track counts represent a best effort attempt to avoid the extra allocations this requires.
    pub fn withTrackCounts(gpa: Allocator, columns: TrackCounts, rows: TrackCounts) LayoutError!CellOccupancyMatrix {
        var row_intervals: std.ArrayList(TrackIntervals) = .empty;
        errdefer row_intervals.deinit(gpa);
        try row_intervals.appendNTimes(gpa, .{}, rows.len());
        var column_intervals: std.ArrayList(TrackIntervals) = .empty;
        errdefer column_intervals.deinit(gpa);
        try column_intervals.appendNTimes(gpa, .{}, columns.len());
        return .{ .rows = rows, .columns = columns, .row_intervals = row_intervals, .column_intervals = column_intervals };
    }

    /// Free the matrix's memory
    pub fn deinit(self: *CellOccupancyMatrix, gpa: Allocator) void {
        for (self.row_intervals.items) |*track| track.deinit(gpa);
        self.row_intervals.deinit(gpa);
        for (self.column_intervals.items) |*track| track.deinit(gpa);
        self.column_intervals.deinit(gpa);
    }

    /// The per-track interval lists for tracks in the specified axis. Each row track's intervals
    /// are in column coordinates and vice versa.
    fn trackLists(self: *const CellOccupancyMatrix, track_axis: AbsoluteAxis) []TrackIntervals {
        return switch (track_axis) {
            .horizontal => self.column_intervals.items,
            .vertical => self.row_intervals.items,
        };
    }

    /// Insert `count` empty tracks at the front of `list`
    fn prependEmptyTracks(gpa: Allocator, list: *std.ArrayList(TrackIntervals), count: usize) LayoutError!void {
        const slot = try list.addManyAt(gpa, 0, count);
        @memset(slot, .{});
    }

    /// Expands the grid (potentially in all 4 directions) in order to ensure that the specified
    /// spans (in OriginZero coordinates) fit within the tracked tracks
    fn expandToFitRange(self: *CellOccupancyMatrix, gpa: Allocator, row_span: Line(OriginZeroLine), col_span: Line(OriginZeroLine)) LayoutError!void {
        // Calculate number of rows and columns missing to accommodate ranges (if any)
        const req_negative_rows: i16 = @max(-@as(i16, @bitCast(self.rows.negative_implicit)) - row_span.start.inner, 0);
        const req_positive_rows: i16 = @max(row_span.end.inner - self.rows.implicitEndLine().inner, 0);
        const req_negative_cols: i16 = @max(-@as(i16, @bitCast(self.columns.negative_implicit)) - col_span.start.inner, 0);
        const req_positive_cols: i16 = @max(col_span.end.inner - self.columns.implicitEndLine().inner, 0);

        // Add empty tracks to the front and/or back of the per-track interval lists.
        // Interval contents are stored in OriginZero coordinates, so they do not need to shift.
        if (req_negative_rows > 0) {
            try prependEmptyTracks(gpa, &self.row_intervals, @intCast(req_negative_rows));
        }
        if (req_positive_rows > 0) {
            try self.row_intervals.appendNTimes(gpa, .{}, @intCast(req_positive_rows));
        }
        if (req_negative_cols > 0) {
            try prependEmptyTracks(gpa, &self.column_intervals, @intCast(req_negative_cols));
        }
        if (req_positive_cols > 0) {
            try self.column_intervals.appendNTimes(gpa, .{}, @intCast(req_positive_cols));
        }

        self.rows.negative_implicit += @intCast(req_negative_rows);
        self.rows.positive_implicit += @intCast(req_positive_rows);
        self.columns.negative_implicit += @intCast(req_negative_cols);
        self.columns.positive_implicit += @intCast(req_positive_cols);
    }

    /// Mark an area of the matrix as occupied, expanding the allocated space as necessary to accommodate the passed area.
    pub fn markAreaAs(
        self: *CellOccupancyMatrix,
        gpa: Allocator,
        primary_axis: AbsoluteAxis,
        primary_span: Line(OriginZeroLine),
        secondary_span: Line(OriginZeroLine),
        value: CellOccupancyState,
    ) LayoutError!void {
        const row_span: Line(OriginZeroLine), const column_span: Line(OriginZeroLine) = switch (primary_axis) {
            .horizontal => .{ secondary_span, primary_span },
            .vertical => .{ primary_span, secondary_span },
        };

        try self.expandToFitRange(gpa, row_span, column_span);

        if (value == .auto_placed and
            primary_span.start.inner < primary_span.end.inner and
            secondary_span.start.inner < secondary_span.end.inner)
        {
            self.advanceAutoPlacementCursor(primary_axis, secondary_span.start, primary_span.end);
        }

        const row_range = self.rows.ozLineRangeToTrackRange(row_span);
        const col_range = self.columns.ozLineRangeToTrackRange(column_span);
        var row_index = row_range.start;
        while (row_index < row_range.end) : (row_index += 1) {
            try self.row_intervals.items[@intCast(row_index)].paint(gpa, .{ .start = column_span.start.inner, .end = column_span.end.inner }, value);
        }
        var column_index = col_range.start;
        while (column_index < col_range.end) : (column_index += 1) {
            try self.column_intervals.items[@intCast(column_index)].paint(gpa, .{ .start = row_span.start.inner, .end = row_span.end.inner }, value);
        }
    }

    /// Determines whether a grid area specified by the bounding grid lines in OriginZero coordinates
    /// is entirely unnocupied. Returns true if all grid cells within the grid area are unnocupied, else false.
    pub fn lineAreaIsUnoccupied(
        self: *const CellOccupancyMatrix,
        primary_axis: AbsoluteAxis,
        primary_span: Line(OriginZeroLine),
        secondary_span: Line(OriginZeroLine),
    ) bool {
        return self.lineAreaCollisionJump(primary_axis, primary_span, secondary_span) == null;
    }

    /// Checks the specified area for occupied cells (`primary_span` and `secondary_span` are
    /// bounding grid lines in OriginZero coordinates). Returns `null` if the area is entirely
    /// unoccupied. Otherwise returns the next search position (in OriginZero coordinates, along
    /// `primary_axis`) that is not guaranteed to collide with the occupied cells found in the
    /// area. This allows the auto-placement search cursor to jump past collisions rather than
    /// advancing one track at a time.
    pub fn lineAreaCollisionJump(
        self: *const CellOccupancyMatrix,
        primary_axis: AbsoluteAxis,
        primary_span: Line(OriginZeroLine),
        secondary_span: Line(OriginZeroLine),
    ) ?OriginZeroLine {
        const track_lists = self.trackLists(primary_axis.otherAxis());
        const secondary_counts = self.trackCounts(primary_axis.otherAxis());
        const secondary_range = secondary_counts.ozLineRangeToTrackRange(secondary_span);

        // Out of bounds cells are considered unoccupied, so clamp the secondary range to the
        // tracks which actually exist
        const secondary_start: i16 = @max(secondary_range.start, 0);
        const secondary_end: i16 = @min(secondary_range.end, @as(i16, @intCast(track_lists.len)));

        const primary_range: Range(i16) = .{ .start = primary_span.start.inner, .end = primary_span.end.inner };

        var extent: ?i16 = null;
        var secondary_index = secondary_start;
        while (secondary_index < secondary_end) : (secondary_index += 1) {
            const cell = track_lists[@intCast(secondary_index)].collisionExtent(primary_range) orelse continue;
            extent = if (extent) |best| @max(best, cell) else cell;
        }

        return if (extent) |cell| OriginZeroLine.from(cell + 1) else null;
    }

    /// Given a span of tracks in `axis` (in OriginZero coordinates), returns the next search
    /// position past all non-empty tracks within the span, or `null` if all tracks within the
    /// span are entirely unoccupied. Used to place items which span every track in the other
    /// axis (such items can only fit in a stripe of entirely unoccupied tracks).
    pub fn occupiedTrackJump(self: *const CellOccupancyMatrix, axis: AbsoluteAxis, span: Line(OriginZeroLine)) ?OriginZeroLine {
        const counts = self.trackCounts(axis);
        const track_lists = self.trackLists(axis);
        const range = counts.ozLineRangeToTrackRange(span);
        const start: i16 = @max(range.start, 0);
        const end: i16 = @min(range.end, @as(i16, @intCast(track_lists.len)));
        var index = end;
        while (index > start) {
            index -= 1;
            if (!track_lists[@intCast(index)].isEmpty()) {
                const line = counts.trackToPrevOzLine(@intCast(index));
                return line.add(@as(u16, 1));
            }
        }
        return null;
    }

    /// Determines whether the specified row contains any items
    pub fn rowIsOccupied(self: *const CellOccupancyMatrix, row_index: usize) bool {
        const lists = self.trackLists(.vertical);
        return row_index < lists.len and !lists[row_index].isEmpty();
    }

    /// Determines whether the specified column contains any items
    pub fn columnIsOccupied(self: *const CellOccupancyMatrix, column_index: usize) bool {
        const lists = self.trackLists(.horizontal);
        return column_index < lists.len and !lists[column_index].isEmpty();
    }

    /// Returns the track counts of this CellOccunpancyMatrix in the relevant axis
    pub fn trackCounts(self: *const CellOccupancyMatrix, track_type: AbsoluteAxis) TrackCounts {
        return switch (track_type) {
            .horizontal => self.columns,
            .vertical => self.rows,
        };
    }

    /// The sparse placement cursor for items starting in the given secondary-axis track.
    pub fn autoPlacementCursor(self: *const CellOccupancyMatrix, track_type: AbsoluteAxis, start_at: OriginZeroLine) ?OriginZeroLine {
        const track_counts = self.trackCounts(track_type.otherAxis());
        const track_computed_index = track_counts.ozLineToNextTrack(start_at);
        const track_lists = self.trackLists(track_type.otherAxis());
        if (track_computed_index < 0 or track_computed_index >= @as(i16, @intCast(track_lists.len))) {
            // Index out of bounds: no tracks to search
            return null;
        }
        return track_lists[@intCast(track_computed_index)].auto_placement_cursor;
    }

    /// Advances the sparse placement cursor to at least `primary_end`.
    /// The secondary-axis track must already exist in the matrix.
    fn advanceAutoPlacementCursor(
        self: *CellOccupancyMatrix,
        primary_axis: AbsoluteAxis,
        secondary_start: OriginZeroLine,
        primary_end: OriginZeroLine,
    ) void {
        const track_index: usize = @intCast(self.trackCounts(primary_axis.otherAxis()).ozLineToNextTrack(secondary_start));
        const tracks = switch (primary_axis) {
            .horizontal => self.row_intervals.items,
            .vertical => self.column_intervals.items,
        };
        const cursor = &tracks[track_index].auto_placement_cursor;
        // `max(Option, Option)`: `None` is less than any `Some`
        cursor.* = if (cursor.*) |current| OriginZeroLine.max(current, primary_end) else primary_end;
    }

    /// Debug representation of the matrix in a compact 2d text format
    pub fn format(self: *const CellOccupancyMatrix, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("Rows: neg_implicit={d} explicit={d} pos_implicit={d}\n", .{ self.rows.negative_implicit, self.rows.explicit, self.rows.positive_implicit });
        try w.print("Cols: neg_implicit={d} explicit={d} pos_implicit={d}\n", .{ self.columns.negative_implicit, self.columns.explicit, self.columns.positive_implicit });
        if (self.rows.len() > 100 or self.columns.len() > 100) {
            try w.writeAll("State: (not printed: more than 100 tracks)\n");
            return;
        }
        try w.writeAll("State:\n");
        for (self.row_intervals.items) |*row| {
            for (0..self.columns.len()) |column_index| {
                const coordinate = self.columns.trackToPrevOzLine(@intCast(column_index));
                const letter: u8 = switch (row.stateAt(coordinate.inner)) {
                    .unoccupied => '_',
                    .definitely_placed => 'D',
                    .auto_placed => 'A',
                };
                try w.writeByte(letter);
            }
            try w.writeByte('\n');
        }
    }
};

// ---------------------------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn testInterval(start: i16, end: i16, state: CellOccupancyState) OccupiedInterval {
    return .{ .range = .{ .start = start, .end = end }, .state = state };
}

fn r(start: i16, end: i16) Range(i16) {
    return .{ .start = start, .end = end };
}

test "track_intervals: paint merges touching same state intervals" {
    var track: TrackIntervals = .{};
    defer track.deinit(testing.allocator);
    try track.paint(testing.allocator, r(0, 2), .auto_placed);
    try track.paint(testing.allocator, r(4, 6), .auto_placed);
    try track.paint(testing.allocator, r(2, 4), .auto_placed);
    try testing.expectEqualSlices(OccupiedInterval, &.{testInterval(0, 6, .auto_placed)}, track.intervals.items);
}

test "track_intervals: paint does not merge different states" {
    var track: TrackIntervals = .{};
    defer track.deinit(testing.allocator);
    try track.paint(testing.allocator, r(0, 2), .auto_placed);
    try track.paint(testing.allocator, r(2, 4), .definitely_placed);
    try testing.expectEqualSlices(OccupiedInterval, &.{ testInterval(0, 2, .auto_placed), testInterval(2, 4, .definitely_placed) }, track.intervals.items);
}

test "track_intervals: paint overwrites overlapped cells" {
    var track: TrackIntervals = .{};
    defer track.deinit(testing.allocator);
    try track.paint(testing.allocator, r(0, 6), .auto_placed);
    try track.paint(testing.allocator, r(2, 4), .definitely_placed);
    try testing.expectEqualSlices(OccupiedInterval, &.{ testInterval(0, 2, .auto_placed), testInterval(2, 4, .definitely_placed), testInterval(4, 6, .auto_placed) }, track.intervals.items);

    // Painting over everything replaces all intervals
    try track.paint(testing.allocator, r(-1, 7), .auto_placed);
    try testing.expectEqualSlices(OccupiedInterval, &.{testInterval(-1, 7, .auto_placed)}, track.intervals.items);
}

test "track_intervals: paint overwrites multiple intervals" {
    var track: TrackIntervals = .{};
    defer track.deinit(testing.allocator);
    try track.paint(testing.allocator, r(0, 2), .auto_placed);
    try track.paint(testing.allocator, r(3, 5), .definitely_placed);
    try track.paint(testing.allocator, r(6, 8), .auto_placed);
    try track.paint(testing.allocator, r(1, 7), .definitely_placed);
    try testing.expectEqualSlices(OccupiedInterval, &.{ testInterval(0, 1, .auto_placed), testInterval(1, 7, .definitely_placed), testInterval(7, 8, .auto_placed) }, track.intervals.items);
}

test "track_intervals: collision extent finds extremal occupied cell" {
    var track: TrackIntervals = .{};
    defer track.deinit(testing.allocator);
    try track.paint(testing.allocator, r(2, 4), .auto_placed);
    try track.paint(testing.allocator, r(6, 8), .definitely_placed);
    // The last cell of the last overlapping interval
    try testing.expectEqual(@as(?i16, 7), track.collisionExtent(r(0, 10)));
    try testing.expectEqual(@as(?i16, 7), track.collisionExtent(r(0, 7)));
    try testing.expectEqual(@as(?i16, 3), track.collisionExtent(r(0, 6)));
    try testing.expectEqual(@as(?i16, null), track.collisionExtent(r(4, 6)));
}

test "track_intervals: state_at distinguishes occupied intervals and gaps" {
    var track: TrackIntervals = .{};
    defer track.deinit(testing.allocator);
    try track.paint(testing.allocator, r(0, 2), .definitely_placed);
    try track.paint(testing.allocator, r(2, 4), .auto_placed);
    try track.paint(testing.allocator, r(6, 8), .auto_placed);
    try track.paint(testing.allocator, r(8, 9), .definitely_placed);
    try testing.expectEqual(CellOccupancyState.definitely_placed, track.stateAt(0));
    try testing.expectEqual(CellOccupancyState.auto_placed, track.stateAt(3));
    try testing.expectEqual(CellOccupancyState.unoccupied, track.stateAt(5));
    try testing.expectEqual(CellOccupancyState.auto_placed, track.stateAt(7));
    try testing.expectEqual(CellOccupancyState.definitely_placed, track.stateAt(8));
}

test "track_intervals: definitely placed overwrite hides auto placed cells" {
    var track: TrackIntervals = .{};
    defer track.deinit(testing.allocator);
    try track.paint(testing.allocator, r(0, 4), .auto_placed);
    try track.paint(testing.allocator, r(2, 4), .definitely_placed);
    try testing.expectEqual(CellOccupancyState.auto_placed, track.stateAt(1));
    try testing.expectEqual(CellOccupancyState.definitely_placed, track.stateAt(2));
    try testing.expectEqual(CellOccupancyState.definitely_placed, track.stateAt(3));
}

fn testLine(start: i16, end: i16) Line(OriginZeroLine) {
    return .{ .start = OriginZeroLine.from(start), .end = OriginZeroLine.from(end) };
}

fn oz(value: i16) OriginZeroLine {
    return OriginZeroLine.from(value);
}

test "cell_occupancy_matrix: negative expansion preserves occupancy" {
    const gpa = testing.allocator;
    var matrix = try CellOccupancyMatrix.withTrackCounts(gpa, TrackCounts.fromRaw(0, 2, 0), TrackCounts.fromRaw(0, 2, 0));
    defer matrix.deinit(gpa);
    try matrix.markAreaAs(gpa, .horizontal, testLine(0, 1), testLine(0, 1), .auto_placed);
    // Expand by marking an area in negative tracks
    try matrix.markAreaAs(gpa, .horizontal, testLine(-2, -1), testLine(-1, 0), .auto_placed);

    try testing.expectEqual(TrackCounts.fromRaw(2, 2, 0), matrix.trackCounts(.horizontal));
    try testing.expectEqual(TrackCounts.fromRaw(1, 2, 0), matrix.trackCounts(.vertical));

    // Original cell still occupied at the same OriginZero coordinates
    try testing.expect(!matrix.lineAreaIsUnoccupied(.horizontal, testLine(0, 1), testLine(0, 1)));
    try testing.expect(!matrix.lineAreaIsUnoccupied(.horizontal, testLine(-2, -1), testLine(-1, 0)));
    try testing.expect(matrix.lineAreaIsUnoccupied(.horizontal, testLine(-1, 0), testLine(0, 1)));

    // Matrix-index based queries account for the shifted origin
    try testing.expect(matrix.columnIsOccupied(0)); // OriginZero column -2
    try testing.expect(!matrix.columnIsOccupied(1)); // OriginZero column -1
    try testing.expect(matrix.columnIsOccupied(2)); // OriginZero column 0
    try testing.expect(matrix.rowIsOccupied(0)); // OriginZero row -1
    try testing.expect(matrix.rowIsOccupied(1)); // OriginZero row 0
    try testing.expect(!matrix.rowIsOccupied(2)); // OriginZero row 1
}

test "cell_occupancy_matrix: auto placed item only advances cursor in first secondary track" {
    const gpa = testing.allocator;
    for ([_]AbsoluteAxis{ .horizontal, .vertical }) |axis| {
        var matrix = try CellOccupancyMatrix.withTrackCounts(gpa, TrackCounts.fromRaw(0, 4, 0), TrackCounts.fromRaw(0, 4, 0));
        defer matrix.deinit(gpa);
        try matrix.markAreaAs(gpa, axis, testLine(1, 3), testLine(1, 4), .auto_placed);

        try testing.expectEqual(@as(?OriginZeroLine, oz(3)), matrix.autoPlacementCursor(axis, oz(1)));
        try testing.expectEqual(@as(?OriginZeroLine, null), matrix.autoPlacementCursor(axis, oz(2)));
        try testing.expectEqual(@as(?OriginZeroLine, null), matrix.autoPlacementCursor(axis, oz(3)));

        try testing.expect(!matrix.lineAreaIsUnoccupied(axis, testLine(1, 3), testLine(2, 4)));
    }
}

test "cell_occupancy_matrix: cursors survive interval merging and grid expansion" {
    const gpa = testing.allocator;
    for ([_]AbsoluteAxis{ .horizontal, .vertical }) |axis| {
        var matrix = try CellOccupancyMatrix.withTrackCounts(gpa, TrackCounts.fromRaw(0, 4, 0), TrackCounts.fromRaw(0, 4, 0));
        defer matrix.deinit(gpa);
        try matrix.markAreaAs(gpa, axis, testLine(2, 4), testLine(1, 2), .auto_placed);
        try matrix.markAreaAs(gpa, axis, testLine(4, 8), testLine(0, 2), .auto_placed);
        try matrix.markAreaAs(gpa, axis, testLine(8, 10), testLine(1, 2), .definitely_placed);
        try matrix.markAreaAs(gpa, axis, testLine(-3, -1), testLine(-2, -1), .auto_placed);
        try matrix.markAreaAs(gpa, axis, testLine(12, 14), testLine(7, 8), .auto_placed);
        try matrix.markAreaAs(gpa, axis, testLine(0, 1), testLine(1, 2), .auto_placed);

        try testing.expectEqual(@as(?OriginZeroLine, oz(4)), matrix.autoPlacementCursor(axis, oz(1)));
        try testing.expectEqual(@as(?OriginZeroLine, oz(8)), matrix.autoPlacementCursor(axis, oz(0)));
        try testing.expectEqual(@as(?OriginZeroLine, oz(-1)), matrix.autoPlacementCursor(axis, oz(-2)));
        try testing.expectEqual(@as(?OriginZeroLine, oz(14)), matrix.autoPlacementCursor(axis, oz(7)));
        for ([_]i16{ -3, -1, 2, 8 }) |track| {
            try testing.expectEqual(@as(?OriginZeroLine, null), matrix.autoPlacementCursor(axis, oz(track)));
        }
    }
}

test "cell_occupancy_matrix: alternating spans merge occupancy and skip the occupied prefix" {
    const gpa = testing.allocator;
    for ([_]AbsoluteAxis{ .horizontal, .vertical }) |axis| {
        var matrix = try CellOccupancyMatrix.withTrackCounts(gpa, TrackCounts.fromRaw(0, 0, 0), TrackCounts.fromRaw(0, 0, 0));
        defer matrix.deinit(gpa);
        var i: i16 = 0;
        while (i < 128) : (i += 1) {
            try matrix.markAreaAs(gpa, axis, testLine(i, i + 1), testLine(@mod(i, 2), 2), .auto_placed);
        }

        const track = &matrix.trackLists(axis.otherAxis())[1];
        try testing.expectEqualSlices(OccupiedInterval, &.{testInterval(0, 128, .auto_placed)}, track.intervals.items);
        try testing.expectEqual(@as(?OriginZeroLine, oz(128)), matrix.lineAreaCollisionJump(axis, testLine(0, 1), testLine(1, 2)));
    }
}

test "cell_occupancy_matrix: collision jump returns next search position" {
    const gpa = testing.allocator;
    var matrix = try CellOccupancyMatrix.withTrackCounts(gpa, TrackCounts.fromRaw(0, 4, 0), TrackCounts.fromRaw(0, 4, 0));
    defer matrix.deinit(gpa);
    try matrix.markAreaAs(gpa, .horizontal, testLine(1, 3), testLine(0, 1), .auto_placed);

    // Jump past the end of the last colliding interval
    try testing.expectEqual(@as(?OriginZeroLine, oz(3)), matrix.lineAreaCollisionJump(.horizontal, testLine(0, 2), testLine(0, 1)));
    try testing.expectEqual(@as(?OriginZeroLine, oz(3)), matrix.lineAreaCollisionJump(.horizontal, testLine(0, 4), testLine(0, 1)));
    // No collision in a different row
    try testing.expectEqual(@as(?OriginZeroLine, null), matrix.lineAreaCollisionJump(.horizontal, testLine(0, 4), testLine(1, 2)));
}

test "cell_occupancy_matrix: occupied track jump skips non-empty tracks" {
    const gpa = testing.allocator;
    var matrix = try CellOccupancyMatrix.withTrackCounts(gpa, TrackCounts.fromRaw(0, 4, 0), TrackCounts.fromRaw(0, 4, 0));
    defer matrix.deinit(gpa);
    try matrix.markAreaAs(gpa, .horizontal, testLine(0, 1), testLine(1, 2), .auto_placed);

    // Vertical (row) tracks: row 1 is occupied
    try testing.expectEqual(@as(?OriginZeroLine, oz(2)), matrix.occupiedTrackJump(.vertical, testLine(0, 4)));
    try testing.expectEqual(@as(?OriginZeroLine, null), matrix.occupiedTrackJump(.vertical, testLine(2, 4)));

    // Debug printing
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{&matrix});
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "____\nA___\n") != null);
}
