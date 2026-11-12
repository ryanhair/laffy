//! Helper functions for building grid track lists.
//!
//! Single values are built with declarations on the types themselves, for example
//! `Dimension.fromLength(10)`, `LengthPercentageAuto.auto` or `GridPlacement.fromLineIndex(2)`.
//! `Size`, `Rect`, `Line` and `Point` provide the same declarations in terms of their element
//! type, so `Size(Dimension).auto` and `Rect(LengthPercentage).zero` work.
const std = @import("std");
const grid = @import("style/grid.zig");
const GridTemplateComponent = grid.GridTemplateComponent;
const GridTemplateRepetition = grid.GridTemplateRepetition;
const MaxTrackSizingFunction = grid.MaxTrackSizingFunction;
const MinTrackSizingFunction = grid.MinTrackSizingFunction;
const RepetitionCount = grid.RepetitionCount;
const TrackSizingFunction = grid.TrackSizingFunction;

/// Returns a MinMax with min value of min and max value of max.
///
/// `Output` is `TrackSizingFunction` or `GridTemplateComponent` (upstream: any type that
/// implements `From<MinMax<MinTrackSizingFunction, MaxTrackSizingFunction>>`).
pub fn minmax(comptime Output: type, min: MinTrackSizingFunction, max: MaxTrackSizingFunction) Output {
    const track: TrackSizingFunction = .{ .min = min, .max = max };
    if (Output == TrackSizingFunction) {
        return track;
    } else {
        return Output.fromMinMax(track);
    }
}

/// Shorthand for minmax(0, Nfr). Probably what you want if you want exactly evenly sized tracks.
pub fn flex(comptime Output: type, flex_fraction: anytype) Output {
    return minmax(Output, .zero, .fromFr(flex_fraction));
}

/// Returns an auto-repeated track definition.
///
/// `repetition_kind` may be a `RepetitionCount`, an integer (repeat count), or the string
/// "auto-fit" / "auto-fill" (panics on any other string).
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
            @panic("repeat: a string repetition count must be \"auto-fit\" or \"auto-fill\"");
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
const LengthPercentage = dimension.LengthPercentage;
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
    try testing.expect(std.meta.eql(Dimension.zero, Dimension.fromLength(0.0)));
    try testing.expect(std.meta.eql(LengthPercentage.zero, LengthPercentage.fromLength(0.0)));
    try testing.expect(AvailableSpace.zero.eql(.{ .definite = 0.0 }));
    try testing.expect(@as(Dimension, .auto) == .auto);
    try testing.expect(GridPlacement.auto == .auto);
    try testing.expect(@as(Dimension, .min_content) == .min_content);
    try testing.expect(@as(Dimension, .max_content) == .max_content);
    try testing.expect(TrackSizingFunction.min_content.eql(TrackSizingFunction.min_content));
    try testing.expect(GridTemplateComponent.max_content.single.eql(TrackSizingFunction.max_content));

    const s = Size(Dimension).auto;
    try testing.expect(s.width == .auto and s.height == .auto);
    const r = Rect(LengthPercentage).zero;
    try testing.expect(r.left.eql(.zero) and r.bottom.eql(.zero));
    const l = Line(Dimension).min_content;
    try testing.expect(l.start == .min_content and l.end == .min_content);
    const p = Point(Dimension).max_content;
    try testing.expect(p.x == .max_content and p.y == .max_content);
    try testing.expectEqual(Point(?f32){ .x = 0, .y = 0 }, Point(?f32).zero);
    const sa = Size(AvailableSpace).max_content;
    try testing.expect(sa.width.eql(.max_content) and sa.height.eql(.max_content));
    const ls = Line(GridPlacement).auto;
    try testing.expect(ls.start == .auto and ls.end == .auto);
}

test "length / percent / fr / fit-content" {
    try testing.expect(std.meta.eql(Dimension.fromLength(10), Dimension.fromLength(10)));
    try testing.expect(std.meta.eql(LengthPercentageAuto.fromPercent(0.25), LengthPercentageAuto.fromPercent(0.25)));
    try testing.expect(AvailableSpace.fromLength(3).eql(.{ .definite = 3 }));
    try testing.expect(std.meta.eql(MaxTrackSizingFunction.fromFr(2), MaxTrackSizingFunction.fromFr(2)));
    try testing.expect(TrackSizingFunction.fromFr(2).eql(.{ .min = .auto, .max = MaxTrackSizingFunction.fromFr(2) }));
    try testing.expect(GridTemplateComponent.fromFr(1).single.eql(TrackSizingFunction.fromFr(1)));
    try testing.expect(std.meta.eql(MaxTrackSizingFunction.fitContent(LengthPercentage.fromLength(10)), MaxTrackSizingFunction.fitContentPx(10)));
    try testing.expect(TrackSizingFunction.fitContent(LengthPercentage.fromLength(10)).eql(.{ .min = .auto, .max = MaxTrackSizingFunction.fitContentPx(10) }));
    try testing.expect(GridTemplateComponent.fitContent(LengthPercentage.fromLength(10)).single.eql(TrackSizingFunction.fitContent(LengthPercentage.fromLength(10))));
    const sl = Size(Dimension).fromLength(4);
    try testing.expect(sl.width.eql(.{ .length = 4 }) and sl.height.eql(.{ .length = 4 }));
    const rp = Rect(LengthPercentage).fromPercent(0.1);
    try testing.expect(std.meta.eql(rp.top, LengthPercentage.fromPercent(0.1)));
    const lf = Line(TrackSizingFunction).fitContent(LengthPercentage.fromLength(3));
    try testing.expect(lf.end.eql(TrackSizingFunction.fitContent(LengthPercentage.fromLength(3))));
    const pl = Point(f32).fromLength(2);
    try testing.expectEqual(Point(f32){ .x = 2, .y = 2 }, pl);
    try testing.expect(TrackSizingFunction.fromLength(5).eql(.{ .min = MinTrackSizingFunction.fromLength(5), .max = MaxTrackSizingFunction.fromLength(5) }));
    try testing.expect(GridTemplateComponent.fromPercent(0.5).single.eql(TrackSizingFunction.fromPercent(0.5)));
    try testing.expect(GridTemplateComponent.zero.single.eql(TrackSizingFunction.zero));
}

test "line / span / minmax / flex / evenly sized tracks" {
    try testing.expect(GridPlacement.fromLineIndex(3).eql(.{ .line = .{ .inner = 3 } }));
    const l = Line(GridPlacement).fromLineIndex(-1);
    try testing.expect(l.start.eql(.{ .line = .{ .inner = -1 } }) and l.end == .auto);
    try testing.expect(GridPlacement.fromSpan(2).eql(.{ .span = 2 }));
    const ls = Line(GridPlacement).fromSpan(2);
    try testing.expect(ls.start.eql(.{ .span = 2 }) and ls.end == .auto);

    const mm = minmax(TrackSizingFunction, MinTrackSizingFunction.fromLength(1), MaxTrackSizingFunction.fromFr(1));
    try testing.expect(mm.eql(.{ .min = MinTrackSizingFunction.fromLength(1), .max = MaxTrackSizingFunction.fromFr(1) }));
    const mmc = minmax(GridTemplateComponent, MinTrackSizingFunction.fromLength(1), MaxTrackSizingFunction.fromFr(1));
    try testing.expect(mmc.single.eql(mm));
    try testing.expect(flex(TrackSizingFunction, 2).eql(.{ .min = MinTrackSizingFunction.zero, .max = MaxTrackSizingFunction.fromFr(2) }));

    const tracks = evenlySizedTracks(4);
    try testing.expectEqual(RepetitionCount{ .count = 4 }, tracks[0].repeat.count);
    try testing.expectEqual(@as(usize, 1), tracks[0].repeat.tracks.len);
    try testing.expect(tracks[0].repeat.tracks[0].eql(flex(TrackSizingFunction, 1.0)));
    try testing.expect(repeat(@as(RepetitionCount, .auto_fill), TEST_VEC).isAutoRepetition());
}
