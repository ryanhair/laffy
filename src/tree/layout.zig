//! Final data structures that represent the high-level UI layout
//!
//! # Errors
//!
//! Layout can only fail by running out of memory. `LayoutError` is the error set of every function
//! in the layout call graph (`computeChildLayout`, the algorithms, the cache and the out-of-flow
//! pass). It is declared explicitly everywhere, because layout recurses through generic functions
//! and Zig cannot infer error sets across that recursion.
//!
//! # Ownership of out-of-flow candidates
//!
//! `LayoutOutput.oof_candidates` is a heap list (empty, and allocation-free, in the common case).
//! All candidate lists are allocated with the tree's allocator (`tree.allocator()`). A
//! `LayoutOutput` owns its list: whoever receives a `LayoutOutput` (for example from
//! `computeChildLayout`) must either move the candidates elsewhere (`OofCandidates.append` /
//! `OofCandidates.take`) or call `LayoutOutput.deinit`. Outputs of `RunMode.compute_size` runs never
//! carry candidates, so dropping them without `deinit` is harmless, but calling `deinit` is always
//! correct.
const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("../geometry.zig");
const AbsoluteAxis = geometry.AbsoluteAxis;
const Line = geometry.Line;
const Point = geometry.Point;
const Rect = geometry.Rect;
const Size = geometry.Size;
const style = @import("../style.zig");
const AlignItemsKeyword = style.AlignItemsKeyword;
const AlignSelf = style.AlignSelf;
const AlignmentSafety = style.AlignmentSafety;
const AvailableSpace = style.AvailableSpace;
const Position = style.Position;
const NodeId = @import("node.zig").NodeId;
const sys = @import("../util/sys.zig");

/// The error set of every function in the layout call graph. Layout can only fail by running out
/// of memory.
pub const LayoutError = error{OutOfMemory};

/// Scrollable overflow and the physical directions in which scrolling starts at the end edge.
///
/// The rectangle uses physical x/y coordinates relative to the client area's top-left edge.
/// To obtain border-box coordinates, add `border.left`/`border.top`, plus the horizontal
/// scrollbar gutter in RTL (where the vertical scrollbar is on the left). RTL does not mirror
/// these coordinates. For a scroll container, unreachable overflow is clipped: on normal axes
/// the start is zero, while on reversed axes the end is at most the client extent.
/// Non-scroll containers retain all overflow, for propagation and hit testing, and have no flags.
///
/// Rectangles contain `(0, 0)`: left/top are non-positive and right/bottom non-negative.
/// Algorithms accumulate ordinary rectangles from `Rect(f32).zero` and pack them only at output.
/// The sign bits of the stored right/bottom encode reversal, including when an extent is zero.
/// Always use `rect()` before doing geometry with this value.
pub const ScrollableOverflow = struct {
    /// The packed rectangle (upstream tuple field `.0`)
    inner: Rect(f32),

    /// Empty overflow with normal scroll origins.
    pub const zero: ScrollableOverflow = .{ .inner = Rect(f32).zero };

    /// Pack an origin-containing rectangle and its physical scroll-origin directions.
    pub fn new(rect_: Rect(f32), reversed: Point(bool)) ScrollableOverflow {
        std.debug.assert(rect_.left <= 0.0 and rect_.top <= 0.0 and rect_.right >= 0.0 and rect_.bottom >= 0.0);
        return .{ .inner = .{
            .left = rect_.left,
            .right = sys.copysign(rect_.right, if (reversed.x) -1.0 else 1.0),
            .top = rect_.top,
            .bottom = sys.copysign(rect_.bottom, if (reversed.y) -1.0 else 1.0),
        } };
    }

    /// The physical overflow rectangle, with the packed signs restored.
    pub fn rect(self: ScrollableOverflow) Rect(f32) {
        return .{
            .left = self.inner.left,
            .right = @abs(self.inner.right),
            .top = self.inner.top,
            .bottom = @abs(self.inner.bottom),
        };
    }

    /// The physical left overflow edge.
    pub fn left(self: ScrollableOverflow) f32 {
        return self.inner.left;
    }

    /// The physical right overflow edge, with its sign restored.
    pub fn right(self: ScrollableOverflow) f32 {
        return @abs(self.inner.right);
    }

    /// The physical top overflow edge.
    pub fn top(self: ScrollableOverflow) f32 {
        return self.inner.top;
    }

    /// The physical bottom overflow edge, with its sign restored.
    pub fn bottom(self: ScrollableOverflow) f32 {
        return @abs(self.inner.bottom);
    }

    /// Whether the physical x/y scroll origins are at the right/bottom edges.
    pub fn isReversed(self: ScrollableOverflow) Point(bool) {
        return .{ .x = std.math.signbit(self.inner.right), .y = std.math.signbit(self.inner.bottom) };
    }

    /// Swap the physical axes, preserving origin directions and signed zeroes.
    pub fn transpose(self: ScrollableOverflow) ScrollableOverflow {
        return .{ .inner = self.inner.transpose() };
    }

    /// Bitwise equality of the packed values (upstream `PartialEq`)
    pub fn eql(self: ScrollableOverflow, other: ScrollableOverflow) bool {
        const a = self.inner;
        const b = other.inner;
        return @as(u32, @bitCast(a.left)) == @as(u32, @bitCast(b.left)) and
            @as(u32, @bitCast(a.right)) == @as(u32, @bitCast(b.right)) and
            @as(u32, @bitCast(a.top)) == @as(u32, @bitCast(b.top)) and
            @as(u32, @bitCast(a.bottom)) == @as(u32, @bitCast(b.bottom));
    }
};

/// Whether we are performing a full layout, or we merely need to size the node
pub const RunMode = enum(u8) {
    /// A full layout for this node and all children should be computed
    perform_layout,
    /// The layout algorithm should be executed such that an accurate container size for the node can be determined.
    /// Layout steps that aren't necessary for determining the container size of the current node can be skipped.
    compute_size,
    /// This node should have a null layout set as it has been hidden (i.e. using `Display.none`)
    perform_hidden_layout,
};

/// Whether styles should be taken into account when computing size
pub const SizingMode = enum(u8) {
    /// Only content contributions should be taken into account
    content_size,
    /// Inherent size styles should be taken into account in addition to content contributions
    inherent_size,
};

/// A set of margins that are available for collapsing with for block layout's margin collapsing
pub const CollapsibleMarginSet = struct {
    /// The largest positive margin
    positive: f32,
    /// The smallest negative margin (with largest absolute value)
    negative: f32,

    /// A default margin set with no collapsible margins
    pub const zero: CollapsibleMarginSet = .{ .positive = 0.0, .negative = 0.0 };

    /// Create a set from a single margin
    pub fn fromMargin(margin: f32) CollapsibleMarginSet {
        if (margin >= 0.0) {
            return .{ .positive = margin, .negative = 0.0 };
        } else {
            return .{ .positive = 0.0, .negative = margin };
        }
    }

    /// Collapse a single margin with this set
    pub fn collapseWithMargin(self: CollapsibleMarginSet, margin: f32) CollapsibleMarginSet {
        var result = self;
        if (margin >= 0.0) {
            result.positive = @max(result.positive, margin);
        } else {
            result.negative = @min(result.negative, margin);
        }
        return result;
    }

    /// Collapse another margin set with this set
    pub fn collapseWithSet(self: CollapsibleMarginSet, other: CollapsibleMarginSet) CollapsibleMarginSet {
        var result = self;
        result.positive = @max(result.positive, other.positive);
        result.negative = @min(result.negative, other.negative);
        return result;
    }

    /// Resolve the resultant margin from this set once all collapsible margins
    /// have been collapsed into it
    pub fn resolve(self: CollapsibleMarginSet) f32 {
        return self.positive + self.negative;
    }

    /// Equality (upstream derived `PartialEq`)
    pub fn eql(self: CollapsibleMarginSet, other: CollapsibleMarginSet) bool {
        return self.positive == other.positive and self.negative == other.negative;
    }
};

/// An axis that layout algorithms can be requested to compute a size for
pub const RequestedAxis = enum(u8) {
    /// The horizontal axis
    horizontal,
    /// The vertical axis
    vertical,
    /// Both axes
    both,

    /// Swap the horizontal and vertical axes (`both` is unchanged)
    pub fn transpose(self: RequestedAxis) RequestedAxis {
        return switch (self) {
            .horizontal => .vertical,
            .vertical => .horizontal,
            .both => .both,
        };
    }

    /// Upstream `From<AbsoluteAxis> for RequestedAxis`
    pub fn fromAbsoluteAxis(value: AbsoluteAxis) RequestedAxis {
        return switch (value) {
            .horizontal => .horizontal,
            .vertical => .vertical,
        };
    }

    /// Upstream `TryFrom<RequestedAxis> for AbsoluteAxis`: `null` for `both`
    pub fn toAbsoluteAxis(self: RequestedAxis) ?AbsoluteAxis {
        return switch (self) {
            .horizontal => .horizontal,
            .vertical => .vertical,
            .both => null,
        };
    }
};

/// A struct containing the inputs constraints/hints for laying out a node, which are passed in by the parent
pub const LayoutInput = struct {
    /// Whether we only need to know the Node's size, or whether we need to perform a full layout
    run_mode: RunMode,
    /// Whether a Node's style sizes should be taken into account or ignored
    sizing_mode: SizingMode,
    /// Which axis we need the size of
    axis: RequestedAxis,

    /// Known dimensions represent dimensions (width/height) which should be taken as fixed when performing layout.
    /// For example, if known_dimensions.width is set to WIDTH then this means something like:
    ///
    ///    "What would the height of this node be, assuming the width is WIDTH"
    ///
    /// Layout functions will be called with both known_dimensions set for final layout. Where the meaning is:
    ///
    ///   "The exact size of this node is WIDTHxHEIGHT. Please lay out your children"
    ///
    known_dimensions: Size(?f32),
    /// Whether each known dimension should be treated as a *definite* size when laying out the node's
    /// own content (resolving percentage sizes of children, and collecting flex items into flex lines).
    ///
    /// This should be set to `false` for a dimension when a parent imposes a known dimension on a node
    /// that is derived from the node's own content, and is therefore indefinite per CSS. For example,
    /// the post-flexing main size of a flex item is indefinite if the flex container's main size is
    /// indefinite and the item's used flex basis is not definite
    /// (see <https://www.w3.org/TR/css-flexbox-1/#definite-sizes>).
    ///
    /// This flag is ignored (treated as `true`) for axes where the corresponding known dimension is `null`.
    known_dimensions_are_definite: Size(bool),
    /// Parent size dimensions are intended to be used for percentage resolution.
    parent_size: Size(?f32),
    /// Available space represents an amount of space to layout into, and is used as a soft constraint
    /// for the purpose of wrapping.
    ///
    /// A definite available space is the space available to the node's border box: the parent
    /// subtracts the node's margins before passing it, and the node must not subtract them again.
    available_space: Size(AvailableSpace),
    /// Specific to CSS Block layout. Used for correctly computing margin collapsing. You probably want to set this to `Line(bool).false`.
    vertical_margins_are_collapsible: Line(bool),

    /// A LayoutInput that can be used to request hidden layout
    pub const hidden: LayoutInput = .{
        // The important property for hidden layout
        .run_mode = .perform_hidden_layout,
        // The rest will be ignored
        .known_dimensions = Size(?f32).none,
        .known_dimensions_are_definite = .{ .width = true, .height = true },
        .parent_size = Size(?f32).none,
        .available_space = Size(AvailableSpace).max_content,
        .sizing_mode = .inherent_size,
        .axis = .both,
        .vertical_margins_are_collapsible = Line(bool).false,
    };

    /// Swap the horizontal and vertical axes of every per-axis input.
    ///
    /// Lets a tree lay out a node in a vertical writing mode: transpose the inputs, run the
    /// (horizontal-tb) algorithm, then transpose the `LayoutOutput` back.
    /// `vertical_margins_are_collapsible` is reset to `Line(bool).false` as margins cannot collapse
    /// across a change of block axis.
    pub fn transpose(self: LayoutInput) LayoutInput {
        return .{
            .run_mode = self.run_mode,
            .sizing_mode = self.sizing_mode,
            .axis = self.axis.transpose(),
            .known_dimensions = self.known_dimensions.transpose(),
            .known_dimensions_are_definite = self.known_dimensions_are_definite.transpose(),
            .parent_size = self.parent_size.transpose(),
            .available_space = self.available_space.transpose(),
            .vertical_margins_are_collapsible = Line(bool).false,
        };
    }

    /// Equality (upstream derived `PartialEq`)
    pub fn eql(self: LayoutInput, other: LayoutInput) bool {
        return self.run_mode == other.run_mode and
            self.sizing_mode == other.sizing_mode and
            self.axis == other.axis and
            std.meta.eql(self.known_dimensions, other.known_dimensions) and
            std.meta.eql(self.known_dimensions_are_definite, other.known_dimensions_are_definite) and
            std.meta.eql(self.parent_size, other.parent_size) and
            self.available_space.width.eql(other.available_space.width) and
            self.available_space.height.eql(other.available_space.height) and
            std.meta.eql(self.vertical_margins_are_collapsible, other.vertical_margins_are_collapsible);
    }
};

/// The first and last baselines of a node in the horizontal axis (i.e. baselines for horizontal text,
/// measured as an offset from the top edge of the node's border box).
///
/// A baseline is the line on which text sits. See <https://www.w3.org/TR/css-writing-modes-3/#intro-baselines>
/// for details.
pub const Baselines = struct {
    /// The first baseline of the node, if any
    first: ?f32,
    /// The last baseline of the node, if any
    last: ?f32,

    /// A `Baselines` with neither a first nor a last baseline
    pub const none: Baselines = .{ .first = null, .last = null };

    /// Create a `Baselines` from just a first baseline
    pub fn fromFirst(first: ?f32) Baselines {
        return .{ .first = first, .last = null };
    }
};

/// The physical alignment of an out-of-flow box's margin box within its static-position
/// area (per-axis).
///
/// The static position of an out-of-flow box may depend on alignment properties
/// (`justify-content`/`align-self` in flexbox, `justify-self`/`align-self` in grid) which cannot
/// be fully resolved until the box's final size is known. To defer that resolution, the static
/// position is recorded as an *area* plus the physical alignment keyword to apply to the box's
/// margin box within that area.
pub const AxisStaticEdge = enum(u8) {
    /// Align the start (left/top) edge of the box's margin box to the start of the area
    start,
    /// Center the box within the area
    center,
    /// Align the end (right/bottom) edge of the box's margin box to the end of the area
    end,
};

/// The alignment to apply to an out-of-flow box's margin box within its static-position area
/// in a single axis.
///
/// Keywords are physical: container-specific semantics (`justify-content`/`align-self`
/// resolution, flex-direction/wrap-reverse reversal, RTL flipping, `self-start`/`self-end`)
/// are resolved by the emitting layout algorithm.
pub const AxisStaticAlign = struct {
    /// The physical alignment keyword
    keyword: AxisStaticEdge,
    /// The `safe` overflow-position keyword from CSS Box Alignment: when `safe`, the
    /// `fallback` keyword is used instead if the box's margin box overflows the area
    safety: AlignmentSafety,
    /// The physical alignment keyword to fall back to when `safety` is `safe` and the box's
    /// margin box overflows the area
    fallback: AxisStaticEdge,

    /// Create a `AxisStaticAlign` from a keyword with no safe fallback
    pub fn fromKeyword(keyword: AxisStaticEdge) AxisStaticAlign {
        return .{ .keyword = keyword, .safety = .default, .fallback = keyword };
    }
};

/// The static position of an out-of-flow box in a single axis: the alignment container
/// (start/end coordinates) plus the alignment to apply to the box's margin box within it.
///
/// Area coordinates are initially relative to the border box of the node which produced the
/// candidate and are translated by each node's location as the candidate bubbles up the tree, so
/// they are always relative to the border box of the node currently holding the candidate.
///
/// Emitters which have no alignment area in an axis (e.g. block layout, where the static
/// position is a point) emit a degenerate area (`start == end`).
pub const AxisStaticPosition = struct {
    /// The alignment container in this axis
    area: Line(f32),
    /// The alignment to apply to the box's margin box within `area`
    @"align": AxisStaticAlign,

    /// Create a `AxisStaticPosition` with a degenerate (zero-extent) area at `anchor` and no
    /// safe fallback
    pub fn fromEdge(anchor: f32, edge: AxisStaticEdge) AxisStaticPosition {
        return .{ .area = .{ .start = anchor, .end = anchor }, .@"align" = AxisStaticAlign.fromKeyword(edge) };
    }

    /// Create a `AxisStaticPosition` which aligns the box within `area` according to its
    /// self-alignment property in this axis (`justify-self` in the inline axis, `align-self` in
    /// the block axis). `normal` and `stretch` behave as `start`. This is the static position
    /// used by block and inline layout.
    ///
    /// `alignment` must already be resolved: `auto` (`null`) replaced by the container's
    /// `justify-items`/`align-items`, and `self-start`/`self-end` resolved against the
    /// container's direction (see `AlignSelf.resolveSelfRelative`).
    /// `axis_is_rtl` is whether this axis is the inline axis of a right-to-left static-position
    /// containing block, in which case `start` and `end` are flipped.
    pub fn fromAlignment(alignment: AlignSelf, area: Line(f32), axis_is_rtl: bool) AxisStaticPosition {
        // self-start/self-end must be resolved before computing the static position
        std.debug.assert(alignment.keyword != .self_start and alignment.keyword != .self_end);
        const fallback: AlignItemsKeyword = if (alignment.safety == .safe) .start else alignment.keyword;
        return .{
            .area = area,
            .@"align" = .{
                .keyword = edgeFor(alignment.keyword, axis_is_rtl),
                .safety = alignment.safety,
                .fallback = edgeFor(fallback, axis_is_rtl),
            },
        };
    }

    /// The edge of the static-position rectangle that a (resolved) alignment keyword
    /// aligns the box to. Normal and Stretch (and anything else that is not an end or
    /// center alignment) fall back to start-alignment for static-position purposes.
    fn edgeFor(keyword: AlignItemsKeyword, axis_is_rtl: bool) AxisStaticEdge {
        const start_position = (!(keyword == .end or keyword == .flex_end)) != axis_is_rtl;
        return switch (keyword) {
            .center => .center,
            else => if (start_position) .start else .end,
        };
    }
};

/// A record of an out-of-flow (`position: absolute` or `position: fixed`) box which has not yet
/// been laid out because its containing block is an ancestor of its parent.
///
/// Candidates are produced by the layout algorithm of the box's parent (which computes the static
/// position) and bubble up through `LayoutOutput` until they reach a node which acts as the box's
/// containing block, which lays the box out.
pub const OofCandidate = struct {
    /// The id of the out-of-flow node
    node: NodeId,
    /// The `order` value that the node's layout should be assigned (its child index within its parent)
    order: u32,
    /// The position style of the node (`Position.absolute` or `Position.fixed`)
    position: Position,
    /// The static position of the box in each axis
    static_position: Point(AxisStaticPosition),
};

/// A list of `OofCandidate`s.
///
/// This is a lazily-allocated heap list (an empty list performs no allocation). Every method that
/// can allocate or free takes the allocator the list was allocated with (the tree's allocator).
pub const OofCandidates = struct {
    /// Backing storage for the candidates
    inner: std.ArrayList(OofCandidate) = .empty,

    /// An empty list of candidates
    pub const none: OofCandidates = .{};

    /// Free the list's memory
    pub fn deinit(self: *OofCandidates, gpa: Allocator) void {
        self.inner.deinit(gpa);
        self.* = none;
    }

    /// Whether the list contains no candidates
    pub fn isEmpty(self: *const OofCandidates) bool {
        return self.inner.items.len == 0;
    }

    /// The candidates as a slice
    pub fn asSlice(self: *const OofCandidates) []const OofCandidate {
        return self.inner.items;
    }

    /// The candidates as a mutable slice
    pub fn asMutSlice(self: *OofCandidates) []OofCandidate {
        return self.inner.items;
    }

    /// Append a candidate to the list
    pub fn push(self: *OofCandidates, gpa: Allocator, candidate: OofCandidate) LayoutError!void {
        try self.inner.append(gpa, candidate);
    }

    /// Move all candidates from `other` into `self`, leaving `other` empty
    pub fn append(self: *OofCandidates, gpa: Allocator, other: *OofCandidates) LayoutError!void {
        if (other.isEmpty()) return;
        if (self.inner.capacity == 0) {
            self.inner = other.inner;
            other.* = none;
        } else {
            try self.inner.appendSlice(gpa, other.inner.items);
            other.deinit(gpa);
        }
    }

    /// Take the candidates out of this list, leaving it empty
    pub fn take(self: *OofCandidates) OofCandidates {
        const result = self.*;
        self.* = none;
        return result;
    }

    /// Remove all candidates from the list (and free its memory)
    pub fn clear(self: *OofCandidates, gpa: Allocator) void {
        self.deinit(gpa);
    }

    /// A deep copy of the list (upstream `Clone`). Copying an empty list does not allocate.
    pub fn clone(self: *const OofCandidates, gpa: Allocator) LayoutError!OofCandidates {
        if (self.isEmpty()) return none;
        return .{ .inner = try self.inner.clone(gpa) };
    }

    /// Translate the static-position areas of every candidate in the list by `offset`.
    ///
    /// This is used to convert areas from being relative to a child node's border box to being
    /// relative to the parent node's border box as candidates bubble up the tree.
    pub fn translate(self: *OofCandidates, offset: Point(f32)) void {
        for (self.asMutSlice()) |*candidate| {
            candidate.static_position.x.area.start += offset.x;
            candidate.static_position.x.area.end += offset.x;
            candidate.static_position.y.area.start += offset.y;
            candidate.static_position.y.area.end += offset.y;
        }
    }

    /// Element-wise equality (upstream derived `PartialEq`)
    pub fn eql(self: *const OofCandidates, other: *const OofCandidates) bool {
        if (self.inner.items.len != other.inner.items.len) return false;
        for (self.inner.items, other.inner.items) |a, b| {
            if (!std.meta.eql(a, b)) return false;
        }
        return true;
    }
};

/// The area of a container against which the insets of its out-of-flow (absolute/fixed) boxes
/// are resolved: the container's border box minus its borders and scrollbar gutters.
///
/// Container layout algorithms record this on `LayoutOutput` (for `RunMode.perform_layout` runs)
/// so that the out-of-flow positioning pass (`computeOofLayout`) can run after the algorithm has
/// finished. When the container is a grid, per-box grid areas are resolved within this area by the
/// positioning pass itself (from the container's detailed grid info).
pub const OofPositioningArea = struct {
    /// The size of the area
    size: Size(f32),
    /// The offset of the area from the container's border box origin
    offset: Point(f32),
};

/// A struct containing the result of laying a single node, which is returned up to the parent node
///
/// A baseline is the line on which text sits. Your node likely has a baseline if it is a text node, or contains
/// children that may be text nodes. See <https://www.w3.org/TR/css-writing-modes-3/#intro-baselines> for details.
/// If your node does not have a baseline (or you are unsure how to compute it), then simply return `Baselines.none`
/// for the baselines field
///
/// A `LayoutOutput` owns its `oof_candidates` list; see the module documentation.
pub const LayoutOutput = struct {
    /// The size of the node
    size: Size(f32),
    /// The scrollable overflow rectangle of the node's content
    /// (see `Layout.scrollable_overflow_rect` for the coordinate conventions)
    scrollable_overflow_rect: ScrollableOverflow,
    /// The first and last baselines of the node in the horizontal axis, if any
    baselines: Baselines,
    /// Top margin that can be collapsed with. This is used for CSS block layout and can be set to
    /// `CollapsibleMarginSet.zero` for other layout modes that don't support margin collapsing
    top_margin: CollapsibleMarginSet,
    /// Bottom margin that can be collapsed with. This is used for CSS block layout and can be set to
    /// `CollapsibleMarginSet.zero` for other layout modes that don't support margin collapsing
    bottom_margin: CollapsibleMarginSet,
    /// Whether margins can be collapsed through this node. This is used for CSS block layout and can
    /// be set to `false` for other layout modes that don't support margin collapsing
    margins_can_collapse_through: bool,
    /// Out-of-flow (absolute/fixed) descendants of this node for which this node is *not* the
    /// containing block. These bubble up the tree until they reach their containing block, which
    /// lays them out. Empty (allocation-free) when there are no such descendants (the common case).
    ///
    /// Candidates are only produced by `RunMode.perform_layout` passes.
    ///
    /// Container layout algorithms place the *full* document-ordered candidate list here (direct
    /// out-of-flow children plus candidates bubbled from in-flow children). The out-of-flow
    /// positioning pass (`computeOofLayout`) then lays out those for which the node is the
    /// containing block and replaces this list with the unclaimed remainder.
    oof_candidates: OofCandidates,
    /// The node's inset-resolution area for out-of-flow boxes. Set by container layout
    /// algorithms for `RunMode.perform_layout` runs; `null` for leaves and size-only runs
    /// (in which case the out-of-flow positioning pass is a no-op).
    oof_positioning_area: ?OofPositioningArea,

    /// An all-zero `LayoutOutput` for hidden nodes
    pub const hidden: LayoutOutput = .{
        .size = Size(f32).zero,
        .scrollable_overflow_rect = ScrollableOverflow.zero,
        .baselines = Baselines.none,
        .top_margin = CollapsibleMarginSet.zero,
        .bottom_margin = CollapsibleMarginSet.zero,
        .margins_can_collapse_through = false,
        .oof_candidates = OofCandidates.none,
        .oof_positioning_area = null,
    };

    /// Constructor to create a `LayoutOutput` from just the size, scrollable overflow rectangle and baselines
    pub fn fromSizesAndBaselines(
        size: Size(f32),
        scrollable_overflow_rect: ScrollableOverflow,
        baselines: Baselines,
    ) LayoutOutput {
        return .{
            .size = size,
            .scrollable_overflow_rect = scrollable_overflow_rect,
            .baselines = baselines,
            .top_margin = CollapsibleMarginSet.zero,
            .bottom_margin = CollapsibleMarginSet.zero,
            .margins_can_collapse_through = false,
            .oof_candidates = OofCandidates.none,
            .oof_positioning_area = null,
        };
    }

    /// Construct a `LayoutOutput` from just the container size and scrollable overflow rectangle
    pub fn fromSizes(size: Size(f32), scrollable_overflow_rect: ScrollableOverflow) LayoutOutput {
        return fromSizesAndBaselines(size, scrollable_overflow_rect, Baselines.none);
    }

    /// Swap the horizontal and vertical axes of the output (inverse of `LayoutInput.transpose`).
    ///
    /// Baselines and collapsible margins are block-axis quantities that have no meaning on the
    /// parent's inline axis, so they are dropped. Out-of-flow candidates are unaffected (and are
    /// moved into the result).
    pub fn transpose(self: LayoutOutput) LayoutOutput {
        return .{
            .size = self.size.transpose(),
            .scrollable_overflow_rect = self.scrollable_overflow_rect.transpose(),
            .baselines = Baselines.none,
            .top_margin = CollapsibleMarginSet.zero,
            .bottom_margin = CollapsibleMarginSet.zero,
            .margins_can_collapse_through = false,
            .oof_candidates = self.oof_candidates,
            .oof_positioning_area = if (self.oof_positioning_area) |area|
                .{ .size = area.size.transpose(), .offset = area.offset.transpose() }
            else
                null,
        };
    }

    /// Construct a `LayoutOutput` from just the container's size.
    pub fn fromOuterSize(size: Size(f32)) LayoutOutput {
        return fromSizes(size, ScrollableOverflow.zero);
    }

    /// Free the output's out-of-flow candidate list
    pub fn deinit(self: *LayoutOutput, gpa: Allocator) void {
        self.oof_candidates.deinit(gpa);
    }

    /// A deep copy of the output (upstream `Clone`). Does not allocate when there are no candidates.
    pub fn clone(self: *const LayoutOutput, gpa: Allocator) LayoutError!LayoutOutput {
        var result = self.*;
        result.oof_candidates = try self.oof_candidates.clone(gpa);
        return result;
    }

    /// Equality (upstream derived `PartialEq`)
    pub fn eql(self: *const LayoutOutput, other: *const LayoutOutput) bool {
        return std.meta.eql(self.size, other.size) and
            self.scrollable_overflow_rect.eql(other.scrollable_overflow_rect) and
            std.meta.eql(self.baselines, other.baselines) and
            self.top_margin.eql(other.top_margin) and
            self.bottom_margin.eql(other.bottom_margin) and
            self.margins_can_collapse_through == other.margins_can_collapse_through and
            self.oof_candidates.eql(&other.oof_candidates) and
            std.meta.eql(self.oof_positioning_area, other.oof_positioning_area);
    }
};

/// The final result of a layout algorithm for a single node.
pub const Layout = struct {
    /// The relative ordering of the node
    ///
    /// Nodes with a higher order should be rendered on top of those with a lower order.
    /// This is effectively a topological sort of each tree.
    order: u32 = 0,
    /// The top-left corner of the node
    location: Point(f32) = Point(f32).zero,
    /// The width and height of the node
    size: Size(f32) = Size(f32).zero,
    /// The scrollable overflow rectangle of the node: the axis-aligned rectangle containing the
    /// content of the node (the border boxes of its descendants plus their non-clipped overflow),
    /// corresponding to the CSS "scrollable overflow rectangle"
    /// (<https://www.w3.org/TR/css-overflow-3/#scrollable>), except that transforms are not
    /// accounted for.
    ///
    /// See `ScrollableOverflow` for physical coordinates and reversed-origin flags.
    /// A normal axis has range `0..scrollWidth()` (or `scrollHeight()`); a reversed axis
    /// has range `-scrollWidth()..0` (or `-scrollHeight()..0`). The initial offset is zero.
    scrollable_overflow_rect: ScrollableOverflow = ScrollableOverflow.zero,
    /// The size of the scrollbars in each dimension. If there is no scrollbar then the size will be zero.
    scrollbar_size: Size(f32) = Size(f32).zero,
    /// The size of the borders of the node
    border: Rect(f32) = Rect(f32).zero,
    /// The size of the padding of the node
    padding: Rect(f32) = Rect(f32).zero,
    /// The size of the margin of the node
    margin: Rect(f32) = Rect(f32).zero,

    /// Creates a new zero-`Layout` with the supplied `order` value.
    ///
    /// Nodes with a higher order should be rendered on top of those with a lower order.
    /// The Zero-layout has size and location set to ZERO.
    pub fn withOrder(order: u32) Layout {
        return .{ .order = order };
    }

    /// Get the width of the node's content box
    pub fn contentBoxWidth(self: Layout) f32 {
        return self.size.width - self.padding.left - self.padding.right - self.border.left - self.border.right;
    }

    /// Get the height of the node's content box
    pub fn contentBoxHeight(self: Layout) f32 {
        return self.size.height - self.padding.top - self.padding.bottom - self.border.top - self.border.bottom;
    }

    /// Get the size of the node's content box
    pub fn contentBoxSize(self: Layout) Size(f32) {
        return .{ .width = self.contentBoxWidth(), .height = self.contentBoxHeight() };
    }

    /// Get x offset of the node's content box relative to it's parent's border box
    pub fn contentBoxX(self: Layout) f32 {
        return self.location.x + self.border.left + self.padding.left;
    }

    /// Get y offset of the node's content box relative to it's parent's border box
    pub fn contentBoxY(self: Layout) f32 {
        return self.location.y + self.border.top + self.padding.top;
    }

    /// Return the magnitude of the reachable horizontal scroll range.
    /// This is the reachable extent of the content less the width of the padding box, floored at zero.
    pub fn scrollWidth(self: Layout) f32 {
        if (self.scrollable_overflow_rect.isReversed().x) {
            return -self.scrollable_overflow_rect.left();
        }
        return @max(
            0.0,
            self.scrollable_overflow_rect.right() + @min(self.scrollbar_size.width, self.size.width) -
                self.size.width +
                self.border.left +
                self.border.right,
        );
    }

    /// Return the magnitude of the reachable vertical scroll range.
    /// This is the reachable extent of the content less the height of the padding box, floored at zero.
    pub fn scrollHeight(self: Layout) f32 {
        if (self.scrollable_overflow_rect.isReversed().y) {
            return -self.scrollable_overflow_rect.top();
        }
        return @max(
            0.0,
            self.scrollable_overflow_rect.bottom() + @min(self.scrollbar_size.height, self.size.height) -
                self.size.height +
                self.border.top +
                self.border.bottom,
        );
    }

    /// Equality (upstream derived `PartialEq`)
    pub fn eql(self: Layout, other: Layout) bool {
        return self.order == other.order and
            std.meta.eql(self.location, other.location) and
            std.meta.eql(self.size, other.size) and
            self.scrollable_overflow_rect.eql(other.scrollable_overflow_rect) and
            std.meta.eql(self.scrollbar_size, other.scrollbar_size) and
            std.meta.eql(self.border, other.border) and
            std.meta.eql(self.padding, other.padding) and
            std.meta.eql(self.margin, other.margin);
    }
};

/// The additional information from layout algorithm
///
/// Upstream is generic over the custom identifier string type; laffy uses `[]const u8` names.
///
/// Ownership: the `grid` variant owns its boxed `DetailedGridInfo` (allocated with the tree's
/// allocator, see `LayoutGridContainer.setDetailedGridInfo` in `traits.zig`); free it with
/// `deinit`. The line and area names it holds are borrowed from the grid container's style.
pub const DetailedLayoutInfo = union(enum) {
    /// For node that hasn't had any detailed information yet
    none,
    /// Enum variant for `DetailedGridInfo`
    grid: *DetailedGridInfo,

    /// Free the info's memory (and reset it to `.none`)
    pub fn deinit(self: *DetailedLayoutInfo, gpa: Allocator) void {
        switch (self.*) {
            .none => {},
            .grid => |info| {
                info.deinit(gpa);
                gpa.destroy(info);
            },
        }
        self.* = .none;
    }
};

const DetailedGridInfo = @import("../compute/grid.zig").DetailedGridInfo;

// ---------------------------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn bits(value: f32) u32 {
    return @bitCast(value);
}

test "side accessors match restored rectangle" {
    const rects = [_]Rect(f32){
        Rect(f32).zero,
        .{ .left = -0.0, .top = -0.0, .right = 0.0, .bottom = 0.0 },
        .{ .left = -10.0, .top = -20.0, .right = 30.0, .bottom = 40.0 },
    };
    for (rects) |r| {
        for ([_]bool{ false, true }) |x| {
            for ([_]bool{ false, true }) |y| {
                const overflow = ScrollableOverflow.new(r, .{ .x = x, .y = y });
                const restored = overflow.rect();
                try testing.expectEqual(bits(restored.left), bits(overflow.left()));
                try testing.expectEqual(bits(restored.right), bits(overflow.right()));
                try testing.expectEqual(bits(restored.top), bits(overflow.top()));
                try testing.expectEqual(bits(restored.bottom), bits(overflow.bottom()));
            }
        }
    }
}

test "packing preserves flags rectangles and signed zeroes" {
    for ([_]f32{ 0.0, 10.0 }) |right| {
        for ([_]f32{ 0.0, 20.0 }) |bottom| {
            for ([_]bool{ false, true }) |x| {
                for ([_]bool{ false, true }) |y| {
                    const r: Rect(f32) = .{ .left = -0.0, .right = right, .top = -0.0, .bottom = bottom };
                    const reversed: Point(bool) = .{ .x = x, .y = y };
                    const overflow = ScrollableOverflow.new(r, reversed);
                    try testing.expectEqual(bits(-0.0), bits(overflow.left()));
                    try testing.expectEqual(bits(-0.0), bits(overflow.top()));
                    try testing.expectEqual(bits(right), bits(overflow.right()));
                    try testing.expectEqual(bits(bottom), bits(overflow.bottom()));
                    try testing.expectEqual(reversed, overflow.isReversed());
                    try testing.expectEqual(x, std.math.signbit(overflow.inner.right));
                    try testing.expectEqual(y, std.math.signbit(overflow.inner.bottom));
                    try testing.expectEqual(Point(bool){ .x = y, .y = x }, overflow.transpose().isReversed());
                    try testing.expect(overflow.transpose().transpose().eql(overflow));
                }
            }
        }
    }
    try testing.expect(!ScrollableOverflow.zero.eql(ScrollableOverflow.new(Rect(f32).zero, .{ .x = true, .y = false })));
    var left_neg_zero = Rect(f32).zero;
    left_neg_zero.left = -0.0;
    try testing.expect(!ScrollableOverflow.zero.eql(ScrollableOverflow.new(left_neg_zero, .{ .x = false, .y = false })));
    var top_neg_zero = Rect(f32).zero;
    top_neg_zero.top = -0.0;
    try testing.expect(!ScrollableOverflow.zero.eql(ScrollableOverflow.new(top_neg_zero, .{ .x = false, .y = false })));
}

test "CollapsibleMarginSet" {
    const set = CollapsibleMarginSet.fromMargin(5.0).collapseWithMargin(-3.0).collapseWithMargin(10.0).collapseWithMargin(-7.0);
    try testing.expectEqual(@as(f32, 10.0), set.positive);
    try testing.expectEqual(@as(f32, -7.0), set.negative);
    try testing.expectEqual(@as(f32, 3.0), set.resolve());
    const other = CollapsibleMarginSet.fromMargin(-9.0);
    try testing.expectEqual(@as(f32, 1.0), set.collapseWithSet(other).resolve());
    try testing.expectEqual(@as(f32, 0.0), CollapsibleMarginSet.zero.resolve());
}

test "RequestedAxis conversions" {
    try testing.expectEqual(RequestedAxis.vertical, RequestedAxis.horizontal.transpose());
    try testing.expectEqual(RequestedAxis.both, RequestedAxis.both.transpose());
    try testing.expectEqual(RequestedAxis.vertical, RequestedAxis.fromAbsoluteAxis(.vertical));
    try testing.expectEqual(@as(?AbsoluteAxis, .horizontal), RequestedAxis.horizontal.toAbsoluteAxis());
    try testing.expectEqual(@as(?AbsoluteAxis, null), RequestedAxis.both.toAbsoluteAxis());
    // FlexDirection relies on the variant names
    try testing.expect(style.FlexDirection.row.mainAxisIsRequestedAxis(RequestedAxis.horizontal));
}

test "LayoutInput transpose" {
    const input: LayoutInput = .{
        .run_mode = .compute_size,
        .sizing_mode = .content_size,
        .axis = .horizontal,
        .known_dimensions = .{ .width = 1.0, .height = null },
        .known_dimensions_are_definite = .{ .width = false, .height = true },
        .parent_size = .{ .width = null, .height = 3.0 },
        .available_space = .{ .width = .min_content, .height = .{ .definite = 4.0 } },
        .vertical_margins_are_collapsible = Line(bool).true,
    };
    const t = input.transpose();
    try testing.expectEqual(RequestedAxis.vertical, t.axis);
    try testing.expectEqual(Size(?f32){ .width = null, .height = 1.0 }, t.known_dimensions);
    try testing.expectEqual(Size(bool){ .width = true, .height = false }, t.known_dimensions_are_definite);
    try testing.expectEqual(Size(?f32){ .width = 3.0, .height = null }, t.parent_size);
    try testing.expect(t.available_space.width.eql(.{ .definite = 4.0 }));
    try testing.expectEqual(Line(bool).false, t.vertical_margins_are_collapsible);
    try testing.expect(LayoutInput.hidden.eql(LayoutInput.hidden));
    try testing.expect(!input.eql(t));
}

test "AxisStaticPosition" {
    const area: Line(f32) = .{ .start = 0.0, .end = 10.0 };
    const a = AxisStaticPosition.fromAlignment(style.AlignItems.end, area, false);
    try testing.expectEqual(AxisStaticEdge.end, a.@"align".keyword);
    try testing.expectEqual(AxisStaticEdge.end, a.@"align".fallback);
    const b = AxisStaticPosition.fromAlignment(style.AlignItems.safe_end, area, true);
    try testing.expectEqual(AxisStaticEdge.start, b.@"align".keyword);
    try testing.expectEqual(AxisStaticEdge.end, b.@"align".fallback);
    const c = AxisStaticPosition.fromAlignment(style.AlignItems.stretch, area, false);
    try testing.expectEqual(AxisStaticEdge.start, c.@"align".keyword);
    const d = AxisStaticPosition.fromAlignment(style.AlignItems.center, area, true);
    try testing.expectEqual(AxisStaticEdge.center, d.@"align".keyword);
    const e = AxisStaticPosition.fromEdge(5.0, .end);
    try testing.expectEqual(Line(f32){ .start = 5.0, .end = 5.0 }, e.area);
    try testing.expectEqual(AlignmentSafety.default, e.@"align".safety);
}

test "OofCandidates ownership" {
    const gpa = testing.allocator;
    const candidate: OofCandidate = .{
        .node = NodeId.new(1),
        .order = 0,
        .position = .absolute,
        .static_position = .{ .x = AxisStaticPosition.fromEdge(1.0, .start), .y = AxisStaticPosition.fromEdge(2.0, .start) },
    };
    var a: OofCandidates = .none;
    try testing.expect(a.isEmpty());
    try a.push(gpa, candidate);
    var b: OofCandidates = .none;
    try b.append(gpa, &a);
    try testing.expect(a.isEmpty());
    try testing.expectEqual(@as(usize, 1), b.asSlice().len);
    var c = try b.clone(gpa);
    try testing.expect(c.eql(&b));
    c.translate(.{ .x = 10.0, .y = 20.0 });
    try testing.expectEqual(@as(f32, 11.0), c.asSlice()[0].static_position.x.area.start);
    try testing.expectEqual(@as(f32, 22.0), c.asSlice()[0].static_position.y.area.end);
    try b.append(gpa, &c);
    try testing.expectEqual(@as(usize, 2), b.asSlice().len);
    var taken = b.take();
    try testing.expect(b.isEmpty());
    taken.deinit(gpa);

    var output = LayoutOutput.fromOuterSize(.{ .width = 1.0, .height = 2.0 });
    try output.oof_candidates.push(gpa, candidate);
    var copy = try output.clone(gpa);
    try testing.expect(copy.eql(&output));
    var transposed = copy.transpose();
    try testing.expectEqual(Size(f32){ .width = 2.0, .height = 1.0 }, transposed.size);
    transposed.deinit(gpa);
    output.deinit(gpa);
}

test "Layout helpers" {
    var layout = Layout.withOrder(3);
    try testing.expectEqual(@as(u32, 3), layout.order);
    layout.size = .{ .width = 100.0, .height = 50.0 };
    layout.location = .{ .x = 5.0, .y = 6.0 };
    layout.padding = Rect(f32).new(1, 2, 3, 4);
    layout.border = Rect(f32).new(10, 20, 30, 40);
    try testing.expectEqual(@as(f32, 67.0), layout.contentBoxWidth());
    try testing.expectEqual(@as(f32, -27.0), layout.contentBoxHeight());
    try testing.expectEqual(Size(f32){ .width = 67.0, .height = -27.0 }, layout.contentBoxSize());
    try testing.expectEqual(@as(f32, 16.0), layout.contentBoxX());
    try testing.expectEqual(@as(f32, 39.0), layout.contentBoxY());

    var scroll: Layout = .{};
    scroll.size = .{ .width = 100.0, .height = 100.0 };
    scroll.scrollable_overflow_rect = ScrollableOverflow.new(.{ .left = -30.0, .right = 150.0, .top = 0.0, .bottom = 120.0 }, .{ .x = false, .y = false });
    try testing.expectEqual(@as(f32, 50.0), scroll.scrollWidth());
    try testing.expectEqual(@as(f32, 20.0), scroll.scrollHeight());
    scroll.scrollable_overflow_rect = ScrollableOverflow.new(.{ .left = -30.0, .right = 150.0, .top = 0.0, .bottom = 120.0 }, .{ .x = true, .y = false });
    try testing.expectEqual(@as(f32, 30.0), scroll.scrollWidth());
}

test "Baselines" {
    try testing.expectEqual(Baselines{ .first = 3.0, .last = null }, Baselines.fromFirst(3.0));
    try testing.expectEqual(Baselines{ .first = null, .last = null }, Baselines.none);
}
