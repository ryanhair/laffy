//! A typed representation of [CSS style properties](https://css-tricks.com/snippets/css/a-guide-to-flexbox/). Used as input to layout computation.
//!
//! Layout algorithms read a node's style as a `*const Style` and use its fields directly.
const std = @import("std");
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Rect = geometry.Rect;
const Size = geometry.Size;
const Line = geometry.Line;
const AbsoluteAxis = geometry.AbsoluteAxis;
const AbstractAxis = geometry.AbstractAxis;

pub const alignment = @import("style/alignment.zig");
pub const available_space = @import("style/available_space.zig");
pub const compact_length = @import("style/compact_length.zig");
pub const dimension = @import("style/dimension.zig");
pub const block = @import("style/block.zig");
pub const flex = @import("style/flex.zig");
pub const float = @import("style/float.zig");
pub const grid = @import("style/grid.zig");

pub const AlignContent = alignment.AlignContent;
pub const AlignContentKeyword = alignment.AlignContentKeyword;
pub const AlignItems = alignment.AlignItems;
pub const AlignItemsKeyword = alignment.AlignItemsKeyword;
pub const AlignSelf = alignment.AlignSelf;
pub const AlignmentSafety = alignment.AlignmentSafety;
pub const JustifyContent = alignment.JustifyContent;
pub const JustifyItems = alignment.JustifyItems;
pub const JustifySelf = alignment.JustifySelf;
pub const AvailableSpace = available_space.AvailableSpace;
pub const CompactLength = compact_length.CompactLength;
pub const CalcHandle = compact_length.CalcHandle;
pub const NoCalc = compact_length.NoCalc;
pub const ConstCalc = compact_length.ConstCalc;
pub const Dimension = dimension.Dimension;
pub const LengthPercentage = dimension.LengthPercentage;
pub const LengthPercentageAuto = dimension.LengthPercentageAuto;
pub const TextAlign = block.TextAlign;
pub const FlexDirection = flex.FlexDirection;
pub const FlexWrap = flex.FlexWrap;
pub const Clear = float.Clear;
pub const Float = float.Float;
pub const FloatDirection = float.FloatDirection;
pub const GenericGridPlacement = grid.GenericGridPlacement;
pub const GenericGridTemplateComponent = grid.GenericGridTemplateComponent;
pub const GridAutoFlow = grid.GridAutoFlow;
pub const GridAutoTracks = grid.GridAutoTracks;
pub const GridPlacement = grid.GridPlacement;
pub const GridTemplateComponent = grid.GridTemplateComponent;
pub const GridTemplateRepetition = grid.GridTemplateRepetition;
pub const GridTemplateTracks = grid.GridTemplateTracks;
pub const MaxTrackSizingFunction = grid.MaxTrackSizingFunction;
pub const MinTrackSizingFunction = grid.MinTrackSizingFunction;
pub const RepetitionCount = grid.RepetitionCount;
pub const TrackSizingFunction = grid.TrackSizingFunction;
pub const GridAreaAxis = grid.GridAreaAxis;
pub const GridAreaEnd = grid.GridAreaEnd;
pub const GridTemplateArea = grid.GridTemplateArea;
pub const GridTemplateAreas = grid.GridTemplateAreas;
pub const NamedGridLine = grid.NamedGridLine;
pub const NonNamedGridPlacement = grid.NonNamedGridPlacement;
pub const OriginZeroGridPlacement = grid.OriginZeroGridPlacement;

/// Sets the layout used for the children of this node
///
/// The default is `flex` (upstream's default with all features enabled).
pub const Display = enum(u8) {
    /// The children will follow the block layout algorithm
    block,
    /// The children will follow the block layout algorithm and establish a new block formatting context
    flow_root,
    /// The children will follow the flexbox layout algorithm
    flex,
    /// The children will follow the CSS Grid layout algorithm
    grid,
    /// The node is hidden, and it's children will also be hidden
    none,

    /// The default Display mode
    pub const default: Display = .flex;

    /// Upstream `core::fmt::Display`
    pub fn format(self: Display, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(switch (self) {
            .none => "NONE",
            .block => "BLOCK",
            .flow_root => "FLOW-ROOT",
            .flex => "FLEX",
            .grid => "GRID",
        });
    }
};

/// An abstracted version of the CSS `display` property where any value other than "none" is represented by "normal"
/// See: <https://www.w3.org/TR/css-display-3/#box-generation>
pub const BoxGenerationMode = enum(u8) {
    /// The node generates a box in the regular way
    normal,
    /// The node and it's descendants generate no boxes (they are hidden)
    none,

    /// The default of BoxGenerationMode
    pub const default: BoxGenerationMode = .normal;
};

/// The positioning strategy for this item.
///
/// This controls both how the origin is determined for the `Style.position` field,
/// and whether or not the item will be controlled by flexbox's layout algorithm.
///
/// WARNING: this enum follows the behavior of [CSS's `position` property](https://developer.mozilla.org/en-US/docs/Web/CSS/position),
/// which can be unintuitive.
///
/// `Position.static` is the default value, matching the default behavior in CSS.
pub const Position = enum(u8) {
    /// The item is laid out in normal flow. `inset` has no effect on statically positioned items,
    /// and they do not act as a containing block for absolutely positioned descendants.
    static,
    /// The item is laid out in normal flow, then the `inset` offset is applied as a correction factor.
    /// Offsets do not affect the position of any other items.
    /// Relatively positioned items act as a containing block for absolutely positioned descendants.
    relative,
    /// The item is taken out of normal flow and positioned relative to its closest positioned ancestor
    /// (its containing block), if any. Otherwise, it is placed relative to the root.
    /// No space is created for the item in the page layout, and its size will not be altered.
    ///
    /// WARNING: to opt-out of layouting entirely, you must use `Display.none` instead on your `Style` object.
    absolute,
    /// The item is taken out of normal flow and positioned relative to the root (viewport),
    /// unless an ancestor overrides containing-block behavior (e.g. via transforms in a full CSS implementation).
    fixed,
    /// The item is laid out in normal flow exactly like a statically positioned item: `inset` is *not* applied
    /// as an offset (in CSS, sticky insets are scroll thresholds, which laffy has no knowledge of; applying the
    /// sticky offset is the responsibility of the caller once it knows the scroll position).
    /// Like `relative`, a sticky item acts as a containing block for absolutely positioned descendants.
    sticky,

    /// The default value
    pub const default: Position = .static;

    /// Returns true if this position takes the item out of normal flow (`absolute` or `fixed`)
    pub fn isOutOfFlow(self: Position) bool {
        return self == .absolute or self == .fixed;
    }

    /// Returns true if this position causes the item to act as a containing block
    /// for absolutely positioned descendants (any value other than `static`)
    pub fn isPositioned(self: Position) bool {
        return self != .static;
    }
};

/// Which out-of-flow positions a node establishes a containing block for.
///
/// Returned by `Style.isContainingBlock`.
pub const ContainingBlockClaims = struct {
    /// Whether the node is the containing block for `position: absolute` boxes
    absolute: bool,
    /// Whether the node is the containing block for `position: fixed` boxes
    fixed: bool,

    /// Claims nothing
    pub const none: ContainingBlockClaims = .{ .absolute = false, .fixed = false };
    /// Claims every out-of-flow box (the initial containing block)
    pub const all: ContainingBlockClaims = .{ .absolute = true, .fixed = true };

    /// Whether the node is the containing block for a box with the given `position`
    pub fn forPosition(self: ContainingBlockClaims, position: Position) bool {
        return switch (position) {
            .absolute => self.absolute,
            .fixed => self.fixed,
            else => false,
        };
    }
};

/// Specifies whether size styles for this node are assigned to the node's "content box" or "border box"
///
/// - The "content box" is the node's inner size excluding padding, border and margin
/// - The "border box" is the node's outer size including padding and border (but still excluding margin)
///
/// This property modifies the application of the following styles:
///
///   - `size`
///   - `min_size`
///   - `max_size`
///   - `flex_basis`
///
/// See <https://developer.mozilla.org/en-US/docs/Web/CSS/box-sizing>
pub const BoxSizing = enum(u8) {
    /// Size styles such size, min_size, max_size specify the box's "border box" (the size excluding margin but including padding/border)
    border_box,
    /// Size styles such size, min_size, max_size specify the box's "content box" (the size excluding padding/border/margin)
    content_box,

    /// The default value
    pub const default: BoxSizing = .border_box;
};

/// How children overflowing their container should affect layout
///
/// In CSS the primary effect of this property is to control whether contents of a parent container that overflow that container should
/// be displayed anyway, be clipped, or trigger the container to become a scroll container. However it also has secondary effects on layout,
/// the main ones being:
///
///   - The automatic minimum size Flexbox/CSS Grid items with non-`visible` overflow is `0` rather than being content based
///   - `Overflow.scroll` nodes have space in the layout reserved for a scrollbar (width controlled by the `scrollbar_width` property)
///
/// In laffy, we only implement the layout related secondary effects as we are not concerned with drawing/painting. The amount of space reserved for
/// a scrollbar is controlled by the `scrollbar_width` property. If this is `0` then `scroll` behaves identically to `hidden`.
///
/// <https://developer.mozilla.org/en-US/docs/Web/CSS/overflow>
pub const Overflow = enum(u8) {
    /// The automatic minimum size of this node as a flexbox/grid item should be based on the size of its content.
    /// Content that overflows this node *should* contribute to the scroll region of its parent.
    visible,
    /// The automatic minimum size of this node as a flexbox/grid item should be based on the size of its content.
    /// Content that overflows this node should *not* contribute to the scroll region of its parent.
    clip,
    /// The automatic minimum size of this node as a flexbox/grid item should be `0`.
    /// Content that overflows this node should *not* contribute to the scroll region of its parent.
    hidden,
    /// The automatic minimum size of this node as a flexbox/grid item should be `0`. Additionally, space should be reserved
    /// for a scrollbar. The amount of space reserved is controlled by the `scrollbar_width` property.
    /// Content that overflows this node should *not* contribute to the scroll region of its parent.
    scroll,

    /// The default value
    pub const default: Overflow = .visible;

    /// Returns true for overflow modes that contain their contents (`hidden`, `scroll`)
    /// or else false for overflow modes that allow their contains to spill (`visible`, `clip`).
    pub fn isScrollContainer(self: Overflow) bool {
        return switch (self) {
            .visible, .clip => false,
            .hidden, .scroll => true,
        };
    }

    /// Returns `0.0` if the overflow mode would cause the automatic minimum size of a Flexbox or CSS Grid item
    /// to be `0`. Else returns null.
    pub fn maybeIntoAutomaticMinSize(self: Overflow) ?f32 {
        return if (self.isScrollContainer()) 0.0 else null;
    }
};

/// The layout-affecting parts of the CSS `contain` property.
///
/// Containment limits the ways in which a box's contents can affect layout outside of the box
/// (and vice versa). laffy implements the layout-relevant containment types:
///
///   - `Contain.layout`: the box establishes an independent formatting context, and is treated
///     as having no baseline for baseline-alignment purposes (layout containment).
///   - `Contain.paint`: the box establishes an independent formatting context. Paint
///     containment's other effects (clipping, containing absolutely-positioned descendants,
///     stacking context) are outside of laffy's scope.
///
/// The `style` containment type has no effect on layout and is therefore not represented.
/// Size and inline-size containment are not currently implemented.
///
/// <https://developer.mozilla.org/en-US/docs/Web/CSS/contain>
pub const Contain = packed struct(u8) {
    inner: u8,

    /// No containment (the default)
    pub const none: Contain = .{ .inner = 0 };
    /// Layout containment: the box establishes an independent formatting context and is treated
    /// as having no baseline for baseline-alignment purposes.
    /// <https://drafts.csswg.org/css-contain-2/#containment-layout>
    pub const layout: Contain = .{ .inner = 1 << 0 };
    /// Paint containment: the box establishes an independent formatting context. Its other
    /// effects don't affect layout.
    /// <https://drafts.csswg.org/css-contain-2/#containment-paint>
    pub const paint: Contain = .{ .inner = 1 << 1 };
    /// The containment implied by `contain: content` (`layout paint`, ignoring style containment)
    pub const content: Contain = .{ .inner = layout.inner | paint.inner };

    /// The default containment (no containment)
    pub const default: Contain = none;

    /// Returns whether `self` contains all of the containment types in `other`
    pub fn contains(self: Contain, other: Contain) bool {
        return self.inner & other.inner == other.inner;
    }

    /// Returns whether `self` contains any of the containment types in `other`
    pub fn intersects(self: Contain, other: Contain) bool {
        return self.inner & other.inner != 0;
    }

    /// Returns the union of the containment types in `self` and `other` (also upstream `BitOr`)
    pub fn @"union"(self: Contain, other: Contain) Contain {
        return .{ .inner = self.inner | other.inner };
    }

    /// Whether this containment causes the box to establish an independent formatting context
    /// (both layout and paint containment do)
    pub fn establishesIndependentFormattingContext(self: Contain) bool {
        return self.intersects(layout.@"union"(paint));
    }

    /// Whether this containment suppresses the box's baseline for baseline-alignment purposes
    /// (layout containment does, paint containment does not)
    pub fn suppressesBaseline(self: Contain) bool {
        return self.contains(layout);
    }

    /// Whether this containment prevents the box's overflowing content from contributing to an
    /// ancestor's scrollable overflow region (layout containment treats such overflow as ink
    /// overflow; paint containment clips it)
    pub fn containsScrollableOverflow(self: Contain) bool {
        return self.intersects(layout.@"union"(paint));
    }
};

/// Sets the direction of text, table and grid columns, and horizontal overflow.
/// <https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/Properties/direction>
pub const Direction = enum(u8) {
    /// Left-to-right
    ltr,
    /// Right-to-left
    rtl,

    /// The default value
    pub const default: Direction = .ltr;

    /// Returns true if the direction is right-to-left
    pub fn isRtl(self: Direction) bool {
        return self == .rtl;
    }
};

/// A typed representation of the CSS style information for a single node.
///
/// The most important idea in flexbox is the notion of a "main" and "cross" axis, which are always perpendicular to each other.
/// The orientation of these axes are controlled via the `FlexDirection` field of this struct.
///
/// This struct follows the [CSS equivalent](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_Flexible_Box_Layout/Basic_Concepts_of_Flexbox) directly;
/// information about the behavior on the web should transfer directly.
///
/// Detailed information about the exact behavior of each of these fields
/// can be found on [MDN](https://developer.mozilla.org/en-US/docs/Web/CSS) by searching for the field name.
/// The distinction between margin, padding and border is explained well in
/// this [introduction to the box model](https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_Box_Model/Introduction_to_the_CSS_box_model).
///
/// `Style` is a plain copyable value. Every field has its default value, so `.{}` (or
/// `Style.default`) is the default style.
///
/// Ownership: the grid fields hold borrowed slices (`grid_template_rows`, `grid_template_columns`,
/// `grid_auto_rows`, `grid_auto_columns`, `grid_template_areas`, `grid_template_column_names`,
/// `grid_template_row_names`, and the line/area names inside them and inside `grid_row` /
/// `grid_column`). The style never owns or frees that memory: the caller must keep it alive (and
/// unchanged) for as long as the style is used. The defaults are empty slices.
pub const Style = struct {
    /// What layout strategy should be used?
    display: Display = .flex,
    /// Whether a child is display:table or not. This affects children of block layouts.
    /// This should really be part of `Display`, but it is currently seperate because table layout isn't implemented
    item_is_table: bool = false,
    /// Is it a replaced element like an image or video? Implies `isCompressibleReplaced`.
    /// <https://html.spec.whatwg.org/multipage/rendering.html#replaced-elements>
    item_is_replaced: bool = false,
    /// Is it a compressible replaced element that is not a replaced element (a form control with
    /// an intrinsic size)? <https://drafts.csswg.org/css-sizing-3/#compressible>
    item_is_compressible_replaced: bool = false,
    /// Should size styles apply to the content box or the border box of the node
    box_sizing: BoxSizing = .border_box,
    /// Sets the direction of text, table and grid columns, and horizontal overflow.
    direction: Direction = .ltr,

    // Overflow properties
    /// How children overflowing their container should affect layout
    overflow: Point(Overflow) = .{ .x = .visible, .y = .visible },
    /// How much space (in points) should be reserved for the scrollbars of `Overflow.scroll` nodes.
    scrollbar_width: f32 = 0.0,
    /// The layout-affecting parts of the CSS `contain` property
    contain: Contain = Contain.none,

    /// Should the box be floated
    float: Float = .none,
    /// Should the box clear floats
    clear: Clear = .none,

    // Position properties
    /// What should the `position` value of this struct use as a base offset?
    position: Position = .static,
    /// How should the position of this element be tweaked relative to the layout defined?
    inset: Rect(LengthPercentageAuto) = Rect(LengthPercentageAuto).auto,

    // Size properties
    /// Sets the initial size of the item
    size: Size(Dimension) = Size(Dimension).auto,
    /// Controls the minimum size of the item
    min_size: Size(LengthPercentageAuto) = Size(LengthPercentageAuto).auto,
    /// Controls the maximum size of the item
    max_size: Size(LengthPercentageAuto) = Size(LengthPercentageAuto).auto,
    /// Sets the preferred aspect ratio for the item
    ///
    /// The ratio is calculated as width divided by height.
    aspect_ratio: ?f32 = null,

    // Spacing Properties
    /// How large should the margin be on each side?
    margin: Rect(LengthPercentageAuto) = Rect(LengthPercentageAuto).zero,
    /// How large should the padding be on each side?
    padding: Rect(LengthPercentage) = Rect(LengthPercentage).zero,
    /// How large should the border be on each side?
    border: Rect(LengthPercentage) = Rect(LengthPercentage).zero,

    // Alignment properties
    /// How this node's children aligned in the cross/block axis?
    align_items: AlignItems = AlignItems.normal,
    /// How this node should be aligned in the cross/block axis
    /// Falls back to the parents `AlignItems` if not set
    align_self: ?AlignSelf = null,
    /// How this node's children should be aligned in the inline axis
    justify_items: AlignItems = AlignItems.normal,
    /// How this node should be aligned in the inline axis
    /// Falls back to the parents `JustifyItems` if not set
    justify_self: ?AlignSelf = null,
    /// How should content contained within this item be aligned in the cross/block axis
    align_content: AlignContent = AlignContent.normal,
    /// How should content contained within this item be aligned in the main/inline axis
    justify_content: JustifyContent = JustifyContent.normal,
    /// How large should the gaps between items in a grid or flex container be?
    gap: Size(LengthPercentage) = Size(LengthPercentage).zero,

    // Block container properties
    /// How items elements should aligned in the inline axis
    text_align: TextAlign = .auto,

    // Flexbox container properties
    /// Which direction does the main axis flow in?
    flex_direction: FlexDirection = .row,
    /// Should elements wrap, or stay in a single line?
    flex_wrap: FlexWrap = .no_wrap,
    /// The minimum number of flex lines requested for a multi-line container. When items are
    /// balanced (`FlexWrap.balance` or `FlexWrap.balance_reverse`) they are balanced into
    /// at least this many lines. For any multi-line container, definite cross-axis available
    /// space for measuring items is divided between this many lines.
    ///
    /// 1 is the default value, and this value must be at least 1.
    flex_line_count: u16 = 1,

    // Flexbox item properties
    /// Sets the initial main axis size of the item
    flex_basis: Dimension = .auto,
    /// The relative rate at which this item grows when it is expanding to fill space
    ///
    /// 0.0 is the default value, and this value must be positive.
    flex_grow: f32 = 0.0,
    /// The relative rate at which this item shrinks when it is contracting to fit into space
    ///
    /// 1.0 is the default value, and this value must be positive.
    flex_shrink: f32 = 1.0,

    // Grid container properies
    /// Defines the track sizing functions (heights) of the grid rows (borrowed)
    grid_template_rows: []const GridTemplateComponent = &.{},
    /// Defines the track sizing functions (widths) of the grid columns (borrowed)
    grid_template_columns: []const GridTemplateComponent = &.{},
    /// Defines the size of implicitly created rows (borrowed)
    grid_auto_rows: []const TrackSizingFunction = &.{},
    /// Defined the size of implicitly created columns (borrowed)
    grid_auto_columns: []const TrackSizingFunction = &.{},
    /// Controls how items get placed into the grid for auto-placed items
    grid_auto_flow: GridAutoFlow = .row,

    // Grid container named properties
    /// Defines the rectangular grid areas (borrowed)
    grid_template_areas: ?GridTemplateAreas = null,
    /// The named lines between the columns: one set of names per line (borrowed)
    grid_template_column_names: []const []const []const u8 = &.{},
    /// The named lines between the rows: one set of names per line (borrowed)
    grid_template_row_names: []const []const []const u8 = &.{},

    // Grid child properties
    /// Defines which row in the grid the item should start and end at
    grid_row: Line(GridPlacement) = Line(GridPlacement).auto,
    /// Defines which column in the grid the item should start and end at
    grid_column: Line(GridPlacement) = Line(GridPlacement).auto,

    /// The default style (upstream `Style::DEFAULT`)
    pub const default: Style = .{};

    /// Whether the node generates a box (`display: none` does not)
    pub fn boxGenerationMode(self: *const Style) BoxGenerationMode {
        return switch (self.display) {
            .none => .none,
            else => .normal,
        };
    }

    /// Whether the node is a block container that takes part in its parent's block formatting
    /// context (true only for `display: block`, not `flow-root`)
    pub fn isBlock(self: *const Style) bool {
        return self.display == .block;
    }

    /// Whether the node is a replaced element that can be compressed below its natural size
    pub fn isCompressibleReplaced(self: *const Style) bool {
        return self.item_is_replaced or self.item_is_compressible_replaced;
    }

    /// Which out-of-flow boxes the node is the containing block for
    pub fn isContainingBlock(self: *const Style) ContainingBlockClaims {
        return .{ .absolute = self.position.isPositioned(), .fixed = false };
    }

    /// The node's grid placement in the passed axis
    pub fn gridPlacement(self: *const Style, axis: AbsoluteAxis) Line(GridPlacement) {
        return switch (axis) {
            .horizontal => self.grid_column,
            .vertical => self.grid_row,
        };
    }

    /// The named grid areas, if any
    pub fn gridTemplateAreas(self: *const Style) ?[]const GridTemplateArea {
        return if (self.grid_template_areas) |template| template.areas else null;
    }

    /// The number of rows spanned by the named grid areas
    pub fn gridTemplateAreaRowCount(self: *const Style) u16 {
        return if (self.grid_template_areas) |template| template.row_count else 0;
    }

    /// The number of columns spanned by the named grid areas
    pub fn gridTemplateAreaColumnCount(self: *const Style) u16 {
        return if (self.grid_template_areas) |template| template.column_count else 0;
    }

    /// The track template in the passed axis
    pub fn gridTemplateTracks(self: *const Style, axis: AbsoluteAxis) []const GridTemplateComponent {
        return switch (axis) {
            .horizontal => self.grid_template_columns,
            .vertical => self.grid_template_rows,
        };
    }

    /// A grid container's align-content or justify-content alignment depending on the axis
    /// passed (with `normal` resolved to `stretch`)
    pub fn gridAlignContent(self: *const Style, axis: AbstractAxis) AlignContent {
        const align_value = switch (axis) {
            .@"inline" => self.justify_content,
            .block => self.align_content,
        };
        return switch (align_value.keyword) {
            .normal => AlignContent.stretch,
            else => align_value,
        };
    }
};

const testing = std.testing;

test {
    _ = alignment;
    _ = available_space;
    _ = compact_length;
    _ = dimension;
    _ = block;
    _ = flex;
    _ = float;
    _ = grid;
}

test "defaults match" {
    const old_defaults: Style = .{
        .display = Display.default,
        .item_is_table = false,
        .item_is_replaced = false,
        .item_is_compressible_replaced = false,
        .box_sizing = BoxSizing.default,
        .float = Float.default,
        .clear = Clear.default,
        .direction = Direction.default,
        .overflow = .{ .x = Overflow.default, .y = Overflow.default },
        .scrollbar_width = 0.0,
        .contain = Contain.default,
        .position = Position.default,
        .flex_direction = FlexDirection.default,
        .flex_wrap = FlexWrap.default,
        .flex_line_count = 1,
        .align_items = AlignItems.default,
        .align_self = null,
        .justify_items = AlignItems.default,
        .justify_self = null,
        .align_content = AlignContent.default,
        .justify_content = JustifyContent.default,
        .inset = Rect(LengthPercentageAuto).auto,
        .margin = Rect(LengthPercentageAuto).zero,
        .padding = Rect(LengthPercentage).zero,
        .border = Rect(LengthPercentage).zero,
        .gap = Size(LengthPercentage).zero,
        .text_align = TextAlign.default,
        .flex_grow = 0.0,
        .flex_shrink = 1.0,
        .flex_basis = .auto,
        .size = Size(Dimension).auto,
        .min_size = Size(LengthPercentageAuto).auto,
        .max_size = Size(LengthPercentageAuto).auto,
        .aspect_ratio = null,
        .grid_template_rows = &.{},
        .grid_template_columns = &.{},
        .grid_template_row_names = &.{},
        .grid_template_column_names = &.{},
        .grid_template_areas = null,
        .grid_auto_rows = &.{},
        .grid_auto_columns = &.{},
        .grid_auto_flow = GridAutoFlow.default,
        .grid_row = .{ .start = .auto, .end = .auto },
        .grid_column = .{ .start = .auto, .end = .auto },
    };
    try testing.expectEqualDeep(Style.default, Style{});
    try testing.expectEqualDeep(Style.default, old_defaults);
    try testing.expectEqual(Display.flex, Style.default.display);
}

// Checked in every build, so that a change that grows one of these types cannot go unnoticed
comptime {
    // Display and Position
    std.debug.assert(@sizeOf(Display) == 1);
    std.debug.assert(@sizeOf(BoxSizing) == 1);
    std.debug.assert(@sizeOf(Position) == 1);
    std.debug.assert(@sizeOf(Overflow) == 1);

    // Dimensions and aggregations of Dimensions
    std.debug.assert(@sizeOf(f32) == 4);
    std.debug.assert(@sizeOf(LengthPercentage) == 8);
    std.debug.assert(@sizeOf(LengthPercentageAuto) == 8);
    std.debug.assert(@sizeOf(Dimension) == 8);
    std.debug.assert(@sizeOf(Size(LengthPercentage)) == 16);
    std.debug.assert(@sizeOf(Size(LengthPercentageAuto)) == 16);
    std.debug.assert(@sizeOf(Size(Dimension)) == 16);
    std.debug.assert(@sizeOf(Rect(LengthPercentage)) == 32);
    std.debug.assert(@sizeOf(Rect(LengthPercentageAuto)) == 32);
    std.debug.assert(@sizeOf(Rect(Dimension)) == 32);

    // Alignment
    std.debug.assert(@sizeOf(AlignContentKeyword) == 1);
    std.debug.assert(@sizeOf(AlignItemsKeyword) == 1);
    std.debug.assert(@sizeOf(AlignmentSafety) == 1);
    std.debug.assert(@sizeOf(AlignContent) == 2);
    std.debug.assert(@sizeOf(AlignItems) == 2);

    // Flexbox Container
    std.debug.assert(@sizeOf(FlexDirection) == 1);
    std.debug.assert(@sizeOf(FlexWrap) == 1);

    // CSS Grid Container
    std.debug.assert(@sizeOf(GridAutoFlow) == 1);
    std.debug.assert(@sizeOf(MinTrackSizingFunction) == 8);
    std.debug.assert(@sizeOf(MaxTrackSizingFunction) == 8);
    std.debug.assert(@sizeOf(TrackSizingFunction) == 16);
}

test "enums and helpers" {
    try testing.expect(Position.absolute.isOutOfFlow());
    try testing.expect(Position.fixed.isOutOfFlow());
    try testing.expect(!Position.sticky.isOutOfFlow());
    try testing.expect(Position.sticky.isPositioned());
    try testing.expect(!Position.static.isPositioned());
    try testing.expect(ContainingBlockClaims.all.forPosition(.fixed));
    try testing.expect(!ContainingBlockClaims.none.forPosition(.absolute));
    try testing.expect(!ContainingBlockClaims.all.forPosition(.relative));
    try testing.expect(Overflow.hidden.isScrollContainer());
    try testing.expect(!Overflow.clip.isScrollContainer());
    try testing.expectEqual(@as(?f32, 0.0), Overflow.scroll.maybeIntoAutomaticMinSize());
    try testing.expectEqual(@as(?f32, null), Overflow.visible.maybeIntoAutomaticMinSize());
    try testing.expect(Direction.rtl.isRtl());
    try testing.expect(!Direction.ltr.isRtl());

    try testing.expect(Contain.content == Contain.layout.@"union"(Contain.paint));
    try testing.expect(Contain.content.contains(Contain.layout));
    try testing.expect(!Contain.paint.contains(Contain.layout));
    try testing.expect(Contain.paint.intersects(Contain.content));
    try testing.expect(Contain.paint.establishesIndependentFormattingContext());
    try testing.expect(!Contain.none.establishesIndependentFormattingContext());
    try testing.expect(Contain.layout.suppressesBaseline());
    try testing.expect(!Contain.paint.suppressesBaseline());
    try testing.expect(Contain.paint.containsScrollableOverflow());

    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("FLOW-ROOT", try std.fmt.bufPrint(&buf, "{f}", .{Display.flow_root}));
    try testing.expectEqualStrings("NONE", try std.fmt.bufPrint(&buf, "{f}", .{Display.none}));
}

/// Checks the default value of every style field
fn expectDefaultAccessors(s: anytype) !void {
    // CoreStyle
    try testing.expectEqual(BoxGenerationMode.normal, s.boxGenerationMode());
    try testing.expect(!s.isBlock());
    try testing.expect(!s.isCompressibleReplaced());
    try testing.expect(!s.item_is_replaced);
    try testing.expectEqual(BoxSizing.border_box, s.box_sizing);
    try testing.expectEqual(Direction.ltr, s.direction);
    try testing.expectEqual(Point(Overflow){ .x = .visible, .y = .visible }, s.overflow);
    try testing.expectEqual(@as(f32, 0.0), s.scrollbar_width);
    try testing.expectEqual(Position.static, s.position);
    try testing.expectEqual(Rect(LengthPercentageAuto).auto, s.inset);
    try testing.expectEqual(ContainingBlockClaims{ .absolute = false, .fixed = false }, s.isContainingBlock());
    try testing.expectEqual(Size(Dimension).auto, s.size);
    try testing.expectEqual(Size(LengthPercentageAuto).auto, s.min_size);
    try testing.expectEqual(Size(LengthPercentageAuto).auto, s.max_size);
    try testing.expectEqual(@as(?f32, null), s.aspect_ratio);
    try testing.expectEqual(Rect(LengthPercentageAuto).zero, s.margin);
    try testing.expectEqual(Rect(LengthPercentage).zero, s.padding);
    try testing.expectEqual(Rect(LengthPercentage).zero, s.border);
    try testing.expect(s.contain == Contain.none);
    // OofItemStyle / BlockItemStyle / FlexboxItemStyle / GridItemStyle
    try testing.expectEqual(@as(?AlignSelf, null), s.align_self);
    try testing.expectEqual(@as(?AlignSelf, null), s.justify_self);
    try testing.expect(!s.item_is_table);
    try testing.expectEqual(Line(GridPlacement).auto, s.grid_row);
    try testing.expectEqual(Line(GridPlacement).auto, s.grid_column);
    try testing.expectEqual(Line(GridPlacement).auto, s.gridPlacement(.horizontal));
    try testing.expectEqual(Float.none, s.float);
    try testing.expectEqual(Clear.none, s.clear);
    // FlexboxContainerStyle
    try testing.expectEqual(FlexDirection.row, s.flex_direction);
    try testing.expectEqual(FlexWrap.no_wrap, s.flex_wrap);
    try testing.expectEqual(@as(u16, 1), s.flex_line_count);
    try testing.expectEqual(Size(LengthPercentage).zero, s.gap);
    try testing.expect(s.align_content == AlignContent.normal);
    try testing.expect(s.align_items == AlignItems.normal);
    try testing.expect(s.justify_content == JustifyContent.normal);
    // FlexboxItemStyle
    try testing.expect(s.flex_basis == .auto);
    try testing.expectEqual(@as(f32, 0.0), s.flex_grow);
    try testing.expectEqual(@as(f32, 1.0), s.flex_shrink);
    // GridContainerStyle
    try testing.expectEqual(@as(usize, 0), s.grid_template_rows.len);
    try testing.expectEqual(@as(usize, 0), s.grid_template_columns.len);
    try testing.expectEqual(@as(usize, 0), s.grid_auto_rows.len);
    try testing.expectEqual(@as(usize, 0), s.grid_auto_columns.len);
    try testing.expectEqual(@as(?[]const GridTemplateArea, null), s.gridTemplateAreas());
    try testing.expectEqual(@as(u16, 0), s.gridTemplateAreaRowCount());
    try testing.expectEqual(@as(u16, 0), s.gridTemplateAreaColumnCount());
    try testing.expectEqual(@as(usize, 0), s.grid_template_column_names.len);
    try testing.expectEqual(@as(usize, 0), s.grid_template_row_names.len);
    try testing.expectEqual(GridAutoFlow.row, s.grid_auto_flow);
    try testing.expect(s.justify_items == AlignItems.normal);
    try testing.expectEqual(@as(usize, 0), s.gridTemplateTracks(.vertical).len);
    try testing.expect(s.gridAlignContent(.@"inline") == AlignContent.stretch);
    try testing.expect(s.gridAlignContent(.block) == AlignContent.stretch);
    // BlockContainerStyle
    try testing.expectEqual(TextAlign.auto, s.text_align);
}

test "Style field defaults" {
    const s: Style = .{};
    try expectDefaultAccessors(s);
    try expectDefaultAccessors(&s);
}

test "Style helpers read fields" {
    const rows = [_]GridTemplateComponent{GridTemplateComponent.auto};
    const cols = [_]GridTemplateComponent{ GridTemplateComponent.auto, GridTemplateComponent.zero };
    const areas = [_]GridTemplateArea{.{ .name = "a", .row_start = 1, .row_end = 2, .column_start = 1, .column_end = 2 }};
    const s: Style = .{
        .display = .block,
        .position = .relative,
        .item_is_compressible_replaced = true,
        .grid_template_rows = &rows,
        .grid_template_columns = &cols,
        .grid_template_areas = .{ .areas = &areas, .row_count = 5, .column_count = 6 },
        .grid_row = Line(GridPlacement).fromLineIndex(2),
        .justify_content = JustifyContent.center,
        .align_content = AlignContent.end,
    };
    try testing.expect(s.isBlock());
    try testing.expect(s.isCompressibleReplaced());
    try testing.expect(!s.item_is_replaced);
    try testing.expectEqual(ContainingBlockClaims{ .absolute = true, .fixed = false }, s.isContainingBlock());
    try testing.expectEqual(@as(usize, 2), s.gridTemplateTracks(.horizontal).len);
    try testing.expectEqual(@as(usize, 1), s.gridTemplateTracks(.vertical).len);
    try testing.expectEqual(@as(u16, 5), s.gridTemplateAreaRowCount());
    try testing.expectEqual(@as(u16, 6), s.gridTemplateAreaColumnCount());
    try testing.expectEqual(@as(usize, 1), s.gridTemplateAreas().?.len);
    try testing.expect(s.gridPlacement(.vertical).start.eql(.{ .line = .{ .inner = 2 } }));
    try testing.expect(s.gridAlignContent(.@"inline") == AlignContent.center);
    try testing.expect(s.gridAlignContent(.block) == AlignContent.end);
    const hidden: Style = .{ .display = .none };
    try testing.expectEqual(BoxGenerationMode.none, hidden.boxGenerationMode());
}
