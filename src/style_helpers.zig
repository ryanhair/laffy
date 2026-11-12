//! Helper functions which make it easier to create instances of types in the `style` and `geometry` modules.
//!
//! Upstream makes these generic over the target type with traits (`TaffyZero`, `TaffyAuto`,
//! `TaffyMinContent`, `TaffyMaxContent`, `TaffyFitContent`, `FromLength`, `FromPercent`, `FromFr`,
//! `TaffyGridLine`, `TaffyGridSpan`). In laffy each type provides the corresponding declarations
//! directly, and the free functions below take the target type as their first (comptime) argument:
//!
//! | upstream trait     | declaration on the type             | free function                |
//! | ------------------ | ----------------------------------- | ---------------------------- |
//! | `TaffyZero`        | `T.zero`                            | `zero(T)`                    |
//! | `TaffyAuto`        | `T.auto`                            | `auto(T)`                    |
//! | `TaffyMinContent`  | `T.min_content`                     | `minContent(T)`              |
//! | `TaffyMaxContent`  | `T.max_content`                     | `maxContent(T)`              |
//! | `TaffyFitContent`  | `T.fitContent(lp: LengthPercentage)` | `fitContent(T, lp)`          |
//! | `FromLength`       | `T.fromLength(value: anytype)`      | `length(T, value)`           |
//! | `FromPercent`      | `T.fromPercent(value: anytype)`     | `percent(T, value)`          |
//! | `FromFr`           | `T.fromFr(value: anytype)`          | `fr(T, value)`               |
//! | `TaffyGridLine`    | `T.fromLineIndex(index: i16)`       | `line(T, index)`             |
//! | `TaffyGridSpan`    | `T.fromSpan(span: u16)`             | `span(T, count)`             |
//!
//! `f32` and optionals are handled by the free functions themselves (`zero(f32) == 0.0`,
//! `zero(?T) == zero(T)`, `length(?f32, 5) == 5.0`, ...), mirroring the upstream impls for
//! `f32` and `Option<T>`. `Size`, `Rect`, `Line` and `Point` provide every declaration in terms
//! of their element type, so e.g. `Size(Dimension).auto` and `Rect(LengthPercentage).zero` work.
//!
//! The `value` arguments accept any integer or float (upstream `Into<f64>`); they are converted
//! via `f64` to `f32` like upstream.
const std = @import("std");
const toF32 = @import("style/compact_length.zig").toF32;
const LengthPercentage = @import("style/dimension.zig").LengthPercentage;
const grid = @import("style/grid.zig");
const GridTemplateComponent = grid.GridTemplateComponent;
const GridTemplateRepetition = grid.GridTemplateRepetition;
const MaxTrackSizingFunction = grid.MaxTrackSizingFunction;
const MinTrackSizingFunction = grid.MinTrackSizingFunction;
const RepetitionCount = grid.RepetitionCount;
const TrackSizingFunction = grid.TrackSizingFunction;

/// Returns the zero value for that type
pub inline fn zero(comptime T: type) T {
    if (T == f32) {
        return 0.0;
    } else if (@typeInfo(T) == .optional) {
        return zero(@typeInfo(T).optional.child);
    } else {
        return T.zero;
    }
}

/// Returns the auto value for that type
pub inline fn auto(comptime T: type) T {
    if (@typeInfo(T) == .optional) {
        return auto(@typeInfo(T).optional.child);
    } else {
        return T.auto;
    }
}

/// Returns the min-content value for that type
pub inline fn minContent(comptime T: type) T {
    if (@typeInfo(T) == .optional) {
        return minContent(@typeInfo(T).optional.child);
    } else {
        return T.min_content;
    }
}

/// Returns the max-content value for that type
pub inline fn maxContent(comptime T: type) T {
    if (@typeInfo(T) == .optional) {
        return maxContent(@typeInfo(T).optional.child);
    } else {
        return T.max_content;
    }
}

/// Returns a value of the requested type which represent a `fit-content(…)` value
/// with the given argument.
pub inline fn fitContent(comptime T: type, argument: LengthPercentage) T {
    return T.fitContent(argument);
}

/// Returns a value of the requested type which represent an absolute length
pub inline fn length(comptime T: type, value: anytype) T {
    if (T == f32 or T == ?f32) {
        return toF32(value);
    } else {
        return T.fromLength(value);
    }
}

/// Returns a value of the requested type which represent a percentage
pub inline fn percent(comptime T: type, value: anytype) T {
    if (T == f32 or T == ?f32) {
        return toF32(value);
    } else {
        return T.fromPercent(value);
    }
}

/// Create a `Fraction` track sizing function (`fr` in CSS)
pub inline fn fr(comptime T: type, flex_value: anytype) T {
    return T.fromFr(flex_value);
}

/// Specifies a grid line to place a grid item between in CSS Grid Line coordinates:
///  - Positive indices count upwards from the start (top or left) of the explicit grid
///  - Negative indices count downwards from the end (bottom or right) of the explicit grid
///  - ZERO IS INVALID index, and will be treated as a GridPlacement::Auto.
///
/// `T` is `GridPlacement` or `Line(GridPlacement)`.
pub inline fn line(comptime T: type, index: i16) T {
    return T.fromLineIndex(index);
}

/// Returns a `GridPlacement.span` (or a `Line(GridPlacement)` starting with one)
pub inline fn span(comptime T: type, count: u16) T {
    return T.fromSpan(count);
}

/// Returns a MinMax with min value of min and max value of max.
///
/// `Output` is `TrackSizingFunction` or `GridTemplateComponent` (upstream: any type that
/// implements `From<MinMax<MinTrackSizingFunction, MaxTrackSizingFunction>>`).
pub inline fn minmax(comptime Output: type, min: MinTrackSizingFunction, max: MaxTrackSizingFunction) Output {
    const track: TrackSizingFunction = .{ .min = min, .max = max };
    if (Output == TrackSizingFunction) {
        return track;
    } else {
        return Output.fromMinMax(track);
    }
}

/// Shorthand for minmax(0, Nfr). Probably what you want if you want exactly evenly sized tracks.
pub inline fn flex(comptime Output: type, flex_fraction: anytype) Output {
    return minmax(Output, zero(MinTrackSizingFunction), fr(MaxTrackSizingFunction, flex_fraction));
}

/// Returns an auto-repeated track definition.
///
/// `repetition_kind` may be a `RepetitionCount`, an integer (repeat count), or the string
/// "auto-fit" / "auto-fill" (panics on any other string, as upstream's `unwrap()` does).
/// `tracks` is borrowed by the returned value.
pub fn repeat(repetition_kind: anytype, tracks: []const TrackSizingFunction) GridTemplateComponent {
    return .{ .repeat = .{
        .count = toRepetitionCount(repetition_kind),
        .tracks = tracks,
        .line_names = &.{},
    } };
}

fn toRepetitionCount(value: anytype) RepetitionCount {
    const T = @TypeOf(value);
    if (T == RepetitionCount) {
        return value;
    } else if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) {
        return .{ .count = @intCast(value) };
    } else {
        const str: []const u8 = value;
        return RepetitionCount.tryFromStr(str) catch
            @panic("&str can only be converted to GridTrackRepetition if it's value is 'auto-fit' or 'auto-fill'");
    }
}

/// A single `1fr` track (`flex(1.0)`), used by `evenlySizedTracks`
const one_fr_track = [1]TrackSizingFunction{flex(TrackSizingFunction, 1.0)};

/// Returns a grid template containing `count` evenly sized tracks
///
/// Upstream returns a `Vec`; laffy returns a one-element array by value. The repeated track list
/// points to static memory, so the result needs no allocation and no cleanup.
pub fn evenlySizedTracks(count: u16) [1]GridTemplateComponent {
    return .{repeat(count, &one_fr_track)};
}

const testing = std.testing;
const geometry = @import("geometry.zig");
const Size = geometry.Size;
const Rect = geometry.Rect;
const Line = geometry.Line;
const Point = geometry.Point;
const dimension = @import("style/dimension.zig");
const Dimension = dimension.Dimension;
const LengthPercentageAuto = dimension.LengthPercentageAuto;
const AvailableSpace = @import("style/available_space.zig").AvailableSpace;
const CompactLength = @import("style/compact_length.zig").CompactLength;
const GridPlacement = grid.GridPlacement;

const TEST_VEC: []const TrackSizingFunction = &.{};

test "repeat u16" {
    try testing.expectEqualDeep(
        GridTemplateComponent{ .repeat = .{ .count = .{ .count = 123 }, .tracks = TEST_VEC, .line_names = &.{} } },
        repeat(@as(u16, 123), TEST_VEC),
    );
}

test "repeat auto-fit str" {
    try testing.expectEqualDeep(
        GridTemplateComponent{ .repeat = .{ .count = .auto_fit, .tracks = TEST_VEC, .line_names = &.{} } },
        repeat("auto-fit", TEST_VEC),
    );
}

test "repeat auto-fill str" {
    try testing.expectEqualDeep(
        GridTemplateComponent{ .repeat = .{ .count = .auto_fill, .tracks = TEST_VEC, .line_names = &.{} } },
        repeat("auto-fill", TEST_VEC),
    );
}

test "zero / auto / min-content / max-content for every type" {
    try testing.expectEqual(@as(f32, 0.0), zero(f32));
    try testing.expectEqual(@as(?f32, 0.0), zero(?f32));
    try testing.expect(zero(Dimension) == Dimension.length(0.0));
    try testing.expect(zero(LengthPercentage) == LengthPercentage.length(0.0));
    try testing.expect(zero(CompactLength) == CompactLength.length(0.0));
    try testing.expect(zero(AvailableSpace).eql(.{ .definite = 0.0 }));
    try testing.expect(zero(?Dimension).? == Dimension.zero);
    try testing.expect(auto(Dimension) == Dimension.auto);
    try testing.expect(auto(?LengthPercentageAuto).? == LengthPercentageAuto.auto);
    try testing.expect(auto(GridPlacement) == .auto);
    try testing.expect(minContent(Dimension) == Dimension.min_content);
    try testing.expect(maxContent(Dimension) == Dimension.max_content);
    try testing.expect(minContent(AvailableSpace).eql(.min_content));
    try testing.expect(maxContent(AvailableSpace).eql(.max_content));
    try testing.expect(minContent(TrackSizingFunction).eql(TrackSizingFunction.min_content));
    try testing.expect(maxContent(GridTemplateComponent).single.eql(TrackSizingFunction.max_content));

    const s = Size(Dimension).auto;
    try testing.expect(s.width == Dimension.auto and s.height == Dimension.auto);
    const r = Rect(LengthPercentage).zero;
    try testing.expect(r.left == LengthPercentage.zero and r.bottom == LengthPercentage.zero);
    const l = Line(Dimension).min_content;
    try testing.expect(l.start == Dimension.min_content and l.end == Dimension.min_content);
    const p = Point(Dimension).max_content;
    try testing.expect(p.x == Dimension.max_content and p.y == Dimension.max_content);
    try testing.expectEqual(Point(?f32){ .x = 0, .y = 0 }, Point(?f32).zero);
    const sa = Size(AvailableSpace).max_content;
    try testing.expect(sa.width.eql(.max_content) and sa.height.eql(.max_content));
    const ls = Line(GridPlacement).auto;
    try testing.expect(ls.start == .auto and ls.end == .auto);
}

test "length / percent / fr / fit-content" {
    try testing.expectEqual(@as(f32, 5.0), length(f32, 5));
    try testing.expectEqual(@as(?f32, 5.0), length(?f32, @as(u8, 5)));
    try testing.expectEqual(@as(f32, 0.5), percent(f32, 0.5));
    try testing.expect(length(Dimension, 10) == Dimension.length(10));
    try testing.expect(percent(LengthPercentageAuto, 0.25) == LengthPercentageAuto.percent(0.25));
    try testing.expect(length(AvailableSpace, 3).eql(.{ .definite = 3 }));
    try testing.expect(fr(MaxTrackSizingFunction, 2) == MaxTrackSizingFunction.fr(2));
    try testing.expect(fr(TrackSizingFunction, 2).eql(.{ .min = MinTrackSizingFunction.auto, .max = MaxTrackSizingFunction.fr(2) }));
    try testing.expect(fr(GridTemplateComponent, 1).single.eql(TrackSizingFunction.fromFr(1)));
    try testing.expect(fr(CompactLength, 1) == CompactLength.fr(1));
    try testing.expect(fitContent(CompactLength, LengthPercentage.length(10)) == CompactLength.fitContentPx(10));
    try testing.expect(fitContent(CompactLength, LengthPercentage.percent(0.5)) == CompactLength.fitContentPercent(0.5));
    try testing.expect(fitContent(MaxTrackSizingFunction, LengthPercentage.length(10)) == MaxTrackSizingFunction.fitContentPx(10));
    try testing.expect(fitContent(TrackSizingFunction, LengthPercentage.length(10)).eql(.{ .min = MinTrackSizingFunction.auto, .max = MaxTrackSizingFunction.fitContentPx(10) }));
    try testing.expect(fitContent(GridTemplateComponent, LengthPercentage.length(10)).single.eql(TrackSizingFunction.fitContent(LengthPercentage.length(10))));
    const sl = Size(Dimension).length(4);
    try testing.expect(sl.width == Dimension.length(4) and sl.height == Dimension.length(4));
    const rp = Rect(LengthPercentage).percent(0.1);
    try testing.expect(rp.top == LengthPercentage.percent(0.1));
    const lf = Line(TrackSizingFunction).fitContent(LengthPercentage.length(3));
    try testing.expect(lf.end.eql(TrackSizingFunction.fitContent(LengthPercentage.length(3))));
    const pl = Point(f32).length(2);
    try testing.expectEqual(Point(f32){ .x = 2, .y = 2 }, pl);
    try testing.expect(length(TrackSizingFunction, 5).eql(.{ .min = MinTrackSizingFunction.length(5), .max = MaxTrackSizingFunction.length(5) }));
    try testing.expect(percent(GridTemplateComponent, 0.5).single.eql(TrackSizingFunction.fromPercent(0.5)));
    try testing.expect(zero(GridTemplateComponent).single.eql(TrackSizingFunction.zero));
}

test "line / span / minmax / flex / evenly sized tracks" {
    try testing.expect(line(GridPlacement, 3).eql(.{ .line = .{ .inner = 3 } }));
    const l = line(Line(GridPlacement), -1);
    try testing.expect(l.start.eql(.{ .line = .{ .inner = -1 } }) and l.end == .auto);
    try testing.expect(span(GridPlacement, 2).eql(.{ .span = 2 }));
    const ls = span(Line(GridPlacement), 2);
    try testing.expect(ls.start.eql(.{ .span = 2 }) and ls.end == .auto);

    const mm = minmax(TrackSizingFunction, MinTrackSizingFunction.length(1), MaxTrackSizingFunction.fr(1));
    try testing.expect(mm.eql(.{ .min = MinTrackSizingFunction.length(1), .max = MaxTrackSizingFunction.fr(1) }));
    const mmc = minmax(GridTemplateComponent, MinTrackSizingFunction.length(1), MaxTrackSizingFunction.fr(1));
    try testing.expect(mmc.single.eql(mm));
    try testing.expect(flex(TrackSizingFunction, 2).eql(.{ .min = MinTrackSizingFunction.zero, .max = MaxTrackSizingFunction.fr(2) }));

    const tracks = evenlySizedTracks(4);
    try testing.expectEqual(RepetitionCount{ .count = 4 }, tracks[0].repeat.count);
    try testing.expectEqual(@as(usize, 1), tracks[0].repeat.tracks.len);
    try testing.expect(tracks[0].repeat.tracks[0].eql(flex(TrackSizingFunction, 1.0)));
    try testing.expect(repeat(@as(RepetitionCount, .auto_fill), TEST_VEC).isAutoRepetition());
}
