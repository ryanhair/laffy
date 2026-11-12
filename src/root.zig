//! laffy: a Zig port of the taffy UI layout library (flexbox, CSS grid, block and float layout).
//!
//! The port tracks the upstream commit recorded in `tests/fixtures/UPSTREAM`.
//!
//! This file is upstream's `lib.rs`; it also re-exports what upstream's `prelude.rs` exports.
const std = @import("std");

/// The taffy release this port tracks.
pub const upstream_version = "0.15.0";

pub const geometry = @import("geometry.zig");
pub const style = @import("style.zig");
pub const style_helpers = @import("style_helpers.zig");
pub const util = @import("util.zig");

// geometry (upstream `pub use crate::geometry::*`)
pub const AbsoluteAxis = geometry.AbsoluteAxis;
pub const AbstractAxis = geometry.AbstractAxis;
pub const InBothAbsAxis = geometry.InBothAbsAxis;
pub const Rect = geometry.Rect;
pub const Line = geometry.Line;
pub const FloatInsets = geometry.FloatInsets;
pub const Size = geometry.Size;
pub const Point = geometry.Point;
pub const MinMax = geometry.MinMax;

// style (upstream `pub use crate::style::*`)
pub const Style = style.Style;
pub const AlignContent = style.AlignContent;
pub const AlignContentKeyword = style.AlignContentKeyword;
pub const AlignItems = style.AlignItems;
pub const AlignItemsKeyword = style.AlignItemsKeyword;
pub const AlignSelf = style.AlignSelf;
pub const AlignmentSafety = style.AlignmentSafety;
pub const JustifyContent = style.JustifyContent;
pub const JustifyItems = style.JustifyItems;
pub const JustifySelf = style.JustifySelf;
pub const AvailableSpace = style.AvailableSpace;
pub const CompactLength = style.CompactLength;
pub const NoCalc = style.NoCalc;
pub const ConstCalc = style.ConstCalc;
pub const Dimension = style.Dimension;
pub const ExpandedDimension = style.ExpandedDimension;
pub const ExpandedLengthPercentage = style.ExpandedLengthPercentage;
pub const ExpandedLengthPercentageAuto = style.ExpandedLengthPercentageAuto;
pub const LengthPercentage = style.LengthPercentage;
pub const LengthPercentageAuto = style.LengthPercentageAuto;
pub const Display = style.Display;
pub const BoxGenerationMode = style.BoxGenerationMode;
pub const Position = style.Position;
pub const ContainingBlockClaims = style.ContainingBlockClaims;
pub const BoxSizing = style.BoxSizing;
pub const Overflow = style.Overflow;
pub const Contain = style.Contain;
pub const Direction = style.Direction;
pub const TextAlign = style.TextAlign;
pub const FlexDirection = style.FlexDirection;
pub const FlexWrap = style.FlexWrap;
pub const Clear = style.Clear;
pub const Float = style.Float;
pub const FloatDirection = style.FloatDirection;
pub const ExpandedMaxTrackSizingFunction = style.ExpandedMaxTrackSizingFunction;
pub const ExpandedMinTrackSizingFunction = style.ExpandedMinTrackSizingFunction;
pub const GenericGridPlacement = style.GenericGridPlacement;
pub const GenericGridTemplateComponent = style.GenericGridTemplateComponent;
pub const GridAutoFlow = style.GridAutoFlow;
pub const GridAutoTracks = style.GridAutoTracks;
pub const GridPlacement = style.GridPlacement;
pub const GridTemplateComponent = style.GridTemplateComponent;
pub const GridTemplateRepetition = style.GridTemplateRepetition;
pub const GridTemplateTracks = style.GridTemplateTracks;
pub const MaxTrackSizingFunction = style.MaxTrackSizingFunction;
pub const MinTrackSizingFunction = style.MinTrackSizingFunction;
pub const RepetitionCount = style.RepetitionCount;
pub const TrackSizingFunction = style.TrackSizingFunction;
pub const GridTemplateArea = style.GridTemplateArea;
pub const GridTemplateAreas = style.GridTemplateAreas;
pub const NamedGridLine = style.NamedGridLine;
pub const CoreStyleDefaults = style.CoreStyleDefaults;
pub const OofItemStyleDefaults = style.OofItemStyleDefaults;
pub const FlexboxContainerStyleDefaults = style.FlexboxContainerStyleDefaults;
pub const FlexboxItemStyleDefaults = style.FlexboxItemStyleDefaults;
pub const GridContainerStyleDefaults = style.GridContainerStyleDefaults;
pub const GridItemStyleDefaults = style.GridItemStyleDefaults;
pub const BlockContainerStyleDefaults = style.BlockContainerStyleDefaults;
pub const BlockItemStyleDefaults = style.BlockItemStyleDefaults;

// util (upstream `pub use crate::util::*`)
pub const maybeMin = util.maybeMin;
pub const maybeMax = util.maybeMax;
pub const maybeClamp = util.maybeClamp;
pub const maybeAdd = util.maybeAdd;
pub const maybeSub = util.maybeSub;
pub const maybeResolve = util.maybeResolve;
pub const resolveOrZero = util.resolveOrZero;

// style_helpers (upstream prelude)
pub const zero = style_helpers.zero;
pub const auto = style_helpers.auto;
pub const minContent = style_helpers.minContent;
pub const maxContent = style_helpers.maxContent;
pub const fitContent = style_helpers.fitContent;
pub const length = style_helpers.length;
pub const percent = style_helpers.percent;
pub const fr = style_helpers.fr;
pub const line = style_helpers.line;
pub const span = style_helpers.span;
pub const minmax = style_helpers.minmax;
pub const flex = style_helpers.flex;
pub const repeat = style_helpers.repeat;
pub const evenlySizedTracks = style_helpers.evenlySizedTracks;

test {
    std.testing.refAllDecls(@This());
    _ = geometry;
    _ = style;
    _ = style_helpers;
    _ = util;
    _ = @import("compute/grid/types/coordinates.zig");
}
