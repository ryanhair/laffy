const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const NodeId = laffy.NodeId;
const Dimension = laffy.Dimension;
const LengthPercentage = laffy.LengthPercentage;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const AlignItems = laffy.AlignItems;
const AvailableSpace = laffy.AvailableSpace;
const LayoutInput = laffy.LayoutInput;
const LayoutOutput = laffy.LayoutOutput;
const length = laffy.style_helpers.length;
const auto = laffy.style_helpers.auto;
const TestNodeContext = measure.TestNodeContext;
const TaffyTree = laffy.TaffyTree(TestNodeContext);

fn hundredHundred() TestNodeContext {
    return TestNodeContext.fixed(100.0, 100.0);
}
fn hundredFifty() TestNodeContext {
    return TestNodeContext.fixed(100.0, 50.0);
}
fn fiftyFifty() TestNodeContext {
    return TestNodeContext.fixed(50.0, 50.0);
}

fn layoutRoot(taffy: *TaffyTree, node: NodeId) !void {
    try taffy.computeLayoutWithMeasure(node, Size(AvailableSpace).max_content, measure.TestMeasurer{});
}

fn dim(v: f32) Dimension {
    return Dimension.fromLength(v);
}

test "measure_root" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const node = try taffy.newLeafWithContext(Style{}, hundredHundred());
    try layoutRoot(&taffy, node);

    try testing.expectEqual(@as(f32, 100.0), taffy.layout(node).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(node).size.height);
}

test "measure_child" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const child = try taffy.newLeafWithContext(Style{}, hundredHundred());

    const node = try taffy.newWithChildren(Style{}, &.{child});
    try layoutRoot(&taffy, node);

    try testing.expectEqual(@as(f32, 100.0), taffy.layout(node).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(node).size.height);

    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child).size.height);
}

test "measure_child_constraint" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeafWithContext(Style{}, hundredHundred());

    const node = try taffy.newWithChildren(
        .{ .size = .{ .width = dim(50.0), .height = auto(Dimension) } },
        &.{child},
    );

    try layoutRoot(&taffy, node);

    // Parent
    try testing.expectEqual(@as(f32, 50.0), taffy.layout(node).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(node).size.height);
    // Child
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child).size.height);
}

test "measure_child_constraint_padding_parent" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeafWithContext(Style{}, hundredHundred());

    const node = try taffy.newWithChildren(
        .{
            .size = .{ .width = dim(50.0), .height = auto(Dimension) },
            .padding = .{
                .left = LengthPercentage.fromLength(10.0),
                .right = LengthPercentage.fromLength(10.0),
                .top = LengthPercentage.fromLength(10.0),
                .bottom = LengthPercentage.fromLength(10.0),
            },
        },
        &.{child},
    );
    try layoutRoot(&taffy, node);

    try testing.expectEqual(@as(f32, 0.0), taffy.layout(node).location.x);
    try testing.expectEqual(@as(f32, 0.0), taffy.layout(node).location.y);
    try testing.expectEqual(@as(f32, 50.0), taffy.layout(node).size.width);
    try testing.expectEqual(@as(f32, 120.0), taffy.layout(node).size.height);

    try testing.expectEqual(@as(f32, 10.0), taffy.layout(child).location.x);
    try testing.expectEqual(@as(f32, 10.0), taffy.layout(child).location.y);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child).size.height);
}

test "measure_child_with_flex_grow" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child0 = try taffy.newLeaf(.{ .size = .{ .width = dim(50.0), .height = dim(50.0) } });

    const child1 = try taffy.newLeafWithContext(.{ .flex_grow = 1.0 }, fiftyFifty());

    const node = try taffy.newWithChildren(
        .{ .size = .{ .width = dim(100.0), .height = auto(Dimension) } },
        &.{ child0, child1 },
    );

    try layoutRoot(&taffy, node);

    try testing.expectEqual(@as(f32, 50.0), taffy.layout(child1).size.width);
    try testing.expectEqual(@as(f32, 50.0), taffy.layout(child1).size.height);
}

test "measure_child_with_flex_shrink" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child0 = try taffy.newLeaf(.{
        .size = .{ .width = dim(50.0), .height = dim(50.0) },
        .flex_shrink = 0.0,
    });

    const child1 = try taffy.newLeafWithContext(Style{}, hundredFifty());

    const node = try taffy.newWithChildren(
        .{ .size = .{ .width = dim(100.0), .height = auto(Dimension) } },
        &.{ child0, child1 },
    );

    try layoutRoot(&taffy, node);

    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child1).size.width);
    try testing.expectEqual(@as(f32, 50.0), taffy.layout(child1).size.height);
}

test "remeasure_child_after_growing" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child0 = try taffy.newLeaf(.{ .size = .{ .width = dim(50.0), .height = dim(50.0) } });

    const child1 = try taffy.newLeafWithContext(
        .{ .flex_grow = 1.0 },
        TestNodeContext.aspectRatio(10.0, 2.0),
    );

    const node = try taffy.newWithChildren(
        .{
            .size = .{ .width = dim(100.0), .height = auto(Dimension) },
            .align_items = AlignItems.start,
        },
        &.{ child0, child1 },
    );

    try layoutRoot(&taffy, node);

    try testing.expectEqual(@as(f32, 50.0), taffy.layout(child1).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child1).size.height);
}

test "remeasure_child_after_shrinking" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();

    const child0 = try taffy.newLeaf(.{
        .size = .{ .width = dim(50.0), .height = dim(50.0) },
        .flex_shrink = 0.0,
    });

    const child1 = try taffy.newLeafWithContext(Style{}, TestNodeContext.aspectRatio(100.0, 2.0));

    const node = try taffy.newWithChildren(
        .{
            .size = .{ .width = dim(100.0), .height = auto(Dimension) },
            .align_items = AlignItems.start,
        },
        &.{ child0, child1 },
    );

    try layoutRoot(&taffy, node);

    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child1).size.width);
    try testing.expectEqual(@as(f32, 200.0), taffy.layout(child1).size.height);
}

test "remeasure_child_after_stretching" {
    var taffy = try laffy.TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();

    const ContentMeasure = struct {
        pub fn measure(_: @This(), known_dimensions: Size(?f32), _: Size(AvailableSpace)) Size(f32) {
            const height = known_dimensions.height orelse 50.0;
            const width = known_dimensions.width orelse height;
            return .{ .width = width, .height = height };
        }
    };

    const CustomMeasure = struct {
        pub fn measure(_: @This(), inputs: LayoutInput, _: NodeId, _: ?*void, style: *const Style) LayoutOutput {
            return laffy.computeLeafLayout(inputs, style, laffy.NoCalc{}, ContentMeasure{});
        }
    };

    const child = try taffy.newLeafWithContext(Style{}, {});

    const node = try taffy.newWithChildren(
        .{ .size = .{ .width = dim(100.0), .height = dim(100.0) } },
        &.{child},
    );

    try taffy.computeLayoutWithMeasure(node, Size(AvailableSpace).max_content, CustomMeasure{});

    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child).size.height);
}

test "width_overrides_measure" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeafWithContext(
        .{ .size = .{ .width = dim(50.0), .height = auto(Dimension) } },
        hundredHundred(),
    );

    const node = try taffy.newWithChildren(Style{}, &.{child});
    try layoutRoot(&taffy, node);

    try testing.expectEqual(@as(f32, 50.0), taffy.layout(child).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child).size.height);
}

test "height_overrides_measure" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeafWithContext(
        .{ .size = .{ .width = auto(Dimension), .height = dim(50.0) } },
        hundredHundred(),
    );

    const node = try taffy.newWithChildren(Style{}, &.{child});
    try layoutRoot(&taffy, node);

    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child).size.width);
    try testing.expectEqual(@as(f32, 50.0), taffy.layout(child).size.height);
}

test "flex_basis_overrides_measure" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child0 = try taffy.newLeaf(.{ .flex_basis = dim(50.0), .flex_grow = 1.0 });

    const child1 = try taffy.newLeafWithContext(
        .{ .flex_basis = dim(50.0), .flex_grow = 1.0 },
        hundredHundred(),
    );

    const node = try taffy.newWithChildren(
        .{ .size = .{ .width = dim(200.0), .height = dim(100.0) } },
        &.{ child0, child1 },
    );

    try layoutRoot(&taffy, node);

    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child0).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child0).size.height);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child1).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child1).size.height);
}

test "stretch_overrides_measure" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeafWithContext(Style{}, fiftyFifty());

    const node = try taffy.newWithChildren(
        .{ .size = .{ .width = dim(100.0), .height = dim(100.0) } },
        &.{child},
    );

    try layoutRoot(&taffy, node);

    try testing.expectEqual(@as(f32, 50.0), taffy.layout(child).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child).size.height);
}

test "explicit_min_main_size_skips_min_content_measurement" {
    // Upstream asserts inside the measure function; here the violation is recorded and checked
    // after layout (the measure function cannot return an error).
    const AssertNotMinContent = struct {
        saw_min_content: bool = false,

        pub fn measure(self: *@This(), inputs: LayoutInput, _: NodeId, _: ?*void, _: *const Style) LayoutOutput {
            if (inputs.available_space.width == .min_content) self.saw_min_content = true;
            return LayoutOutput.fromOuterSize(.{ .width = 10.0, .height = 10.0 });
        }
    };

    var taffy = try laffy.TaffyTree(void).init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeafWithContext(
        .{ .min_size = .{ .width = length(LengthPercentageAuto, 10.0), .height = auto(LengthPercentageAuto) } },
        {},
    );
    const root = try taffy.newWithChildren(Style{}, &.{child});

    var measurer: AssertNotMinContent = .{};
    try taffy.computeLayoutWithMeasure(root, Size(AvailableSpace).max_content, &measurer);
    try testing.expect(!measurer.saw_min_content);
}

test "measure_absolute_child" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeafWithContext(.{ .position = .absolute }, fiftyFifty());

    const node = try taffy.newWithChildren(
        .{ .size = .{ .width = dim(100.0), .height = dim(100.0) } },
        &.{child},
    );

    try layoutRoot(&taffy, node);

    try testing.expectEqual(@as(f32, 50.0), taffy.layout(child).size.width);
    try testing.expectEqual(@as(f32, 50.0), taffy.layout(child).size.height);
}

test "ignore_invalid_measure" {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const child = try taffy.newLeaf(.{ .flex_grow = 1.0 });

    const node = try taffy.newWithChildren(
        .{ .size = .{ .width = dim(100.0), .height = dim(100.0) } },
        &.{child},
    );

    try layoutRoot(&taffy, node);

    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child).size.width);
    try testing.expectEqual(@as(f32, 100.0), taffy.layout(child).size.height);
}
