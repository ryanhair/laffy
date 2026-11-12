//! Tests for style inputs which are valid to construct, but which are degenerate or hostile
//! (non-finite numbers, extreme values, or internally inconsistent grid templates).
//!
//! These tests are primarily about layout *terminating* without panicking.
const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Line = laffy.Line;
const Dimension = laffy.Dimension;
const AvailableSpace = laffy.AvailableSpace;
const Direction = laffy.Direction;
const GridPlacement = laffy.GridPlacement;
const GridTemplateComponent = laffy.GridTemplateComponent;
const TrackSizingFunction = laffy.TrackSizingFunction;
const MinTrackSizingFunction = laffy.MinTrackSizingFunction;
const MaxTrackSizingFunction = laffy.MaxTrackSizingFunction;
const repeat = laffy.style_helpers.repeat;
const TaffyTree = laffy.TaffyTree(measure.TestNodeContext);

fn definite(size: f32) Size(AvailableSpace) {
    return .{ .width = .{ .definite = size }, .height = .{ .definite = size } };
}

fn dim(v: f32) Dimension {
    return Dimension.fromLength(v);
}

// A `NaN` flex factor makes every comparison in the "find the size of an fr" algorithm false,
// which used to prevent that algorithm from ever finding a valid hypothetical fr size.
test "non_finite_flex_factor_terminates" {
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |flex_factor| {
        var tree = try TaffyTree.init(testing.allocator);
        defer tree.deinit();
        const child = try tree.newLeaf(.{
            .size = .{ .width = dim(10.0), .height = dim(10.0) },
        });
        const columns = [_]GridTemplateComponent{.{ .single = .{
            .min = MinTrackSizingFunction.auto,
            .max = MaxTrackSizingFunction.fromFr(flex_factor),
        } }};
        const root = try tree.newWithChildren(
            .{
                .display = .grid,
                .grid_template_columns = &columns,
            },
            &.{child},
        );

        try tree.computeLayout(root, definite(100.0));
    }
}

// A non-finite size on a grid container makes the space to fill non-finite, which used to
// prevent the "find the size of an fr" algorithm from terminating.
test "non_finite_grid_container_size_terminates" {
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32) }) |width| {
        var tree = try TaffyTree.init(testing.allocator);
        defer tree.deinit();
        const child = try tree.newLeaf(Style{});
        const tracks = [_]TrackSizingFunction{TrackSizingFunction.fromFr(1.0)};
        const columns = [_]GridTemplateComponent{repeat(2, &tracks)};
        const root = try tree.newWithChildren(
            .{
                .display = .grid,
                .size = .{ .width = dim(width), .height = dim(100.0) },
                .grid_template_columns = &columns,
            },
            &.{child},
        );

        try tree.computeLayout(root, definite(100.0));
    }
}

// `repeat()` definitions are allowed to contain no line name sets at all (the `repeat` style
// helper creates such repetitions). Line numbering must still account for the tracks that
// each repetition generates.
test "repetition_without_line_names_resolves_lines" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.newLeaf(.{
        .size = .{ .width = dim(5.0), .height = dim(5.0) },
        .grid_column = .{ .start = .{ .named_line = .{ .name = "c", .index = 1 } }, .end = .auto },
    });
    const tracks = [_]TrackSizingFunction{TrackSizingFunction.fromLength(10.0)};
    const columns = [_]GridTemplateComponent{ repeat(2, &tracks), GridTemplateComponent.fromLength(10.0) };
    const column_names = [_][]const []const u8{ &.{}, &.{}, &.{"c"} };
    const root = try tree.newWithChildren(
        .{
            .display = .grid,
            .size = .{ .width = dim(100.0), .height = dim(100.0) },
            .grid_template_columns = &columns,
            .grid_template_column_names = &column_names,
        },
        &.{child},
    );

    try tree.computeLayout(root, definite(100.0));

    // "c" is the 4th line of the grid: the line after the three 10px columns
    try testing.expectEqual(@as(f32, 30.0), tree.layout(child).location.x);
}

// A zero span (an invalid value which gets normalized to 1) combined with an unresolvable
// named span used to size the implicit grid estimate to zero tracks, while auto-placement
// resolved the same placement to a span of 1. The auto-placement search then looped forever
// looking for a position that could never fit.
test "zero_span_and_named_span_terminates" {
    for ([_]Direction{ .ltr, .rtl }) |direction| {
        var tree = try TaffyTree.init(testing.allocator);
        defer tree.deinit();
        const child = try tree.newLeaf(.{
            .grid_column = .{
                .start = .{ .named_span = .{ .name = "does-not-exist", .count = 1 } },
                .end = GridPlacement.fromSpan(0),
            },
        });
        const root = try tree.newWithChildren(.{ .display = .grid, .direction = direction }, &.{child});

        try tree.computeLayout(root, definite(100.0));
    }
}

// Not ported: `repetition_with_wrong_line_name_set_count_panics`. Upstream marks it
// `#[should_panic(expected = "line name sets")]`: a non-empty list of line name sets whose length
// does not match `track_count + 1` violates the `GridTemplateRepetition` API contract and must
// panic. Zig tests cannot assert that a panic happens (a panic aborts the test process).

// When auto-placement collides with an occupied area, the search cursor must jump past the
// whole occupied interval. Jumping only within the queried area used to make the search
// advance one track at a time through large occupied areas, so a small item searching a grid
// occupied by a maximum-size item scanned (10000 tracks)^2 candidate positions.
test "small_item_in_max_size_occupied_grid_terminates" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const big = try tree.newLeaf(.{
        .grid_row = .{ .start = GridPlacement.fromSpan(10000), .end = .auto },
        .grid_column = .{ .start = GridPlacement.fromSpan(10000), .end = .auto },
    });
    const small = try tree.newLeaf(.{
        .grid_row = .{ .start = GridPlacement.fromSpan(10000), .end = .auto },
        .grid_column = .{ .start = GridPlacement.fromSpan(1), .end = .auto },
    });
    const root = try tree.newWithChildren(
        .{
            .display = .grid,
            .size = .{ .width = dim(100.0), .height = dim(100.0) },
        },
        &.{ big, small },
    );

    try tree.computeLayout(root, definite(100.0));
}

// Items may span thousands of tracks and be placed thousands of tracks outside of the explicit
// grid. Auto-placing such items must not take an excessive amount of time.
test "extreme_placements_and_spans_terminate" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const placements = [_]Line(GridPlacement){
        .{ .start = .auto, .end = GridPlacement.fromSpan(2000) },
        .{ .start = GridPlacement.fromLineIndex(-2000), .end = GridPlacement.fromLineIndex(2000) },
    };
    var children: [placements.len]laffy.NodeId = undefined;
    for (placements, 0..) |placement, i| {
        children[i] = try tree.newLeaf(.{ .grid_row = placement, .grid_column = placement });
    }
    const root = try tree.newWithChildren(
        .{
            .display = .grid,
            .size = .{ .width = dim(100.0), .height = dim(100.0) },
        },
        &children,
    );

    try tree.computeLayout(root, definite(100.0));
}
