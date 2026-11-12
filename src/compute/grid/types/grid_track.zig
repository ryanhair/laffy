//! Contains GridTrack used to represent a single grid track (row/column) during layout
const std = @import("std");
const style = @import("../../../style.zig");
const LengthPercentage = style.LengthPercentage;
const MaxTrackSizingFunction = style.MaxTrackSizingFunction;
const MinTrackSizingFunction = style.MinTrackSizingFunction;
const sys = @import("../../../util/sys.zig");

/// Whether a GridTrack represents an actual track or a gutter.
pub const GridTrackKind = enum {
    /// Track is an actual track
    track,
    /// Track is a gutter (aka grid line) (aka gap)
    gutter,
};

/// Internal sizing information for a single grid track (row/column)
/// Gutters between tracks are sized similarly to actual tracks, so they
/// are also represented by this struct
pub const GridTrack = struct {
    /// Whether the track is a full track, a gutter, or a placeholder that has not yet been initialised
    kind: GridTrackKind,

    /// Whether the track is a collapsed track/gutter. Collapsed tracks are effectively treated as if
    /// they don't exist for the purposes of grid sizing. Gutters between collapsed tracks are also collapsed.
    is_collapsed: bool,

    /// The minimum track sizing function of the track
    min_track_sizing_function: MinTrackSizingFunction,

    /// The maximum track sizing function of the track
    max_track_sizing_function: MaxTrackSizingFunction,

    /// The distance of the start of the track from the start of the grid container
    offset: f32,

    /// The size (width/height as applicable) of the track
    base_size: f32,

    /// A temporary scratch value when sizing tracks
    /// Note: can be infinity
    growth_limit: f32,

    /// A temporary scratch value when sizing tracks. Is used as an additional amount to add to the
    /// estimate for the available space in the opposite axis when content sizing items
    content_alignment_adjustment: f32,

    /// A temporary scratch value when "distributing space" to avoid clobbering planned increase variable
    item_incurred_increase: f32,
    /// A temporary scratch value when "distributing space" to avoid clobbering the main variable
    base_size_planned_increase: f32,
    /// A temporary scratch value when "distributing space" to avoid clobbering the main variable
    growth_limit_planned_increase: f32,
    /// A temporary scratch value when "distributing space"
    /// See: https://www.w3.org/TR/css3-grid-layout/#infinitely-growable
    infinitely_growable: bool,

    /// The resolved `fit-content()` limit of the max track sizing function (infinity if it is not `fit-content()`
    /// or the limit cannot be resolved). Resolved once per track sizing pass by `resolveFitContentLimit`.
    fit_content_limit: f32,

    /// GridTrack constructor with all configuration parameters for the other constructors exposed
    fn newWithKind(
        kind: GridTrackKind,
        min_track_sizing_function: MinTrackSizingFunction,
        max_track_sizing_function: MaxTrackSizingFunction,
    ) GridTrack {
        return .{
            .kind = kind,
            .is_collapsed = false,
            .min_track_sizing_function = min_track_sizing_function,
            .max_track_sizing_function = max_track_sizing_function,
            .offset = 0.0,
            .base_size = 0.0,
            .growth_limit = 0.0,
            .content_alignment_adjustment = 0.0,
            .item_incurred_increase = 0.0,
            .base_size_planned_increase = 0.0,
            .growth_limit_planned_increase = 0.0,
            .infinitely_growable = false,
            .fit_content_limit = std.math.inf(f32),
        };
    }

    /// Create new GridTrack representing an actual track (not a gutter)
    pub fn new(
        min_track_sizing_function: MinTrackSizingFunction,
        max_track_sizing_function: MaxTrackSizingFunction,
    ) GridTrack {
        return newWithKind(.track, min_track_sizing_function, max_track_sizing_function);
    }

    /// Create a new GridTrack representing a gutter
    pub fn gutter(size: LengthPercentage) GridTrack {
        return newWithKind(
            .gutter,
            MinTrackSizingFunction.fromLengthPercentage(size),
            MaxTrackSizingFunction.fromLengthPercentage(size),
        );
    }

    /// Mark a GridTrack as collapsed. Also sets both of the track's sizing functions
    /// to fixed zero-sized sizing functions.
    pub fn collapse(self: *GridTrack) void {
        self.is_collapsed = true;
        self.min_track_sizing_function = MinTrackSizingFunction.zero;
        self.max_track_sizing_function = MaxTrackSizingFunction.zero;
        self.fit_content_limit = std.math.inf(f32);
    }

    /// Returns true if the track is flexible (has a Flex MaxTrackSizingFunction), else false.
    pub inline fn isFlexible(self: *const GridTrack) bool {
        return self.max_track_sizing_function.isFr();
    }

    /// Returns true if the track uses a percentage track sizing function
    pub inline fn usesPercentage(self: *const GridTrack) bool {
        return self.min_track_sizing_function.usesPercentage() or self.max_track_sizing_function.usesPercentage();
    }

    /// Returns true if the track has an intrinsic min and or max sizing function
    pub inline fn hasIntrinsicSizingFunction(self: *const GridTrack) bool {
        return self.min_track_sizing_function.isIntrinsic() or self.max_track_sizing_function.isIntrinsic();
    }

    /// Cache the `fit-content()` limit of the max track sizing function (if any), resolved against the
    /// container's inner size in this axis. Percentage and calc() limits resolve to infinity if that size is
    /// indefinite, as do tracks which are not `fit-content()`.
    pub inline fn resolveFitContentLimit(self: *GridTrack, axis_inner_node_size: ?f32, calc_resolver: anytype) void {
        self.fit_content_limit = self.max_track_sizing_function.fitContentLimit(axis_inner_node_size, calc_resolver) orelse std.math.inf(f32);
    }

    /// Returns the resolved `fit-content()` limit of the track (infinity if the track is not `fit-content()`)
    pub inline fn fitContentLimit(self: *const GridTrack) f32 {
        return self.fit_content_limit;
    }

    /// Returns the track's growth limit, capped by its `fit-content()` limit (if any)
    pub inline fn fitContentLimitedGrowthLimit(self: *const GridTrack) f32 {
        return sys.f32Min(self.growth_limit, self.fit_content_limit);
    }

    /// Returns the track's flex factor if it is a flex track, else 0.
    pub inline fn flexFactor(self: *const GridTrack) f32 {
        if (self.max_track_sizing_function.isFr()) {
            return self.max_track_sizing_function.inner.value();
        } else {
            return 0.0;
        }
    }
};
