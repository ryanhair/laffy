const std = @import("std");
const laffy = @import("laffy");
const measure = @import("../support/measure.zig");

const testing = std.testing;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const NodeId = laffy.NodeId;
const Display = laffy.Display;
const FlexDirection = laffy.FlexDirection;
const Dimension = laffy.Dimension;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const AvailableSpace = laffy.AvailableSpace;
const LayoutInput = laffy.LayoutInput;
const LayoutOutput = laffy.LayoutOutput;
const TrackSizingFunction = laffy.TrackSizingFunction;
const GridTemplateComponent = laffy.GridTemplateComponent;
const TestNodeContext = measure.TestNodeContext;
const TaffyTree = laffy.TaffyTree(TestNodeContext);

/// Records every `LayoutInput` with a negative known dimension or available space that reaches
/// the measure function, then defers to the test measure function.
const NegativeInputRecorder = struct {
    gpa: std.mem.Allocator,
    negative_inputs: std.ArrayList([]u8) = .empty,

    fn deinit(self: *NegativeInputRecorder) void {
        for (self.negative_inputs.items) |item| self.gpa.free(item);
        self.negative_inputs.deinit(self.gpa);
    }

    fn isNegative(value: ?f32) bool {
        return if (value) |v| v < 0.0 else false;
    }

    fn isNegativeAvail(value: AvailableSpace) bool {
        return switch (value) {
            .definite => |v| v < 0.0,
            else => false,
        };
    }

    pub fn measure(self: *NegativeInputRecorder, inputs: LayoutInput, node_id: NodeId, context: ?*TestNodeContext, style: *const Style) LayoutOutput {
        const known = inputs.known_dimensions;
        const avail = inputs.available_space;
        if (isNegative(known.width) or isNegative(known.height) or isNegativeAvail(avail.width) or isNegativeAvail(avail.height)) {
            const message = std.fmt.allocPrint(self.gpa, "known={any} available={any}", .{ known, avail }) catch @panic("OOM");
            self.negative_inputs.append(self.gpa, message) catch @panic("OOM");
        }
        return measure_mod.testMeasureFunction(inputs, node_id, context, style);
    }
};
const measure_mod = measure;

const Result = struct { leaf_width: f32, recorder: NegativeInputRecorder };

/// Lays out a 20px wide container of the given display type with a single leaf whose
/// horizontal margins (40px) exceed the container width. Returns the leaf's final width
/// and every `LayoutInput` with a negative known dimension or available space that reached
/// the leaf's measure function.
fn layoutWithOversizedMargins(display: Display, flex_direction: FlexDirection) !Result {
    var taffy = try TaffyTree.init(testing.allocator);
    defer taffy.deinit();
    const leaf = try taffy.newLeafWithContext(
        .{
            .margin = .{
                .left = LengthPercentageAuto.fromLength(30.0),
                .right = LengthPercentageAuto.fromLength(10.0),
                .top = LengthPercentageAuto.zero,
                .bottom = LengthPercentageAuto.zero,
            },
            .size = .{ .width = .auto, .height = .auto },
        },
        TestNodeContext.zero(),
    );
    const columns = [_]GridTemplateComponent{GridTemplateComponent.fromLength(20.0)};
    const root = try taffy.newWithChildren(
        .{
            .display = display,
            .flex_direction = flex_direction,
            .size = .{ .width = Dimension.fromLength(20.0), .height = .auto },
            .grid_template_columns = &columns,
        },
        &.{leaf},
    );

    var recorder: NegativeInputRecorder = .{ .gpa = testing.allocator };
    errdefer recorder.deinit();
    try taffy.computeLayoutWithMeasure(root, Size(AvailableSpace).max_content, &recorder);

    return .{ .leaf_width = taffy.layout(leaf).size.width, .recorder = recorder };
}

fn assertFlooredAtZero(display: Display, flex_direction: FlexDirection) !void {
    var result = try layoutWithOversizedMargins(display, flex_direction);
    defer result.recorder.deinit();
    if (result.recorder.negative_inputs.items.len != 0) {
        std.debug.print("leaf received negative layout inputs:\n", .{});
        for (result.recorder.negative_inputs.items) |item| std.debug.print("  {s}\n", .{item});
    }
    try testing.expect(result.recorder.negative_inputs.items.len == 0);
    try testing.expectEqual(@as(f32, 0.0), result.leaf_width);
}

test "block_child_margins_exceed_container_width" {
    try assertFlooredAtZero(.block, .row);
}

test "flex_column_child_margins_exceed_container_width" {
    try assertFlooredAtZero(.flex, .column);
}

test "grid_child_margins_exceed_container_width" {
    try assertFlooredAtZero(.grid, .row);
}
