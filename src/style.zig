//! A typed representation of [CSS style properties](https://css-tricks.com/snippets/css/a-guide-to-flexbox/). Used as input to layout computation.
//!
//! # Style accessor interfaces
//!
//! Upstream defines the traits `CoreStyle`, `OofItemStyle`, `FlexboxContainerStyle`,
//! `FlexboxItemStyle`, `GridContainerStyle`, `GridItemStyle`, `BlockContainerStyle` and
//! `BlockItemStyle`, which layout algorithms use to read styles. In laffy these are duck-typed
//! interfaces: layout algorithms take the style as `anytype` and call the methods listed below.
//! `Style` implements every method, so `Style` or `*const Style` can be passed directly.
//!
//! Method naming: Zig does not allow a method and a field with the same name, and `Style` has a
//! field for most properties. Every accessor is therefore named `get` + the upstream method name in
//! PascalCase (`size()` -> `getSize()`, `box_sizing()` -> `getBoxSizing()`), except predicates
//! whose upstream name starts with `is_`, which keep that name (`is_block()` -> `isBlock()`).
//!
//! A custom style type implements the methods of each interface it is used as. Methods marked
//! "default" have an upstream default implementation, which is available as a function taking
//! `self: anytype` in the matching `*Defaults` namespace below. A custom type can adopt a default
//! with a declaration, e.g. `pub const getBoxSizing = style.CoreStyleDefaults.getBoxSizing;`.
//! Methods marked "required" have no upstream default.
//!
//! ## CoreStyle (`CoreStyleDefaults`)
//!
//!   - `getBoxGenerationMode() BoxGenerationMode`: default `.normal`
//!   - `isBlock() bool`: default `false` (true only for `display: block`, not `flow-root`)
//!   - `isCompressibleReplaced() bool`: default `false`
//!   - `isReplaced() bool`: default `false`
//!   - `getBoxSizing() BoxSizing`: default `.border_box`
//!   - `getDirection() Direction`: default `.ltr`
//!   - `getOverflow() Point(Overflow)`: default `.{ .x = .visible, .y = .visible }`
//!   - `getScrollbarWidth() f32`: default `0.0`
//!   - `getPosition() Position`: default `.static`
//!   - `getInset() Rect(LengthPercentageAuto)`: default `Rect(LengthPercentageAuto).auto`
//!   - `isContainingBlock() ContainingBlockClaims`: default
//!     `.{ .absolute = self.getPosition().isPositioned(), .fixed = false }`
//!   - `getSize() Size(Dimension)`: default `Size(Dimension).auto`
//!   - `getMinSize() Size(LengthPercentageAuto)`: default `Size(LengthPercentageAuto).auto`
//!   - `getMaxSize() Size(LengthPercentageAuto)`: default `Size(LengthPercentageAuto).auto`
//!   - `getAspectRatio() ?f32`: default `null`
//!   - `getMargin() Rect(LengthPercentageAuto)`: default `Rect(LengthPercentageAuto).zero`
//!   - `getPadding() Rect(LengthPercentage)`: default `Rect(LengthPercentage).zero`
//!   - `getBorder() Rect(LengthPercentage)`: default `Rect(LengthPercentage).zero`
//!   - `getContain() Contain`: default `Contain.none`
//!
//! Upstream's associated type `CoreStyle::CustomIdent` has no equivalent: names are `[]const u8`.
//!
//! ## OofItemStyle (`OofItemStyleDefaults`), in addition to CoreStyle
//!
//!   - `getAlignSelf() ?AlignSelf`: default `null`
//!   - `getJustifySelf() ?AlignSelf`: default `null`
//!   - `isTable() bool`: default `false`
//!   - `getGridRow() Line(GridPlacement)`: default `Line(GridPlacement).auto`
//!   - `getGridColumn() Line(GridPlacement)`: default `Line(GridPlacement).auto`
//!
//! ## FlexboxContainerStyle (`FlexboxContainerStyleDefaults`), in addition to CoreStyle
//!
//!   - `getFlexDirection() FlexDirection`: default `.row`
//!   - `getFlexWrap() FlexWrap`: default `.no_wrap`
//!   - `getFlexLineCount() u16`: default `1`
//!   - `getGap() Size(LengthPercentage)`: default `Size(LengthPercentage).zero`
//!   - `getAlignContent() AlignContent`: default `AlignContent.normal`
//!   - `getAlignItems() AlignItems`: default `AlignItems.normal`
//!   - `getJustifyContent() JustifyContent`: default `JustifyContent.normal`
//!
//! ## FlexboxItemStyle (`FlexboxItemStyleDefaults`), in addition to CoreStyle
//!
//!   - `getFlexBasis() Dimension`: default `Dimension.auto`
//!   - `getFlexGrow() f32`: default `0.0`
//!   - `getFlexShrink() f32`: default `1.0`
//!   - `getAlignSelf() ?AlignSelf`: default `null`
//!
//! ## GridContainerStyle (`GridContainerStyleDefaults`), in addition to CoreStyle
//!
//! Upstream returns iterators through associated types (`TemplateTrackList`, `AutoTrackList`,
//! `TemplateLineNames`, `GridTemplateAreas`, `Repetition`); laffy returns slices instead.
//!
//!   - `getGridTemplateRows() ?[]const GridTemplateComponent`: required
//!   - `getGridTemplateColumns() ?[]const GridTemplateComponent`: required
//!   - `getGridAutoRows() []const TrackSizingFunction`: required
//!   - `getGridAutoColumns() []const TrackSizingFunction`: required
//!   - `getGridTemplateAreas() ?[]const GridTemplateArea`: required
//!   - `getGridTemplateAreaRowCount() u16`: default: the maximum of `max(area.row_end, 1) - 1`
//!     over `getGridTemplateAreas()` (0 if there are no areas)
//!   - `getGridTemplateAreaColumnCount() u16`: default: the maximum of `max(area.column_end, 1) - 1`
//!     over `getGridTemplateAreas()` (0 if there are no areas)
//!   - `getGridTemplateColumnNames() ?[]const []const []const u8`: required
//!   - `getGridTemplateRowNames() ?[]const []const []const u8`: required
//!   - `getGridAutoFlow() GridAutoFlow`: default `.row`
//!   - `getGap() Size(LengthPercentage)`: default `Size(LengthPercentage).zero`
//!   - `getAlignContent() AlignContent`: default `AlignContent.normal`
//!   - `getJustifyContent() JustifyContent`: default `JustifyContent.normal`
//!   - `getAlignItems() AlignItems`: default `AlignItems.normal`
//!   - `getJustifyItems() AlignItems`: default `AlignItems.normal`
//!   - `getGridTemplateTracks(axis: AbsoluteAxis) ?[]const GridTemplateComponent`: default:
//!     columns for `.horizontal`, rows for `.vertical`
//!   - `getGridAlignContent(axis: AbstractAxis) AlignContent`: default: `getJustifyContent()` for
//!     `.inline`, `getAlignContent()` for `.block`, with `normal` resolved to `stretch`
//!
//! ## GridItemStyle (`GridItemStyleDefaults`), in addition to CoreStyle
//!
//!   - `getGridRow() Line(GridPlacement)`: default `Line(GridPlacement).auto`
//!   - `getGridColumn() Line(GridPlacement)`: default `Line(GridPlacement).auto`
//!   - `getAlignSelf() ?AlignSelf`: default `null`
//!   - `getJustifySelf() ?AlignSelf`: default `null`
//!   - `getGridPlacement(axis: AbsoluteAxis) Line(GridPlacement)`: default: `getGridColumn()` for
//!     `.horizontal`, `getGridRow()` for `.vertical`
//!
//! ## BlockContainerStyle (`BlockContainerStyleDefaults`), in addition to CoreStyle
//!
//!   - `getTextAlign() TextAlign`: default `.auto`
//!   - `getAlignContent() AlignContent`: default `AlignContent.normal`
//!   - `getJustifyItems() AlignItems`: default `AlignItems.normal`
//!
//! ## BlockItemStyle (`BlockItemStyleDefaults`), in addition to CoreStyle
//!
//!   - `isTable() bool`: default `false`
//!   - `getAlignSelf() ?AlignSelf`: default `null`
//!   - `getJustifySelf() ?AlignSelf`: default `null`
//!   - `getAlignContent() AlignContent`: default `AlignContent.normal`
//!   - `getFloat() Float`: default `.none`
//!   - `getClear() Clear`: default `.none`
//!
//! Upstream also implements every trait for `&T`. In Zig a `*const T` can be used to call the
//! same methods, so nothing extra is needed.
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
pub const NoCalc = compact_length.NoCalc;
pub const ConstCalc = compact_length.ConstCalc;
pub const Dimension = dimension.Dimension;
pub const ExpandedDimension = dimension.ExpandedDimension;
pub const ExpandedLengthPercentage = dimension.ExpandedLengthPercentage;
pub const ExpandedLengthPercentageAuto = dimension.ExpandedLengthPercentageAuto;
pub const LengthPercentage = dimension.LengthPercentage;
pub const LengthPercentageAuto = dimension.LengthPercentageAuto;
pub const TextAlign = block.TextAlign;
pub const FlexDirection = flex.FlexDirection;
pub const FlexWrap = flex.FlexWrap;
pub const Clear = float.Clear;
pub const Float = float.Float;
pub const FloatDirection = float.FloatDirection;
pub const ExpandedMaxTrackSizingFunction = grid.ExpandedMaxTrackSizingFunction;
pub const ExpandedMinTrackSizingFunction = grid.ExpandedMinTrackSizingFunction;
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
    pub inline fn isOutOfFlow(self: Position) bool {
        return self == .absolute or self == .fixed;
    }

    /// Returns true if this position causes the item to act as a containing block
    /// for absolutely positioned descendants (any value other than `static`)
    pub inline fn isPositioned(self: Position) bool {
        return self != .static;
    }
};

/// Which out-of-flow positions a node establishes a containing block for.
///
/// Returned by the `isContainingBlock` style accessor.
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
    pub inline fn forPosition(self: ContainingBlockClaims, position: Position) bool {
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
    pub inline fn isScrollContainer(self: Overflow) bool {
        return switch (self) {
            .visible, .clip => false,
            .hidden, .scroll => true,
        };
    }

    /// Returns `0.0` if the overflow mode would cause the automatic minimum size of a Flexbox or CSS Grid item
    /// to be `0`. Else returns null.
    pub inline fn maybeIntoAutomaticMinSize(self: Overflow) ?f32 {
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
    pub inline fn contains(self: Contain, other: Contain) bool {
        return self.inner & other.inner == other.inner;
    }

    /// Returns whether `self` contains any of the containment types in `other`
    pub inline fn intersects(self: Contain, other: Contain) bool {
        return self.inner & other.inner != 0;
    }

    /// Returns the union of the containment types in `self` and `other` (also upstream `BitOr`)
    pub inline fn @"union"(self: Contain, other: Contain) Contain {
        return .{ .inner = self.inner | other.inner };
    }

    /// Whether this containment causes the box to establish an independent formatting context
    /// (both layout and paint containment do)
    pub inline fn establishesIndependentFormattingContext(self: Contain) bool {
        return self.intersects(layout.@"union"(paint));
    }

    /// Whether this containment suppresses the box's baseline for baseline-alignment purposes
    /// (layout containment does, paint containment does not)
    pub inline fn suppressesBaseline(self: Contain) bool {
        return self.contains(layout);
    }

    /// Whether this containment prevents the box's overflowing content from contributing to an
    /// ancestor's scrollable overflow region (layout containment treats such overflow as ink
    /// overflow; paint containment clips it)
    pub inline fn containsScrollableOverflow(self: Contain) bool {
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
    pub inline fn isRtl(self: Direction) bool {
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
    flex_basis: Dimension = Dimension.auto,
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

    // CoreStyle

    pub inline fn getBoxGenerationMode(self: *const Style) BoxGenerationMode {
        return switch (self.display) {
            .none => .none,
            else => .normal,
        };
    }
    pub inline fn isBlock(self: *const Style) bool {
        return self.display == .block;
    }
    pub inline fn isCompressibleReplaced(self: *const Style) bool {
        return self.item_is_replaced or self.item_is_compressible_replaced;
    }
    pub inline fn isReplaced(self: *const Style) bool {
        return self.item_is_replaced;
    }
    pub inline fn getBoxSizing(self: *const Style) BoxSizing {
        return self.box_sizing;
    }
    pub inline fn getDirection(self: *const Style) Direction {
        return self.direction;
    }
    pub inline fn getOverflow(self: *const Style) Point(Overflow) {
        return self.overflow;
    }
    pub inline fn getScrollbarWidth(self: *const Style) f32 {
        return self.scrollbar_width;
    }
    pub inline fn getPosition(self: *const Style) Position {
        return self.position;
    }
    pub inline fn getInset(self: *const Style) Rect(LengthPercentageAuto) {
        return self.inset;
    }
    pub inline fn isContainingBlock(self: *const Style) ContainingBlockClaims {
        return CoreStyleDefaults.isContainingBlock(self);
    }
    pub inline fn getSize(self: *const Style) Size(Dimension) {
        return self.size;
    }
    pub inline fn getMinSize(self: *const Style) Size(LengthPercentageAuto) {
        return self.min_size;
    }
    pub inline fn getMaxSize(self: *const Style) Size(LengthPercentageAuto) {
        return self.max_size;
    }
    pub inline fn getAspectRatio(self: *const Style) ?f32 {
        return self.aspect_ratio;
    }
    pub inline fn getMargin(self: *const Style) Rect(LengthPercentageAuto) {
        return self.margin;
    }
    pub inline fn getPadding(self: *const Style) Rect(LengthPercentage) {
        return self.padding;
    }
    pub inline fn getBorder(self: *const Style) Rect(LengthPercentage) {
        return self.border;
    }
    pub inline fn getContain(self: *const Style) Contain {
        return self.contain;
    }

    // OofItemStyle / BlockItemStyle / FlexboxItemStyle / GridItemStyle

    pub inline fn getAlignSelf(self: *const Style) ?AlignSelf {
        return self.align_self;
    }
    pub inline fn getJustifySelf(self: *const Style) ?AlignSelf {
        return self.justify_self;
    }
    pub inline fn isTable(self: *const Style) bool {
        return self.item_is_table;
    }
    pub inline fn getGridRow(self: *const Style) Line(GridPlacement) {
        return self.grid_row;
    }
    pub inline fn getGridColumn(self: *const Style) Line(GridPlacement) {
        return self.grid_column;
    }
    pub inline fn getGridPlacement(self: *const Style, axis: AbsoluteAxis) Line(GridPlacement) {
        return GridItemStyleDefaults.getGridPlacement(self, axis);
    }
    pub inline fn getFloat(self: *const Style) Float {
        return self.float;
    }
    pub inline fn getClear(self: *const Style) Clear {
        return self.clear;
    }

    // BlockContainerStyle

    pub inline fn getTextAlign(self: *const Style) TextAlign {
        return self.text_align;
    }

    // Shared by the container interfaces

    pub inline fn getAlignContent(self: *const Style) AlignContent {
        return self.align_content;
    }
    pub inline fn getJustifyItems(self: *const Style) AlignItems {
        return self.justify_items;
    }
    pub inline fn getAlignItems(self: *const Style) AlignItems {
        return self.align_items;
    }
    pub inline fn getJustifyContent(self: *const Style) JustifyContent {
        return self.justify_content;
    }
    pub inline fn getGap(self: *const Style) Size(LengthPercentage) {
        return self.gap;
    }

    // FlexboxContainerStyle

    pub inline fn getFlexDirection(self: *const Style) FlexDirection {
        return self.flex_direction;
    }
    pub inline fn getFlexWrap(self: *const Style) FlexWrap {
        return self.flex_wrap;
    }
    pub inline fn getFlexLineCount(self: *const Style) u16 {
        return self.flex_line_count;
    }

    // FlexboxItemStyle

    pub inline fn getFlexBasis(self: *const Style) Dimension {
        return self.flex_basis;
    }
    pub inline fn getFlexGrow(self: *const Style) f32 {
        return self.flex_grow;
    }
    pub inline fn getFlexShrink(self: *const Style) f32 {
        return self.flex_shrink;
    }

    // GridContainerStyle

    pub inline fn getGridTemplateRows(self: *const Style) ?[]const GridTemplateComponent {
        return self.grid_template_rows;
    }
    pub inline fn getGridTemplateColumns(self: *const Style) ?[]const GridTemplateComponent {
        return self.grid_template_columns;
    }
    pub inline fn getGridAutoRows(self: *const Style) []const TrackSizingFunction {
        return self.grid_auto_rows;
    }
    pub inline fn getGridAutoColumns(self: *const Style) []const TrackSizingFunction {
        return self.grid_auto_columns;
    }
    pub inline fn getGridAutoFlow(self: *const Style) GridAutoFlow {
        return self.grid_auto_flow;
    }
    pub inline fn getGridTemplateAreas(self: *const Style) ?[]const GridTemplateArea {
        return if (self.grid_template_areas) |template| template.areas else null;
    }
    pub inline fn getGridTemplateAreaRowCount(self: *const Style) u16 {
        return if (self.grid_template_areas) |template| template.row_count else 0;
    }
    pub inline fn getGridTemplateAreaColumnCount(self: *const Style) u16 {
        return if (self.grid_template_areas) |template| template.column_count else 0;
    }
    pub inline fn getGridTemplateColumnNames(self: *const Style) ?[]const []const []const u8 {
        return self.grid_template_column_names;
    }
    pub inline fn getGridTemplateRowNames(self: *const Style) ?[]const []const []const u8 {
        return self.grid_template_row_names;
    }
    pub inline fn getGridTemplateTracks(self: *const Style, axis: AbsoluteAxis) ?[]const GridTemplateComponent {
        return GridContainerStyleDefaults.getGridTemplateTracks(self, axis);
    }
    pub inline fn getGridAlignContent(self: *const Style, axis: AbstractAxis) AlignContent {
        return GridContainerStyleDefaults.getGridAlignContent(self, axis);
    }
};

/// Upstream default implementations of the `CoreStyle` methods (see the file documentation)
pub const CoreStyleDefaults = struct {
    pub inline fn getBoxGenerationMode(_: anytype) BoxGenerationMode {
        return BoxGenerationMode.default;
    }
    pub inline fn isBlock(_: anytype) bool {
        return false;
    }
    pub inline fn isCompressibleReplaced(_: anytype) bool {
        return false;
    }
    pub inline fn isReplaced(_: anytype) bool {
        return false;
    }
    pub inline fn getBoxSizing(_: anytype) BoxSizing {
        return .border_box;
    }
    pub inline fn getDirection(_: anytype) Direction {
        return .ltr;
    }
    pub inline fn getOverflow(_: anytype) Point(Overflow) {
        return Style.default.overflow;
    }
    pub inline fn getScrollbarWidth(_: anytype) f32 {
        return 0.0;
    }
    pub inline fn getPosition(_: anytype) Position {
        return Style.default.position;
    }
    pub inline fn getInset(_: anytype) Rect(LengthPercentageAuto) {
        return Style.default.inset;
    }
    pub inline fn isContainingBlock(self: anytype) ContainingBlockClaims {
        return .{ .absolute = self.getPosition().isPositioned(), .fixed = false };
    }
    pub inline fn getSize(_: anytype) Size(Dimension) {
        return Style.default.size;
    }
    pub inline fn getMinSize(_: anytype) Size(LengthPercentageAuto) {
        return Style.default.min_size;
    }
    pub inline fn getMaxSize(_: anytype) Size(LengthPercentageAuto) {
        return Style.default.max_size;
    }
    pub inline fn getAspectRatio(_: anytype) ?f32 {
        return Style.default.aspect_ratio;
    }
    pub inline fn getMargin(_: anytype) Rect(LengthPercentageAuto) {
        return Style.default.margin;
    }
    pub inline fn getPadding(_: anytype) Rect(LengthPercentage) {
        return Style.default.padding;
    }
    pub inline fn getBorder(_: anytype) Rect(LengthPercentage) {
        return Style.default.border;
    }
    pub inline fn getContain(_: anytype) Contain {
        return Contain.none;
    }
};

/// Upstream default implementations of the `OofItemStyle` methods
pub const OofItemStyleDefaults = struct {
    pub inline fn getAlignSelf(_: anytype) ?AlignSelf {
        return null;
    }
    pub inline fn getJustifySelf(_: anytype) ?AlignSelf {
        return null;
    }
    pub inline fn isTable(_: anytype) bool {
        return false;
    }
    pub inline fn getGridRow(_: anytype) Line(GridPlacement) {
        return Line(GridPlacement).auto;
    }
    pub inline fn getGridColumn(_: anytype) Line(GridPlacement) {
        return Line(GridPlacement).auto;
    }
};

/// Upstream default implementations of the `FlexboxContainerStyle` methods
pub const FlexboxContainerStyleDefaults = struct {
    pub inline fn getFlexDirection(_: anytype) FlexDirection {
        return Style.default.flex_direction;
    }
    pub inline fn getFlexWrap(_: anytype) FlexWrap {
        return Style.default.flex_wrap;
    }
    pub inline fn getFlexLineCount(_: anytype) u16 {
        return Style.default.flex_line_count;
    }
    pub inline fn getGap(_: anytype) Size(LengthPercentage) {
        return Style.default.gap;
    }
    pub inline fn getAlignContent(_: anytype) AlignContent {
        return Style.default.align_content;
    }
    pub inline fn getAlignItems(_: anytype) AlignItems {
        return Style.default.align_items;
    }
    pub inline fn getJustifyContent(_: anytype) JustifyContent {
        return Style.default.justify_content;
    }
};

/// Upstream default implementations of the `FlexboxItemStyle` methods
pub const FlexboxItemStyleDefaults = struct {
    pub inline fn getFlexBasis(_: anytype) Dimension {
        return Style.default.flex_basis;
    }
    pub inline fn getFlexGrow(_: anytype) f32 {
        return Style.default.flex_grow;
    }
    pub inline fn getFlexShrink(_: anytype) f32 {
        return Style.default.flex_shrink;
    }
    pub inline fn getAlignSelf(_: anytype) ?AlignSelf {
        return Style.default.align_self;
    }
};

/// Upstream default implementations of the `GridContainerStyle` methods. The track list, area
/// and line name accessors have no default and must be implemented by every grid container style.
pub const GridContainerStyleDefaults = struct {
    pub fn getGridTemplateAreaRowCount(self: anytype) u16 {
        const areas = self.getGridTemplateAreas() orelse return 0;
        var result: ?u16 = null;
        for (areas) |area| {
            const v = @max(area.row_end, 1) - 1;
            result = if (result) |r| @max(r, v) else v;
        }
        return result orelse 0;
    }
    pub fn getGridTemplateAreaColumnCount(self: anytype) u16 {
        const areas = self.getGridTemplateAreas() orelse return 0;
        var result: ?u16 = null;
        for (areas) |area| {
            const v = @max(area.column_end, 1) - 1;
            result = if (result) |r| @max(r, v) else v;
        }
        return result orelse 0;
    }
    pub inline fn getGridAutoFlow(_: anytype) GridAutoFlow {
        return Style.default.grid_auto_flow;
    }
    pub inline fn getGap(_: anytype) Size(LengthPercentage) {
        return Style.default.gap;
    }
    pub inline fn getAlignContent(_: anytype) AlignContent {
        return Style.default.align_content;
    }
    pub inline fn getJustifyContent(_: anytype) JustifyContent {
        return Style.default.justify_content;
    }
    pub inline fn getAlignItems(_: anytype) AlignItems {
        return Style.default.align_items;
    }
    pub inline fn getJustifyItems(_: anytype) AlignItems {
        return Style.default.justify_items;
    }
    /// Get a grid container's template tracks for the axis passed
    pub inline fn getGridTemplateTracks(self: anytype, axis: AbsoluteAxis) ?[]const GridTemplateComponent {
        return switch (axis) {
            .horizontal => self.getGridTemplateColumns(),
            .vertical => self.getGridTemplateRows(),
        };
    }
    /// Get a grid container's align-content or justify-content alignment depending on the axis passed
    /// (with `normal` resolved to `stretch`)
    pub inline fn getGridAlignContent(self: anytype, axis: AbstractAxis) AlignContent {
        const align_value = switch (axis) {
            .@"inline" => self.getJustifyContent(),
            .block => self.getAlignContent(),
        };
        return switch (align_value.keyword) {
            .normal => AlignContent.stretch,
            else => align_value,
        };
    }
};

/// Upstream default implementations of the `GridItemStyle` methods
pub const GridItemStyleDefaults = struct {
    pub inline fn getGridRow(_: anytype) Line(GridPlacement) {
        return Line(GridPlacement).auto;
    }
    pub inline fn getGridColumn(_: anytype) Line(GridPlacement) {
        return Line(GridPlacement).auto;
    }
    pub inline fn getAlignSelf(_: anytype) ?AlignSelf {
        return Style.default.align_self;
    }
    pub inline fn getJustifySelf(_: anytype) ?AlignSelf {
        return Style.default.justify_self;
    }
    /// Get a grid item's row or column placement depending on the axis passed
    pub inline fn getGridPlacement(self: anytype, axis: AbsoluteAxis) Line(GridPlacement) {
        return switch (axis) {
            .horizontal => self.getGridColumn(),
            .vertical => self.getGridRow(),
        };
    }
};

/// Upstream default implementations of the `BlockContainerStyle` methods
pub const BlockContainerStyleDefaults = struct {
    pub inline fn getTextAlign(_: anytype) TextAlign {
        return Style.default.text_align;
    }
    pub inline fn getAlignContent(_: anytype) AlignContent {
        return Style.default.align_content;
    }
    pub inline fn getJustifyItems(_: anytype) AlignItems {
        return Style.default.justify_items;
    }
};

/// Upstream default implementations of the `BlockItemStyle` methods
pub const BlockItemStyleDefaults = struct {
    pub inline fn isTable(_: anytype) bool {
        return false;
    }
    pub inline fn getAlignSelf(_: anytype) ?AlignSelf {
        return null;
    }
    pub inline fn getJustifySelf(_: anytype) ?AlignSelf {
        return null;
    }
    pub inline fn getAlignContent(_: anytype) AlignContent {
        return AlignContent.normal;
    }
    pub inline fn getFloat(_: anytype) Float {
        return .none;
    }
    pub inline fn getClear(_: anytype) Clear {
        return .none;
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
        .flex_basis = Dimension.auto,
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

test "style sizes" {
    // Display and Position
    try testing.expectEqual(1, @sizeOf(Display));
    try testing.expectEqual(1, @sizeOf(BoxSizing));
    try testing.expectEqual(1, @sizeOf(Position));
    try testing.expectEqual(1, @sizeOf(Overflow));

    // Dimensions and aggregations of Dimensions
    try testing.expectEqual(4, @sizeOf(f32));
    try testing.expectEqual(8, @sizeOf(LengthPercentage));
    try testing.expectEqual(8, @sizeOf(LengthPercentageAuto));
    try testing.expectEqual(8, @sizeOf(Dimension));
    try testing.expectEqual(16, @sizeOf(Size(LengthPercentage)));
    try testing.expectEqual(16, @sizeOf(Size(LengthPercentageAuto)));
    try testing.expectEqual(16, @sizeOf(Size(Dimension)));
    try testing.expectEqual(32, @sizeOf(Rect(LengthPercentage)));
    try testing.expectEqual(32, @sizeOf(Rect(LengthPercentageAuto)));
    try testing.expectEqual(32, @sizeOf(Rect(Dimension)));

    // Alignment
    try testing.expectEqual(1, @sizeOf(AlignContentKeyword));
    try testing.expectEqual(1, @sizeOf(AlignItemsKeyword));
    try testing.expectEqual(1, @sizeOf(AlignmentSafety));
    try testing.expectEqual(2, @sizeOf(AlignContent));
    try testing.expectEqual(2, @sizeOf(AlignItems));

    // Flexbox Container
    try testing.expectEqual(1, @sizeOf(FlexDirection));
    try testing.expectEqual(1, @sizeOf(FlexWrap));

    // CSS Grid Container
    try testing.expectEqual(1, @sizeOf(GridAutoFlow));
    try testing.expectEqual(8, @sizeOf(MinTrackSizingFunction));
    try testing.expectEqual(8, @sizeOf(MaxTrackSizingFunction));
    try testing.expectEqual(16, @sizeOf(TrackSizingFunction));
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

/// Checks every accessor of a style type against the upstream defaults
fn expectDefaultAccessors(s: anytype) !void {
    // CoreStyle
    try testing.expectEqual(BoxGenerationMode.normal, s.getBoxGenerationMode());
    try testing.expect(!s.isBlock());
    try testing.expect(!s.isCompressibleReplaced());
    try testing.expect(!s.isReplaced());
    try testing.expectEqual(BoxSizing.border_box, s.getBoxSizing());
    try testing.expectEqual(Direction.ltr, s.getDirection());
    try testing.expectEqual(Point(Overflow){ .x = .visible, .y = .visible }, s.getOverflow());
    try testing.expectEqual(@as(f32, 0.0), s.getScrollbarWidth());
    try testing.expectEqual(Position.static, s.getPosition());
    try testing.expectEqual(Rect(LengthPercentageAuto).auto, s.getInset());
    try testing.expectEqual(ContainingBlockClaims{ .absolute = false, .fixed = false }, s.isContainingBlock());
    try testing.expectEqual(Size(Dimension).auto, s.getSize());
    try testing.expectEqual(Size(LengthPercentageAuto).auto, s.getMinSize());
    try testing.expectEqual(Size(LengthPercentageAuto).auto, s.getMaxSize());
    try testing.expectEqual(@as(?f32, null), s.getAspectRatio());
    try testing.expectEqual(Rect(LengthPercentageAuto).zero, s.getMargin());
    try testing.expectEqual(Rect(LengthPercentage).zero, s.getPadding());
    try testing.expectEqual(Rect(LengthPercentage).zero, s.getBorder());
    try testing.expect(s.getContain() == Contain.none);
    // OofItemStyle / BlockItemStyle / FlexboxItemStyle / GridItemStyle
    try testing.expectEqual(@as(?AlignSelf, null), s.getAlignSelf());
    try testing.expectEqual(@as(?AlignSelf, null), s.getJustifySelf());
    try testing.expect(!s.isTable());
    try testing.expectEqual(Line(GridPlacement).auto, s.getGridRow());
    try testing.expectEqual(Line(GridPlacement).auto, s.getGridColumn());
    try testing.expectEqual(Line(GridPlacement).auto, s.getGridPlacement(.horizontal));
    try testing.expectEqual(Float.none, s.getFloat());
    try testing.expectEqual(Clear.none, s.getClear());
    // FlexboxContainerStyle
    try testing.expectEqual(FlexDirection.row, s.getFlexDirection());
    try testing.expectEqual(FlexWrap.no_wrap, s.getFlexWrap());
    try testing.expectEqual(@as(u16, 1), s.getFlexLineCount());
    try testing.expectEqual(Size(LengthPercentage).zero, s.getGap());
    try testing.expect(s.getAlignContent() == AlignContent.normal);
    try testing.expect(s.getAlignItems() == AlignItems.normal);
    try testing.expect(s.getJustifyContent() == JustifyContent.normal);
    // FlexboxItemStyle
    try testing.expect(s.getFlexBasis() == Dimension.auto);
    try testing.expectEqual(@as(f32, 0.0), s.getFlexGrow());
    try testing.expectEqual(@as(f32, 1.0), s.getFlexShrink());
    // GridContainerStyle
    try testing.expectEqual(@as(usize, 0), s.getGridTemplateRows().?.len);
    try testing.expectEqual(@as(usize, 0), s.getGridTemplateColumns().?.len);
    try testing.expectEqual(@as(usize, 0), s.getGridAutoRows().len);
    try testing.expectEqual(@as(usize, 0), s.getGridAutoColumns().len);
    try testing.expectEqual(@as(?[]const GridTemplateArea, null), s.getGridTemplateAreas());
    try testing.expectEqual(@as(u16, 0), s.getGridTemplateAreaRowCount());
    try testing.expectEqual(@as(u16, 0), s.getGridTemplateAreaColumnCount());
    try testing.expectEqual(@as(usize, 0), s.getGridTemplateColumnNames().?.len);
    try testing.expectEqual(@as(usize, 0), s.getGridTemplateRowNames().?.len);
    try testing.expectEqual(GridAutoFlow.row, s.getGridAutoFlow());
    try testing.expect(s.getJustifyItems() == AlignItems.normal);
    try testing.expectEqual(@as(usize, 0), s.getGridTemplateTracks(.vertical).?.len);
    try testing.expect(s.getGridAlignContent(.@"inline") == AlignContent.stretch);
    try testing.expect(s.getGridAlignContent(.block) == AlignContent.stretch);
    // BlockContainerStyle
    try testing.expectEqual(TextAlign.auto, s.getTextAlign());
}

test "Style accessors return upstream defaults" {
    const s: Style = .{};
    try expectDefaultAccessors(s);
    try expectDefaultAccessors(&s);
}

/// A custom style type that implements every interface using only the upstream defaults (plus
/// the required grid accessors)
const DefaultsOnlyStyle = struct {
    const C = CoreStyleDefaults;
    const O = OofItemStyleDefaults;
    const FC = FlexboxContainerStyleDefaults;
    const FI = FlexboxItemStyleDefaults;
    const GC = GridContainerStyleDefaults;
    const GI = GridItemStyleDefaults;
    const BC = BlockContainerStyleDefaults;
    const BI = BlockItemStyleDefaults;

    areas: ?[]const GridTemplateArea = null,

    pub const getBoxGenerationMode = C.getBoxGenerationMode;
    pub const isBlock = C.isBlock;
    pub const isCompressibleReplaced = C.isCompressibleReplaced;
    pub const isReplaced = C.isReplaced;
    pub const getBoxSizing = C.getBoxSizing;
    pub const getDirection = C.getDirection;
    pub const getOverflow = C.getOverflow;
    pub const getScrollbarWidth = C.getScrollbarWidth;
    pub const getPosition = C.getPosition;
    pub const getInset = C.getInset;
    pub const isContainingBlock = C.isContainingBlock;
    pub const getSize = C.getSize;
    pub const getMinSize = C.getMinSize;
    pub const getMaxSize = C.getMaxSize;
    pub const getAspectRatio = C.getAspectRatio;
    pub const getMargin = C.getMargin;
    pub const getPadding = C.getPadding;
    pub const getBorder = C.getBorder;
    pub const getContain = C.getContain;

    pub const getAlignSelf = O.getAlignSelf;
    pub const getJustifySelf = O.getJustifySelf;
    pub const isTable = O.isTable;
    pub const getGridRow = O.getGridRow;
    pub const getGridColumn = O.getGridColumn;
    pub const getGridPlacement = GI.getGridPlacement;
    pub const getFloat = BI.getFloat;
    pub const getClear = BI.getClear;

    pub const getFlexDirection = FC.getFlexDirection;
    pub const getFlexWrap = FC.getFlexWrap;
    pub const getFlexLineCount = FC.getFlexLineCount;
    pub const getGap = FC.getGap;
    pub const getAlignContent = FC.getAlignContent;
    pub const getAlignItems = FC.getAlignItems;
    pub const getJustifyContent = FC.getJustifyContent;

    pub const getFlexBasis = FI.getFlexBasis;
    pub const getFlexGrow = FI.getFlexGrow;
    pub const getFlexShrink = FI.getFlexShrink;

    pub fn getGridTemplateRows(_: DefaultsOnlyStyle) ?[]const GridTemplateComponent {
        return &.{};
    }
    pub fn getGridTemplateColumns(_: DefaultsOnlyStyle) ?[]const GridTemplateComponent {
        return &.{};
    }
    pub fn getGridAutoRows(_: DefaultsOnlyStyle) []const TrackSizingFunction {
        return &.{};
    }
    pub fn getGridAutoColumns(_: DefaultsOnlyStyle) []const TrackSizingFunction {
        return &.{};
    }
    pub fn getGridTemplateAreas(self: DefaultsOnlyStyle) ?[]const GridTemplateArea {
        return self.areas;
    }
    pub fn getGridTemplateColumnNames(_: DefaultsOnlyStyle) ?[]const []const []const u8 {
        return &.{};
    }
    pub fn getGridTemplateRowNames(_: DefaultsOnlyStyle) ?[]const []const []const u8 {
        return &.{};
    }
    pub const getGridTemplateAreaRowCount = GC.getGridTemplateAreaRowCount;
    pub const getGridTemplateAreaColumnCount = GC.getGridTemplateAreaColumnCount;
    pub const getGridAutoFlow = GC.getGridAutoFlow;
    pub const getJustifyItems = GC.getJustifyItems;
    pub const getGridTemplateTracks = GC.getGridTemplateTracks;
    pub const getGridAlignContent = GC.getGridAlignContent;

    pub const getTextAlign = BC.getTextAlign;

    comptime {
        // The remaining defaults are equivalent to the ones adopted above; reference them so
        // that they are type-checked.
        _ = GC.getGap;
        _ = GC.getAlignContent;
        _ = GC.getJustifyContent;
        _ = GC.getAlignItems;
        _ = GI.getGridRow;
        _ = GI.getGridColumn;
        _ = GI.getAlignSelf;
        _ = GI.getJustifySelf;
        _ = FI.getAlignSelf;
        _ = BC.getAlignContent;
        _ = BC.getJustifyItems;
        _ = BI.isTable;
        _ = BI.getAlignSelf;
        _ = BI.getJustifySelf;
        _ = BI.getAlignContent;
    }
};

test "default accessor implementations match Style defaults" {
    const s: DefaultsOnlyStyle = .{};
    try expectDefaultAccessors(s);
    try expectDefaultAccessors(&s);
    // The remaining defaults, called directly
    try testing.expectEqual(Size(LengthPercentage).zero, GridContainerStyleDefaults.getGap(s));
    try testing.expect(GridContainerStyleDefaults.getAlignContent(s) == AlignContent.normal);
    try testing.expect(GridContainerStyleDefaults.getJustifyContent(s) == JustifyContent.normal);
    try testing.expect(GridContainerStyleDefaults.getAlignItems(s) == AlignItems.normal);
    try testing.expectEqual(Line(GridPlacement).auto, GridItemStyleDefaults.getGridRow(s));
    try testing.expectEqual(Line(GridPlacement).auto, GridItemStyleDefaults.getGridColumn(s));
    try testing.expectEqual(@as(?AlignSelf, null), GridItemStyleDefaults.getAlignSelf(s));
    try testing.expectEqual(@as(?AlignSelf, null), GridItemStyleDefaults.getJustifySelf(s));
    try testing.expectEqual(@as(?AlignSelf, null), FlexboxItemStyleDefaults.getAlignSelf(s));
    try testing.expect(BlockContainerStyleDefaults.getAlignContent(s) == AlignContent.normal);
    try testing.expect(BlockContainerStyleDefaults.getJustifyItems(s) == AlignItems.normal);
    try testing.expect(!BlockItemStyleDefaults.isTable(s));
    try testing.expectEqual(@as(?AlignSelf, null), BlockItemStyleDefaults.getAlignSelf(s));
    try testing.expectEqual(@as(?AlignSelf, null), BlockItemStyleDefaults.getJustifySelf(s));
    try testing.expect(BlockItemStyleDefaults.getAlignContent(s) == AlignContent.normal);

    // Computed default for the area template size
    const areas = [_]GridTemplateArea{
        .{ .name = "a", .row_start = 1, .row_end = 3, .column_start = 1, .column_end = 2 },
        .{ .name = "b", .row_start = 3, .row_end = 4, .column_start = 2, .column_end = 5 },
        .{ .name = "c", .row_start = 0, .row_end = 0, .column_start = 0, .column_end = 0 },
    };
    const with_areas: DefaultsOnlyStyle = .{ .areas = &areas };
    try testing.expectEqual(@as(u16, 3), with_areas.getGridTemplateAreaRowCount());
    try testing.expectEqual(@as(u16, 4), with_areas.getGridTemplateAreaColumnCount());
}

test "Style accessors read fields" {
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
    try testing.expect(!s.isReplaced());
    try testing.expectEqual(ContainingBlockClaims{ .absolute = true, .fixed = false }, s.isContainingBlock());
    try testing.expectEqual(@as(usize, 2), s.getGridTemplateTracks(.horizontal).?.len);
    try testing.expectEqual(@as(usize, 1), s.getGridTemplateTracks(.vertical).?.len);
    try testing.expectEqual(@as(u16, 5), s.getGridTemplateAreaRowCount());
    try testing.expectEqual(@as(u16, 6), s.getGridTemplateAreaColumnCount());
    try testing.expectEqual(@as(usize, 1), s.getGridTemplateAreas().?.len);
    try testing.expect(s.getGridPlacement(.vertical).start.eql(.{ .line = .{ .inner = 2 } }));
    try testing.expect(s.getGridAlignContent(.@"inline") == AlignContent.center);
    try testing.expect(s.getGridAlignContent(.block) == AlignContent.end);
    const hidden: Style = .{ .display = .none };
    try testing.expectEqual(BoxGenerationMode.none, hidden.getBoxGenerationMode());
}
