//! Contains both a high-level interface to laffy using a ready-made node tree, and a set of interfaces for defining custom node trees.
//!
//! - For documentation on the high-level API, see the `TaffyTree` struct.
//! - For documentation on the low-level interface-based API, see the `traits` module.
pub const cache = @import("tree/cache.zig");
pub const layout = @import("tree/layout.zig");
pub const node = @import("tree/node.zig");
pub const traits = @import("tree/traits.zig");
pub const taffy_tree = @import("tree/taffy_tree.zig");

pub const Cache = cache.Cache;
pub const ClearState = cache.ClearState;

pub const AxisStaticAlign = layout.AxisStaticAlign;
pub const AxisStaticEdge = layout.AxisStaticEdge;
pub const AxisStaticPosition = layout.AxisStaticPosition;
pub const Baselines = layout.Baselines;
pub const CollapsibleMarginSet = layout.CollapsibleMarginSet;
pub const DetailedLayoutInfo = layout.DetailedLayoutInfo;
pub const Layout = layout.Layout;
pub const LayoutError = layout.LayoutError;
pub const LayoutInput = layout.LayoutInput;
pub const LayoutOutput = layout.LayoutOutput;
pub const OofCandidate = layout.OofCandidate;
pub const OofPositioningArea = layout.OofPositioningArea;
pub const RequestedAxis = layout.RequestedAxis;
pub const RunMode = layout.RunMode;
pub const ScrollableOverflow = layout.ScrollableOverflow;
pub const SizingMode = layout.SizingMode;

pub const NodeId = node.NodeId;

pub const TaffyTree = taffy_tree.TaffyTree;
pub const TaffyError = taffy_tree.TaffyError;
pub const LeafMeasurer = taffy_tree.LeafMeasurer;
pub const ZeroMeasure = taffy_tree.ZeroMeasure;

test {
    _ = cache;
    _ = layout;
    _ = node;
    _ = traits;
    _ = taffy_tree;
}
