//! Geometric primitives useful for layout
//!
//! Generic types (`Size(T)`, `Rect(T)`, `Line(T)`, `Point(T)`) carry every upstream helper as a
//! declaration. Zig only analyses a declaration when it is used, so helpers that upstream defines
//! for one specific `T` (for example `Size<f32>::ZERO`, `Size<Option<f32>>::NONE` or
//! `Rect<f32>::new`) are written as declarations of the generic type that only compile for that `T`.
//!
//! Methods that upstream implements on `Line<GridPlacement>`, `Line<OriginZeroGridPlacement>`,
//! `Line<OriginZeroLine>` and friends forward to `T.line*` functions on the element type (see the
//! "Grid helpers" section of `Line`), so this file does not need to know about grid types.
//!
//! Closure-taking helpers (`map`, `zipMap`, `mapMain`, ...) take `comptime` function parameters;
//! where a closure would capture state, write the code explicitly at the call site instead.
const std = @import("std");
const sys = @import("util/sys.zig");
const toF32 = @import("style/compact_length.zig").toF32;
const FlexDirection = @import("style/flex.zig").FlexDirection;
const LengthPercentage = @import("style/dimension.zig").LengthPercentage;

/// The simple absolute horizontal and vertical axis
pub const AbsoluteAxis = enum {
    /// The horizontal axis
    horizontal,
    /// The vertical axis
    vertical,

    /// Returns the other variant of the enum
    pub fn otherAxis(self: AbsoluteAxis) AbsoluteAxis {
        return switch (self) {
            .horizontal => .vertical,
            .vertical => .horizontal,
        };
    }
};

/// The CSS abstract axis
/// <https://www.w3.org/TR/css-writing-modes-3/#abstract-axes>
pub const AbstractAxis = enum {
    /// The axis in the inline dimension, i.e. the horizontal axis in horizontal writing modes and the vertical axis in vertical writing modes.
    @"inline",
    /// The axis in the block dimension, i.e. the vertical axis in horizontal writing modes and the horizontal axis in vertical writing modes.
    block,

    /// Returns the other variant of the enum
    pub fn other(self: AbstractAxis) AbstractAxis {
        return switch (self) {
            .@"inline" => .block,
            .block => .@"inline",
        };
    }

    /// Convert an `AbstractAxis` into an `AbsoluteAxis` naively assuming that the Inline axis is Horizontal
    /// This is currently always true, but will change if laffy ever implements the `writing_mode` property
    pub fn asAbsNaive(self: AbstractAxis) AbsoluteAxis {
        return switch (self) {
            .@"inline" => .horizontal,
            .block => .vertical,
        };
    }
};

/// Container that holds an item in each absolute axis without specifying
/// what kind of item it is.
pub fn InBothAbsAxis(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The item in the horizontal axis
        horizontal: T,
        /// The item in the vertical axis
        vertical: T,

        /// Get the contained item based on the AbsoluteAxis passed
        pub fn get(self: Self, axis: AbsoluteAxis) T {
            return switch (axis) {
                .horizontal => self.horizontal,
                .vertical => self.vertical,
            };
        }
    };
}

/// An axis-aligned UI rectangle
pub fn Rect(comptime T: type) type {
    return struct {
        const Self = @This();
        /// The element type
        pub const Inner = T;

        /// This can represent either the x-coordinate of the starting edge,
        /// or the amount of padding on the starting side.
        ///
        /// The starting edge is the left edge when working with LTR text,
        /// and the right edge when working with RTL text.
        left: T,
        /// This can represent either the x-coordinate of the ending edge,
        /// or the amount of padding on the ending side.
        ///
        /// The ending edge is the right edge when working with LTR text,
        /// and the left edge when working with RTL text.
        right: T,
        /// This can represent either the y-coordinate of the top edge,
        /// or the amount of padding on the top side.
        top: T,
        /// This can represent either the y-coordinate of the bottom edge,
        /// or the amount of padding on the bottom side.
        bottom: T,

        /// Component-wise addition (upstream `Add` impl; numeric `T` only)
        pub fn add(self: Self, rhs: Self) Self {
            return .{
                .left = self.left + rhs.left,
                .right = self.right + rhs.right,
                .top = self.top + rhs.top,
                .bottom = self.bottom + rhs.bottom,
            };
        }

        /// Get either the width or height depending on the AbsoluteAxis passed in
        pub fn gridAxisSum(self: Self, axis: AbsoluteAxis) T {
            return switch (axis) {
                .horizontal => self.left + self.right,
                .vertical => self.top + self.bottom,
            };
        }

        /// Swap the horizontal and vertical sides (`left <-> top`, `right <-> bottom`)
        pub fn transpose(self: Self) Self {
            return .{ .left = self.top, .right = self.bottom, .top = self.left, .bottom = self.right };
        }

        /// Applies the function `f` to all four sides of the rect
        ///
        /// When applied to the left and right sides, the width is used
        /// as the second parameter of `f`.
        /// When applied to the top or bottom sides, the height is used instead.
        pub fn zipSize(
            self: Self,
            comptime U: type,
            size: Size(U),
            comptime R: type,
            comptime f: fn (T, U) R,
        ) Rect(R) {
            return .{
                .left = f(self.left, size.width),
                .right = f(self.right, size.width),
                .top = f(self.top, size.height),
                .bottom = f(self.bottom, size.height),
            };
        }

        /// Applies the function `f` to the left, right, top, and bottom properties
        ///
        /// This is used to transform a `Rect(T)` into a `Rect(R)`.
        pub fn map(self: Self, comptime R: type, comptime f: fn (T) R) Rect(R) {
            return .{ .left = f(self.left), .right = f(self.right), .top = f(self.top), .bottom = f(self.bottom) };
        }

        /// Returns a `Line(T)` representing the left and right properties of the Rect
        pub fn horizontalComponents(self: Self) Line(T) {
            return .{ .start = self.left, .end = self.right };
        }

        /// Returns a `Line(T)` containing the top and bottom properties of the Rect
        pub fn verticalComponents(self: Self) Line(T) {
            return .{ .start = self.top, .end = self.bottom };
        }

        /// The sum of `left` and `right`
        ///
        /// This is typically used when computing total padding.
        ///
        /// **NOTE:** this is *not* the width of the rectangle.
        pub fn horizontalAxisSum(self: Self) T {
            return self.left + self.right;
        }

        /// The sum of `top` and `bottom`
        ///
        /// This is typically used when computing total padding.
        ///
        /// **NOTE:** this is *not* the height of the rectangle.
        pub fn verticalAxisSum(self: Self) T {
            return self.top + self.bottom;
        }

        /// Both horizontalAxisSum and verticalAxisSum as a `Size(T)`
        ///
        /// **NOTE:** this is *not* the width/height of the rectangle.
        pub fn sumAxes(self: Self) Size(T) {
            return .{ .width = self.horizontalAxisSum(), .height = self.verticalAxisSum() };
        }

        /// The sum of the two fields of the `Rect` representing the main axis.
        ///
        /// This is typically used when computing total padding.
        ///
        /// If the `FlexDirection` is `row` or `row_reverse`, this is `horizontalAxisSum`.
        /// Otherwise, this is `verticalAxisSum`.
        pub fn mainAxisSum(self: Self, direction: FlexDirection) T {
            if (direction.isRow()) {
                return self.horizontalAxisSum();
            } else {
                return self.verticalAxisSum();
            }
        }

        /// The sum of the two fields of the `Rect` representing the cross axis.
        ///
        /// If the `FlexDirection` is `row` or `row_reverse`, this is `verticalAxisSum`.
        /// Otherwise, this is `horizontalAxisSum`.
        pub fn crossAxisSum(self: Self, direction: FlexDirection) T {
            if (direction.isRow()) {
                return self.verticalAxisSum();
            } else {
                return self.horizontalAxisSum();
            }
        }

        /// The `start` or `top` value of the `Rect`, from the perspective of the main layout axis
        pub fn mainStart(self: Self, direction: FlexDirection) T {
            return if (direction.isRow()) self.left else self.top;
        }

        /// The `end` or `bottom` value of the `Rect`, from the perspective of the main layout axis
        pub fn mainEnd(self: Self, direction: FlexDirection) T {
            return if (direction.isRow()) self.right else self.bottom;
        }

        /// The `start` or `top` value of the `Rect`, from the perspective of the cross layout axis
        pub fn crossStart(self: Self, direction: FlexDirection) T {
            return if (direction.isRow()) self.top else self.left;
        }

        /// The `end` or `bottom` value of the `Rect`, from the perspective of the cross layout axis
        pub fn crossEnd(self: Self, direction: FlexDirection) T {
            return if (direction.isRow()) self.bottom else self.right;
        }

        /// A `Rect` with `null` as all parameters (`Rect(?f32)` only)
        pub const none: Self = .{ .left = null, .right = null, .top = null, .bottom = null };

        /// Creates a new Rect (`Rect(f32)` only)
        pub fn new(start: f32, end: f32, top: f32, bottom: f32) Self {
            return .{ .left = start, .right = end, .top = top, .bottom = bottom };
        }

        /// Returns the smallest rectangle that contains both `self` and `other`, where the fields
        /// of each `Rect` are interpreted as edge coordinates (`left`/`top` being the minimum
        /// coordinates and `right`/`bottom` the maximum coordinates of the rectangle) (`Rect(f32)` only)
        pub fn @"union"(self: Self, other_rect: Self) Self {
            return .{
                .left = @min(self.left, other_rect.left),
                .right = @max(self.right, other_rect.right),
                .top = @min(self.top, other_rect.top),
                .bottom = @max(self.bottom, other_rect.bottom),
            };
        }

        /// Create a new Rect with length values (`Rect(Dimension)`; upstream `Rect::<Dimension>::from_length`)
        pub fn fromLengths(start: f32, end: f32, top: f32, bottom: f32) Self {
            return .{ .left = T.fromLength(start), .right = T.fromLength(end), .top = T.fromLength(top), .bottom = T.fromLength(bottom) };
        }

        /// Create a new Rect with percentage values (`Rect(Dimension)`; upstream `Rect::<Dimension>::from_percent`)
        pub fn fromPercents(start: f32, end: f32, top: f32, bottom: f32) Self {
            return .{ .left = T.fromPercent(start), .right = T.fromPercent(end), .top = T.fromPercent(top), .bottom = T.fromPercent(bottom) };
        }

        // style_helpers (TaffyZero, TaffyAuto, TaffyMinContent, TaffyMaxContent, TaffyFitContent,
        // FromLength, FromPercent)

        /// A Rect where all sides are the zero value of the contained type (e.g. 0.0, 0.0 or Dimension.zero)
        pub const zero: Self = all(elementZero(T));
        /// A Rect where all sides are the auto value of the contained type
        pub const auto: Self = all(elementAuto(T));
        /// A Rect where all sides are the min_content value of the contained type
        pub const min_content: Self = all(elementMinContent(T));
        /// A Rect where all sides are the max_content value of the contained type
        pub const max_content: Self = all(elementMaxContent(T));

        /// A Rect where all sides are the same `fit-content(…)` value with the given argument
        pub fn fitContent(argument: LengthPercentage) Self {
            return all(elementFitContent(T, argument));
        }
        /// A Rect where all sides are the same given absolute length (upstream `FromLength`)
        pub fn fromLength(value: anytype) Self {
            return all(elementLength(T, value));
        }
        /// A Rect where all sides are the same given percentage (upstream `FromPercent`)
        pub fn fromPercent(value: anytype) Self {
            return all(elementPercent(T, value));
        }

        fn all(value: T) Self {
            return .{ .left = value, .right = value, .top = value, .bottom = value };
        }
    };
}

/// An abstract "line". Represents any type that has a start and an end
pub fn Line(comptime T: type) type {
    return struct {
        const Self = @This();
        /// The element type
        pub const Inner = T;

        /// The start position of a line
        start: T,
        /// The end position of a line
        end: T,

        /// Applies the function `f` to both the start and end
        ///
        /// This is used to transform a `Line(T)` into a `Line(R)`.
        pub fn map(self: Self, comptime R: type, comptime f: fn (T) R) Line(R) {
            return .{ .start = f(self.start), .end = f(self.end) };
        }

        /// A `Line(bool)` with both start and end set to `true`
        pub const @"true": Self = .{ .start = true, .end = true };
        /// A `Line(bool)` with both start and end set to `false`
        pub const @"false": Self = .{ .start = false, .end = false };

        /// Adds the start and end values together and returns the result (numeric `T` only)
        pub fn sum(self: Self) T {
            return self.start + self.end;
        }

        // style_helpers

        /// A Line where both start and end are the zero value of the contained type
        pub const zero: Self = both(elementZero(T));
        /// A Line where both start and end are the auto value of the contained type
        pub const auto: Self = both(elementAuto(T));
        /// A Line where both start and end are the min_content value of the contained type
        pub const min_content: Self = both(elementMinContent(T));
        /// A Line where both start and end are the max_content value of the contained type
        pub const max_content: Self = both(elementMaxContent(T));

        /// A Line with start and end set to the same `fit-content(…)` value with the given argument
        pub fn fitContent(argument: LengthPercentage) Self {
            return both(elementFitContent(T, argument));
        }
        /// A Line where both start and end are the same given absolute length (upstream `FromLength`)
        pub fn fromLength(value: anytype) Self {
            return both(elementLength(T, value));
        }
        /// A Line where both start and end are the same given percentage (upstream `FromPercent`)
        pub fn fromPercent(value: anytype) Self {
            return both(elementPercent(T, value));
        }

        /// Upstream `TaffyGridLine for Line<GridPlacement>`: starts at the given line, ends `auto`
        pub fn fromLineIndex(index: i16) Self {
            return .{ .start = T.fromLineIndex(index), .end = T.auto };
        }

        /// Upstream `TaffyGridSpan for Line<GridPlacement>`: spans the given number of tracks, ends `auto`
        pub fn fromSpan(span_value: u16) Self {
            return .{ .start = T.fromSpan(span_value), .end = T.auto };
        }

        fn both(value: T) Self {
            return .{ .start = value, .end = value };
        }

        // Grid helpers. Upstream implements these on specific `Line<...>` instantiations; here
        // they forward to functions on the element type, which see `style/grid.zig` and
        // `compute/grid/types/coordinates.zig`.

        /// Whether the track position is definite in this axis (or the item will need auto placement).
        /// Valid for `Line(GridPlacement)`, `Line(NonNamedGridPlacement)` and `Line(OriginZeroGridPlacement)`.
        pub fn isDefinite(self: Self) bool {
            return T.lineIsDefinite(self);
        }

        /// Resolves the span for an indefinite placement (a placement that does not consist of two `Track`s).
        /// Panics if called on a definite placement. Valid for `Line(GenericGridPlacement(_))`.
        pub fn indefiniteSpan(self: Self) u16 {
            return T.lineIndefiniteSpan(self);
        }

        /// Convert into origin-zero placements, treating named lines and spans as `auto`.
        /// Valid for `Line(GridPlacement)`.
        pub fn intoOriginZeroIgnoringNamed(self: Self, explicit_track_count: u16) Line(T.OriginZeroPlacement) {
            return T.lineIntoOriginZeroIgnoringNamed(self, explicit_track_count);
        }

        /// Convert into origin-zero placements. Valid for `Line(NonNamedGridPlacement)`.
        pub fn intoOriginZero(self: Self, explicit_track_count: u16) Line(T.OriginZeroPlacement) {
            return T.lineIntoOriginZero(self, explicit_track_count);
        }

        /// If at least one of the of the start and end positions is a track index then the other end can be resolved
        /// into a track index purely based on the information contained with the placement specification.
        /// Valid for `Line(OriginZeroGridPlacement)`.
        pub fn resolveDefiniteGridLines(self: Self) Line(T.LineType) {
            return T.lineResolveDefiniteGridLines(self);
        }

        /// Resolve the grid tracks of an absolutely positioned item. Valid for `Line(OriginZeroGridPlacement)`.
        pub fn resolveAbsolutelyPositionedGridTracks(self: Self) Line(?T.LineType) {
            return T.lineResolveAbsolutelyPositionedGridTracks(self);
        }

        /// If neither of the start and end positions is a track index then the other end can be resolved
        /// into a track index if a definite start position is supplied externally.
        /// Valid for `Line(OriginZeroGridPlacement)`.
        pub fn resolveIndefiniteGridTracks(self: Self, start_line: T.LineType) Line(T.LineType) {
            return T.lineResolveIndefiniteGridTracks(self, start_line);
        }

        /// The number of tracks between the start and end lines. Valid for `Line(OriginZeroLine)`.
        pub fn span(self: Self) u16 {
            return T.lineSpan(self);
        }
    };
}

/// The distances that a horizontal band of space is inset from the left and right edges of a
/// container. Used for the space taken up by floats, and for the position of a containing block
/// within a block formatting context.
pub const FloatInsets = struct {
    /// The inset from the left edge
    left: f32 = 0.0,
    /// The inset from the right edge
    right: f32 = 0.0,

    /// Zero insets on both sides
    pub const zero: FloatInsets = .{ .left = 0.0, .right = 0.0 };

    /// Create a new `FloatInsets`
    pub fn new(left: f32, right: f32) FloatInsets {
        return .{ .left = left, .right = right };
    }

    /// The sum of the left and right insets
    pub fn sum(self: FloatInsets) f32 {
        return self.left + self.right;
    }

    /// The larger of the two insets on each side
    pub fn max(self: FloatInsets, other: FloatInsets) FloatInsets {
        return .{ .left = @max(self.left, other.left), .right = @max(self.right, other.right) };
    }

    /// Component-wise addition (upstream `Add` impl)
    pub fn add(self: FloatInsets, rhs: FloatInsets) FloatInsets {
        return .{ .left = self.left + rhs.left, .right = self.right + rhs.right };
    }
};

/// The width and height of a `Rect`
pub fn Size(comptime T: type) type {
    return struct {
        const Self = @This();
        /// The element type
        pub const Inner = T;

        /// The x extent of the rectangle
        width: T,
        /// The y extent of the rectangle
        height: T,

        /// Component-wise addition (upstream `Add` impl; numeric `T` only)
        pub fn add(self: Self, rhs: Self) Self {
            return .{ .width = self.width + rhs.width, .height = self.height + rhs.height };
        }

        /// Component-wise subtraction (upstream `Sub` impl; numeric `T` only)
        pub fn sub(self: Self, rhs: Self) Self {
            return .{ .width = self.width - rhs.width, .height = self.height - rhs.height };
        }

        /// Get either the width or height depending on the AbsoluteAxis passed in
        pub fn getAbs(self: Self, axis: AbsoluteAxis) T {
            return switch (axis) {
                .horizontal => self.width,
                .vertical => self.height,
            };
        }

        /// Swap the width and height components
        pub fn transpose(self: Self) Self {
            return .{ .width = self.height, .height = self.width };
        }

        /// Applies the function `f` to both the width and height
        ///
        /// This is used to transform a `Size(T)` into a `Size(R)`.
        pub fn map(self: Self, comptime R: type, comptime f: fn (T) R) Size(R) {
            return .{ .width = f(self.width), .height = f(self.height) };
        }

        /// Applies the function `f` to the width
        pub fn mapWidth(self: Self, comptime f: fn (T) T) Self {
            return .{ .width = f(self.width), .height = self.height };
        }

        /// Applies the function `f` to the height
        pub fn mapHeight(self: Self, comptime f: fn (T) T) Self {
            return .{ .width = self.width, .height = f(self.height) };
        }

        /// Applies the function `f` to both the width and height
        /// of this value and another passed value
        pub fn zipMap(
            self: Self,
            comptime Other: type,
            other: Size(Other),
            comptime Ret: type,
            comptime f: fn (T, Other) Ret,
        ) Size(Ret) {
            return .{ .width = f(self.width, other.width), .height = f(self.height, other.height) };
        }

        /// Sets the extent of the main layout axis
        ///
        /// Whether this is the width or height depends on the `direction` provided
        pub fn setMain(self: *Self, direction: FlexDirection, value: T) void {
            if (direction.isRow()) {
                self.width = value;
            } else {
                self.height = value;
            }
        }

        /// Sets the extent of the cross layout axis
        ///
        /// Whether this is the width or height depends on the `direction` provided
        pub fn setCross(self: *Self, direction: FlexDirection, value: T) void {
            if (direction.isRow()) {
                self.height = value;
            } else {
                self.width = value;
            }
        }

        /// Creates a new value of type Self with the main axis set to value provided
        ///
        /// Whether this is the width or height depends on the `direction` provided
        pub fn withMain(self: Self, direction: FlexDirection, value: T) Self {
            var new_value = self;
            if (direction.isRow()) {
                new_value.width = value;
            } else {
                new_value.height = value;
            }
            return new_value;
        }

        /// Creates a new value of type Self with the cross axis set to value provided
        ///
        /// Whether this is the width or height depends on the `direction` provided
        pub fn withCross(self: Self, direction: FlexDirection, value: T) Self {
            var new_value = self;
            if (direction.isRow()) {
                new_value.height = value;
            } else {
                new_value.width = value;
            }
            return new_value;
        }

        /// Creates a new value of type Self with the main axis modified by the callback provided
        ///
        /// Whether this is the width or height depends on the `direction` provided
        pub fn mapMain(self: Self, direction: FlexDirection, comptime mapper: fn (T) T) Self {
            var new_value = self;
            if (direction.isRow()) {
                new_value.width = mapper(new_value.width);
            } else {
                new_value.height = mapper(new_value.height);
            }
            return new_value;
        }

        /// Creates a new value of type Self with the cross axis modified by the callback provided
        ///
        /// Whether this is the width or height depends on the `direction` provided
        pub fn mapCross(self: Self, direction: FlexDirection, comptime mapper: fn (T) T) Self {
            var new_value = self;
            if (direction.isRow()) {
                new_value.height = mapper(new_value.height);
            } else {
                new_value.width = mapper(new_value.width);
            }
            return new_value;
        }

        /// Gets the extent of the main layout axis
        ///
        /// Whether this is the width or height depends on the `direction` provided
        pub fn main(self: Self, direction: FlexDirection) T {
            return if (direction.isRow()) self.width else self.height;
        }

        /// Gets the extent of the cross layout axis
        ///
        /// Whether this is the width or height depends on the `direction` provided
        pub fn cross(self: Self, direction: FlexDirection) T {
            return if (direction.isRow()) self.height else self.width;
        }

        /// Gets the extent of the specified layout axis
        /// Whether this is the width or height depends on the `AbstractAxis` provided
        pub fn get(self: Self, axis: AbstractAxis) T {
            return switch (axis) {
                .@"inline" => self.width,
                .block => self.height,
            };
        }

        /// Sets the extent of the specified layout axis
        /// Whether this is the width or height depends on the `AbstractAxis` provided
        pub fn set(self: *Self, axis: AbstractAxis, value: T) void {
            switch (axis) {
                .@"inline" => self.width = value,
                .block => self.height = value,
            }
        }

        /// Returns a copy with the extent of the specified layout axis set
        /// Whether this is the width or height depends on the `AbstractAxis` provided
        pub fn with(self: Self, axis: AbstractAxis, value: T) Self {
            var new_value = self;
            switch (axis) {
                .@"inline" => new_value.width = value,
                .block => new_value.height = value,
            }
            return new_value;
        }

        /// Upstream `From<Point<T>> for Size<T>`
        pub fn fromPoint(value: Point(T)) Self {
            return .{ .width = value.x, .height = value.y };
        }

        // `Size<f32>` helpers

        /// Applies `@max` to each component separately (`Size(f32)` only)
        pub fn max(self: Self, rhs: Self) Self {
            return .{ .width = @max(self.width, rhs.width), .height = @max(self.height, rhs.height) };
        }

        /// Applies `@min` to each component separately (`Size(f32)` only)
        pub fn min(self: Self, rhs: Self) Self {
            return .{ .width = @min(self.width, rhs.width), .height = @min(self.height, rhs.height) };
        }

        /// Return true if both width and height are greater than 0 else false (`Size(f32)` only)
        pub fn hasNonZeroArea(self: Self) bool {
            return self.width > 0.0 and self.height > 0.0;
        }

        // `Size<Option<f32>>` helpers

        /// A `Size` with `null` width and height (`Size(?f32)` only)
        pub const none: Self = .{ .width = null, .height = null };

        /// A `Size(?f32)` with `width` and `height` as parameters (upstream `Size::<Option<f32>>::new`)
        pub fn new(width: f32, height: f32) Self {
            return .{ .width = width, .height = height };
        }

        /// Creates a new `Size(?f32)` with either the width or height set based on the provided `direction`
        pub fn fromCross(direction: FlexDirection, value: ?f32) Self {
            var new_value: Self = none;
            if (direction.isRow()) {
                new_value.height = value;
            } else {
                new_value.width = value;
            }
            return new_value;
        }

        /// Applies aspect_ratio (if one is supplied) to the Size (`Size(?f32)` only):
        ///   - If width is non-null but height is null, then height is computed from width and aspect_ratio
        ///   - If height is non-null but width is null, then width is computed from height and aspect_ratio
        ///
        /// If aspect_ratio is null then this function simply returns self.
        pub fn maybeApplyAspectRatio(self: Self, aspect_ratio: ?f32) Self {
            const ratio = aspect_ratio orelse return self;
            if (self.width) |width| {
                if (self.height == null) return .{ .width = width, .height = width / ratio };
            } else if (self.height) |height| {
                return .{ .width = height * ratio, .height = height };
            }
            return self;
        }

        // `Size<Option<T>>` helpers

        /// Performs `orelse` on each component separately (upstream `unwrap_or`; optional `T` only)
        pub fn unwrapOr(self: Self, alt: Size(OptionalChild(T))) Size(OptionalChild(T)) {
            return .{ .width = self.width orelse alt.width, .height = self.height orelse alt.height };
        }

        /// Performs Option::or on each component separately (optional `T` only)
        pub fn @"or"(self: Self, alt: Self) Self {
            return .{
                .width = if (self.width != null) self.width else alt.width,
                .height = if (self.height != null) self.height else alt.height,
            };
        }

        /// Return true if both components are non-null, else false. (optional `T` only)
        pub fn bothAxisDefined(self: Self) bool {
            return self.width != null and self.height != null;
        }

        // `Size<Dimension>` helpers

        /// Generates a `Size(Dimension)` using length values
        pub fn fromLengths(width: f32, height: f32) Self {
            return .{ .width = T.fromLength(width), .height = T.fromLength(height) };
        }

        /// Generates a `Size(Dimension)` using percentage values (upstream `Size::<Dimension>::from_percent`)
        pub fn fromPercents(width: f32, height: f32) Self {
            return .{ .width = T.fromPercent(width), .height = T.fromPercent(height) };
        }

        // `Size<AvailableSpace>` helpers

        /// Convert `Size(AvailableSpace)` into `Size(?f32)`
        pub fn intoOptions(self: Self) Size(?f32) {
            return .{ .width = self.width.intoOption(), .height = self.height.intoOption() };
        }

        /// If passed value is non-null then return `.definite` containing that value, else return self
        /// (`Size(AvailableSpace)` only)
        pub fn maybeSet(self: Self, value: Size(?f32)) Self {
            return .{ .width = self.width.maybeSet(value.width), .height = self.height.maybeSet(value.height) };
        }

        // style_helpers

        /// A Size where both components are the zero value of the contained type
        pub const zero: Self = both(elementZero(T));
        /// A Size where both components are the auto value of the contained type
        pub const auto: Self = both(elementAuto(T));
        /// A Size where both components are the min_content value of the contained type
        pub const min_content: Self = both(elementMinContent(T));
        /// A Size where both components are the max_content value of the contained type
        pub const max_content: Self = both(elementMaxContent(T));

        /// A Size with width and height set to the same `fit-content(…)` value with the given argument
        pub fn fitContent(argument: LengthPercentage) Self {
            return both(elementFitContent(T, argument));
        }
        /// A Size where both components are the same given absolute length (upstream `FromLength`)
        pub fn fromLength(value: anytype) Self {
            return both(elementLength(T, value));
        }
        /// A Size where both components are the same given percentage (upstream `FromPercent`)
        pub fn fromPercent(value: anytype) Self {
            return both(elementPercent(T, value));
        }

        fn both(value: T) Self {
            return .{ .width = value, .height = value };
        }
    };
}

/// The child type of an optional type
fn OptionalChild(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |info| info.child,
        else => @compileError("expected an optional type, found " ++ @typeName(T)),
    };
}

/// A 2-dimensional coordinate.
///
/// When used in association with a `Rect`, represents the top-left corner.
pub fn Point(comptime T: type) type {
    return struct {
        const Self = @This();
        /// The element type
        pub const Inner = T;

        /// The x-coordinate
        x: T,
        /// The y-coordinate
        y: T,

        /// A `Point` with values (null, null) (`Point(?f32)` only)
        pub const none: Self = .{ .x = null, .y = null };

        /// Component-wise addition (upstream `Add` impl; numeric `T` only)
        pub fn add(self: Self, rhs: Self) Self {
            return .{ .x = self.x + rhs.x, .y = self.y + rhs.y };
        }

        /// Applies the function `f` to both the x and y
        ///
        /// This is used to transform a `Point(T)` into a `Point(R)`.
        pub fn map(self: Self, comptime R: type, comptime f: fn (T) R) Point(R) {
            return .{ .x = f(self.x), .y = f(self.y) };
        }

        /// Gets the extent of the specified layout axis
        /// Whether this is the x or y depends on the `AbstractAxis` provided
        pub fn get(self: Self, axis: AbstractAxis) T {
            return switch (axis) {
                .@"inline" => self.x,
                .block => self.y,
            };
        }

        /// Swap x and y components
        pub fn transpose(self: Self) Self {
            return .{ .x = self.y, .y = self.x };
        }

        /// Sets the extent of the specified layout axis
        /// Whether this is the x or y depends on the `AbstractAxis` provided
        pub fn set(self: *Self, axis: AbstractAxis, value: T) void {
            switch (axis) {
                .@"inline" => self.x = value,
                .block => self.y = value,
            }
        }

        /// Gets the component in the main layout axis
        ///
        /// Whether this is the x or y depends on the `direction` provided
        pub fn main(self: Self, direction: FlexDirection) T {
            return if (direction.isRow()) self.x else self.y;
        }

        /// Gets the component in the cross layout axis
        ///
        /// Whether this is the x or y depends on the `direction` provided
        pub fn cross(self: Self, direction: FlexDirection) T {
            return if (direction.isRow()) self.y else self.x;
        }

        // style_helpers

        /// A Point where both x and y are the zero value of the contained type (`Point(f32)`: the origin)
        pub const zero: Self = both(elementZero(T));
        /// A Point where both x and y are the auto value of the contained type
        pub const auto: Self = both(elementAuto(T));
        /// A Point where both x and y are the min_content value of the contained type
        pub const min_content: Self = both(elementMinContent(T));
        /// A Point where both x and y are the max_content value of the contained type
        pub const max_content: Self = both(elementMaxContent(T));

        /// A Point with x and y set to the same `fit-content(…)` value with the given argument
        pub fn fitContent(argument: LengthPercentage) Self {
            return both(elementFitContent(T, argument));
        }
        /// A Point where x and y are the same given absolute length (upstream `FromLength`)
        pub fn fromLength(value: anytype) Self {
            return both(elementLength(T, value));
        }
        /// A Point where x and y are the same given percentage (upstream `FromPercent`)
        pub fn fromPercent(value: anytype) Self {
            return both(elementPercent(T, value));
        }

        fn both(value: T) Self {
            return .{ .x = value, .y = value };
        }
    };
}

/// Generic struct which holds a "min" value and a "max" value
pub fn MinMax(comptime Min: type, comptime Max: type) type {
    return struct {
        /// The value representing the minimum
        min: Min,
        /// The value representing the maximum
        max: Max,
    };
}

/// Returns true if `T` is an instantiation of `Size`
pub fn isSize(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Inner") and T == Size(T.Inner);
}

/// Returns true if `T` is an instantiation of `Rect`
pub fn isRect(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Inner") and T == Rect(T.Inner);
}

const testing = std.testing;

// Element-wise constructors. `f32` and optionals have no declarations of their own, so they are
// handled here: `elementZero(f32)` is `0.0` and an optional forwards to its child type.

/// Returns the zero value for that type
fn elementZero(comptime T: type) T {
    if (T == f32) {
        return 0.0;
    } else if (@typeInfo(T) == .optional) {
        return elementZero(@typeInfo(T).optional.child);
    } else {
        return T.zero;
    }
}

/// Returns the auto value for that type
fn elementAuto(comptime T: type) T {
    if (@typeInfo(T) == .optional) {
        return elementAuto(@typeInfo(T).optional.child);
    } else {
        return @as(T, .auto);
    }
}

/// Returns the min-content value for that type
fn elementMinContent(comptime T: type) T {
    if (@typeInfo(T) == .optional) {
        return elementMinContent(@typeInfo(T).optional.child);
    } else {
        return @as(T, .min_content);
    }
}

/// Returns the max-content value for that type
fn elementMaxContent(comptime T: type) T {
    if (@typeInfo(T) == .optional) {
        return elementMaxContent(@typeInfo(T).optional.child);
    } else {
        return @as(T, .max_content);
    }
}

/// Returns a value of the requested type which represent a `fit-content(…)` value
/// with the given argument.
fn elementFitContent(comptime T: type, argument: LengthPercentage) T {
    return T.fitContent(argument);
}

/// Returns a value of the requested type which represent an absolute length
fn elementLength(comptime T: type, value: anytype) T {
    if (T == f32 or T == ?f32) {
        return toF32(value);
    } else {
        return T.fromLength(value);
    }
}

/// Returns a value of the requested type which represent a percentage
fn elementPercent(comptime T: type, value: anytype) T {
    if (T == f32 or T == ?f32) {
        return toF32(value);
    } else {
        return T.fromPercent(value);
    }
}

test "AbsoluteAxis and AbstractAxis" {
    try testing.expectEqual(AbsoluteAxis.vertical, AbsoluteAxis.horizontal.otherAxis());
    try testing.expectEqual(AbsoluteAxis.horizontal, AbsoluteAxis.vertical.otherAxis());
    try testing.expectEqual(AbstractAxis.block, AbstractAxis.@"inline".other());
    try testing.expectEqual(AbsoluteAxis.horizontal, AbstractAxis.@"inline".asAbsNaive());
    try testing.expectEqual(AbsoluteAxis.vertical, AbstractAxis.block.asAbsNaive());
    const both: InBothAbsAxis(u8) = .{ .horizontal = 1, .vertical = 2 };
    try testing.expectEqual(@as(u8, 2), both.get(.vertical));
}

test "Rect helpers" {
    const r = Rect(f32).new(1, 2, 3, 4);
    try testing.expectEqual(@as(f32, 3), r.horizontalAxisSum());
    try testing.expectEqual(@as(f32, 7), r.verticalAxisSum());
    try testing.expectEqual(Size(f32){ .width = 3, .height = 7 }, r.sumAxes());
    try testing.expectEqual(@as(f32, 7), r.gridAxisSum(.vertical));
    try testing.expectEqual(@as(f32, 3), r.mainAxisSum(.row));
    try testing.expectEqual(@as(f32, 3), r.crossAxisSum(.column_reverse));
    try testing.expectEqual(@as(f32, 1), r.mainStart(.row));
    try testing.expectEqual(@as(f32, 4), r.mainEnd(.column));
    try testing.expectEqual(@as(f32, 3), r.crossStart(.row_reverse));
    try testing.expectEqual(@as(f32, 2), r.crossEnd(.column));
    try testing.expectEqual(Rect(f32).new(3, 4, 1, 2), r.transpose());
    try testing.expectEqual(Rect(f32).new(2, 4, 6, 8), r.add(r));
    try testing.expectEqual(Line(f32){ .start = 1, .end = 2 }, r.horizontalComponents());
    try testing.expectEqual(Line(f32){ .start = 3, .end = 4 }, r.verticalComponents());
    try testing.expectEqual(Rect(f32).new(0, 5, 3, 6), r.@"union"(Rect(f32).new(0, 5, 4, 6)));
    try testing.expectEqual(Rect(f32).new(0, 0, 0, 0), Rect(f32).zero);
    try testing.expectEqual(Rect(?f32){ .left = null, .right = null, .top = null, .bottom = null }, Rect(?f32).none);
    const double = struct {
        fn f(x: f32) f32 {
            return x * 2;
        }
    }.f;
    try testing.expectEqual(Rect(f32).new(2, 4, 6, 8), r.map(f32, double));
    const mul = struct {
        fn f(a: f32, b: f32) f32 {
            return a * b;
        }
    }.f;
    try testing.expectEqual(Rect(f32).new(10, 20, 60, 80), r.zipSize(f32, .{ .width = 10, .height = 20 }, f32, mul));
}

test "Line helpers" {
    try testing.expectEqual(Line(bool){ .start = true, .end = true }, Line(bool).true);
    try testing.expectEqual(Line(bool){ .start = false, .end = false }, Line(bool).false);
    const l: Line(f32) = .{ .start = 1, .end = 2 };
    try testing.expectEqual(@as(f32, 3), l.sum());
    try testing.expectEqual(Line(f32){ .start = 0, .end = 0 }, Line(f32).zero);
    try testing.expectEqual(Line(?f32){ .start = 5, .end = 5 }, Line(?f32).fromLength(5));
}

test "FloatInsets" {
    const a = FloatInsets.new(1, 5);
    const b = FloatInsets.new(3, 2);
    try testing.expectEqual(@as(f32, 6), a.sum());
    try testing.expectEqual(FloatInsets.new(3, 5), a.max(b));
    try testing.expectEqual(FloatInsets.new(4, 7), a.add(b));
    try testing.expectEqual(FloatInsets.new(0, 0), FloatInsets.zero);
}

test "Size helpers" {
    var s: Size(f32) = .{ .width = 1, .height = 2 };
    try testing.expectEqual(@as(f32, 1), s.main(.row));
    try testing.expectEqual(@as(f32, 1), s.cross(.column));
    try testing.expectEqual(@as(f32, 2), s.get(.block));
    try testing.expectEqual(@as(f32, 2), s.getAbs(.vertical));
    try testing.expectEqual(Size(f32){ .width = 2, .height = 1 }, s.transpose());
    try testing.expectEqual(Size(f32){ .width = 1, .height = 9 }, s.withMain(.column, 9));
    try testing.expectEqual(Size(f32){ .width = 9, .height = 2 }, s.withCross(.column_reverse, 9));
    try testing.expectEqual(Size(f32){ .width = 9, .height = 2 }, s.with(.@"inline", 9));
    s.setMain(.row, 5);
    s.setCross(.row, 6);
    try testing.expectEqual(Size(f32){ .width = 5, .height = 6 }, s);
    s.set(.block, 7);
    try testing.expectEqual(@as(f32, 7), s.height);
    const neg = struct {
        fn f(x: f32) f32 {
            return -x;
        }
    }.f;
    try testing.expectEqual(Size(f32){ .width = -5, .height = 7 }, s.mapMain(.row, neg));
    try testing.expectEqual(Size(f32){ .width = 5, .height = -7 }, s.mapCross(.row, neg));
    try testing.expectEqual(Size(f32){ .width = -5, .height = 7 }, s.mapWidth(neg));
    try testing.expectEqual(Size(f32){ .width = 5, .height = -7 }, s.mapHeight(neg));
    try testing.expectEqual(Size(f32){ .width = -5, .height = -7 }, s.map(f32, neg));
    try testing.expectEqual(Size(f32){ .width = 10, .height = 14 }, s.add(s));
    try testing.expectEqual(Size(f32){ .width = 0, .height = 0 }, s.sub(s));
    try testing.expectEqual(Size(f32){ .width = 5, .height = 1 }, s.min(.{ .width = 9, .height = 1 }));
    try testing.expectEqual(Size(f32){ .width = 9, .height = 7 }, s.max(.{ .width = 9, .height = 1 }));
    try testing.expect(s.hasNonZeroArea());
    try testing.expect(!Size(f32).zero.hasNonZeroArea());
    const add = struct {
        fn f(a: f32, b: ?f32) f32 {
            return a + (b orelse 0);
        }
    }.f;
    try testing.expectEqual(Size(f32){ .width = 6, .height = 7 }, s.zipMap(?f32, .{ .width = 1, .height = null }, f32, add));
    try testing.expectEqual(Size(f32){ .width = 3, .height = 4 }, Size(f32).fromPoint(.{ .x = 3, .y = 4 }));
}

test "Size(?f32) helpers" {
    const none = Size(?f32).none;
    try testing.expectEqual(Size(?f32){ .width = null, .height = null }, none);
    try testing.expectEqual(Size(?f32){ .width = 1, .height = 2 }, Size(?f32).new(1, 2));
    try testing.expectEqual(Size(?f32){ .width = null, .height = 3 }, Size(?f32).fromCross(.row, 3));
    try testing.expectEqual(Size(?f32){ .width = 3, .height = null }, Size(?f32).fromCross(.column, 3));
    try testing.expectEqual(Size(?f32){ .width = 10, .height = 5 }, (Size(?f32){ .width = 10, .height = null }).maybeApplyAspectRatio(2));
    try testing.expectEqual(Size(?f32){ .width = 10, .height = 5 }, (Size(?f32){ .width = null, .height = 5 }).maybeApplyAspectRatio(2));
    try testing.expectEqual(Size(?f32){ .width = 1, .height = 1 }, (Size(?f32){ .width = 1, .height = 1 }).maybeApplyAspectRatio(2));
    try testing.expectEqual(none, none.maybeApplyAspectRatio(2));
    try testing.expectEqual(Size(?f32){ .width = 10, .height = null }, (Size(?f32){ .width = 10, .height = null }).maybeApplyAspectRatio(null));
    try testing.expectEqual(Size(f32){ .width = 1, .height = 9 }, (Size(?f32){ .width = 1, .height = null }).unwrapOr(.{ .width = 8, .height = 9 }));
    try testing.expectEqual(Size(?f32){ .width = 1, .height = 9 }, (Size(?f32){ .width = 1, .height = null }).@"or"(.{ .width = 8, .height = 9 }));
    try testing.expect(Size(?f32).new(1, 2).bothAxisDefined());
    try testing.expect(!(Size(?f32){ .width = 1, .height = null }).bothAxisDefined());
    try testing.expectEqual(Size(?f32){ .width = 0, .height = 0 }, Size(?f32).zero);
}

test "Point helpers" {
    var p: Point(f32) = .{ .x = 1, .y = 2 };
    try testing.expectEqual(Point(f32){ .x = 0, .y = 0 }, Point(f32).zero);
    try testing.expectEqual(Point(?f32){ .x = null, .y = null }, Point(?f32).none);
    try testing.expectEqual(Point(f32){ .x = 2, .y = 4 }, p.add(p));
    try testing.expectEqual(Point(f32){ .x = 2, .y = 1 }, p.transpose());
    try testing.expectEqual(@as(f32, 2), p.get(.block));
    try testing.expectEqual(@as(f32, 1), p.main(.row));
    try testing.expectEqual(@as(f32, 1), p.cross(.column));
    p.set(.@"inline", 5);
    try testing.expectEqual(@as(f32, 5), p.x);
    const neg = struct {
        fn f(x: f32) f32 {
            return -x;
        }
    }.f;
    try testing.expectEqual(Point(f32){ .x = -5, .y = -2 }, p.map(f32, neg));
}

test "isSize and isRect" {
    try testing.expect(isSize(Size(f32)));
    try testing.expect(!isSize(Rect(f32)));
    try testing.expect(isRect(Rect(?f32)));
    try testing.expect(!isRect(f32));
}

test "style helper declarations on generic geometry types" {
    const dimension = @import("style/dimension.zig");
    const Dimension = dimension.Dimension;
    const lp = LengthPercentage.fromLength(10);
    const TrackSizingFunction = @import("style/grid.zig").TrackSizingFunction;
    const expected = TrackSizingFunction.fitContent(lp);
    try testing.expect(Size(TrackSizingFunction).fitContent(lp).height.eql(expected));
    try testing.expect(Rect(TrackSizingFunction).fitContent(lp).bottom.eql(expected));
    try testing.expect(Point(TrackSizingFunction).fitContent(lp).y.eql(expected));
    try testing.expect(std.meta.eql(Size(Dimension).fromPercent(0.5).width, Dimension.fromPercent(0.5)));
    try testing.expect(std.meta.eql(Point(Dimension).fromPercent(0.5).x, Dimension.fromPercent(0.5)));
    try testing.expect(std.meta.eql(Line(Dimension).fromPercent(0.5).end, Dimension.fromPercent(0.5)));
    try testing.expect(std.meta.eql(Rect(Dimension).fromLength(2).left, Dimension.fromLength(2)));
    try testing.expect(std.meta.eql(Line(Dimension).fromLength(2).start, Dimension.fromLength(2)));
    try testing.expect(Size(Dimension).min_content.width == .min_content);
    try testing.expect(Size(Dimension).max_content.height == .max_content);
    try testing.expect(Rect(Dimension).min_content.top == .min_content);
    try testing.expect(Rect(Dimension).max_content.right == .max_content);
    try testing.expect(Line(Dimension).max_content.start == .max_content);
    try testing.expect(Line(Dimension).auto.end == .auto);
    try testing.expect(Point(Dimension).auto.y == .auto);
    try testing.expect(Point(Dimension).min_content.x == .min_content);
    try testing.expect(std.meta.eql(Size(Dimension).zero.width, Dimension.zero));
    try testing.expect(Rect(Dimension).auto.left == .auto);
    const neg = struct {
        fn f(x: f32) f32 {
            return -x;
        }
    }.f;
    try testing.expectEqual(Line(f32){ .start = -1, .end = -2 }, (Line(f32){ .start = 1, .end = 2 }).map(f32, neg));
}
