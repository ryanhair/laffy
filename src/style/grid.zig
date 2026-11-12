//! Style types for CSS Grid layout
//!
//! String ownership: upstream is generic over a `CheapCloneStr` type for line and area names.
//! laffy uses borrowed `[]const u8` slices everywhere. Names (and the slices that hold track
//! lists, line-name sets and template areas) are NOT owned by the style values: the caller must
//! keep the referenced memory alive for as long as the style is used.
//!
//! The `GridContainerStyle` and `GridItemStyle` accessor interfaces are documented in
//! `src/style.zig` together with the other style accessor interfaces.
const std = @import("std");
const geometry = @import("../geometry.zig");
const Line = geometry.Line;
const AbsoluteAxis = geometry.AbsoluteAxis;
const compact_length = @import("compact_length.zig");
const CompactLength = compact_length.CompactLength;
const toF32 = compact_length.toF32;
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
pub const MaxTrackSizingFunction = packed struct(u64) {
    inner: CompactLength,

    /// Upstream `TaffyZero`
    pub const zero: MaxTrackSizingFunction = .{ .inner = CompactLength.zero };
    /// The dimension should be automatically computed according to algorithm-specific rules
    /// regarding the default size of boxes. (Upstream `auto()` and `TaffyAuto`)
    pub const auto: MaxTrackSizingFunction = .{ .inner = CompactLength.auto };
    /// The size should be the "min-content" size.
    /// This is the smallest size that can fit the item's contents with ALL soft line-wrapping opportunities taken
    pub const min_content: MaxTrackSizingFunction = .{ .inner = CompactLength.min_content };
    /// The size should be the "max-content" size.
    /// This is the smallest size that can fit the item's contents with NO soft line-wrapping opportunities taken
    pub const max_content: MaxTrackSizingFunction = .{ .inner = CompactLength.max_content };

    /// Upstream `TaffyFitContent`
    pub fn fitContent(argument: LengthPercentage) MaxTrackSizingFunction {
        return .{ .inner = CompactLength.fitContent(argument) };
    }
    /// Upstream `From<LengthPercentage>`
    pub fn fromLengthPercentage(input: LengthPercentage) MaxTrackSizingFunction {
        return .{ .inner = input.inner };
    }
    /// Upstream `From<LengthPercentageAuto>`
    pub fn fromLengthPercentageAuto(input: LengthPercentageAuto) MaxTrackSizingFunction {
        return .{ .inner = input.inner };
    }
    /// Upstream `From<Dimension>`
    pub fn fromDimension(input: Dimension) MaxTrackSizingFunction {
        // Dimension supports values that are not valid max track sizing functions.
        // Map those to `auto`.
        return switch (input.inner.tag()) {
            CompactLength.fit_content_keyword_tag, CompactLength.stretch_tag, CompactLength.content_tag => auto,
            else => .{ .inner = input.inner },
        };
    }
    /// Upstream `From<MinTrackSizingFunction>`
    pub fn fromMin(input: MinTrackSizingFunction) MaxTrackSizingFunction {
        return .{ .inner = input.inner };
    }

    /// An absolute length in some abstract units. Users of laffy may define what they correspond
    /// to in their application (pixels, logical pixels, mm, etc) as they see fit.
    pub fn fromLength(val: f32) MaxTrackSizingFunction {
        return .{ .inner = CompactLength.fromLength(val) };
    }

    /// A percentage length relative to the size of the containing block.
    ///
    /// **NOTE: percentages are represented as a f32 value in the range [0.0, 1.0] NOT the range [0.0, 100.0]**
    pub fn fromPercent(val: f32) MaxTrackSizingFunction {
        return .{ .inner = CompactLength.fromPercent(val) };
    }

    /// The size should be computed according to the "fit content" formula:
    ///    `max(min_content, min(max_content, limit))`
    /// where `limit` is a LENGTH value.
    pub fn fitContentPx(limit: f32) MaxTrackSizingFunction {
        return .{ .inner = CompactLength.fitContentPx(limit) };
    }

    /// The size should be computed according to the "fit content" formula:
    ///    `max(min_content, min(max_content, limit))`
    /// where `limit` is a PERCENTAGE value.
    pub fn fitContentPercent(limit: f32) MaxTrackSizingFunction {
        return .{ .inner = CompactLength.fitContentPercent(limit) };
    }

    /// The dimension as a fraction of the total available grid space (`fr` units in CSS)
    /// Specified value is the numerator of the fraction. Denominator is the sum of all fraction specified in that grid dimension
    /// Spec: <https://www.w3.org/TR/css3-grid-layout/#fr-unit>
    pub fn fromFr(val: f32) MaxTrackSizingFunction {
        return .{ .inner = CompactLength.fromFr(val) };
    }

    /// A `calc()` value. The value passed here is treated as an opaque handle to
    /// the actual calc representation and may be a pointer, index, etc.
    ///
    /// The low 3 bits are used as a tag value and will be returned as 0.
    pub fn calc(ptr: *const anyopaque) MaxTrackSizingFunction {
        return .{ .inner = CompactLength.calc(ptr) };
    }

    /// A `fit-content()` track sizing function whose limit is a `calc()` value. The value passed here is treated
    /// as an opaque handle to the actual calc representation and may be a pointer, index, etc.
    ///
    /// The low 3 bits are used as a tag value and will be returned as 0.
    pub fn fitContentCalc(ptr: *const anyopaque) MaxTrackSizingFunction {
        return .{ .inner = CompactLength.fitContentCalc(ptr) };
    }

    /// Create a MaxTrackSizingFunction from a raw `CompactLength`.
    /// The `CompactLength` must represent a valid variant for MaxTrackSizingFunction.
    pub fn fromRaw(val: CompactLength) MaxTrackSizingFunction {
        return .{ .inner = val };
    }

    /// Get the underlying `CompactLength` representation of the value
    pub fn intoRaw(self: MaxTrackSizingFunction) CompactLength {
        return self.inner;
    }

    /// Returns true if the max track sizing function is `MinContent`, `MaxContent`, `FitContent` or `Auto`, else false.
    pub fn isIntrinsic(self: MaxTrackSizingFunction) bool {
        return self.inner.isIntrinsic();
    }

    /// Returns true if the max track sizing function is `MaxContent`, `FitContent` or `Auto` else false.
    /// "In all cases, treat auto and fit-content() as max-content, except where specified otherwise for fit-content()."
    /// See: <https://www.w3.org/TR/css-grid-1/#algo-terms>
    pub fn isMaxContentAlike(self: MaxTrackSizingFunction) bool {
        return self.inner.isMaxContentAlike();
    }

    /// Returns true if the an Fr value, else false.
    pub fn isFr(self: MaxTrackSizingFunction) bool {
        return self.inner.isFr();
    }

    /// Returns true if the is `Auto`, else false.
    pub fn isAuto(self: MaxTrackSizingFunction) bool {
        return self.inner.isAuto();
    }

    /// Returns true if value is MinContent
    pub fn isMinContent(self: MaxTrackSizingFunction) bool {
        return self.inner.isMinContent();
    }

    /// Returns true if value is MaxContent
    pub fn isMaxContent(self: MaxTrackSizingFunction) bool {
        return self.inner.isMaxContent();
    }

    /// Returns true if value is FitContent(...)
    pub fn isFitContent(self: MaxTrackSizingFunction) bool {
        return self.inner.isFitContent();
    }

    /// Returns true if value is MaxContent or FitContent(...)
    pub fn isMaxOrFitContent(self: MaxTrackSizingFunction) bool {
        return self.inner.isMaxOrFitContent();
    }

    /// Returns whether the value can be resolved using `definiteValue`
    pub fn hasDefiniteValue(self: MaxTrackSizingFunction, parent_size: ?f32) bool {
        return switch (self.inner.tag()) {
            CompactLength.length_tag => true,
            CompactLength.percent_tag => parent_size != null,
            else => if (self.inner.isPlainCalc()) parent_size != null else false,
        };
    }

    /// Returns fixed point values directly. Attempts to resolve percentage values against
    /// the passed available_space and returns if this results in a concrete value (which it
    /// will if the available_space is non-null). Otherwise returns null.
    pub fn definiteValue(self: MaxTrackSizingFunction, parent_size: ?f32, calc_resolver: anytype) ?f32 {
        return switch (self.inner.tag()) {
            CompactLength.length_tag => self.inner.value(),
            CompactLength.percent_tag => if (parent_size) |size| self.inner.value() * size else null,
            else => if (self.inner.isPlainCalc())
                (if (parent_size) |size| calc_resolver.resolveCalcValue(self.inner.calcValue(), size) else null)
            else
                null,
        };
    }

    /// Resolve the `fit-content()` limit of this track sizing function against the passed `parent_size`.
    /// Returns null if this is not a `fit-content()` function, or if it has a percentage or `calc()`
    /// argument and `parent_size` is indefinite.
    pub fn fitContentLimit(self: MaxTrackSizingFunction, parent_size: ?f32, calc_resolver: anytype) ?f32 {
        return switch (self.inner.tag()) {
            CompactLength.fit_content_px_tag => self.inner.value(),
            CompactLength.fit_content_percent_tag => if (parent_size) |size| self.inner.value() * size else null,
            else => if (self.inner.isFitContentCalc())
                (if (parent_size) |size| calc_resolver.resolveCalcValue(self.inner.calcValue(), size) else null)
            else
                null,
        };
    }

    /// Resolve the maximum size of the track as defined by either:
    ///     - A fixed track sizing function
    ///     - A percentage track sizing function (with definite available space)
    ///     - A fit-content sizing function with fixed argument
    ///     - A fit-content sizing function with percentage argument (with definite available space)
    /// All other kinds of track sizing function return null.
    pub fn definiteLimit(self: MaxTrackSizingFunction, parent_size: ?f32, calc_resolver: anytype) ?f32 {
        return switch (self.inner.tag()) {
            CompactLength.fit_content_px_tag => self.inner.value(),
            CompactLength.fit_content_percent_tag => if (parent_size) |size| self.inner.value() * size else null,
            else => if (self.inner.isFitContentCalc())
                (if (parent_size) |size| calc_resolver.resolveCalcValue(self.inner.calcValue(), size) else null)
            else
                self.definiteValue(parent_size, calc_resolver),
        };
    }

    /// Resolve percentage values against the passed parent_size, returning the value.
    /// Non-percentage values always return null.
    pub fn resolvedPercentageSize(self: MaxTrackSizingFunction, parent_size: f32, calc_resolver: anytype) ?f32 {
        return self.inner.resolvedPercentageSize(parent_size, calc_resolver);
    }

    /// Whether the track sizing functions depends on the size of the parent node
    pub fn usesPercentage(self: MaxTrackSizingFunction) bool {
        return self.inner.usesPercentage();
    }

    /// Expand the compact representation into an `ExpandedMaxTrackSizingFunction` tagged union.
    pub fn expand(self: MaxTrackSizingFunction) ExpandedMaxTrackSizingFunction {
        const v = self.inner;
        return switch (v.tag()) {
            CompactLength.length_tag => .{ .length = v.value() },
            CompactLength.percent_tag => .{ .percent = v.value() },
            CompactLength.auto_tag => .auto,
            CompactLength.min_content_tag => .min_content,
            CompactLength.max_content_tag => .max_content,
            CompactLength.fit_content_px_tag => .{ .fit_content_px = v.value() },
            CompactLength.fit_content_percent_tag => .{ .fit_content_percent = v.value() },
            CompactLength.fr_tag => .{ .fr = v.value() },
            else => if (v.isFitContentCalc())
                .{ .fit_content_calc = v.calcValue() }
            else if (v.isPlainCalc())
                .{ .calc = v.calcValue() }
            else
                unreachable, // MaxTrackSizingFunction contains a value with an invalid tag
        };
    }

    /// Convert an `ExpandedMaxTrackSizingFunction` back into the compact form (upstream `From`)
    pub fn fromExpanded(value: ExpandedMaxTrackSizingFunction) MaxTrackSizingFunction {
        return switch (value) {
            .length => |val| fromLength(val),
            .percent => |val| fromPercent(val),
            .auto => auto,
            .min_content => min_content,
            .max_content => max_content,
            .fit_content_px => |val| fitContentPx(val),
            .fit_content_percent => |val| fitContentPercent(val),
            .fit_content_calc => |ptr| fitContentCalc(ptr),
            .fr => |val| fromFr(val),
            .calc => |ptr| calc(ptr),
        };
    }
};

/// The expanded, non-compact representation of a `MaxTrackSizingFunction`.
pub const ExpandedMaxTrackSizingFunction = union(enum) {
    /// An absolute length (see `MaxTrackSizingFunction.length`)
    length: f32,
    /// A percentage length (see `MaxTrackSizingFunction.percent`)
    percent: f32,
    /// The automatic keyword (see `MaxTrackSizingFunction.auto`)
    auto,
    /// The `min-content` keyword (see `MaxTrackSizingFunction.min_content`)
    min_content,
    /// The `max-content` keyword (see `MaxTrackSizingFunction.max_content`)
    max_content,
    /// A `fit-content(...)` value with a length limit (see `MaxTrackSizingFunction.fitContentPx`)
    fit_content_px: f32,
    /// A `fit-content(...)` value with a percentage limit (see `MaxTrackSizingFunction.fitContentPercent`)
    fit_content_percent: f32,
    /// Track maximum size should be content sized under a max-content constraint, but not larger than
    /// the `calc()` limit (an opaque handle to the calc representation)
    fit_content_calc: *const anyopaque,
    /// A fraction of the leftover space (see `MaxTrackSizingFunction.fr`)
    fr: f32,
    /// A `calc()` value (see `MaxTrackSizingFunction.calc`). The pointer is an opaque handle to
    /// the calc representation, exactly as passed to the constructor.
    calc: *const anyopaque,
};

/// Minimum track sizing function
///
/// Specifies the minimum size of a grid track. A grid track will automatically size between it's minimum and maximum size based
/// on the size of it's contents, the amount of available space, and the sizing constraint the grid is being size under.
/// See <https://developer.mozilla.org/en-US/docs/Web/CSS/grid-template-columns>
pub const MinTrackSizingFunction = packed struct(u64) {
    inner: CompactLength,

    /// Upstream `TaffyZero`
    pub const zero: MinTrackSizingFunction = .{ .inner = CompactLength.zero };
    /// The dimension should be automatically computed according to algorithm-specific rules
    /// regarding the default size of boxes. (Upstream `auto()` and `TaffyAuto`)
    pub const auto: MinTrackSizingFunction = .{ .inner = CompactLength.auto };
    /// The size should be the "min-content" size.
    /// This is the smallest size that can fit the item's contents with ALL soft line-wrapping opportunities taken
    pub const min_content: MinTrackSizingFunction = .{ .inner = CompactLength.min_content };
    /// The size should be the "max-content" size.
    /// This is the smallest size that can fit the item's contents with NO soft line-wrapping opportunities taken
    pub const max_content: MinTrackSizingFunction = .{ .inner = CompactLength.max_content };

    /// Upstream `From<LengthPercentage>`
    pub fn fromLengthPercentage(input: LengthPercentage) MinTrackSizingFunction {
        return .{ .inner = input.inner };
    }
    /// Upstream `From<LengthPercentageAuto>`
    pub fn fromLengthPercentageAuto(input: LengthPercentageAuto) MinTrackSizingFunction {
        return .{ .inner = input.inner };
    }
    /// Upstream `From<Dimension>`
    pub fn fromDimension(input: Dimension) MinTrackSizingFunction {
        // Dimension supports values that are not valid min track sizing functions.
        // Map those to `auto`.
        return switch (input.inner.tag()) {
            CompactLength.fit_content_px_tag,
            CompactLength.fit_content_percent_tag,
            CompactLength.fit_content_keyword_tag,
            CompactLength.stretch_tag,
            CompactLength.content_tag,
            => auto,
            else => if (input.inner.isFitContentCalc()) auto else .{ .inner = input.inner },
        };
    }
    /// Upstream `From<MaxTrackSizingFunction>`
    pub fn fromMax(input: MaxTrackSizingFunction) MinTrackSizingFunction {
        if (input.isFr() or input.isFitContent()) {
            return auto;
        }
        return .{ .inner = input.inner };
    }

    /// An absolute length in some abstract units. Users of laffy may define what they correspond
    /// to in their application (pixels, logical pixels, mm, etc) as they see fit.
    pub fn fromLength(val: f32) MinTrackSizingFunction {
        return .{ .inner = CompactLength.fromLength(val) };
    }

    /// A percentage length relative to the size of the containing block.
    ///
    /// **NOTE: percentages are represented as a f32 value in the range [0.0, 1.0] NOT the range [0.0, 100.0]**
    pub fn fromPercent(val: f32) MinTrackSizingFunction {
        return .{ .inner = CompactLength.fromPercent(val) };
    }

    /// A `calc()` value. The value passed here is treated as an opaque handle to
    /// the actual calc representation and may be a pointer, index, etc.
    ///
    /// The low 3 bits are used as a tag value and will be returned as 0.
    pub fn calc(ptr: *const anyopaque) MinTrackSizingFunction {
        return .{ .inner = CompactLength.calc(ptr) };
    }

    /// Create a MinTrackSizingFunction from a raw `CompactLength`.
    /// The `CompactLength` must represent a valid variant for MinTrackSizingFunction.
    pub fn fromRaw(val: CompactLength) MinTrackSizingFunction {
        return .{ .inner = val };
    }

    /// Get the underlying `CompactLength` representation of the value
    pub fn intoRaw(self: MinTrackSizingFunction) CompactLength {
        return self.inner;
    }

    /// Returns true if the min track sizing function is `MinContent`, `MaxContent` or `Auto`, else false.
    pub fn isIntrinsic(self: MinTrackSizingFunction) bool {
        return self.inner.isIntrinsic();
    }

    /// Returns true if the min track sizing function is `MinContent` or `MaxContent`, else false.
    pub fn isMinOrMaxContent(self: MinTrackSizingFunction) bool {
        return self.inner.isMinOrMaxContent();
    }

    /// Returns true if the value is an fr value
    pub fn isFr(self: MinTrackSizingFunction) bool {
        return self.inner.isFr();
    }

    /// Returns true if the is `Auto`, else false.
    pub fn isAuto(self: MinTrackSizingFunction) bool {
        return self.inner.isAuto();
    }

    /// Returns true if the value is `Auto`, or is a percentage and `parent_size` is null
    pub fn behavesAsAuto(self: MinTrackSizingFunction, parent_size: ?f32) bool {
        return self.inner.isAuto() or (parent_size == null and self.inner.usesPercentage());
    }

    /// Returns true if value is MinContent
    pub fn isMinContent(self: MinTrackSizingFunction) bool {
        return self.inner.isMinContent();
    }

    /// Returns true if value is MaxContent
    pub fn isMaxContent(self: MinTrackSizingFunction) bool {
        return self.inner.isMaxContent();
    }

    /// Returns fixed point values directly. Attempts to resolve percentage values against
    /// the passed available_space and returns if this results in a concrete value (which it
    /// will if the available_space is non-null). Otherwise returns null.
    pub fn definiteValue(self: MinTrackSizingFunction, parent_size: ?f32, calc_resolver: anytype) ?f32 {
        return switch (self.inner.tag()) {
            CompactLength.length_tag => self.inner.value(),
            CompactLength.percent_tag => if (parent_size) |size| self.inner.value() * size else null,
            else => if (self.inner.isPlainCalc())
                (if (parent_size) |size| calc_resolver.resolveCalcValue(self.inner.calcValue(), size) else null)
            else
                null,
        };
    }

    /// Resolve percentage values against the passed parent_size, returning the value.
    /// Non-percentage values always return null.
    pub fn resolvedPercentageSize(self: MinTrackSizingFunction, parent_size: f32, calc_resolver: anytype) ?f32 {
        return self.inner.resolvedPercentageSize(parent_size, calc_resolver);
    }

    /// Whether the track sizing functions depends on the size of the parent node
    pub fn usesPercentage(self: MinTrackSizingFunction) bool {
        return self.inner.usesPercentage();
    }

    /// Expand the compact representation into an `ExpandedMinTrackSizingFunction` tagged union.
    pub fn expand(self: MinTrackSizingFunction) ExpandedMinTrackSizingFunction {
        const v = self.inner;
        return switch (v.tag()) {
            CompactLength.length_tag => .{ .length = v.value() },
            CompactLength.percent_tag => .{ .percent = v.value() },
            CompactLength.auto_tag => .auto,
            CompactLength.min_content_tag => .min_content,
            CompactLength.max_content_tag => .max_content,
            else => if (v.isPlainCalc())
                .{ .calc = v.calcValue() }
            else
                unreachable, // MinTrackSizingFunction contains a value with an invalid tag
        };
    }

    /// Convert an `ExpandedMinTrackSizingFunction` back into the compact form (upstream `From`)
    pub fn fromExpanded(value: ExpandedMinTrackSizingFunction) MinTrackSizingFunction {
        return switch (value) {
            .length => |val| fromLength(val),
            .percent => |val| fromPercent(val),
            .auto => auto,
            .min_content => min_content,
            .max_content => max_content,
            .calc => |ptr| calc(ptr),
        };
    }
};

/// The expanded, non-compact representation of a `MinTrackSizingFunction`.
pub const ExpandedMinTrackSizingFunction = union(enum) {
    /// An absolute length (see `MinTrackSizingFunction.length`)
    length: f32,
    /// A percentage length (see `MinTrackSizingFunction.percent`)
    percent: f32,
    /// The automatic keyword (see `MinTrackSizingFunction.auto`)
    auto,
    /// The `min-content` keyword (see `MinTrackSizingFunction.min_content`)
    min_content,
    /// The `max-content` keyword (see `MinTrackSizingFunction.max_content`)
    max_content,
    /// A `calc()` value (see `MinTrackSizingFunction.calc`). The pointer is an opaque handle to
    /// the calc representation, exactly as passed to the constructor.
    calc: *const anyopaque,
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
        return self.min.inner.isLengthPercentageOrCalc() or self.max.inner.isLengthPercentageOrCalc();
    }

    /// Upstream `TaffyAuto`
    pub const auto: TrackSizingFunction = .{ .min = MinTrackSizingFunction.auto, .max = MaxTrackSizingFunction.auto };
    /// Upstream `TaffyMinContent`
    pub const min_content: TrackSizingFunction = .{ .min = MinTrackSizingFunction.min_content, .max = MaxTrackSizingFunction.min_content };
    /// Upstream `TaffyMaxContent`
    pub const max_content: TrackSizingFunction = .{ .min = MinTrackSizingFunction.max_content, .max = MaxTrackSizingFunction.max_content };
    /// Upstream `TaffyZero`
    pub const zero: TrackSizingFunction = .{ .min = MinTrackSizingFunction.zero, .max = MaxTrackSizingFunction.zero };

    /// Upstream `TaffyFitContent`
    pub fn fitContent(argument: LengthPercentage) TrackSizingFunction {
        return .{ .min = MinTrackSizingFunction.auto, .max = MaxTrackSizingFunction.fitContent(argument) };
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
        return .{ .min = MinTrackSizingFunction.auto, .max = MaxTrackSizingFunction.fromFr(value) };
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
        return self.min == other.min and self.max == other.max;
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

var calc_handle_storage: u64 align(8) = 0;

test "repetition track count saturates" {
    const tracks = try testing.allocator.alloc(TrackSizingFunction, std.math.maxInt(u16) + 1);
    defer testing.allocator.free(tracks);
    @memset(tracks, TrackSizingFunction.auto);
    const repetition: GridTemplateRepetition = .{ .count = .{ .count = 1 }, .tracks = tracks };
    try testing.expectEqual(@as(u16, std.math.maxInt(u16)), repetition.getTrackCount());
}

test "max track sizing function round trips" {
    const cases = [_]MaxTrackSizingFunction{
        MaxTrackSizingFunction.fromLength(12.0),
        MaxTrackSizingFunction.fromPercent(0.5),
        MaxTrackSizingFunction.auto,
        MaxTrackSizingFunction.min_content,
        MaxTrackSizingFunction.max_content,
        MaxTrackSizingFunction.fitContentPx(30.0),
        MaxTrackSizingFunction.fitContentPercent(0.75),
        MaxTrackSizingFunction.fromFr(2.0),
    };
    for (cases) |value| {
        try testing.expect(MaxTrackSizingFunction.fromExpanded(value.expand()) == value);
    }
    try testing.expectEqual(ExpandedMaxTrackSizingFunction{ .fr = 2.0 }, MaxTrackSizingFunction.fromFr(2.0).expand());
    try testing.expectEqual(ExpandedMaxTrackSizingFunction{ .fit_content_px = 30.0 }, MaxTrackSizingFunction.fitContentPx(30.0).expand());
}

test "min track sizing function round trips" {
    const cases = [_]MinTrackSizingFunction{
        MinTrackSizingFunction.fromLength(12.0),
        MinTrackSizingFunction.fromPercent(0.5),
        MinTrackSizingFunction.auto,
        MinTrackSizingFunction.min_content,
        MinTrackSizingFunction.max_content,
    };
    for (cases) |value| {
        try testing.expect(MinTrackSizingFunction.fromExpanded(value.expand()) == value);
    }
    try testing.expectEqual(ExpandedMinTrackSizingFunction.max_content, MinTrackSizingFunction.max_content.expand());
}

test "track sizing function calc round trips" {
    const handle: *const anyopaque = &calc_handle_storage;
    try testing.expectEqual(ExpandedMaxTrackSizingFunction{ .calc = handle }, MaxTrackSizingFunction.calc(handle).expand());
    try testing.expectEqual(ExpandedMaxTrackSizingFunction{ .fit_content_calc = handle }, MaxTrackSizingFunction.fitContentCalc(handle).expand());
    try testing.expect(MaxTrackSizingFunction.fromExpanded(.{ .fit_content_calc = handle }) == MaxTrackSizingFunction.fitContentCalc(handle));
    try testing.expect(MaxTrackSizingFunction.fitContent(LengthPercentage.calc(handle)) == MaxTrackSizingFunction.fitContentCalc(handle));
    try testing.expect(MinTrackSizingFunction.fromMax(MaxTrackSizingFunction.fitContentCalc(handle)) == MinTrackSizingFunction.auto);
    try testing.expect(MinTrackSizingFunction.fromDimension(Dimension.fitContentCalc(handle)) == MinTrackSizingFunction.auto);
    try testing.expect(MaxTrackSizingFunction.fromExpanded(.{ .calc = handle }) == MaxTrackSizingFunction.calc(handle));
    try testing.expectEqual(ExpandedMinTrackSizingFunction{ .calc = handle }, MinTrackSizingFunction.calc(handle).expand());
}

test "track sizing function conversions" {
    try testing.expect(MaxTrackSizingFunction.fromDimension(Dimension.stretch) == MaxTrackSizingFunction.auto);
    try testing.expect(MaxTrackSizingFunction.fromDimension(Dimension.fitContentPx(3)) == MaxTrackSizingFunction.fitContentPx(3));
    try testing.expect(MinTrackSizingFunction.fromDimension(Dimension.fitContentPx(3)) == MinTrackSizingFunction.auto);
    try testing.expect(MinTrackSizingFunction.fromMax(MaxTrackSizingFunction.fromFr(1)) == MinTrackSizingFunction.auto);
    try testing.expect(MinTrackSizingFunction.fromMax(MaxTrackSizingFunction.fromLength(4)) == MinTrackSizingFunction.fromLength(4));
    try testing.expect(TrackSizingFunction.fromFr(2).eql(.{ .min = MinTrackSizingFunction.auto, .max = MaxTrackSizingFunction.fromFr(2) }));
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
