//! This module is not required for spec compliance, but is used as a performance optimisation
//! to reduce the number of allocations required when creating a grid.
const std = @import("std");
const geometry = @import("../../geometry.zig");
const Line = geometry.Line;
const OriginZeroGridPlacement = @import("../../style.zig").OriginZeroGridPlacement;
const types = @import("types.zig");
const OriginZeroLine = types.OriginZeroLine;
const TrackCounts = types.TrackCounts;
const max_oz_line = types.max_oz_line;
const min_oz_line = types.min_oz_line;
const ItemPlacement = @import("placement.zig").ItemPlacement;

/// The result of `computeGridSizeEstimate`: (column counts, row counts)
pub const GridSizeEstimate = struct { TrackCounts, TrackCounts };

/// Estimate the number of rows and columns in the grid
/// This is used as a performance optimisation to pre-size vectors and reduce allocations. It also forms a necessary step
/// in the auto-placement
///   - The estimates for the explicit and negative implicit track counts are exact.
///   - However, the estimates for the positive explicit track count is a lower bound as auto-placement can affect this
///     in ways which are impossible to predict until the auto-placement algorithm is run.
///
/// Note that this function internally mixes use of grid track numbers and grid line numbers
pub fn computeGridSizeEstimate(
    explicit_col_count: u16,
    explicit_row_count: u16,
    placements: []const ItemPlacement,
) GridSizeEstimate {
    // Iterate over children, producing an estimate of the min and max grid lines (in origin-zero coordinates where)
    // along with the span of each item
    const known = getKnownChildPositions(placements);

    // Compute *track* count estimates for each axis from:
    //   - The explicit track counts
    //   - The origin-zero coordinate min and max grid line variables
    const negative_implicit_inline_tracks = known.col_min.impliedNegativeImplicitTracks();
    const explicit_inline_tracks = explicit_col_count;
    var positive_implicit_inline_tracks = known.col_max.impliedPositiveImplicitTracks(explicit_col_count);
    const negative_implicit_block_tracks = known.row_min.impliedNegativeImplicitTracks();
    const explicit_block_tracks = explicit_row_count;
    var positive_implicit_block_tracks = known.row_max.impliedPositiveImplicitTracks(explicit_row_count);

    // In each axis, adjust positive track estimate if any items have a span that does not fit within
    // the total number of tracks in the estimate
    const tot_inline_tracks = negative_implicit_inline_tracks + explicit_inline_tracks + positive_implicit_inline_tracks;
    if (tot_inline_tracks < known.col_max_span) {
        positive_implicit_inline_tracks = known.col_max_span - explicit_inline_tracks - negative_implicit_inline_tracks;
    }

    const tot_block_tracks = negative_implicit_block_tracks + explicit_block_tracks + positive_implicit_block_tracks;
    if (tot_block_tracks < known.row_max_span) {
        positive_implicit_block_tracks = known.row_max_span - explicit_block_tracks - negative_implicit_block_tracks;
    }

    const column_counts = TrackCounts.fromRaw(negative_implicit_inline_tracks, explicit_inline_tracks, positive_implicit_inline_tracks);

    const row_counts = TrackCounts.fromRaw(negative_implicit_block_tracks, explicit_block_tracks, positive_implicit_block_tracks);

    return .{ column_counts, row_counts };
}

/// The result of `getKnownChildPositions`
const KnownChildPositions = struct {
    col_min: OriginZeroLine,
    col_max: OriginZeroLine,
    col_max_span: u16,
    row_min: OriginZeroLine,
    row_max: OriginZeroLine,
    row_max_span: u16,
};

/// Iterate over the children's `grid-row`/`grid-column` styles (named lines resolved), producing an estimate of the
/// min and max grid *lines* along with the span of each item
///
/// Min and max grid lines are returned in origin-zero coordinates)
/// The span is measured in tracks spanned
fn getKnownChildPositions(placements: []const ItemPlacement) KnownChildPositions {
    var result: KnownChildPositions = .{
        .col_min = OriginZeroLine.from(0),
        .col_max = OriginZeroLine.from(0),
        .col_max_span = 0,
        .row_min = OriginZeroLine.from(0),
        .row_max = OriginZeroLine.from(0),
        .row_max_span = 0,
    };
    for (placements) |placement| {
        // Note: that the children reference the lines in between (and around) the tracks not tracks themselves,
        // and thus we must subtract 1 to get an accurate estimate of the number of tracks
        const child_col = childMinLineMaxLineSpan(placement.horizontal);
        const child_row = childMinLineMaxLineSpan(placement.vertical);

        result.col_min = OriginZeroLine.min(result.col_min, child_col.min);
        result.col_max = OriginZeroLine.max(result.col_max, child_col.max);
        result.col_max_span = @max(result.col_max_span, child_col.span);
        result.row_min = OriginZeroLine.min(result.row_min, child_row.min);
        result.row_max = OriginZeroLine.max(result.row_max, child_row.max);
        result.row_max_span = @max(result.row_max_span, child_row.span);
    }
    return result;
}

/// The result of `childMinLineMaxLineSpan`
const ChildMinMaxSpan = struct { min: OriginZeroLine, max: OriginZeroLine, span: u16 };

/// Helper function for `computeGridSizeEstimate`
/// Produces a conservative estimate of the greatest and smallest grid lines used by a single grid item
///
/// Values are returned in origin-zero coordinates
fn childMinLineMaxLineSpan(oz_line: Line(OriginZeroGridPlacement)) ChildMinMaxSpan {
    // 8.3.1. Grid Placement Conflict Handling
    // A. If the placement for a grid item contains two lines, and the start line is further end-ward than the end line, swap the two lines.
    // B. If the start line is equal to the end line, remove the end line.
    // C. If the placement contains two spans, remove the one contributed by the end grid-placement property.
    // D. If the placement contains only a span for a named line, replace it with a span of 1.

    const min: OriginZeroLine = switch (oz_line.start) {
        .line => |track1| switch (oz_line.end) {
            // Both tracks specified
            // See rules A and B above
            .line => |track2| if (track1 == track2) track1 else OriginZeroLine.min(track1, track2),
            // Start track specified
            .auto, .span => track1,
        },
        .span => |span| switch (oz_line.end) {
            // End track specified
            .line => |track| track.sub(span),
            // Only spans or autos
            // We ignore spans here by returning 0 which never effect the estimate as these are accounted for separately
            .auto, .span => OriginZeroLine.from(0),
        },
        .auto => switch (oz_line.end) {
            // End track specified
            // An auto start with a definite end resolves to a span of 1 ending at that line
            .line => |track| track.sub(@as(u16, 1)),
            .auto, .span => OriginZeroLine.from(0),
        },
    };

    const max: OriginZeroLine = switch (oz_line.start) {
        .line => |track1| switch (oz_line.end) {
            // Both tracks specified
            // See rules A and B above
            .line => |track2| if (track1 == track2) track1.add(@as(u16, 1)) else OriginZeroLine.max(track1, track2),
            // Start track specified
            .auto => track1.add(@as(u16, 1)),
            .span => |span| track1.add(span),
        },
        .span, .auto => switch (oz_line.end) {
            // End track specified
            .line => |track| track,
            // Only spans or autos
            // We ignore spans here by returning 0 which never effect the estimate as these are accounted for separately
            .auto, .span => OriginZeroLine.from(0),
        },
    };

    // Calculate span only for indefinitely placed items as we don't need for other items (whose required space will
    // be taken into account by min and max)
    const span: u16 = if (oz_line.start != .line and oz_line.end != .line) oz_line.indefiniteSpan() else 1;

    // Clamp the min and max lines into the limited grid so that the estimated implicit track counts
    // stay within the maximum track limit (https://www.w3.org/TR/css-grid-1/#overlarge-grids).
    // This matches the clamping of the actual item placements performed during placement.
    const clamped_min = OriginZeroLine.from(@max(min.inner, min_oz_line));
    const clamped_max = OriginZeroLine.from(@min(max.inner, max_oz_line));

    return .{ .min = clamped_min, .max = clamped_max, .span = span };
}

// ---------------------------------------------------------------------------------------------
// Tests

const testing = std.testing;
const GridPlacement = @import("../../style.zig").GridPlacement;
const Style = @import("../../style.zig").Style;
const NamedLineResolver = types.NamedLineResolver;
const test_helpers = @import("util/test_helpers.zig");
const intoGridChild = test_helpers.intoGridChild;
const gridLine = test_helpers.line;
const gridSpan = test_helpers.span;
const auto = GridPlacement.auto;

test "child min max line auto" {
    const result = childMinLineMaxLineSpan((Line(GridPlacement){ .start = gridLine(5), .end = gridSpan(6) }).intoOriginZeroIgnoringNamed(6));
    try testing.expectEqual(OriginZeroLine.from(4), result.min);
    try testing.expectEqual(OriginZeroLine.from(10), result.max);
    try testing.expectEqual(@as(u16, 1), result.span);
}

test "child min max line negative track" {
    const result = childMinLineMaxLineSpan((Line(GridPlacement){ .start = gridLine(-5), .end = gridSpan(3) }).intoOriginZeroIgnoringNamed(6));
    try testing.expectEqual(OriginZeroLine.from(2), result.min);
    try testing.expectEqual(OriginZeroLine.from(5), result.max);
    try testing.expectEqual(@as(u16, 1), result.span);
}

fn estimate(explicit_col_count: u16, explicit_row_count: u16, child_styles: []const Style) !GridSizeEstimate {
    var name_resolver = try NamedLineResolver.new(testing.allocator, &Style.default, 0, 0);
    defer name_resolver.deinit(testing.allocator);
    name_resolver.setExplicitColumnCount(explicit_col_count);
    name_resolver.setExplicitRowCount(explicit_row_count);
    const placements = try test_helpers.resolveNamedLines(testing.allocator, child_styles, &name_resolver, explicit_col_count, explicit_row_count);
    defer testing.allocator.free(placements);
    return computeGridSizeEstimate(explicit_col_count, explicit_row_count, placements);
}

test "explicit grid sizing with children" {
    const explicit_col_count = 6;
    const explicit_row_count = 8;
    const child_styles = [_]Style{
        intoGridChild(gridLine(1), gridSpan(2), gridLine(2), auto),
        intoGridChild(gridLine(-4), auto, gridLine(-2), auto),
    };
    const inline_counts, const block_counts = try estimate(explicit_col_count, explicit_row_count, &child_styles);
    try testing.expectEqual(@as(u16, 0), inline_counts.negative_implicit);
    try testing.expectEqual(@as(u16, explicit_col_count), inline_counts.explicit);
    try testing.expectEqual(@as(u16, 0), inline_counts.positive_implicit);
    try testing.expectEqual(@as(u16, 0), block_counts.negative_implicit);
    try testing.expectEqual(@as(u16, explicit_row_count), block_counts.explicit);
    try testing.expectEqual(@as(u16, 0), block_counts.positive_implicit);
}

test "negative implicit grid sizing" {
    const explicit_col_count = 4;
    const explicit_row_count = 4;
    const child_styles = [_]Style{
        intoGridChild(gridLine(-6), gridSpan(2), gridLine(-8), auto),
        intoGridChild(gridLine(4), auto, gridLine(3), auto),
    };
    const inline_counts, const block_counts = try estimate(explicit_col_count, explicit_row_count, &child_styles);
    try testing.expectEqual(@as(u16, 1), inline_counts.negative_implicit);
    try testing.expectEqual(@as(u16, explicit_col_count), inline_counts.explicit);
    try testing.expectEqual(@as(u16, 0), inline_counts.positive_implicit);
    try testing.expectEqual(@as(u16, 3), block_counts.negative_implicit);
    try testing.expectEqual(@as(u16, explicit_row_count), block_counts.explicit);
    try testing.expectEqual(@as(u16, 0), block_counts.positive_implicit);
}
