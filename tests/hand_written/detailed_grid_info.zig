//! Tests for the detailed grid info exposed by the built-in tree: per-track positions,
//! per-line names, and resolved track list serialization.
const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const Line = laffy.Line;
const Point = laffy.Point;
const NodeId = laffy.NodeId;
const Direction = laffy.Direction;
const Dimension = laffy.Dimension;
const LengthPercentage = laffy.LengthPercentage;
const AvailableSpace = laffy.AvailableSpace;
const GridPlacement = laffy.GridPlacement;
const GridTemplateComponent = laffy.GridTemplateComponent;
const GridTemplateArea = laffy.GridTemplateArea;
const GridTemplateAreas = laffy.GridTemplateAreas;
const GridTemplateRepetition = laffy.GridTemplateRepetition;
const TrackSizingFunction = laffy.TrackSizingFunction;
const DetailedGridInfo = laffy.DetailedGridInfo;
const length = laffy.style_helpers.length;
const line = laffy.style_helpers.line;
const TestNodeContext = measure.TestNodeContext;
const TaffyTree = laffy.TaffyTree(TestNodeContext);

const LineNames = []const []const u8;

fn definite(width: f32, height: f32) Size(AvailableSpace) {
    return .{ .width = .{ .definite = width }, .height = .{ .definite = height } };
}

fn dimSize(w: f32, h: f32) Size(Dimension) {
    return .{ .width = Dimension.fromLength(w), .height = Dimension.fromLength(h) };
}

fn track(v: f32) GridTemplateComponent {
    return length(GridTemplateComponent, v);
}

fn getDetailedGridInfo(tree: *const TaffyTree, node: NodeId) *const DetailedGridInfo {
    return switch (tree.detailedLayoutInfo(node).*) {
        .grid => |info| info,
        else => @panic("expected detailed grid info"),
    };
}

/// The name groups of every line of an axis, in line order (caller frees)
fn collectLineNames(tracks: anytype) !std.ArrayList(LineNames) {
    var out: std.ArrayList(LineNames) = .empty;
    errdefer out.deinit(testing.allocator);
    var it = tracks.iterLineNames();
    while (it.next()) |names| try out.append(testing.allocator, names);
    return out;
}

fn expectNames(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

fn expectColumns(info: *const DetailedGridInfo, zoom: f32, expected: []const u8) !void {
    const s = try info.gridTemplateColumns(testing.allocator, zoom);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(expected, s);
}

fn expectRows(info: *const DetailedGridInfo, zoom: f32, expected: []const u8) !void {
    const s = try info.gridTemplateRows(testing.allocator, zoom);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(expected, s);
}

fn rect(left: f32, right: f32, top: f32, bottom: f32) Rect(f32) {
    return .{ .left = left, .right = right, .top = top, .bottom = bottom };
}

fn lines(start: GridPlacement, end: GridPlacement) Line(GridPlacement) {
    return .{ .start = start, .end = end };
}

fn ln(index: i16) GridPlacement {
    return GridPlacement.fromLineIndex(index);
}

fn named(name: []const u8, index: i16) GridPlacement {
    return .{ .named_line = .{ .name = name, .index = index } };
}

const auto_line = Line(GridPlacement).auto;
const auto_placement: GridPlacement = .auto;

test "no_line_names" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.newLeaf(Style{});
    const root = try tree.newWithChildren(
        .{
            .display = .grid,
            .size = dimSize(100.0, 50.0),
            .grid_template_columns = &.{ track(40.0), track(60.0) },
            .grid_template_rows = &.{track(50.0)},
        },
        &.{child},
    );
    try tree.computeLayout(root, definite(100.0, 50.0));

    const info = getDetailedGridInfo(&tree, root);
    try testing.expect(info.columns.line_names.isEmpty());
    try testing.expect(info.rows.line_names.isEmpty());
    var count: usize = 0;
    var it = info.columns.iterLineNames();
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 0), count);
    try expectColumns(info, 1.0, "40px 60px");
    try expectRows(info, 1.0, "50px");
}

test "zoomed_track_list" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.newLeaf(Style{});
    const root = try tree.newWithChildren(
        .{
            .display = .grid,
            .grid_template_columns = &.{ track(80.0), track(120.0) },
            .grid_template_rows = &.{track(100.0)},
        },
        &.{child},
    );
    try tree.computeLayout(root, definite(200.0, 100.0));

    const info = getDetailedGridInfo(&tree, root);
    try expectColumns(info, 2.0, "40px 60px");
    try expectRows(info, 2.0, "50px");
}

test "template_and_area_line_names" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.newLeaf(Style{});
    const root = try tree.newWithChildren(
        .{
            .display = .grid,
            .size = dimSize(100.0, 50.0),
            .grid_template_columns = &.{ track(40.0), track(60.0) },
            .grid_template_column_names = &.{
                &.{"full-start"},
                &.{"main-start"},
                &.{ "main-end", "full-end" },
            },
            .grid_template_rows = &.{track(50.0)},
            .grid_template_areas = GridTemplateAreas{
                .areas = &.{GridTemplateArea{
                    .name = "hero",
                    .row_start = 1,
                    .row_end = 2,
                    .column_start = 1,
                    .column_end = 3,
                }},
                .row_count = 1,
                .column_count = 2,
            },
        },
        &.{child},
    );
    try tree.computeLayout(root, definite(100.0, 50.0));

    const info = getDetailedGridInfo(&tree, root);
    var column_lines = try collectLineNames(&info.columns);
    defer column_lines.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), column_lines.items.len);
    try expectNames(&.{"full-start"}, column_lines.items[0]);
    try expectNames(&.{"main-start"}, column_lines.items[1]);
    try expectNames(&.{ "main-end", "full-end" }, column_lines.items[2]);
    try expectNames(&.{"main-start"}, info.columns.namesForLine(1));

    // Implicit `<area>-start`/`<area>-end` names are not part of the resolved track list
    var row_lines = try collectLineNames(&info.rows);
    defer row_lines.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), row_lines.items.len);

    try expectColumns(info, 1.0, "[full-start] 40px [main-start] 60px [main-end full-end]");
    try expectRows(info, 1.0, "50px");

    // ...but they still resolve for placement
    try testing.expectEqual(
        rect(0.0, 100.0, 0.0, 50.0),
        info.resolveAbsoluteGridArea(
            lines(ln(1), ln(2)),
            lines(named("hero-start", 1), named("hero-end", 1)),
            .ltr,
            rect(0.0, 100.0, 0.0, 50.0),
        ),
    );
}

test "repeat_expansion_line_names" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.newLeaf(Style{});
    const root = try tree.newWithChildren(
        .{
            .display = .grid,
            .size = dimSize(100.0, 50.0),
            .grid_template_columns = &.{GridTemplateComponent{ .repeat = GridTemplateRepetition{
                .count = .{ .count = 2 },
                .tracks = &.{length(TrackSizingFunction, 50.0)},
                .line_names = &.{ &.{"col-start"}, &.{"col-end"} },
            } }},
            .grid_template_column_names = &.{ &.{"outer-start"}, &.{"outer-end"} },
            .grid_template_rows = &.{track(50.0)},
        },
        &.{child},
    );
    try tree.computeLayout(root, definite(100.0, 50.0));

    const info = getDetailedGridInfo(&tree, root);
    var column_lines = try collectLineNames(&info.columns);
    defer column_lines.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), column_lines.items.len);
    // First repetition's end line collapses with the second repetition's start line,
    // and the last repetition's end line collapses with the following template name set
    try expectNames(&.{ "outer-start", "col-start" }, column_lines.items[0]);
    try expectNames(&.{ "col-end", "col-start" }, column_lines.items[1]);
    try expectNames(&.{ "col-end", "outer-end" }, column_lines.items[2]);

    try expectColumns(info, 1.0, "[outer-start col-start] 50px [col-end col-start] 50px [col-end outer-end]");
}

test "implicit_tracks_shift_line_names" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.newLeaf(.{
        .grid_column = .{ .start = ln(-3), .end = auto_placement },
    });
    const root = try tree.newWithChildren(
        .{
            .display = .grid,
            .size = dimSize(100.0, 50.0),
            .grid_template_columns = &.{track(50.0)},
            .grid_template_column_names = &.{ &.{"a"}, &.{"b"} },
            .grid_template_rows = &.{track(50.0)},
        },
        &.{child},
    );
    try tree.computeLayout(root, definite(100.0, 50.0));

    const info = getDetailedGridInfo(&tree, root);
    try testing.expectEqual(@as(u16, 1), info.columns.negative_implicit_tracks);
    var column_lines = try collectLineNames(&info.columns);
    defer column_lines.deinit(testing.allocator);
    // One leading implicit track: its lines are unnamed, explicit names shift by one
    try testing.expectEqual(@as(usize, 3), column_lines.items.len);
    try testing.expectEqual(@as(usize, 0), column_lines.items[0].len);
    try expectNames(&.{"a"}, column_lines.items[1]);
    try expectNames(&.{"b"}, column_lines.items[2]);
    const first = info.columns.positions.items[0];
    const expected = try std.fmt.allocPrint(testing.allocator, "{d}px [a] 50px [b]", .{first.end - first.start});
    defer testing.allocator.free(expected);
    try expectColumns(info, 1.0, expected);
}

test "item_grid_area" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child_a = try tree.newLeaf(Style{});
    const child_b = try tree.newLeaf(.{
        .grid_row = line(Line(GridPlacement), 2),
        .grid_column = .{ .start = line(GridPlacement, 1), .end = line(GridPlacement, 3) },
    });
    const container = try tree.newWithChildren(
        .{
            .display = .grid,
            .grid_template_columns = &.{ track(40.0), track(60.0) },
            .grid_template_rows = &.{ track(50.0), track(30.0) },
            .gap = length(Size(LengthPercentage), 10.0),
            .padding = length(Rect(LengthPercentage), 5.0),
        },
        &.{ child_a, child_b },
    );

    try tree.computeLayout(container, Size(AvailableSpace).max_content);
    const info = getDetailedGridInfo(&tree, container);

    const Area = DetailedGridInfo.ItemGridArea;
    // child_a is auto-placed into row 1 / column 1
    try testing.expectEqual(
        @as(?Area, .{ .location = .{ .x = 5.0, .y = 5.0 }, .size = .{ .width = 40.0, .height = 50.0 } }),
        info.itemGridArea(0),
    );
    // child_b spans both columns in row 2
    try testing.expectEqual(
        @as(?Area, .{ .location = .{ .x = 5.0, .y = 65.0 }, .size = .{ .width = 110.0, .height = 30.0 } }),
        info.itemGridArea(1),
    );
    // out of bounds index
    try testing.expectEqual(@as(?Area, null), info.itemGridArea(2));

    try testing.expectEqual(
        rect(5.0, 115.0, 5.0, 95.0),
        info.resolveAbsoluteGridArea(
            lines(line(GridPlacement, 1), line(GridPlacement, 3)),
            lines(line(GridPlacement, 1), line(GridPlacement, 3)),
            .ltr,
            rect(0.0, 120.0, 0.0, 100.0),
        ),
    );
    try testing.expectEqual(
        rect(0.0, 45.0, 0.0, 100.0),
        info.resolveAbsoluteGridArea(
            auto_line,
            lines(auto_placement, line(GridPlacement, 2)),
            .ltr,
            rect(0.0, 120.0, 0.0, 100.0),
        ),
    );
    try testing.expectEqual(
        rect(115.0, 120.0, 0.0, 100.0),
        info.resolveAbsoluteGridArea(
            auto_line,
            lines(line(GridPlacement, -1), auto_placement),
            .ltr,
            rect(0.0, 120.0, 0.0, 100.0),
        ),
    );
    try testing.expectEqual(
        // An unknown named line resolves to the first implicit line past the explicit grid,
        // which (being outside the grid) falls back to the padding edge. The resulting
        // start/end pair is swapped, so this is equivalent to `2 / <padding-end>`.
        rect(55.0, 120.0, 0.0, 100.0),
        info.resolveAbsoluteGridArea(
            auto_line,
            lines(named("missing", 1), line(GridPlacement, 2)),
            .ltr,
            rect(0.0, 120.0, 0.0, 100.0),
        ),
    );
    try testing.expectEqual(
        rect(0.0, 120.0, 0.0, 100.0),
        info.resolveAbsoluteGridArea(
            auto_line,
            lines(.{ .span = 2 }, .{ .span = 3 }),
            .ltr,
            rect(0.0, 120.0, 0.0, 100.0),
        ),
    );
}

test "absolute_grid_area_named_span" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.newLeaf(Style{});
    const root = try tree.newWithChildren(
        .{
            .display = .grid,
            .size = dimSize(90.0, 50.0),
            .grid_template_columns = &.{ track(30.0), track(30.0), track(30.0) },
            .grid_template_column_names = &.{ &.{"a"}, &.{"b"}, &.{"b"}, &.{"c"} },
            .grid_template_rows = &.{track(50.0)},
        },
        &.{child},
    );
    try tree.computeLayout(root, definite(90.0, 50.0));

    const info = getDetailedGridInfo(&tree, root);
    try testing.expectEqual(
        rect(0.0, 60.0, 0.0, 50.0),
        info.resolveAbsoluteGridArea(
            auto_line,
            lines(named("a", 1), .{ .named_span = .{ .name = "b", .count = 2 } }),
            .ltr,
            rect(0.0, 90.0, 0.0, 50.0),
        ),
    );
    try testing.expectEqual(
        rect(60.0, 90.0, 0.0, 50.0),
        info.resolveAbsoluteGridArea(
            auto_line,
            lines(named("b", 2), named("c", 1)),
            .ltr,
            rect(0.0, 90.0, 0.0, 50.0),
        ),
    );
}

test "rtl_line_names_are_logical_order" {
    var tree = try TaffyTree.init(testing.allocator);
    defer tree.deinit();
    const child = try tree.newLeaf(Style{});
    const root = try tree.newWithChildren(
        .{
            .display = .grid,
            .direction = .rtl,
            .size = dimSize(100.0, 50.0),
            .grid_template_columns = &.{ track(40.0), track(60.0) },
            .grid_template_column_names = &.{ &.{"a"}, &.{"b"}, &.{"c"} },
            .grid_template_rows = &.{track(50.0)},
        },
        &.{child},
    );
    try tree.computeLayout(root, definite(100.0, 50.0));

    const info = getDetailedGridInfo(&tree, root);
    var column_lines = try collectLineNames(&info.columns);
    defer column_lines.deinit(testing.allocator);
    // Tracks and line names are in logical order regardless of direction
    try expectNames(&.{"a"}, column_lines.items[0]);
    try expectNames(&.{"b"}, column_lines.items[1]);
    try expectNames(&.{"c"}, column_lines.items[2]);
    try expectColumns(info, 1.0, "[a] 40px [b] 60px [c]");

    // Positions hold physical coordinates: logical track 1 is physically rightmost in RTL
    try testing.expectEqual(Line(f32){ .start = 60.0, .end = 100.0 }, info.columns.positions.items[0]);
    try testing.expectEqual(Line(f32){ .start = 0.0, .end = 60.0 }, info.columns.positions.items[1]);
    // itemGridArea resolves the physical rectangle of the (auto-placed) item's grid area
    try testing.expectEqual(
        @as(?DetailedGridInfo.ItemGridArea, .{ .location = .{ .x = 60.0, .y = 0.0 }, .size = .{ .width = 40.0, .height = 50.0 } }),
        info.itemGridArea(0),
    );
    try testing.expectEqual(
        rect(60.0, 100.0, 0.0, 50.0),
        info.resolveAbsoluteGridArea(
            auto_line,
            lines(line(GridPlacement, 1), line(GridPlacement, 2)),
            .rtl,
            rect(0.0, 100.0, 0.0, 50.0),
        ),
    );
    try testing.expectEqual(
        rect(60.0, 100.0, 0.0, 50.0),
        info.resolveAbsoluteGridArea(
            auto_line,
            lines(named("a", 1), named("b", 1)),
            .rtl,
            rect(0.0, 100.0, 0.0, 50.0),
        ),
    );
    try testing.expectEqual(
        rect(0.0, 100.0, 0.0, 50.0),
        info.resolveAbsoluteGridArea(
            auto_line,
            lines(line(GridPlacement, 1), auto_placement),
            .rtl,
            rect(0.0, 100.0, 0.0, 50.0),
        ),
    );
}
