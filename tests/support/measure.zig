//! Port of upstream's shared test helper crate (`tests/common/src/lib.rs`): the node context,
//! the measure data variants and the test measure function used by the fixture runner.

const std = @import("std");
const laffy = @import("laffy");

const Size = laffy.Size;
const AvailableSpace = laffy.AvailableSpace;
const AbsoluteAxis = laffy.AbsoluteAxis;
const LayoutInput = laffy.LayoutInput;
const LayoutOutput = laffy.LayoutOutput;
const NodeId = laffy.NodeId;
const Style = laffy.Style;

/// Whether text is horizontal or vertical
pub const WritingMode = enum { horizontal, vertical };

/// Measure data for nodes that returns results based on an intrinsic aspect ratio
pub const AspectRatioMeasureData = struct {
    width: f32,
    height_ratio: f32,

    fn measure(self: AspectRatioMeasureData, known_dimensions: Size(?f32)) Size(f32) {
        const width = known_dimensions.width orelse self.width;
        const height = known_dimensions.height orelse width * self.height_ratio;
        return .{ .width = width, .height = height };
    }
};

/// Measure data for nodes contain text using the Ahem testing font
pub const AhemTextMeasureData = struct {
    /// The text string (borrowed)
    text_content: []const u8,
    /// The writing mode
    writing_mode: WritingMode,

    fn measure(self: AhemTextMeasureData, known_dimensions: Size(?f32), available_space: Size(AvailableSpace)) Size(f32) {
        const zws = "\u{200B}";
        const h_width: f32 = 10.0;
        const h_height: f32 = 10.0;

        const inline_axis: AbsoluteAxis = switch (self.writing_mode) {
            .horizontal => .horizontal,
            .vertical => .vertical,
        };
        const block_axis = inline_axis.otherAxis();

        // `str::split` always yields at least one (possibly empty) item, so `lines` is never empty.
        // Lengths are in bytes, like Rust's `str::len`.
        var min_line_length: usize = 0;
        var max_line_length: usize = 0;
        {
            var it = std.mem.splitSequence(u8, self.text_content, zws);
            while (it.next()) |line| {
                min_line_length = @max(min_line_length, line.len);
                max_line_length += line.len;
            }
        }

        const min_f: f32 = @floatFromInt(min_line_length);
        const max_f: f32 = @floatFromInt(max_line_length);
        const inline_size = @max(known_dimensions.getAbs(inline_axis) orelse switch (available_space.getAbs(inline_axis)) {
            .min_content => min_f * h_width,
            .max_content => max_f * h_width,
            .definite => |d| @min(d, max_f * h_width),
        }, min_f * h_width);

        const block_size = known_dimensions.getAbs(block_axis) orelse blk: {
            // Rust's float to `usize` cast saturates (and maps NaN and negatives to 0)
            const fl = @floor(inline_size / h_width);
            const inline_line_length: usize = if (fl > 0) @intFromFloat(@min(fl, @as(f32, @floatFromInt(std.math.maxInt(u32))))) else 0;
            var line_count: usize = 1;
            var current_line_length: usize = 0;
            var it = std.mem.splitSequence(u8, self.text_content, zws);
            while (it.next()) |line| {
                if (current_line_length + line.len > inline_line_length) {
                    if (current_line_length > 0) line_count += 1;
                    current_line_length = line.len;
                } else {
                    current_line_length += line.len;
                }
            }
            const count: f32 = @floatFromInt(line_count);
            break :blk count * h_height;
        };

        return switch (self.writing_mode) {
            .horizontal => .{ .width = inline_size, .height = block_size },
            .vertical => .{ .width = block_size, .height = inline_size },
        };
    }
};

/// The measurement data for the node
pub const TestMeasureData = union(enum) {
    /// A zero-sized node
    zero,
    /// A node with a fixed size
    fixed: Size(f32),
    /// A node with a width and an aspect ratio
    aspect_ratio: AspectRatioMeasureData,
    /// A node with text using the Ahem font
    ahem_text: AhemTextMeasureData,
};

/// A shared node context for tests
pub const TestNodeContext = struct {
    /// How many times the measure function has been called
    count: usize = 0,
    /// The measurement data to compute the intrinsic size from
    measure_data: TestMeasureData,

    pub fn new(measure_data: TestMeasureData) TestNodeContext {
        return .{ .measure_data = measure_data };
    }

    pub fn zero() TestNodeContext {
        return new(.zero);
    }

    pub fn fixed(width: f32, height: f32) TestNodeContext {
        return new(.{ .fixed = .{ .width = width, .height = height } });
    }

    pub fn aspectRatio(width: f32, height_ratio: f32) TestNodeContext {
        return new(.{ .aspect_ratio = .{ .width = width, .height_ratio = height_ratio } });
    }

    /// `text_content` is borrowed and must outlive the context.
    pub fn ahemText(text_content: []const u8, writing_mode: WritingMode) TestNodeContext {
        return new(.{ .ahem_text = .{ .text_content = text_content, .writing_mode = writing_mode } });
    }
};

/// The content measurer handed to `computeLeafLayout`
const ContentMeasure = struct {
    context: ?*TestNodeContext,

    pub fn measure(self: *ContentMeasure, known_dimensions: Size(?f32), available_space: Size(AvailableSpace)) Size(f32) {
        if (known_dimensions.width != null and known_dimensions.height != null) {
            return .{ .width = known_dimensions.width.?, .height = known_dimensions.height.? };
        }

        const context = self.context orelse return .{
            .width = known_dimensions.width orelse 0.0,
            .height = known_dimensions.height orelse 0.0,
        };

        // Increment count
        context.count += 1;

        const compute_size: Size(f32) = switch (context.measure_data) {
            .zero => Size(f32).zero,
            .fixed => |size| size,
            .aspect_ratio => |data| data.measure(known_dimensions),
            .ahem_text => |data| data.measure(known_dimensions, available_space),
        };

        return .{
            .width = known_dimensions.width orelse compute_size.width,
            .height = known_dimensions.height orelse compute_size.height,
        };
    }
};

/// A measure function for tests that works with `TestNodeContext` (upstream `test_measure_function`)
pub fn testMeasureFunction(
    inputs: LayoutInput,
    _: NodeId,
    context: ?*TestNodeContext,
    style: *const Style,
) LayoutOutput {
    const is_horizontal_text = if (context) |c| switch (c.measure_data) {
        .ahem_text => |data| data.writing_mode == .horizontal,
        else => false,
    } else false;

    var content: ContentMeasure = .{ .context = context };
    var output = laffy.computeLeafLayout(inputs, style, laffy.NoCalc{}, &content);

    // Ahem text (10px, line-height 1): ascent 8px and descent 2px per line
    if (is_horizontal_text) {
        const padding = laffy.util.resolve.resolveOrZero(style.padding, inputs.parent_size.width, laffy.NoCalc{});
        const border = laffy.util.resolve.resolveOrZero(style.border, inputs.parent_size.width, laffy.NoCalc{});
        const first = padding.top + border.top + 8.0;
        const last = output.size.height - padding.bottom - border.bottom - 2.0;
        output.baselines = .{ .first = first, .last = @max(last, first) };
    }
    return output;
}

/// The measurer value passed to `TaffyTree.computeLayoutWithMeasure`
pub const TestMeasurer = struct {
    pub fn measure(_: TestMeasurer, inputs: LayoutInput, node_id: NodeId, context: ?*TestNodeContext, style: *const Style) LayoutOutput {
        return testMeasureFunction(inputs, node_id, context, style);
    }
};
