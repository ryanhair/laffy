//! Helpers for use in unit tests within the grid module
const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("../../../geometry.zig");
const Line = geometry.Line;
const Size = geometry.Size;
const style_mod = @import("../../../style.zig");
const AlignSelf = style_mod.AlignSelf;
const Dimension = style_mod.Dimension;
const GridPlacement = style_mod.GridPlacement;
const GridTemplateComponent = style_mod.GridTemplateComponent;
const Style = style_mod.Style;
const NodeId = @import("../../../tree/node.zig").NodeId;
const types = @import("../types.zig");
const GridItem = types.GridItem;
const GridLine = types.GridLine;
const NamedLineResolver = types.NamedLineResolver;
const OriginZeroLine = types.OriginZeroLine;
const ItemPlacement = @import("../placement.zig").ItemPlacement;

/// Create a `GridItem` (with start alignment) for each `(index, style)` pair, as `computeGridLayout` does
/// for the in-flow children of a grid container. The caller owns the returned slice.
pub fn gridItems(gpa: Allocator, indexes: []const usize, styles: []const Style) Allocator.Error![]GridItem {
    const items = try gpa.alloc(GridItem, styles.len);
    for (items, indexes, styles) |*item, index, *style| {
        item.* = GridItem.newWithStyleAndOrder(NodeId.fromUsize(index), style, AlignSelf.start, AlignSelf.start, @intCast(index));
    }
    return items;
}

/// Resolve the named lines in the `grid-row`/`grid-column` styles of the given child styles (and convert them to
/// origin-zero coordinates), as `computeGridLayout` does before estimating the grid size and placing items.
/// The caller owns the returned slice.
pub fn resolveNamedLines(
    gpa: Allocator,
    child_styles: []const Style,
    name_resolver: *const NamedLineResolver,
    explicit_col_count: u16,
    explicit_row_count: u16,
) Allocator.Error![]ItemPlacement {
    const placements = try gpa.alloc(ItemPlacement, child_styles.len);
    for (placements, child_styles) |*placement, *style| {
        placement.* = .{
            .horizontal = name_resolver.resolveColumnNames(style.grid_column).intoOriginZero(explicit_col_count),
            .vertical = name_resolver.resolveRowNames(style.grid_row).intoOriginZero(explicit_row_count),
        };
    }
    return placements;
}

/// Upstream `CreateParentTestNode::into_grid` for `(width, height, columns, rows)`: a grid with `columns`
/// columns and `rows` rows of `1fr`. The track lists are allocated; free them with `freeGrid`.
pub fn intoGrid(gpa: Allocator, width: f32, height: f32, columns: usize, rows: usize) Allocator.Error!Style {
    const column_tracks = try gpa.alloc(GridTemplateComponent, columns);
    errdefer gpa.free(column_tracks);
    @memset(column_tracks, GridTemplateComponent.fromFr(1.0));
    const row_tracks = try gpa.alloc(GridTemplateComponent, rows);
    @memset(row_tracks, GridTemplateComponent.fromFr(1.0));
    var style: Style = .{ .display = .grid };
    style.size = .{ .width = Dimension.fromLength(width), .height = Dimension.fromLength(height) };
    style.grid_template_columns = column_tracks;
    style.grid_template_rows = row_tracks;
    return style;
}

/// Free the track lists of a style created by `intoGrid`
pub fn freeGrid(gpa: Allocator, style: *Style) void {
    gpa.free(style.grid_template_columns);
    gpa.free(style.grid_template_rows);
}

/// Upstream `CreateChildTestNode::into_grid_child` for `(column start, column end, row start, row end)`
pub fn intoGridChild(column_start: GridPlacement, column_end: GridPlacement, row_start: GridPlacement, row_end: GridPlacement) Style {
    var style: Style = .{ .display = .grid };
    style.grid_column = .{ .start = column_start, .end = column_end };
    style.grid_row = .{ .start = row_start, .end = row_end };
    return style;
}

/// Upstream `CreateExpectedPlacement::into_oz`
pub fn intoOz(placement: struct { i16, i16, i16, i16 }) struct { OriginZeroLine, OriginZeroLine, OriginZeroLine, OriginZeroLine } {
    return .{ OriginZeroLine.from(placement[0]), OriginZeroLine.from(placement[1]), OriginZeroLine.from(placement[2]), OriginZeroLine.from(placement[3]) };
}

/// Upstream `style_helpers::line` for `GridPlacement`
pub fn line(index: i16) GridPlacement {
    return .{ .line = GridLine.from(index) };
}

/// Upstream `style_helpers::span` for `GridPlacement`
pub fn span(count: u16) GridPlacement {
    return .{ .span = count };
}
