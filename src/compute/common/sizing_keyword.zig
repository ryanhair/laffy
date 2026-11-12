//! Shared resolution logic for sizing keywords (`min-content`, `max-content`, `fit-content`,
//! `fit-content(...)`, and `stretch`) on the `width`/`height` style properties
const std = @import("std");
const geometry = @import("../../geometry.zig");
const Line = geometry.Line;
const Rect = geometry.Rect;
const Size = geometry.Size;
const style = @import("../../style.zig");
const AvailableSpace = style.AvailableSpace;
const CompactLength = style.CompactLength;
const Dimension = style.Dimension;
const layout = @import("../../tree/layout.zig");
const LayoutError = layout.LayoutError;
const SizingMode = layout.SizingMode;
const NodeId = @import("../../tree/node.zig").NodeId;
const traits = @import("../../tree/traits.zig");
const sys = @import("../../util/sys.zig");

/// How a sizing keyword resolves to a used size
pub const SizingKeywordResolution = union(enum) {
    /// The size is the result of measuring the item under the given available space constraint
    measure: AvailableSpace,
    /// The size resolves to an exact value without measuring the item
    exact: f32,
};

/// Resolve an item's size style in one axis if it is a sizing keyword (`min-content`,
/// `max-content`, `fit-content`, `fit-content(...)`, or `stretch`).
///
/// - `stretch_size` is the size the item would take if stretched to fill the available space
///   (available space minus margins). Used by `fit-content` and `stretch`.
/// - `percent_resolution_basis` is the size that percentages resolve against in this axis.
///   Used by `fit-content(<percentage>)`.
/// - `calc_resolver` is any value with a `resolveCalcValue(ptr, basis) f32` method (usually the tree).
///
/// Returns `null` if the size style is not a sizing keyword, or if it cannot
/// be resolved in the current context (in which case it behaves as `auto`).
pub fn resolveSizingKeyword(
    size_style: Dimension,
    stretch_size: ?f32,
    percent_resolution_basis: ?f32,
    calc_resolver: anytype,
) ?SizingKeywordResolution {
    const tag = size_style.tag();
    if (tag == CompactLength.min_content_tag) {
        return .{ .measure = .min_content };
    } else if (tag == CompactLength.max_content_tag) {
        return .{ .measure = .max_content };
    } else if (tag == CompactLength.fit_content_px_tag) {
        return .{ .measure = .{ .definite = size_style.value() } };
    } else if (tag == CompactLength.fit_content_percent_tag) {
        const basis = percent_resolution_basis orelse return null;
        return .{ .measure = .{ .definite = basis * size_style.value() } };
    } else if (tag == CompactLength.fit_content_keyword_tag) {
        const size = stretch_size orelse return null;
        return .{ .measure = .{ .definite = size } };
    } else if (size_style.isFitContentCalc()) {
        const basis = percent_resolution_basis orelse return null;
        return .{ .measure = .{ .definite = calc_resolver.resolveCalcValue(size_style.calcValue(), basis) } };
    } else if (tag == CompactLength.stretch_tag) {
        const size = stretch_size orelse return null;
        return .{ .exact = size };
    } else {
        return null;
    }
}

/// Resolve the sizing keywords (`min-content`, `max-content`, `fit-content`, `fit-content(...)`,
/// and `stretch`) on the size styles of an absolutely positioned item, filling in the
/// corresponding `known_dimensions` axes.
///
/// - `area_size` is the size of the item's containing block (which insets and percentages
///   resolve against).
/// - The stretch size in each axis is the containing block minus the item's insets and margins
///   in that axis.
pub fn resolveAbsoluteSizingKeywords(
    tree: anytype,
    node: NodeId,
    known_dimensions: *Size(?f32),
    size_style: Size(Dimension),
    area_size: Size(f32),
    inset: Rect(?f32),
    margin: Rect(?f32),
    sizing_mode: SizingMode,
) LayoutError!void {
    const stretch_size: Size(f32) = .{
        .width = @max(
            area_size.width - (inset.left orelse 0.0) - (inset.right orelse 0.0) - (margin.left orelse 0.0) - (margin.right orelse 0.0),
            0.0,
        ),
        .height = @max(
            area_size.height - (inset.top orelse 0.0) - (inset.bottom orelse 0.0) - (margin.top orelse 0.0) - (margin.bottom orelse 0.0),
            0.0,
        ),
    };
    const area_size_options: Size(?f32) = .{ .width = area_size.width, .height = area_size.height };

    const keyword_width: ?SizingKeywordResolution = if (known_dimensions.width == null)
        resolveSizingKeyword(size_style.width, stretch_size.width, area_size.width, tree)
    else
        null;
    const keyword_height: ?SizingKeywordResolution = if (known_dimensions.height == null)
        resolveSizingKeyword(size_style.height, stretch_size.height, area_size.height, tree)
    else
        null;

    // If both axes need to be measured then resolve them with a single measure call
    if (keyword_width != null and keyword_width.? == .measure and keyword_height != null and keyword_height.? == .measure) {
        const measured_size = try traits.measureChildSizeBoth(
            tree,
            node,
            Size(?f32).none,
            area_size_options,
            .{ .width = keyword_width.?.measure, .height = keyword_height.?.measure },
            sizing_mode,
            Line(bool).false,
        );
        known_dimensions.* = .{ .width = measured_size.width, .height = measured_size.height };
        return;
    }

    if (keyword_width) |resolution| {
        known_dimensions.width = switch (resolution) {
            .exact => |width| width,
            .measure => |available_width| try traits.measureChildSize(
                tree,
                node,
                known_dimensions.*,
                area_size_options,
                .{ .width = available_width, .height = .{ .definite = stretch_size.height } },
                sizing_mode,
                .horizontal,
                Line(bool).false,
            ),
        };
    }
    if (keyword_height) |resolution| {
        known_dimensions.height = switch (resolution) {
            .exact => |height| height,
            .measure => |available_height| try traits.measureChildSize(
                tree,
                node,
                known_dimensions.*,
                area_size_options,
                .{
                    .width = if (known_dimensions.width) |width| .{ .definite = width } else .{ .definite = stretch_size.width },
                    .height = available_height,
                },
                sizing_mode,
                .vertical,
                Line(bool).false,
            ),
        };
    }
}

const testing = std.testing;

test "resolveSizingKeyword" {
    const no_calc = style.NoCalc{};
    try testing.expect(resolveSizingKeyword(Dimension.length(10), 5.0, 5.0, no_calc) == null);
    try testing.expect(resolveSizingKeyword(Dimension.auto, 5.0, 5.0, no_calc) == null);
    try testing.expect(resolveSizingKeyword(Dimension.min_content, null, null, no_calc).?.measure == .min_content);
    try testing.expect(resolveSizingKeyword(Dimension.max_content, null, null, no_calc).?.measure == .max_content);
    try testing.expect(resolveSizingKeyword(Dimension.fitContentPx(30), null, null, no_calc).?.measure.eql(.{ .definite = 30.0 }));
    try testing.expect(resolveSizingKeyword(Dimension.fitContentPercent(0.5), null, 200.0, no_calc).?.measure.eql(.{ .definite = 100.0 }));
    try testing.expect(resolveSizingKeyword(Dimension.fitContentPercent(0.5), null, null, no_calc) == null);
    try testing.expect(resolveSizingKeyword(Dimension.fit_content, 70.0, null, no_calc).?.measure.eql(.{ .definite = 70.0 }));
    try testing.expect(resolveSizingKeyword(Dimension.fit_content, null, null, no_calc) == null);
    try testing.expectEqual(@as(f32, 70.0), resolveSizingKeyword(Dimension.stretch, 70.0, null, no_calc).?.exact);
    try testing.expect(resolveSizingKeyword(Dimension.stretch, null, null, no_calc) == null);
    const calc_value: u64 = 0;
    const fit_calc = Dimension.fitContentCalc(@ptrCast(&calc_value));
    try testing.expect(resolveSizingKeyword(fit_calc, null, 200.0, style.ConstCalc{ .value = 42.0 }).?.measure.eql(.{ .definite = 42.0 }));
}
