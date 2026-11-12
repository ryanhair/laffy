//! Style types for CSS Grid layout
//!
//! String ownership: upstream is generic over a `CheapCloneStr` type for line and area names.
//! laffy uses borrowed `[]const u8` slices everywhere. Names (and the slices that hold track
//! lists, line-name sets and template areas) are NOT owned by the style values: the caller must
//! keep the referenced memory alive for as long as the style is used.
const std = @import("std");
const geometry = @import("../geometry.zig");
const Line = geometry.Line;
const AbsoluteAxis = geometry.AbsoluteAxis;
const compact_length = @import("compact_length.zig");
const CompactLength = compact_length.CompactLength;
const toF32 = compact_length.toF32;
const CalcHandle = compact_length.CalcHandle;
const dimension = @import("dimension.zig");
const LengthPercentage = dimension.LengthPercentage;
const LengthPercentageAuto = dimension.LengthPercentageAuto;
const Dimension = dimension.Dimension;
const coordinates = @import("../compute/grid/types/coordinates.zig");
const GridLine = coordinates.GridLine;
const OriginZeroLine = coordinates.OriginZeroLine;
const max_grid_tracks = coordinates.max_grid_tracks;

/// Defines the value of the `grid-template-areas` property: the named areas plus the overall
/// size (in tracks) of the area template.
///
/// The template may be larger than the extents of the named areas due to unnamed (`.`) cells,
/// so the size is stored explicitly.
pub const GridTemplateAreas = struct {
    /// The named grid areas (borrowed)
    areas: []const GridTemplateArea = &.{},
    /// The number of rows in the area template
    row_count: u16 = 0,
    /// The number of columns in the area template
    column_count: u16 = 0,
};

/// Defines a grid area
pub const GridTemplateArea = struct {
    /// The name of the grid area (borrowed)
    name: []const u8,
    /// The index of the row at which the grid area starts in grid coordinates.
    row_start: u16,
    /// The index of the row at which the grid area ends in grid coordinates.
    row_end: u16,
    /// The index of the column at which the grid area starts in grid coordinates.
    column_start: u16,
    /// The index of the column at which the grid area end in grid coordinates.
    column_end: u16,
};

/// Defines a named grid line
pub const NamedGridLine = struct {
    /// The name of the grid line (borrowed)
    name: []const u8,
    /// The index of the line
    index: u16,
};

/// Axis as `row` or `column`
pub const GridAreaAxis = enum {
    /// The `Row` axis
    row,
    /// The `Column` axis
    column,
};

/// Logical end (`start` or `end`)
pub const GridAreaEnd = enum {
    /// The `Start` end
    start,
    /// The `End` end
    end,
};

/// A component in a `grid-template-*` definition where the type representing `repeat()`s is
/// generic (upstream `GenericGridTemplateComponent<S, Repetition>`).
///
/// `Repetition` must provide the `GenericRepetition` interface:
///
///   - `getCount(self) RepetitionCount`: the repetition count (integer, auto-fill, or auto-fit)
///   - `getTracks(self) []const TrackSizingFunction`: the repeated tracks
///   - `getTrackCount(self) u16`: the number of repeated tracks, saturated to `u16`
///     (upstream default: `min(tracks.len, u16::MAX)`)
///   - `getLinesNames(self) []const []const []const u8`: the line name sets. Line name sets are
///     positional: set `i` names the `i`th line of each repetition. There must be either no sets
///     at all (all lines are unnamed) or exactly `getTrackCount() + 1` of them.
///
/// Upstream returns iterators from these methods; laffy returns slices.
pub fn GenericGridTemplateComponent(comptime Repetition: type) type {
    return union(enum) {
        const Self = @This();

        /// A single track sizing function
        single: TrackSizingFunction,
        /// A `repeat()`
        repeat: Repetition,

        /// Whether the track definition is a auto-repeated fragment
        pub fn isAutoRepetition(self: Self) bool {
            return switch (self) {
                .single => false,
                .repeat => |repeat_value| switch (repeat_value.getCount()) {
                    .auto_fit, .auto_fill => true,
                    .count => false,
                },
            };
        }

        /// Upstream `GridTemplateComponent::as_component_ref`. laffy's `GridTemplateComponent`
        /// already is the "ref" form (its repetition borrows its track list), so this is the identity.
        pub fn asComponentRef(self: Self) Self {
            return self;
        }

        /// Upstream `TaffyAuto`
        pub const auto: Self = .{ .single = TrackSizingFunction.auto };
        /// Upstream `TaffyMinContent`
        pub const min_content: Self = .{ .single = TrackSizingFunction.min_content };
        /// Upstream `TaffyMaxContent`
        pub const max_content: Self = .{ .single = TrackSizingFunction.max_content };
        /// Upstream `TaffyZero`
        pub const zero: Self = .{ .single = TrackSizingFunction.zero };

        /// Upstream `TaffyFitContent`
        pub fn fitContent(argument: LengthPercentage) Self {
            return .{ .single = TrackSizingFunction.fitContent(argument) };
        }
        /// Upstream `FromLength`
        pub fn fromLength(value: anytype) Self {
            return .{ .single = TrackSizingFunction.fromLength(value) };
        }
        /// Upstream `FromPercent`
        pub fn fromPercent(value: anytype) Self {
            return .{ .single = TrackSizingFunction.fromPercent(value) };
        }
        /// Upstream `FromFr`
        pub fn fromFr(value: anytype) Self {
            return .{ .single = TrackSizingFunction.fromFr(value) };
        }
        /// Upstream `From<MinMax<MinTrackSizingFunction, MaxTrackSizingFunction>>`
        pub fn fromMinMax(input: TrackSizingFunction) Self {
            return .{ .single = input };
        }
    };
}

/// An element in a `grid-template-columns` or `grid-template-rows` definition.
/// Either a track sizing function or a repeat().
///
/// See <https://developer.mozilla.org/en-US/docs/Web/CSS/grid-template-columns>
pub const GridTemplateComponent = GenericGridTemplateComponent(GridTemplateRepetition);

/// Controls whether grid items are placed row-wise or column-wise. And whether the sparse or dense packing algorithm is used.
///
/// The "dense" packing algorithm attempts to fill in holes earlier in the grid, if smaller items come up later. This may cause items to appear out-of-order, when doing so would fill in holes left by larger items.
///
/// Defaults to `GridAutoFlow.row`
///
/// [MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/grid-auto-flow)
pub const GridAutoFlow = enum(u8) {
    /// Items are placed by filling each row in turn, adding new rows as necessary
    row,
    /// Items are placed by filling each column in turn, adding new columns as necessary.
    column,
    /// Combines `row` with the dense packing algorithm.
    row_dense,
    /// Combines `column` with the dense packing algorithm.
    column_dense,

    /// The default value
    pub const default: GridAutoFlow = .row;

    /// Whether grid auto placement uses the sparse placement algorithm or the dense placement algorithm
    /// See: <https://developer.mozilla.org/en-US/docs/Web/CSS/grid-auto-flow#values>
    pub fn isDense(self: GridAutoFlow) bool {
        return switch (self) {
            .row, .column => false,
            .row_dense, .column_dense => true,
        };
    }

    /// Whether grid auto placement fills areas row-wise or column-wise
    /// See: <https://developer.mozilla.org/en-US/docs/Web/CSS/grid-auto-flow#values>
    pub fn primaryAxis(self: GridAutoFlow) AbsoluteAxis {
        return switch (self) {
            .row, .row_dense => .horizontal,
            .column, .column_dense => .vertical,
        };
    }
};

/// A grid line placement specification which is generic over the coordinate system that it uses to define
/// grid line positions.
///
/// `GenericGridPlacement(GridLine)` is aliased as `NonNamedGridPlacement`.
/// `GenericGridPlacement(OriginZeroLine)` is aliased as `OriginZeroGridPlacement` and is used internally for placement computations.
pub fn GenericGridPlacement(comptime LineTypeParam: type) type {
    return union(enum) {
        const Self = @This();

        /// The coordinate type of this placement (`GridLine` or `OriginZeroLine`)
        pub const LineType = LineTypeParam;
        /// The origin-zero placement type (target of `intoOriginZero*` conversions)
        pub const OriginZeroPlacement = OriginZeroGridPlacement;

        /// Place item according to the auto-placement algorithm, and the parent's grid_auto_flow property
        auto,
        /// Place item at specified line (column or row) index
        line: LineTypeParam,
        /// Item should span specified number of tracks (columns or rows)
        span: u16,

        /// Apply a mapping function if the placement is a `line`. Otherwise return `self` unmodified.
        /// (`NonNamedGridPlacement` only)
        pub fn intoOriginZeroPlacement(self: Self, explicit_track_count: u16) OriginZeroGridPlacement {
            return switch (self) {
                .auto => .auto,
                // Spans are clamped between 1 (a zero span is an invalid value which is treated as 1)
                // and the maximum track limit (https://www.w3.org/TR/css-grid-1/#overlarge-grids)
                .span => |span_value| .{ .span = std.math.clamp(span_value, 1, max_grid_tracks) },
                // Grid line zero is an invalid index, so it gets treated as Auto
                // See: https://developer.mozilla.org/en-US/docs/Web/CSS/grid-row-start#values
                .line => |grid_line| switch (grid_line.asI16()) {
                    0 => .auto,
                    else => .{ .line = grid_line.intoOriginZeroLine(explicit_track_count) },
                },
            };
        }

        // Implementations of the `Line(GenericGridPlacement(_))` methods (see `geometry.Line`)

        /// `Line(..).indefiniteSpan`: Resolves the span for an indefinite placement (a placement
        /// that does not consist of two `line`s). Panics if called on a definite placement
        pub fn lineIndefiniteSpan(l: Line(Self)) u16 {
            return switch (l.start) {
                .line => switch (l.end) {
                    .auto => 1,
                    .span => |span_value| span_value,
                    .line => @panic("indefiniteSpan should only be called on indefinite grid tracks"),
                },
                .auto => switch (l.end) {
                    .line => 1,
                    .auto => 1,
                    .span => |span_value| span_value,
                },
                .span => |span_value| span_value,
            };
        }

        /// `Line(..).isDefinite`: Whether the track position is definite in this axis (or the
        /// item will need auto placement).
        ///
        /// For `GridLine` coordinates the track position is definite if least one of the start and
        /// end positions is a NON-ZERO track index (0 is an invalid line in GridLine coordinates,
        /// and falls back to "auto" which is indefinite). For `OriginZeroLine` coordinates it is
        /// definite if least one of the start and end positions is a track index.
        pub fn lineIsDefinite(l: Line(Self)) bool {
            if (LineTypeParam == GridLine) {
                if (l.start == .line and l.start.line.asI16() != 0) return true;
                if (l.end == .line and l.end.line.asI16() != 0) return true;
                return false;
            } else {
                return l.start == .line or l.end == .line;
            }
        }

        /// `Line(..).intoOriginZero`: Apply a mapping function if the placement is a `line`.
        /// Otherwise return `self` unmodified. (`NonNamedGridPlacement` only)
        pub fn lineIntoOriginZero(l: Line(Self), explicit_track_count: u16) Line(OriginZeroGridPlacement) {
            return .{
                .start = l.start.intoOriginZeroPlacement(explicit_track_count),
                .end = l.end.intoOriginZeroPlacement(explicit_track_count),
            };
        }

        /// `Line(..).resolveDefiniteGridLines`: If at least one of the of the start and end positions
        /// is a track index then the other end can be resolved into a track index purely based on
        /// the information contained with the placement specification. (`OriginZeroGridPlacement` only)
        pub fn lineResolveDefiniteGridLines(l: Line(Self)) Line(OriginZeroLine) {
            switch (l.start) {
                .line => |line1| switch (l.end) {
                    .line => |line2| {
                        if (line1 == line2) {
                            return .{ .start = line1, .end = line1.add(@as(u16, 1)) };
                        } else {
                            return .{ .start = OriginZeroLine.min(line1, line2), .end = OriginZeroLine.max(line1, line2) };
                        }
                    },
                    .span => |span_value| return .{ .start = line1, .end = line1.add(span_value) },
                    .auto => return .{ .start = line1, .end = line1.add(@as(u16, 1)) },
                },
                .span => |span_value| switch (l.end) {
                    .line => |line2| return .{ .start = line2.sub(span_value), .end = line2 },
                    else => {},
                },
                .auto => switch (l.end) {
                    .line => |line2| return .{ .start = line2.sub(@as(u16, 1)), .end = line2 },
                    else => {},
                },
            }
            @panic("resolveDefiniteGridTracks should only be called on definite grid tracks");
        }

        /// `Line(..).resolveAbsolutelyPositionedGridTracks` (`OriginZeroGridPlacement` only).
        ///
        /// For absolutely positioned items:
        ///   - Tracks resolve to definite tracks
        ///   - For Spans:
        ///      - If the other position is a Track, they resolve to a definite track relative to the other track
        ///      - Else resolve to null
        ///   - Auto resolves to null
        ///
        /// When finally positioning the item, a value of null means that the item's grid area is bounded by the grid
        /// container's border box on that side.
        pub fn lineResolveAbsolutelyPositionedGridTracks(l: Line(Self)) Line(?OriginZeroLine) {
            switch (l.start) {
                .line => |track1| switch (l.end) {
                    .line => |track2| {
                        if (track1 == track2) {
                            return .{ .start = track1, .end = track1.add(@as(u16, 1)) };
                        } else {
                            return .{ .start = OriginZeroLine.min(track1, track2), .end = OriginZeroLine.max(track1, track2) };
                        }
                    },
                    .span => |span_value| return .{ .start = track1, .end = track1.add(span_value) },
                    .auto => return .{ .start = track1, .end = null },
                },
                .span => |span_value| switch (l.end) {
                    .line => |track2| return .{ .start = track2.sub(span_value), .end = track2 },
                    else => {},
                },
                .auto => switch (l.end) {
                    .line => |track2| return .{ .start = null, .end = track2 },
                    else => {},
                },
            }
            return .{ .start = null, .end = null };
        }

        /// `Line(..).resolveIndefiniteGridTracks`: If neither of the start and end positions is a
        /// track index then the other end can be resolved into a track index if a definite start
        /// position is supplied externally. (`OriginZeroGridPlacement` only)
        pub fn lineResolveIndefiniteGridTracks(l: Line(Self), start: OriginZeroLine) Line(OriginZeroLine) {
            switch (l.start) {
                .auto => switch (l.end) {
                    .auto => return .{ .start = start, .end = start.add(@as(u16, 1)) },
                    .span => |span_value| return .{ .start = start, .end = start.add(span_value) },
                    .line => {},
                },
                .span => |span_value| switch (l.end) {
                    .auto => return .{ .start = start, .end = start.add(span_value) },
                    .span => return .{ .start = start, .end = start.add(span_value) },
                    .line => {},
                },
                .line => {},
            }
            @panic("resolveIndefiniteGridTracks should only be called on indefinite grid tracks");
        }
    };
}

/// A grid line placement using the normalized OriginZero coordinates to specify line positions.
pub const OriginZeroGridPlacement = GenericGridPlacement(OriginZeroLine);

/// A grid line placement using CSS grid line coordinates to specify line positions. This uses the same coordinate
/// system as the public `GridPlacement` type but doesn't support named lines (these are expected to have already
/// been resolved by the time values of this type are constructed).
pub const NonNamedGridPlacement = GenericGridPlacement(GridLine);

/// A grid line placement specification. Used for grid-[row/column]-[start/end].
///
/// Defaults to `GridPlacement.auto`
///
/// Names are borrowed `[]const u8` slices (see the file documentation).
///
/// [Specification](https://www.w3.org/TR/css3-grid-layout/#typedef-grid-row-start-grid-line)
pub const GridPlacement = union(enum) {
    /// The origin-zero placement type (target of `intoOriginZero*` conversions)
    pub const OriginZeroPlacement = OriginZeroGridPlacement;

    /// Payload of `named_line` (upstream `NamedLine(S, i16)`)
    pub const NamedLine = struct {
        /// The line name
        name: []const u8,
        /// Which line with this name (upstream tuple field 1)
        index: i16,
    };

    /// Payload of `named_span` (upstream `NamedSpan(S, u16)`)
    pub const NamedSpan = struct {
        /// The line name
        name: []const u8,
        /// How many lines with this name to span (upstream tuple field 1)
        count: u16,
    };

    /// Place item according to the auto-placement algorithm, and the parent's grid_auto_flow property
    auto,
    /// Place item at specified line (column or row) index
    line: GridLine,
    /// Place item at specified named line (column or row)
    named_line: NamedLine,
    /// Item should span specified number of tracks (columns or rows)
    span: u16,
    /// Item should span until the nth line named `<name>`.
    ///
    /// If there are less than n lines named `<name>` in the specified direction then
    /// all implicit lines will be counted.
    named_span: NamedSpan,

    /// The default value
    pub const default: GridPlacement = .auto;

    /// Upstream `TaffyGridLine::from_line_index`
    pub fn fromLineIndex(index: i16) GridPlacement {
        return .{ .line = GridLine.from(index) };
    }

    /// Upstream `TaffyGridSpan::from_span`
    pub fn fromSpan(span_value: u16) GridPlacement {
        return .{ .span = span_value };
    }

    /// Equality (upstream derived `PartialEq`; names are compared by content)
    pub fn eql(self: GridPlacement, other: GridPlacement) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .auto => true,
            .line => |l| l == other.line,
            .named_line => |n| n.index == other.named_line.index and std.mem.eql(u8, n.name, other.named_line.name),
            .span => |s| s == other.span,
            .named_span => |n| n.count == other.named_span.count and std.mem.eql(u8, n.name, other.named_span.name),
        };
    }

    /// Apply a mapping function if the `GridPlacement` is a `line`. Otherwise return `self` unmodified.
    /// Named lines and spans become `auto`.
    pub fn intoOriginZeroPlacementIgnoringNamed(self: GridPlacement, explicit_track_count: u16) OriginZeroGridPlacement {
        return switch (self) {
            .auto => .auto,
            // Spans are clamped between 1 (a zero span is an invalid value which is treated as 1)
            // and the maximum track limit (https://www.w3.org/TR/css-grid-1/#overlarge-grids)
            .span => |span_value| .{ .span = std.math.clamp(span_value, 1, max_grid_tracks) },
            // Grid line zero is an invalid index, so it gets treated as Auto
            // See: https://developer.mozilla.org/en-US/docs/Web/CSS/grid-row-start#values
            .line => |grid_line| switch (grid_line.asI16()) {
                0 => .auto,
                else => .{ .line = grid_line.intoOriginZeroLine(explicit_track_count) },
            },
            .named_line => .auto,
            .named_span => .auto,
        };
    }

    /// `Line(GridPlacement).intoOriginZeroIgnoringNamed`
    pub fn lineIntoOriginZeroIgnoringNamed(l: Line(GridPlacement), explicit_track_count: u16) Line(OriginZeroGridPlacement) {
        return .{
            .start = l.start.intoOriginZeroPlacementIgnoringNamed(explicit_track_count),
            .end = l.end.intoOriginZeroPlacementIgnoringNamed(explicit_track_count),
        };
    }

    /// `Line(GridPlacement).isDefinite`: Whether the track position is definite in this axis (or
    /// the item will need auto placement). The track position is definite if least one of the start
    /// and end positions is a NON-ZERO track index (0 is an invalid line in GridLine coordinates, and
    /// falls back to "auto" which is indefinite), or a named line.
    pub fn lineIsDefinite(l: Line(GridPlacement)) bool {
        if (l.start == .line and l.start.line.asI16() != 0) return true;
        if (l.end == .line and l.end.line.asI16() != 0) return true;
        if (l.start == .named_line) return true;
        if (l.end == .named_line) return true;
        return false;
    }
};

/// Maximum track sizing function
///
/// Specifies the maximum size of a grid track. A grid track will automatically size between it's minimum and maximum size based
/// on the size of it's contents, the amount of available space, and the sizing constraint the grid is being size under.
/// See <https://developer.mozilla.org/en-US/docs/Web/CSS/grid-template-columns>
pub const MaxTrackSizingFunction = union(enum) {
    /// An absolute length in some abstract units
    length: f32,
    /// A percentage length relative to the size of the containing block, in the range [0.0, 1.0]
    percent: f32,
    /// A `calc()` value
    calc: CalcHandle,
    /// The dimension should be automatically computed according to algorithm-specific rules
    /// regarding the default size of boxes.
    auto,
    /// The smallest size that can fit the item's contents with ALL soft line-wrapping opportunities taken
    min_content,
    /// The smallest size that can fit the item's contents with NO soft line-wrapping opportunities taken
    max_content,
    /// `fit-content(<length>)`
    fit_content_px: f32,
    /// `fit-content(<percentage>)`
    fit_content_percent: f32,
    /// `fit-content(calc(...))`
    fit_content_calc: CalcHandle,
    /// A fraction of the leftover space in the grid container (`fr`)
    fr: f32,

    /// Zero length
    pub const zero: MaxTrackSizingFunction = .{ .length = 0.0 };

    /// `fit-content(...)` with the passed limit
    pub fn fitContent(argument: LengthPercentage) MaxTrackSizingFunction {
        return CompactLength.fitContent(argument).into(MaxTrackSizingFunction);
    }

    pub fn fromLengthPercentage(input: LengthPercentage) MaxTrackSizingFunction {
        return CompactLength.from(input).into(MaxTrackSizingFunction);
    }

    pub fn fromLengthPercentageAuto(input: LengthPercentageAuto) MaxTrackSizingFunction {
        return CompactLength.from(input).into(MaxTrackSizingFunction);
    }

    pub fn fromDimension(input: Dimension) MaxTrackSizingFunction {
        // Dimension supports values that are not valid max track sizing functions.
        // Map those to `auto`.
        return switch (input) {
            .fit_content, .stretch, .content => .auto,
            else => CompactLength.from(input).into(MaxTrackSizingFunction),
        };
    }

    pub fn fromMin(input: MinTrackSizingFunction) MaxTrackSizingFunction {
        return CompactLength.from(input).into(MaxTrackSizingFunction);
    }

    pub fn fromLength(value: f32) MaxTrackSizingFunction {
        return .{ .length = value };
    }

    pub fn fromPercent(value: f32) MaxTrackSizingFunction {
        return .{ .percent = value };
    }

    pub fn fitContentPx(limit: f32) MaxTrackSizingFunction {
        return .{ .fit_content_px = limit };
    }

    pub fn fitContentPercent(limit: f32) MaxTrackSizingFunction {
        return .{ .fit_content_percent = limit };
    }

    pub fn fromFr(value: f32) MaxTrackSizingFunction {
        return .{ .fr = value };
    }

    pub fn fromCalc(handle: CalcHandle) MaxTrackSizingFunction {
        return .{ .calc = handle };
    }

    pub fn fitContentCalc(handle: CalcHandle) MaxTrackSizingFunction {
        return .{ .fit_content_calc = handle };
    }

    /// Returns true if the max track sizing function is `min-content`, `max-content`,
    /// `fit-content(...)` or `auto`, else false.
    pub fn isIntrinsic(self: MaxTrackSizingFunction) bool {
        return switch (self) {
            .auto, .min_content, .max_content, .fit_content_px, .fit_content_percent, .fit_content_calc => true,
            .length, .percent, .calc, .fr => false,
        };
    }

    /// Returns true if the max track sizing function is `max-content`, `fit-content(...)` or
    /// `auto`, else false. "In all cases, treat auto and fit-content() as max-content, except
    /// where specified otherwise for fit-content()." See: <https://www.w3.org/TR/css-grid-1/#algo-terms>
    pub fn isMaxContentAlike(self: MaxTrackSizingFunction) bool {
        return switch (self) {
            .auto, .max_content, .fit_content_px, .fit_content_percent, .fit_content_calc => true,
            .length, .percent, .calc, .min_content, .fr => false,
        };
    }

    pub fn isFr(self: MaxTrackSizingFunction) bool {
        return self == .fr;
    }

    pub fn isAuto(self: MaxTrackSizingFunction) bool {
        return self == .auto;
    }

    pub fn isMinContent(self: MaxTrackSizingFunction) bool {
        return self == .min_content;
    }

    pub fn isMaxContent(self: MaxTrackSizingFunction) bool {
        return self == .max_content;
    }

    pub fn isFitContent(self: MaxTrackSizingFunction) bool {
        return self == .fit_content_px or self == .fit_content_percent or self == .fit_content_calc;
    }

    pub fn isMaxOrFitContent(self: MaxTrackSizingFunction) bool {
        return self == .max_content or self.isFitContent();
    }

    /// The flex factor of an `fr` track, or 0 for any other kind
    pub fn flexFactor(self: MaxTrackSizingFunction) f32 {
        return switch (self) {
            .fr => |factor| factor,
            else => 0.0,
        };
    }

    /// Returns whether the max track sizing function has a definite value, given the size of
    /// the container (which percentages and `calc()` values resolve against)
    pub fn hasDefiniteValue(self: MaxTrackSizingFunction, parent_size: ?f32) bool {
        return switch (self) {
            .length => true,
            .percent, .calc => parent_size != null,
            else => false,
        };
    }

    /// Returns fixed point values directly. Attempts to resolve percentage and `calc()` values
    /// against the passed parent size and returns if this results in a concrete value (which it
    /// will if the parent size is non-null). Otherwise returns null.
    pub fn definiteValue(self: MaxTrackSizingFunction, parent_size: ?f32, calc_resolver: anytype) ?f32 {
        return switch (self) {
            .length => |value| value,
            .percent => |fraction| if (parent_size) |size| fraction * size else null,
            .calc => |handle| if (parent_size) |size| calc_resolver.resolveCalcValue(handle, size) else null,
            else => null,
        };
    }

    /// The limit of a `fit-content(...)` function, resolved against the passed parent size,
    /// or null if this is not `fit-content(...)` or the limit cannot be resolved
    pub fn fitContentLimit(self: MaxTrackSizingFunction, parent_size: ?f32, calc_resolver: anytype) ?f32 {
        return switch (self) {
            .fit_content_px => |limit| limit,
            .fit_content_percent => |fraction| if (parent_size) |size| fraction * size else null,
            .fit_content_calc => |handle| if (parent_size) |size| calc_resolver.resolveCalcValue(handle, size) else null,
            else => null,
        };
    }

    /// Resolve the maximum size of the track as defined by either:
    ///   - A fixed track sizing function
    ///   - A percentage track sizing function (with definite available space)
    ///   - A `fit-content(...)` function with a fixed or resolvable argument
    /// All other kinds of track sizing function return null.
    pub fn definiteLimit(self: MaxTrackSizingFunction, parent_size: ?f32, calc_resolver: anytype) ?f32 {
        return switch (self) {
            .fit_content_px, .fit_content_percent, .fit_content_calc => self.fitContentLimit(parent_size, calc_resolver),
            else => self.definiteValue(parent_size, calc_resolver),
        };
    }

    /// The value of a percentage or `calc()` against `parent_size`, or null for other kinds
    pub fn resolvedPercentageSize(self: MaxTrackSizingFunction, parent_size: f32, calc_resolver: anytype) ?f32 {
        return switch (self) {
            .percent => |fraction| fraction * parent_size,
            .calc => |handle| calc_resolver.resolveCalcValue(handle, parent_size),
            else => null,
        };
    }

    /// Whether the track sizing function depends on the size of the parent node
    pub fn usesPercentage(self: MaxTrackSizingFunction) bool {
        return switch (self) {
            .percent, .calc, .fit_content_percent, .fit_content_calc => true,
            else => false,
        };
    }

    pub fn eql(self: MaxTrackSizingFunction, other: MaxTrackSizingFunction) bool {
        return std.meta.eql(self, other);
    }
};

/// Minimum track sizing function
///
/// Specifies the minimum size of a grid track. A grid track will automatically size between it's minimum and maximum size based
/// on the size of it's contents, the amount of available space, and the sizing constraint the grid is being size under.
/// See <https://developer.mozilla.org/en-US/docs/Web/CSS/grid-template-columns>
pub const MinTrackSizingFunction = union(enum) {
    /// An absolute length in some abstract units
    length: f32,
    /// A percentage length relative to the size of the containing block, in the range [0.0, 1.0]
    percent: f32,
    /// A `calc()` value
    calc: CalcHandle,
    /// The dimension should be automatically computed according to algorithm-specific rules
    /// regarding the default size of boxes.
    auto,
    /// The smallest size that can fit the item's contents with ALL soft line-wrapping opportunities taken
    min_content,
    /// The smallest size that can fit the item's contents with NO soft line-wrapping opportunities taken
    max_content,

    /// Zero length
    pub const zero: MinTrackSizingFunction = .{ .length = 0.0 };

    pub fn fromLengthPercentage(input: LengthPercentage) MinTrackSizingFunction {
        return CompactLength.from(input).into(MinTrackSizingFunction);
    }

    pub fn fromLengthPercentageAuto(input: LengthPercentageAuto) MinTrackSizingFunction {
        return CompactLength.from(input).into(MinTrackSizingFunction);
    }

    pub fn fromDimension(input: Dimension) MinTrackSizingFunction {
        // Dimension supports values that are not valid min track sizing functions.
        // Map those to `auto`.
        return switch (input) {
            .fit_content_px, .fit_content_percent, .fit_content_calc, .fit_content, .stretch, .content => .auto,
            else => CompactLength.from(input).into(MinTrackSizingFunction),
        };
    }

    pub fn fromMax(input: MaxTrackSizingFunction) MinTrackSizingFunction {
        if (input.isFr() or input.isFitContent()) {
            return .auto;
        }
        return CompactLength.from(input).into(MinTrackSizingFunction);
    }

    pub fn fromLength(value: f32) MinTrackSizingFunction {
        return .{ .length = value };
    }

    pub fn fromPercent(value: f32) MinTrackSizingFunction {
        return .{ .percent = value };
    }

    pub fn fromCalc(handle: CalcHandle) MinTrackSizingFunction {
        return .{ .calc = handle };
    }

    /// Returns true if the min track sizing function is `min-content`, `max-content` or `auto`, else false.
    pub fn isIntrinsic(self: MinTrackSizingFunction) bool {
        return self == .auto or self == .min_content or self == .max_content;
    }

    pub fn isMinOrMaxContent(self: MinTrackSizingFunction) bool {
        return self == .min_content or self == .max_content;
    }

    /// Always false: a min track sizing function cannot be `fr`
    pub fn isFr(self: MinTrackSizingFunction) bool {
        _ = self;
        return false;
    }

    pub fn isAuto(self: MinTrackSizingFunction) bool {
        return self == .auto;
    }

    /// Whether the function is `auto`, or is a percentage that cannot be resolved because the
    /// container's size is indefinite (in which case it behaves as `auto`)
    pub fn behavesAsAuto(self: MinTrackSizingFunction, parent_size: ?f32) bool {
        return self == .auto or (parent_size == null and self.usesPercentage());
    }

    pub fn isMinContent(self: MinTrackSizingFunction) bool {
        return self == .min_content;
    }

    pub fn isMaxContent(self: MinTrackSizingFunction) bool {
        return self == .max_content;
    }

    /// Returns fixed point values directly. Attempts to resolve percentage and `calc()` values
    /// against the passed parent size and returns if this results in a concrete value (which it
    /// will if the parent size is non-null). Otherwise returns null.
    pub fn definiteValue(self: MinTrackSizingFunction, parent_size: ?f32, calc_resolver: anytype) ?f32 {
        return switch (self) {
            .length => |value| value,
            .percent => |fraction| if (parent_size) |size| fraction * size else null,
            .calc => |handle| if (parent_size) |size| calc_resolver.resolveCalcValue(handle, size) else null,
            else => null,
        };
    }

    /// The value of a percentage or `calc()` against `parent_size`, or null for other kinds
    pub fn resolvedPercentageSize(self: MinTrackSizingFunction, parent_size: f32, calc_resolver: anytype) ?f32 {
        return switch (self) {
            .percent => |fraction| fraction * parent_size,
            .calc => |handle| calc_resolver.resolveCalcValue(handle, parent_size),
            else => null,
        };
    }

    /// Whether the track sizing function depends on the size of the parent node
    pub fn usesPercentage(self: MinTrackSizingFunction) bool {
        return self == .percent or self == .calc;
    }

    pub fn eql(self: MinTrackSizingFunction, other: MinTrackSizingFunction) bool {
        return std.meta.eql(self, other);
    }
};

/// The sizing function for a grid track (row/column)
///
/// May either be a MinMax variant which specifies separate values for the min-/max- track sizing functions
/// or a scalar value which applies to both track sizing functions.
///
/// Upstream this is a type alias for `MinMax<MinTrackSizingFunction, MaxTrackSizingFunction>`. laffy
/// makes it its own struct (with the same `min` / `max` fields) so that it can carry methods.
pub const TrackSizingFunction = struct {
    /// The minimum track sizing function
    min: MinTrackSizingFunction,
    /// The maximum track sizing function
    max: MaxTrackSizingFunction,

    /// Extract the min track sizing function
    pub fn minSizingFunction(self: TrackSizingFunction) MinTrackSizingFunction {
        return self.min;
    }
    /// Extract the max track sizing function
    pub fn maxSizingFunction(self: TrackSizingFunction) MaxTrackSizingFunction {
        return self.max;
    }
    /// Determine whether at least one of the components ("min" and "max") are fixed sizing function
    ///
    /// A fixed sizing function is a `<length-percentage>`, which includes `calc()` values (and so
    /// `min()`, `max()` and `clamp()`) such as `minmax(min(100%, 300px), 1fr)`.
    /// <https://www.w3.org/TR/css-grid-1/#fixed-sizing-function>
    pub fn hasFixedComponent(self: TrackSizingFunction) bool {
        return CompactLength.from(self.min).isLengthPercentageOrCalc() or CompactLength.from(self.max).isLengthPercentageOrCalc();
    }

    /// Upstream `TaffyAuto`
    pub const auto: TrackSizingFunction = .{ .min = .auto, .max = .auto };
    /// Upstream `TaffyMinContent`
    pub const min_content: TrackSizingFunction = .{ .min = .min_content, .max = .min_content };
    /// Upstream `TaffyMaxContent`
    pub const max_content: TrackSizingFunction = .{ .min = .max_content, .max = .max_content };
    /// Upstream `TaffyZero`
    pub const zero: TrackSizingFunction = .{ .min = MinTrackSizingFunction.zero, .max = MaxTrackSizingFunction.zero };

    /// Upstream `TaffyFitContent`
    pub fn fitContent(argument: LengthPercentage) TrackSizingFunction {
        return .{ .min = .auto, .max = MaxTrackSizingFunction.fitContent(argument) };
    }
    /// Upstream `FromLength`
    pub fn fromLength(value: anytype) TrackSizingFunction {
        return .{ .min = MinTrackSizingFunction.fromLength(value), .max = MaxTrackSizingFunction.fromLength(value) };
    }
    /// Upstream `FromPercent`
    pub fn fromPercent(value: anytype) TrackSizingFunction {
        return .{ .min = MinTrackSizingFunction.fromPercent(value), .max = MaxTrackSizingFunction.fromPercent(value) };
    }
    /// Upstream `FromFr`
    pub fn fromFr(value: anytype) TrackSizingFunction {
        return .{ .min = .auto, .max = MaxTrackSizingFunction.fromFr(value) };
    }
    /// Upstream `From<LengthPercentage>`
    pub fn fromLengthPercentage(input: LengthPercentage) TrackSizingFunction {
        return .{ .min = MinTrackSizingFunction.fromLengthPercentage(input), .max = MaxTrackSizingFunction.fromLengthPercentage(input) };
    }
    /// Upstream `From<LengthPercentageAuto>`
    pub fn fromLengthPercentageAuto(input: LengthPercentageAuto) TrackSizingFunction {
        return .{ .min = MinTrackSizingFunction.fromLengthPercentageAuto(input), .max = MaxTrackSizingFunction.fromLengthPercentageAuto(input) };
    }
    /// Upstream `From<Dimension>`
    pub fn fromDimension(input: Dimension) TrackSizingFunction {
        return .{ .min = MinTrackSizingFunction.fromDimension(input), .max = MaxTrackSizingFunction.fromDimension(input) };
    }
    /// Upstream `From<MinMax<..>>` (identity in Rust): build from a `geometry.MinMax`
    pub fn fromMinMax(input: geometry.MinMax(MinTrackSizingFunction, MaxTrackSizingFunction)) TrackSizingFunction {
        return .{ .min = input.min, .max = input.max };
    }
    /// Equality (upstream derived `PartialEq`, bitwise on the compact representations)
    pub fn eql(self: TrackSizingFunction, other: TrackSizingFunction) bool {
        return self.min.eql(other.min) and self.max.eql(other.max);
    }
};

/// The first argument to a repeated track definition. This type represents the type of automatic repetition to perform.
///
/// See <https://www.w3.org/TR/css-grid-1/#auto-repeat> for an explanation of how auto-repeated track definitions work
/// and the difference between AutoFit and AutoFill.
pub const RepetitionCount = union(enum) {
    /// Auto-repeating tracks should be generated to fit the container
    /// See: <https://developer.mozilla.org/en-US/docs/Web/CSS/repeat#auto-fill>
    auto_fill,
    /// Auto-repeating tracks should be generated to fit the container
    /// See: <https://developer.mozilla.org/en-US/docs/Web/CSS/repeat#auto-fit>
    auto_fit,
    /// The specified tracks should be repeated exacts N times
    count: u16,

    /// Upstream `From<u16>`
    pub fn fromU16(value: u16) RepetitionCount {
        return .{ .count = value };
    }

    /// Upstream `TryFrom<&str>`: accepts "auto-fit" or "auto-fill"
    pub fn tryFromStr(value: []const u8) error{InvalidStringRepetitionValue}!RepetitionCount {
        if (std.mem.eql(u8, value, "auto-fit")) return .auto_fit;
        if (std.mem.eql(u8, value, "auto-fill")) return .auto_fill;
        return error.InvalidStringRepetitionValue;
    }
};

/// A typed representation of a `repeat(..)` in `grid-template-*` value
///
/// The track list and line names are borrowed (see the file documentation).
pub const GridTemplateRepetition = struct {
    /// The number of the times the repeat is repeated
    count: RepetitionCount,
    /// The tracks to repeat
    tracks: []const TrackSizingFunction,
    /// The line names for the repeated tracks
    ///
    /// Line name sets are positional: set `i` names the `i`th line of each repetition. This must
    /// either be empty (all lines are unnamed) or contain exactly `tracks.len + 1` sets (one set
    /// per line, including both edge lines; sets may be empty). Other lengths panic during layout.
    line_names: []const []const []const u8 = &.{},

    // `GenericRepetition` interface

    /// The repetition count (integer, auto-fill, or auto-fit)
    pub fn getCount(self: GridTemplateRepetition) RepetitionCount {
        return self.count;
    }
    /// Returns the number of repeated tracks
    pub fn getTrackCount(self: GridTemplateRepetition) u16 {
        return @intCast(@min(self.tracks.len, std.math.maxInt(u16)));
    }
    /// Get the repeated tracks
    pub fn getTracks(self: GridTemplateRepetition) []const TrackSizingFunction {
        return self.tracks;
    }
    /// Returns the line name sets
    pub fn getLinesNames(self: GridTemplateRepetition) []const []const []const u8 {
        return self.line_names;
    }
};

/// Upstream `GridTemplateTracks` (a doc-hidden helper used by the CSS parser): a list of tracks
/// plus positional line name sets.
pub fn GridTemplateTracks(comptime Track: type) type {
    return struct {
        /// The tracks to repeat
        tracks: []const Track = &.{},
        /// The line names for the repeated tracks
        line_names: []const []const []const u8 = &.{},
    };
}

/// Upstream `GridAutoTracks` (a doc-hidden helper used by the CSS parser)
pub const GridAutoTracks = struct {
    inner: []const TrackSizingFunction = &.{},
};

const testing = std.testing;

test "repetition track count saturates" {
    const tracks = try testing.allocator.alloc(TrackSizingFunction, std.math.maxInt(u16) + 1);
    defer testing.allocator.free(tracks);
    @memset(tracks, TrackSizingFunction.auto);
    const repetition: GridTemplateRepetition = .{ .count = .{ .count = 1 }, .tracks = tracks };
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), repetition.getTrackCount());
}

test "track sizing functions are 8 bytes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(MaxTrackSizingFunction));
    try testing.expectEqual(@as(usize, 8), @sizeOf(MinTrackSizingFunction));
}

test "track sizing function calc values" {
    const handle: CalcHandle = 3;
    try testing.expectEqual(MaxTrackSizingFunction{ .calc = handle }, MaxTrackSizingFunction.fromCalc(handle));
    try testing.expectEqual(MaxTrackSizingFunction{ .fit_content_calc = handle }, MaxTrackSizingFunction.fitContent(LengthPercentage.fromCalc(handle)));
    try testing.expect(MinTrackSizingFunction.fromMax(MaxTrackSizingFunction.fitContentCalc(handle)) == .auto);
    try testing.expect(MinTrackSizingFunction.fromDimension(Dimension.fitContentCalc(handle)) == .auto);
    try testing.expectEqual(MinTrackSizingFunction{ .calc = handle }, MinTrackSizingFunction.fromCalc(handle));
    try testing.expectEqual(@as(f32, 2.0), MaxTrackSizingFunction.fromFr(2.0).flexFactor());
    try testing.expectEqual(@as(f32, 0.0), MaxTrackSizingFunction.fromLength(2.0).flexFactor());
}

test "track sizing function conversions" {
    try testing.expect(MaxTrackSizingFunction.fromDimension(@as(Dimension, .stretch)) == .auto);
    try testing.expect(std.meta.eql(MaxTrackSizingFunction.fromDimension(Dimension.fitContentPx(3)), MaxTrackSizingFunction.fitContentPx(3)));
    try testing.expect(MinTrackSizingFunction.fromDimension(Dimension.fitContentPx(3)) == .auto);
    try testing.expect(MinTrackSizingFunction.fromMax(MaxTrackSizingFunction.fromFr(1)) == .auto);
    try testing.expect(std.meta.eql(MinTrackSizingFunction.fromMax(MaxTrackSizingFunction.fromLength(4)), MinTrackSizingFunction.fromLength(4)));
    try testing.expect(TrackSizingFunction.fromFr(2).eql(.{ .min = .auto, .max = MaxTrackSizingFunction.fromFr(2) }));
    try testing.expect(TrackSizingFunction.fromLength(5).hasFixedComponent());
    try testing.expect(!TrackSizingFunction.auto.hasFixedComponent());
    try testing.expectEqual(@as(?f32, 50), MaxTrackSizingFunction.fitContentPercent(0.5).definiteLimit(100, compact_length.NoCalc{}));
    try testing.expectEqual(@as(?f32, 7), MaxTrackSizingFunction.fromLength(7).definiteLimit(null, compact_length.NoCalc{}));
    try testing.expectEqual(@as(?f32, null), MaxTrackSizingFunction.fromPercent(0.5).definiteValue(null, compact_length.NoCalc{}));
    try testing.expect(MinTrackSizingFunction.fromPercent(0.5).behavesAsAuto(null));
    try testing.expect(!MinTrackSizingFunction.fromPercent(0.5).behavesAsAuto(10));
}

test "repetition count and template components" {
    try testing.expectEqual(RepetitionCount.auto_fit, try RepetitionCount.tryFromStr("auto-fit"));
    try testing.expectEqual(RepetitionCount.auto_fill, try RepetitionCount.tryFromStr("auto-fill"));
    try testing.expectError(error.InvalidStringRepetitionValue, RepetitionCount.tryFromStr("banana"));
    const auto_fit: GridTemplateComponent = .{ .repeat = .{ .count = .auto_fit, .tracks = &.{} } };
    try testing.expect(auto_fit.isAutoRepetition());
    const counted: GridTemplateComponent = .{ .repeat = .{ .count = .{ .count = 3 }, .tracks = &.{} } };
    try testing.expect(!counted.isAutoRepetition());
    try testing.expect(!GridTemplateComponent.auto.isAutoRepetition());
}

test "grid auto flow" {
    try testing.expect(GridAutoFlow.row_dense.isDense());
    try testing.expect(!GridAutoFlow.column.isDense());
    try testing.expectEqual(AbsoluteAxis.vertical, GridAutoFlow.column_dense.primaryAxis());
    try testing.expectEqual(AbsoluteAxis.horizontal, GridAutoFlow.row.primaryAxis());
}

test "grid placement" {
    const oz = OriginZeroLine.from;
    // into_origin_zero_placement_ignoring_named
    try testing.expectEqual(OriginZeroGridPlacement.auto, (GridPlacement{ .line = GridLine.from(0) }).intoOriginZeroPlacementIgnoringNamed(3));
    try testing.expectEqual(OriginZeroGridPlacement{ .line = oz(0) }, (GridPlacement{ .line = GridLine.from(1) }).intoOriginZeroPlacementIgnoringNamed(3));
    try testing.expectEqual(OriginZeroGridPlacement{ .span = 1 }, (GridPlacement{ .span = 0 }).intoOriginZeroPlacementIgnoringNamed(3));
    try testing.expectEqual(OriginZeroGridPlacement{ .span = max_grid_tracks }, (GridPlacement{ .span = 60000 }).intoOriginZeroPlacementIgnoringNamed(3));
    try testing.expectEqual(OriginZeroGridPlacement.auto, (GridPlacement{ .named_line = .{ .name = "a", .index = 1 } }).intoOriginZeroPlacementIgnoringNamed(3));

    // Line(GridPlacement)
    const named: Line(GridPlacement) = .{ .start = .{ .named_line = .{ .name = "a", .index = 0 } }, .end = .auto };
    try testing.expect(named.isDefinite());
    try testing.expect(!Line(GridPlacement).auto.isDefinite());
    try testing.expect(Line(GridPlacement).fromLineIndex(2).isDefinite());
    try testing.expect(!Line(GridPlacement).fromLineIndex(0).isDefinite());
    try testing.expect(GridPlacement.eql(Line(GridPlacement).fromSpan(3).start, .{ .span = 3 }));
    const converted = Line(GridPlacement).fromLineIndex(-1).intoOriginZeroIgnoringNamed(3);
    try testing.expectEqual(OriginZeroGridPlacement{ .line = oz(3) }, converted.start);
    try testing.expectEqual(OriginZeroGridPlacement.auto, converted.end);
    try testing.expect(GridPlacement.eql(.{ .named_span = .{ .name = "x", .count = 2 } }, .{ .named_span = .{ .name = "x", .count = 2 } }));
    try testing.expect(!GridPlacement.eql(.{ .named_span = .{ .name = "x", .count = 2 } }, .{ .named_span = .{ .name = "y", .count = 2 } }));

    // Line(NonNamedGridPlacement)
    const non_named: Line(NonNamedGridPlacement) = .{ .start = .{ .line = GridLine.from(2) }, .end = .{ .span = 2 } };
    try testing.expect(non_named.isDefinite());
    try testing.expectEqual(@as(u16, 2), non_named.indefiniteSpan());
    const non_named_oz = non_named.intoOriginZero(3);
    try testing.expectEqual(OriginZeroGridPlacement{ .line = oz(1) }, non_named_oz.start);
    try testing.expectEqual(OriginZeroGridPlacement{ .span = 2 }, non_named_oz.end);

    // Line(OriginZeroGridPlacement)
    const L = Line(OriginZeroGridPlacement);
    try testing.expect((L{ .start = .auto, .end = .{ .line = oz(0) } }).isDefinite());
    try testing.expect(!(L{ .start = .auto, .end = .{ .span = 2 } }).isDefinite());
    try testing.expectEqual(@as(u16, 1), (L{ .start = .auto, .end = .auto }).indefiniteSpan());
    try testing.expectEqual(@as(u16, 3), (L{ .start = .{ .span = 3 }, .end = .{ .span = 2 } }).indefiniteSpan());

    const ozl = Line(OriginZeroLine);
    try testing.expectEqual(ozl{ .start = oz(2), .end = oz(3) }, (L{ .start = .{ .line = oz(2) }, .end = .{ .line = oz(2) } }).resolveDefiniteGridLines());
    try testing.expectEqual(ozl{ .start = oz(1), .end = oz(4) }, (L{ .start = .{ .line = oz(4) }, .end = .{ .line = oz(1) } }).resolveDefiniteGridLines());
    try testing.expectEqual(ozl{ .start = oz(1), .end = oz(3) }, (L{ .start = .{ .line = oz(1) }, .end = .{ .span = 2 } }).resolveDefiniteGridLines());
    try testing.expectEqual(ozl{ .start = oz(1), .end = oz(2) }, (L{ .start = .{ .line = oz(1) }, .end = .auto }).resolveDefiniteGridLines());
    try testing.expectEqual(ozl{ .start = oz(-1), .end = oz(1) }, (L{ .start = .{ .span = 2 }, .end = .{ .line = oz(1) } }).resolveDefiniteGridLines());
    try testing.expectEqual(ozl{ .start = oz(0), .end = oz(1) }, (L{ .start = .auto, .end = .{ .line = oz(1) } }).resolveDefiniteGridLines());

    const ozo = Line(?OriginZeroLine);
    try testing.expectEqual(ozo{ .start = oz(1), .end = null }, (L{ .start = .{ .line = oz(1) }, .end = .auto }).resolveAbsolutelyPositionedGridTracks());
    try testing.expectEqual(ozo{ .start = null, .end = oz(1) }, (L{ .start = .auto, .end = .{ .line = oz(1) } }).resolveAbsolutelyPositionedGridTracks());
    try testing.expectEqual(ozo{ .start = oz(-1), .end = oz(1) }, (L{ .start = .{ .span = 2 }, .end = .{ .line = oz(1) } }).resolveAbsolutelyPositionedGridTracks());
    try testing.expectEqual(ozo{ .start = null, .end = null }, (L{ .start = .{ .span = 2 }, .end = .auto }).resolveAbsolutelyPositionedGridTracks());
    try testing.expectEqual(ozo{ .start = oz(2), .end = oz(5) }, (L{ .start = .{ .line = oz(5) }, .end = .{ .line = oz(2) } }).resolveAbsolutelyPositionedGridTracks());

    try testing.expectEqual(ozl{ .start = oz(4), .end = oz(5) }, (L{ .start = .auto, .end = .auto }).resolveIndefiniteGridTracks(oz(4)));
    try testing.expectEqual(ozl{ .start = oz(4), .end = oz(7) }, (L{ .start = .{ .span = 3 }, .end = .{ .span = 1 } }).resolveIndefiniteGridTracks(oz(4)));
    try testing.expectEqual(ozl{ .start = oz(4), .end = oz(6) }, (L{ .start = .auto, .end = .{ .span = 2 } }).resolveIndefiniteGridTracks(oz(4)));
}
