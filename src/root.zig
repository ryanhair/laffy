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
pub const tree = @import("tree.zig");
pub const compute = @import("compute.zig");
/// The C ABI (`include/laffy.h`); see `docs/c-api.md`
pub const c_api = @import("c_api.zig");

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
pub const CalcHandle = style.CalcHandle;
pub const NoCalc = style.NoCalc;
pub const ConstCalc = style.ConstCalc;
pub const Dimension = style.Dimension;
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

// util (upstream `pub use crate::util::*`)
pub const maybeMin = util.maybeMin;
pub const maybeMax = util.maybeMax;
pub const maybeClamp = util.maybeClamp;
pub const maybeAdd = util.maybeAdd;
pub const maybeSub = util.maybeSub;
pub const maybeResolve = util.maybeResolve;
pub const resolveOrZero = util.resolveOrZero;

// compute (upstream `pub use crate::compute::{...}`)
pub const computeBlockAlignContentOffset = compute.computeBlockAlignContentOffset;
pub const computeBlockLayout = compute.computeBlockLayout;
pub const computeCachedLayout = compute.computeCachedLayout;
pub const computeFlexboxLayout = compute.computeFlexboxLayout;
pub const computeGridLayout = compute.computeGridLayout;
pub const computeHiddenLayout = compute.computeHiddenLayout;
pub const computeLeafLayout = compute.computeLeafLayout;
pub const computeOofLayout = compute.computeOofLayout;
pub const computeOofLayoutForArea = compute.computeOofLayoutForArea;
pub const computeRootLayout = compute.computeRootLayout;
pub const resolveStaticOffset = compute.resolveStaticOffset;
pub const roundLayout = compute.roundLayout;
pub const OofLayoutResult = compute.OofLayoutResult;
pub const BlockContext = compute.BlockContext;
pub const BlockFormattingContext = compute.BlockFormattingContext;
pub const FloatMark = compute.FloatMark;
pub const BfcSlot = compute.BfcSlot;
pub const ContentSlot = compute.ContentSlot;
pub const FloatContext = compute.FloatContext;
pub const FloatIntrinsicWidthCalculator = compute.FloatIntrinsicWidthCalculator;
pub const detailed_info = compute.detailed_info;
pub const DetailedGridInfo = compute.detailed_info.DetailedGridInfo;
pub const DetailedGridItemsInfo = compute.detailed_info.DetailedGridItemsInfo;
pub const DetailedGridTracksInfo = compute.detailed_info.DetailedGridTracksInfo;
pub const GridLineNames = compute.detailed_info.GridLineNames;
pub const GridLineNamesIter = compute.detailed_info.GridLineNamesIter;

// tree (upstream `pub use crate::tree::*` and `pub use crate::tree::traits::*`)
pub const traits = tree.traits;
pub const Cache = tree.Cache;
pub const ClearState = tree.ClearState;
pub const AxisStaticAlign = tree.AxisStaticAlign;
pub const AxisStaticEdge = tree.AxisStaticEdge;
pub const AxisStaticPosition = tree.AxisStaticPosition;
pub const Baselines = tree.Baselines;
pub const CollapsibleMarginSet = tree.CollapsibleMarginSet;
pub const DetailedLayoutInfo = tree.DetailedLayoutInfo;
pub const Layout = tree.Layout;
pub const LayoutError = tree.LayoutError;
pub const LayoutInput = tree.LayoutInput;
pub const LayoutOutput = tree.LayoutOutput;
pub const OofCandidate = tree.OofCandidate;
pub const OofPositioningArea = tree.OofPositioningArea;
pub const RequestedAxis = tree.RequestedAxis;
pub const RunMode = tree.RunMode;
pub const ScrollableOverflow = tree.ScrollableOverflow;
pub const SizingMode = tree.SizingMode;
pub const NodeId = tree.NodeId;
pub const TaffyTree = tree.TaffyTree;
pub const TaffyError = tree.TaffyError;
pub const LeafMeasurer = tree.LeafMeasurer;
pub const ZeroMeasure = tree.ZeroMeasure;
pub const measureChildSize = traits.measureChildSize;
pub const measureChildSizeBoth = traits.measureChildSizeBoth;
pub const performChildLayout = traits.performChildLayout;

// util (upstream `pub use crate::util::print_tree` / `write_tree`)
pub const Scratch = util.Scratch;
pub const printTree = util.printTree;
pub const writeTree = util.writeTree;

// style_helpers (upstream prelude)
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
    _ = tree;
    _ = compute;
    _ = c_api;
    _ = @import("compute/grid/types/coordinates.zig");
}
