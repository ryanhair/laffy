//! The C ABI of laffy: a thin layer of `export fn laffy_*` functions over `TaffyTree`.
//!
//! The matching header is `include/laffy.h`; keep the two in sync (type layouts, enum values and
//! function signatures). The header is the user-facing documentation; comments here describe the
//! implementation.
//!
//! # Design
//!
//!   - A `LaffyTree *` is an opaque handle to a heap-allocated `TreeImpl`, which owns a
//!     `TaffyTree(NodeContext)` and the allocator it uses.
//!   - Node ids cross the boundary as `uint64_t` (`NodeId.inner`). Every id is validated with
//!     `TaffyTree.containsNode` before it reaches a `TaffyTree` method (those panic on stale ids),
//!     and the tree-shape invariants that `TaffyTree` relies on are checked up front: a node has
//!     at most one parent and appears at most once in its parent's child list, and the parent
//!     links contain no cycle. Violations are reported as a `LaffyStatus`.
//!   - Enum values arrive as `c_int` and are range-checked (an out-of-range value is
//!     `LAFFY_STATUS_INVALID_ARGUMENT`, never `@enumFromInt` undefined behaviour).
//!   - `Style` borrows its grid track lists and names. Every grid property set from C is deep-copied
//!     into an arena owned by the node (one arena per property, see `OwnedGrid`). Replacing the
//!     property frees the previous arena; removing the node, clearing the tree, resetting the style
//!     and freeing the tree free all of them.
//!   - Leaf nodes are measured by `CMeasurer`, which calls the node's C measure function (if any)
//!     through `computeLeafLayout`, as upstream's `TaffyTree` measure-function examples do.
//!   - `calc()` values are not exposed: the built-in tree resolves every `calc()` to zero.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const laffy = @import("root.zig");
const NodeId = laffy.NodeId;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const Line = laffy.Line;
const Point = laffy.Point;
const Layout = laffy.Layout;
const LayoutInput = laffy.LayoutInput;
const LayoutOutput = laffy.LayoutOutput;
const AvailableSpace = laffy.AvailableSpace;
const Dimension = laffy.Dimension;
const LengthPercentage = laffy.LengthPercentage;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const MinTrackSizingFunction = laffy.MinTrackSizingFunction;
const MaxTrackSizingFunction = laffy.MaxTrackSizingFunction;
const TrackSizingFunction = laffy.TrackSizingFunction;
const GridTemplateComponent = laffy.GridTemplateComponent;
const GridTemplateArea = laffy.GridTemplateArea;
const GridPlacement = laffy.GridPlacement;
const AlignItems = laffy.AlignItems;
const AlignContent = laffy.AlignContent;

/// The version of the C ABI (`LAFFY_ABI_VERSION` in the header). Bump it on any incompatible
/// change to a type layout, an enum value or a function signature.
pub const abi_version: u32 = 1;

// ---------------------------------------------------------------------------------------------
// Status codes

/// Result of every fallible C API function (`LaffyStatus`)
pub const LaffyStatus = enum(c_int) {
    ok = 0,
    out_of_memory = 1,
    invalid_argument = 2,
    invalid_input_node = 3,
    invalid_parent_node = 4,
    invalid_child_node = 5,
    child_index_out_of_bounds = 6,
    not_a_child = 7,
    child_has_parent = 8,
    would_create_cycle = 9,
};

/// Internal error set; each error maps 1:1 to a `LaffyStatus`
const CError = error{
    OutOfMemory,
    InvalidArgument,
    InvalidInputNode,
    InvalidParentNode,
    InvalidChildNode,
    ChildIndexOutOfBounds,
    NotAChild,
    ChildHasParent,
    WouldCreateCycle,
};

fn toStatus(result: CError!void) LaffyStatus {
    result catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidArgument => .invalid_argument,
        error.InvalidInputNode => .invalid_input_node,
        error.InvalidParentNode => .invalid_parent_node,
        error.InvalidChildNode => .invalid_child_node,
        error.ChildIndexOutOfBounds => .child_index_out_of_bounds,
        error.NotAChild => .not_a_child,
        error.ChildHasParent => .child_has_parent,
        error.WouldCreateCycle => .would_create_cycle,
    };
    return .ok;
}

// ---------------------------------------------------------------------------------------------
// C value types (must match include/laffy.h)

/// `LaffyUnit`: the unit of a `{unit, value}` style value
pub const LaffyUnit = enum(c_int) {
    length = 0,
    percent = 1,
    auto = 2,
    min_content = 3,
    max_content = 4,
    fit_content_length = 5,
    fit_content_percent = 6,
    fit_content = 7,
    stretch = 8,
    content = 9,
    fr = 10,
};

pub const LaffyLengthPercentage = extern struct { unit: c_int, value: f32 };
pub const LaffyLengthPercentageAuto = extern struct { unit: c_int, value: f32 };
pub const LaffyDimension = extern struct { unit: c_int, value: f32 };
pub const LaffyMinTrackSizing = extern struct { unit: c_int, value: f32 };
pub const LaffyMaxTrackSizing = extern struct { unit: c_int, value: f32 };
pub const LaffyTrackSizingFunction = extern struct { min: LaffyMinTrackSizing, max: LaffyMaxTrackSizing };

pub const LaffyAvailableSpaceTag = enum(c_int) { definite = 0, min_content = 1, max_content = 2 };
pub const LaffyAvailableSpace = extern struct { tag: c_int, value: f32 };

pub const LaffyPoint = extern struct { x: f32, y: f32 };
pub const LaffySize = extern struct { width: f32, height: f32 };
pub const LaffyRect = extern struct { top: f32, right: f32, bottom: f32, left: f32 };

pub const LaffyLayout = extern struct {
    order: u32,
    location: LaffyPoint,
    size: LaffySize,
    scrollable_overflow: LaffyRect,
    scrollable_overflow_reversed_x: bool,
    scrollable_overflow_reversed_y: bool,
    scroll_width: f32,
    scroll_height: f32,
    scrollbar_size: LaffySize,
    border: LaffyRect,
    padding: LaffyRect,
    margin: LaffyRect,
};

pub const LaffyDisplay = enum(c_int) { block = 0, flow_root = 1, flex = 2, grid = 3, none = 4 };
pub const LaffyPosition = enum(c_int) { static = 0, relative = 1, absolute = 2, fixed = 3, sticky = 4 };
pub const LaffyBoxSizing = enum(c_int) { border_box = 0, content_box = 1 };
pub const LaffyDirection = enum(c_int) { ltr = 0, rtl = 1 };
pub const LaffyOverflow = enum(c_int) { visible = 0, clip = 1, hidden = 2, scroll = 3 };
pub const LaffyFloat = enum(c_int) { left = 0, right = 1, none = 2 };
pub const LaffyClear = enum(c_int) { left = 0, right = 1, both = 2, none = 3 };
pub const LaffyTextAlign = enum(c_int) { auto = 0, legacy_left = 1, legacy_right = 2, legacy_center = 3 };
pub const LaffyFlexDirection = enum(c_int) { row = 0, column = 1, row_reverse = 2, column_reverse = 3 };
pub const LaffyFlexWrap = enum(c_int) { no_wrap = 0, wrap = 1, wrap_reverse = 2, balance = 3, balance_reverse = 4 };
pub const LaffyGridAutoFlow = enum(c_int) { row = 0, column = 1, row_dense = 2, column_dense = 3 };
pub const LaffyAlignItems = enum(c_int) {
    normal = 0,
    start = 1,
    end = 2,
    flex_start = 3,
    flex_end = 4,
    self_start = 5,
    self_end = 6,
    center = 7,
    baseline = 8,
    stretch = 9,
    /// Only for align-self / justify-self: unset (inherit the parent's align-items / justify-items)
    auto = 10,
};
pub const LaffyAlignContent = enum(c_int) {
    normal = 0,
    start = 1,
    end = 2,
    flex_start = 3,
    flex_end = 4,
    center = 5,
    stretch = 6,
    space_between = 7,
    space_evenly = 8,
    space_around = 9,
};
pub const LaffyAlignmentSafety = enum(c_int) { default = 0, unsafe = 1, safe = 2 };

pub const contain_layout: u32 = 1;
pub const contain_paint: u32 = 2;

pub const LaffyGridTemplateComponentKind = enum(c_int) { single = 0, repeat = 1 };
pub const LaffyRepetitionKind = enum(c_int) { count = 0, auto_fill = 1, auto_fit = 2 };
pub const LaffyGridPlacementKind = enum(c_int) { auto = 0, line = 1, span = 2, named_line = 3, named_span = 4 };

pub const LaffyLineNameSet = extern struct {
    names: ?[*]const ?[*:0]const u8,
    count: usize,
};

pub const LaffyGridTemplateComponent = extern struct {
    kind: c_int,
    track: LaffyTrackSizingFunction,
    repetition_kind: c_int,
    repetition_count: u16,
    repeat_tracks: ?[*]const LaffyTrackSizingFunction,
    repeat_track_count: usize,
    repeat_line_names: ?[*]const LaffyLineNameSet,
    repeat_line_name_count: usize,
};

pub const LaffyGridTemplateArea = extern struct {
    name: ?[*:0]const u8,
    row_start: u16,
    row_end: u16,
    column_start: u16,
    column_end: u16,
};

pub const LaffyGridPlacement = extern struct {
    kind: c_int,
    line: i16,
    span: u16,
    name: ?[*:0]const u8,
};

pub const LaffyMeasureFunc = *const fn (
    user_data: ?*anyopaque,
    node: u64,
    known_width: f32,
    known_height: f32,
    available_width: LaffyAvailableSpace,
    available_height: LaffyAvailableSpace,
) callconv(.c) LaffySize;

pub const LaffyAllocator = extern struct {
    user_data: ?*anyopaque,
    alloc: ?*const fn (user_data: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque,
    free: ?*const fn (user_data: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void,
};

/// The opaque tree handle seen by C (`LaffyTree`)
pub const LaffyTree = opaque {};

// ---------------------------------------------------------------------------------------------
// Tree implementation

/// Per-node data stored as the `TaffyTree` node context
const NodeContext = struct {
    /// Opaque user pointer, passed to the measure function
    user_data: ?*anyopaque = null,
    /// Leaf measure function
    measure: ?LaffyMeasureFunc = null,
    /// Owned copies of the node's grid style data (null until a grid property is set)
    grid: ?*OwnedGrid = null,
};

const Tree = laffy.TaffyTree(NodeContext);

/// The grid style properties whose data the C layer owns
const GridProp = enum { template_rows, template_columns, auto_rows, auto_columns, template_areas, row, column };

/// Owned storage for a node's grid style data: one arena per property, so that replacing a
/// property frees exactly the data it referenced. Linked into `TreeImpl.grids` so that the whole
/// tree's grid data can be freed without walking the node storage.
const OwnedGrid = struct {
    arenas: std.EnumArray(GridProp, ArenaAllocator.State) = .initFill(.init),
    prev: ?*OwnedGrid = null,
    next: ?*OwnedGrid = null,
};

const TreeImpl = struct {
    tree: Tree,
    /// The allocator for the tree, its grid data and this struct
    gpa: Allocator,
    /// The user's allocator when created with `laffy_tree_new_with_allocator` (`gpa` points here)
    c_alloc: LaffyAllocator,
    uses_c_alloc: bool,
    /// All `OwnedGrid`s of this tree
    grids: ?*OwnedGrid = null,

    fn ownedGrid(self: *TreeImpl, ctx: *NodeContext) Allocator.Error!*OwnedGrid {
        if (ctx.grid) |grid| return grid;
        const grid = try self.gpa.create(OwnedGrid);
        grid.* = .{ .next = self.grids };
        if (self.grids) |head| head.prev = grid;
        self.grids = grid;
        ctx.grid = grid;
        return grid;
    }

    fn freeGrid(self: *TreeImpl, grid: *OwnedGrid) void {
        for (&grid.arenas.values) |state| state.promote(self.gpa).deinit();
        if (grid.prev) |prev| prev.next = grid.next else self.grids = grid.next;
        if (grid.next) |next| next.prev = grid.prev;
        self.gpa.destroy(grid);
    }

    fn freeAllGrids(self: *TreeImpl) void {
        while (self.grids) |grid| self.freeGrid(grid);
    }

    /// Replace the arena of one grid property, freeing the previous one
    fn swapArena(self: *TreeImpl, grid: *OwnedGrid, prop: GridProp, new_state: ArenaAllocator.State) void {
        const old = grid.arenas.get(prop);
        grid.arenas.set(prop, new_state);
        old.promote(self.gpa).deinit();
    }

    fn context(self: *TreeImpl, node: NodeId) *NodeContext {
        // Every node created through the C API has a context
        return self.tree.getNodeContextMut(node).?;
    }

    fn deinit(self: *TreeImpl) void {
        self.freeAllGrids();
        self.tree.deinit();
    }
};

fn implOf(tree: ?*LaffyTree) CError!*TreeImpl {
    const t = tree orelse return error.InvalidArgument;
    return @ptrCast(@alignCast(t));
}

/// Adapter from a C `LaffyAllocator` to a Zig `Allocator`
const c_allocator_vtable: Allocator.VTable = .{
    .alloc = cAlloc,
    .resize = Allocator.noResize,
    .remap = Allocator.noRemap,
    .free = cFree,
};

fn cAllocatorInterface(c_alloc: *LaffyAllocator) Allocator {
    return .{ .ptr = c_alloc, .vtable = &c_allocator_vtable };
}

fn cAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    const c_alloc: *LaffyAllocator = @ptrCast(@alignCast(ctx));
    const ptr = c_alloc.alloc.?(c_alloc.user_data, len, alignment.toByteUnits()) orelse return null;
    const addr = @intFromPtr(ptr);
    if (!alignment.check(addr)) {
        // A misaligned block would be undefined behaviour in Zig; report it as allocation failure
        c_alloc.free.?(c_alloc.user_data, ptr, len, alignment.toByteUnits());
        return null;
    }
    return @ptrCast(ptr);
}

fn cFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ret_addr;
    const c_alloc: *LaffyAllocator = @ptrCast(@alignCast(ctx));
    c_alloc.free.?(c_alloc.user_data, memory.ptr, memory.len, alignment.toByteUnits());
}

/// The allocator of `laffy_tree_new`: the C allocator when libc is linked (always the case for
/// the installed libraries)
const default_allocator: Allocator = if (builtin.link_libc) std.heap.c_allocator else std.heap.page_allocator;

/// Create a tree that allocates with the Zig allocator `gpa` (used by `laffy_tree_new` and by tests)
fn createTree(gpa: Allocator) Allocator.Error!*TreeImpl {
    const impl = try gpa.create(TreeImpl);
    errdefer gpa.destroy(impl);
    impl.* = .{
        .tree = try Tree.init(gpa),
        .gpa = gpa,
        .c_alloc = .{ .user_data = null, .alloc = null, .free = null },
        .uses_c_alloc = false,
    };
    return impl;
}

fn createTreeWithCAllocator(c_alloc: LaffyAllocator) Allocator.Error!*TreeImpl {
    var tmp = c_alloc;
    const tmp_gpa = cAllocatorInterface(&tmp);
    const impl = try tmp_gpa.create(TreeImpl);
    errdefer tmp_gpa.destroy(impl);
    impl.c_alloc = c_alloc;
    impl.uses_c_alloc = true;
    impl.gpa = cAllocatorInterface(&impl.c_alloc);
    impl.grids = null;
    impl.tree = try Tree.init(impl.gpa);
    return impl;
}

fn destroyTree(impl: *TreeImpl) void {
    impl.deinit();
    if (impl.uses_c_alloc) {
        var c_alloc = impl.c_alloc;
        cAllocatorInterface(&c_alloc).destroy(impl);
    } else {
        impl.gpa.destroy(impl);
    }
}

fn treeHandle(impl: *TreeImpl) *LaffyTree {
    return @ptrCast(impl);
}

// ---------------------------------------------------------------------------------------------
// Validation helpers

fn enumFromC(comptime E: type, raw: c_int) CError!E {
    return std.enums.fromInt(E, raw) orelse error.InvalidArgument;
}

/// Map a C enum onto the laffy enum with the same tag names
fn mapEnum(comptime Target: type, comptime Source: type, raw: c_int) CError!Target {
    return switch (try enumFromC(Source, raw)) {
        inline else => |tag| @field(Target, @tagName(tag)),
    };
}

fn checkNode(impl: *TreeImpl, id: u64, comptime err: CError) CError!NodeId {
    const node: NodeId = .{ .inner = id };
    if (!impl.tree.containsNode(node)) return err;
    return node;
}

fn number(value: f32) CError!f32 {
    if (std.math.isNan(value)) return error.InvalidArgument;
    return value;
}

fn toTrack(v: LaffyTrackSizingFunction) CError!TrackSizingFunction {
    return .{
        .min = try UnitCodec(LaffyMinTrackSizing, MinTrackSizingFunction).decode(v.min),
        .max = try UnitCodec(LaffyMaxTrackSizing, MaxTrackSizingFunction).decode(v.max),
    };
}

fn toAvailableSpace(v: LaffyAvailableSpace) CError!AvailableSpace {
    return switch (try enumFromC(LaffyAvailableSpaceTag, v.tag)) {
        .definite => .{ .definite = try number(v.value) },
        .min_content => .min_content,
        .max_content => .max_content,
    };
}

fn fromAvailableSpace(v: AvailableSpace) LaffyAvailableSpace {
    return switch (v) {
        .definite => |value| .{ .tag = @backingInt(LaffyAvailableSpaceTag.definite), .value = value },
        .min_content => .{ .tag = @backingInt(LaffyAvailableSpaceTag.min_content), .value = 0 },
        .max_content => .{ .tag = @backingInt(LaffyAvailableSpaceTag.max_content), .value = 0 },
    };
}

fn toAlignItems(keyword: c_int, safety: c_int) CError!AlignItems {
    const kw = try enumFromC(LaffyAlignItems, keyword);
    if (kw == .auto) return error.InvalidArgument;
    return .{
        .keyword = switch (kw) {
            .auto => unreachable,
            inline else => |tag| @field(laffy.AlignItemsKeyword, @tagName(tag)),
        },
        .safety = try mapEnum(laffy.AlignmentSafety, LaffyAlignmentSafety, safety),
    };
}

fn toAlignSelf(keyword: c_int, safety: c_int) CError!?AlignItems {
    if (keyword == @backingInt(LaffyAlignItems.auto)) {
        _ = try enumFromC(LaffyAlignmentSafety, safety);
        return null;
    }
    return try toAlignItems(keyword, safety);
}

fn toAlignContent(keyword: c_int, safety: c_int) CError!AlignContent {
    return .{
        .keyword = try mapEnum(laffy.AlignContentKeyword, LaffyAlignContent, keyword),
        .safety = try mapEnum(laffy.AlignmentSafety, LaffyAlignmentSafety, safety),
    };
}

/// A C array argument as a slice (`ptr` may only be NULL when `len` is 0)
fn cSlice(comptime T: type, ptr: ?[*]const T, len: usize) CError![]const T {
    if (len == 0) return &.{};
    const p = ptr orelse return error.InvalidArgument;
    return p[0..len];
}

/// Copy a C string. The copy keeps its NUL terminator so that getters can hand it back to C.
fn dupeName(arena: Allocator, name: ?[*:0]const u8) CError![]const u8 {
    const n = name orelse return error.InvalidArgument;
    return try arena.dupeSentinel(u8, std.mem.span(n), 0);
}

fn dupeLineNameSets(arena: Allocator, sets: []const LaffyLineNameSet) CError![]const []const []const u8 {
    const out = try arena.alloc([]const []const u8, sets.len);
    for (sets, out) |set, *dst| {
        const names = try cSlice(?[*:0]const u8, set.names, set.count);
        const copied = try arena.alloc([]const u8, names.len);
        for (names, copied) |name, *name_dst| name_dst.* = try dupeName(arena, name);
        dst.* = copied;
    }
    return out;
}

fn dupeTracks(arena: Allocator, tracks: []const LaffyTrackSizingFunction) CError![]const TrackSizingFunction {
    const out = try arena.alloc(TrackSizingFunction, tracks.len);
    for (tracks, out) |track, *dst| dst.* = try toTrack(track);
    return out;
}

fn dupeTemplate(arena: Allocator, components: []const LaffyGridTemplateComponent) CError![]const GridTemplateComponent {
    const out = try arena.alloc(GridTemplateComponent, components.len);
    for (components, out) |component, *dst| {
        dst.* = switch (try enumFromC(LaffyGridTemplateComponentKind, component.kind)) {
            .single => .{ .single = try toTrack(component.track) },
            .repeat => blk: {
                const count: laffy.RepetitionCount = switch (try enumFromC(LaffyRepetitionKind, component.repetition_kind)) {
                    .count => if (component.repetition_count == 0) return error.InvalidArgument else .{ .count = component.repetition_count },
                    .auto_fill => .auto_fill,
                    .auto_fit => .auto_fit,
                };
                const tracks = try cSlice(LaffyTrackSizingFunction, component.repeat_tracks, component.repeat_track_count);
                // An empty repetition is invalid CSS (and would divide by zero in the auto-repeat logic)
                if (tracks.len == 0 or tracks.len > std.math.maxInt(u16)) return error.InvalidArgument;
                const line_names = try cSlice(LaffyLineNameSet, component.repeat_line_names, component.repeat_line_name_count);
                // Line name sets are positional: none at all, or exactly one per line
                if (line_names.len != 0 and line_names.len != tracks.len + 1) return error.InvalidArgument;
                break :blk .{ .repeat = .{
                    .count = count,
                    .tracks = try dupeTracks(arena, tracks),
                    .line_names = try dupeLineNameSets(arena, line_names),
                } };
            },
        };
    }
    return out;
}

fn toPlacement(arena: Allocator, p: LaffyGridPlacement) CError!GridPlacement {
    return switch (try enumFromC(LaffyGridPlacementKind, p.kind)) {
        .auto => .auto,
        .line => GridPlacement.fromLineIndex(p.line),
        .span => .{ .span = p.span },
        .named_line => .{ .named_line = .{ .name = try dupeName(arena, p.name), .index = p.line } },
        .named_span => .{ .named_span = .{ .name = try dupeName(arena, p.name), .count = p.span } },
    };
}

/// Read-modify-write of a node's style
fn updateStyle(tree: ?*LaffyTree, id: u64, comptime update: anytype, args: anytype) CError!void {
    const impl = try implOf(tree);
    const node = try checkNode(impl, id, error.InvalidInputNode);
    var style = impl.tree.style(node).*;
    try @call(.auto, update, .{&style} ++ args);
    impl.tree.setStyle(node, style);
}

/// Set a grid property whose data is owned by the node: `build(arena, &style, args...)` copies
/// the C data into a fresh arena; on success the property's previous arena is freed.
fn updateGridStyle(tree: ?*LaffyTree, id: u64, comptime prop: GridProp, comptime build: anytype, args: anytype) CError!void {
    const impl = try implOf(tree);
    const node = try checkNode(impl, id, error.InvalidInputNode);
    var arena = ArenaAllocator.init(impl.gpa);
    errdefer arena.deinit();
    var style = impl.tree.style(node).*;
    try @call(.auto, build, .{ arena.allocator(), &style } ++ args);
    const grid = try impl.ownedGrid(impl.context(node));
    impl.tree.setStyle(node, style);
    impl.swapArena(grid, prop, arena.state);
}

/// Whether `ancestor` is `node` or one of its ancestors
fn isAncestorOrSelf(impl: *TreeImpl, ancestor: NodeId, node: NodeId) bool {
    var current: ?NodeId = node;
    while (current) |c| : (current = impl.tree.parent(c)) {
        if (c == ancestor) return true;
    }
    return false;
}

/// Validate a node that is about to be attached under `parent`: it must exist, have no parent, and
/// not be `parent` or one of its ancestors
fn checkAttachable(impl: *TreeImpl, parent: NodeId, child_id: u64) CError!NodeId {
    const child = try checkNode(impl, child_id, error.InvalidChildNode);
    if (impl.tree.parent(child) != null) return error.ChildHasParent;
    if (isAncestorOrSelf(impl, child, parent)) return error.WouldCreateCycle;
    return child;
}

/// Validate a list of children: all exist and there are no duplicates. Returns a sorted copy
/// (allocated with `gpa`) for further membership checks.
fn checkChildList(impl: *TreeImpl, ids: []const u64) CError![]u64 {
    for (ids) |id| _ = try checkNode(impl, id, error.InvalidChildNode);
    const sorted = try impl.gpa.dupe(u64, ids);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    if (sorted.len > 1) {
        for (sorted[0 .. sorted.len - 1], sorted[1..]) |a, b| {
            if (a == b) {
                impl.gpa.free(sorted);
                return error.InvalidArgument;
            }
        }
    }
    return sorted;
}

fn orderU64(key: u64, item: u64) std.math.Order {
    return std.math.order(key, item);
}

// ---------------------------------------------------------------------------------------------
// Measure functions

/// The measurer passed to `computeLayoutWithMeasure`: leaves with a C measure function are
/// measured through it, other leaves have zero-sized content (as `TaffyTree.computeLayout`)
const CMeasurer = struct {
    pub fn measure(_: CMeasurer, inputs: LayoutInput, node_id: NodeId, ctx: ?*NodeContext, style: *const Style) LayoutOutput {
        if (ctx) |c| {
            if (c.measure) |func| {
                return laffy.computeLeafLayout(inputs, style, laffy.NoCalc{}, CContent{
                    .func = func,
                    .user_data = c.user_data,
                    .node = node_id.inner,
                });
            }
        }
        return laffy.computeLeafLayout(inputs, style, laffy.NoCalc{}, laffy.ZeroMeasure{});
    }
};

const CContent = struct {
    func: LaffyMeasureFunc,
    user_data: ?*anyopaque,
    node: u64,

    pub fn measure(self: CContent, known_dimensions: Size(?f32), available_space: Size(AvailableSpace)) Size(f32) {
        const nan = std.math.nan(f32);
        const result = self.func(
            self.user_data,
            self.node,
            known_dimensions.width orelse nan,
            known_dimensions.height orelse nan,
            fromAvailableSpace(available_space.width),
            fromAvailableSpace(available_space.height),
        );
        return .{ .width = result.width, .height = result.height };
    }
};

// ---------------------------------------------------------------------------------------------
// Exported functions: meta

export fn laffy_abi_version() u32 {
    return abi_version;
}

export fn laffy_status_string(status: c_int) [*:0]const u8 {
    const s = enumFromC(LaffyStatus, status) catch return "unknown status";
    return switch (s) {
        .ok => "ok",
        .out_of_memory => "out of memory",
        .invalid_argument => "invalid argument",
        .invalid_input_node => "the node is not in this tree",
        .invalid_parent_node => "the parent node is not in this tree",
        .invalid_child_node => "the child node is not in this tree",
        .child_index_out_of_bounds => "child index out of bounds",
        .not_a_child => "the node is not a child of the parent",
        .child_has_parent => "the child node already has a parent",
        .would_create_cycle => "the operation would create a cycle",
    };
}

// ---------------------------------------------------------------------------------------------
// Exported functions: tree lifecycle

export fn laffy_tree_new(out_tree: ?*?*LaffyTree) LaffyStatus {
    const out = out_tree orelse return .invalid_argument;
    const impl = createTree(default_allocator) catch return .out_of_memory;
    out.* = treeHandle(impl);
    return .ok;
}

export fn laffy_tree_new_with_allocator(allocator: ?*const LaffyAllocator, out_tree: ?*?*LaffyTree) LaffyStatus {
    const out = out_tree orelse return .invalid_argument;
    const c_alloc = allocator orelse return .invalid_argument;
    if (c_alloc.alloc == null or c_alloc.free == null) return .invalid_argument;
    const impl = createTreeWithCAllocator(c_alloc.*) catch return .out_of_memory;
    out.* = treeHandle(impl);
    return .ok;
}

export fn laffy_tree_free(tree: ?*LaffyTree) void {
    const impl = implOf(tree) catch return;
    destroyTree(impl);
}

export fn laffy_tree_clear(tree: ?*LaffyTree) LaffyStatus {
    const impl = implOf(tree) catch return .invalid_argument;
    impl.freeAllGrids();
    impl.tree.clear();
    return .ok;
}

export fn laffy_tree_enable_rounding(tree: ?*LaffyTree) LaffyStatus {
    const impl = implOf(tree) catch return .invalid_argument;
    impl.tree.enableRounding();
    return .ok;
}

export fn laffy_tree_disable_rounding(tree: ?*LaffyTree) LaffyStatus {
    const impl = implOf(tree) catch return .invalid_argument;
    impl.tree.disableRounding();
    return .ok;
}

export fn laffy_tree_total_node_count(tree: ?*LaffyTree, out_count: ?*usize) LaffyStatus {
    const impl = implOf(tree) catch return .invalid_argument;
    const out = out_count orelse return .invalid_argument;
    out.* = impl.tree.totalNodeCount();
    return .ok;
}

export fn laffy_tree_contains_node(tree: ?*LaffyTree, node: u64) bool {
    const impl = implOf(tree) catch return false;
    return impl.tree.containsNode(.{ .inner = node });
}

// ---------------------------------------------------------------------------------------------
// Exported functions: nodes and children

export fn laffy_node_new(tree: ?*LaffyTree, out_node: ?*u64) LaffyStatus {
    return toStatus(nodeNew(tree, out_node));
}

fn nodeNew(tree: ?*LaffyTree, out_node: ?*u64) CError!void {
    const impl = try implOf(tree);
    const out = out_node orelse return error.InvalidArgument;
    const node = try impl.tree.newLeafWithContext(.{}, .{});
    out.* = node.inner;
}

export fn laffy_node_new_with_children(tree: ?*LaffyTree, children: ?[*]const u64, child_count: usize, out_node: ?*u64) LaffyStatus {
    return toStatus(nodeNewWithChildren(tree, children, child_count, out_node));
}

fn nodeNewWithChildren(tree: ?*LaffyTree, children_ptr: ?[*]const u64, child_count: usize, out_node: ?*u64) CError!void {
    const impl = try implOf(tree);
    const out = out_node orelse return error.InvalidArgument;
    const ids = try cSlice(u64, children_ptr, child_count);
    const sorted = try checkChildList(impl, ids);
    impl.gpa.free(sorted);
    // A child that already has a parent would end up in two child lists
    for (ids) |id| {
        if (impl.tree.parent(.{ .inner = id }) != null) return error.ChildHasParent;
    }
    const node = try impl.tree.newWithChildren(.{}, @ptrCast(ids));
    impl.tree.setNodeContext(node, NodeContext{});
    out.* = node.inner;
}

export fn laffy_node_remove(tree: ?*LaffyTree, node: u64) LaffyStatus {
    return toStatus(nodeRemove(tree, node));
}

fn nodeRemove(tree: ?*LaffyTree, id: u64) CError!void {
    const impl = try implOf(tree);
    const node = try checkNode(impl, id, error.InvalidInputNode);
    if (impl.context(node).grid) |grid| impl.freeGrid(grid);
    _ = impl.tree.remove(node);
}

export fn laffy_node_add_child(tree: ?*LaffyTree, parent: u64, child: u64) LaffyStatus {
    return toStatus(nodeAddChild(tree, parent, child));
}

fn nodeAddChild(tree: ?*LaffyTree, parent_id: u64, child_id: u64) CError!void {
    const impl = try implOf(tree);
    const parent = try checkNode(impl, parent_id, error.InvalidParentNode);
    const child = try checkAttachable(impl, parent, child_id);
    try impl.tree.addChild(parent, child);
}

export fn laffy_node_insert_child_at_index(tree: ?*LaffyTree, parent: u64, index: usize, child: u64) LaffyStatus {
    return toStatus(nodeInsertChildAtIndex(tree, parent, index, child));
}

fn nodeInsertChildAtIndex(tree: ?*LaffyTree, parent_id: u64, index: usize, child_id: u64) CError!void {
    const impl = try implOf(tree);
    const parent = try checkNode(impl, parent_id, error.InvalidParentNode);
    if (index > impl.tree.childCount(parent)) return error.ChildIndexOutOfBounds;
    const child = try checkAttachable(impl, parent, child_id);
    impl.tree.insertChildAtIndex(parent, index, child) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable, // validated above
    };
}

export fn laffy_node_remove_child(tree: ?*LaffyTree, parent: u64, child: u64) LaffyStatus {
    return toStatus(nodeRemoveChild(tree, parent, child));
}

fn nodeRemoveChild(tree: ?*LaffyTree, parent_id: u64, child_id: u64) CError!void {
    const impl = try implOf(tree);
    const parent = try checkNode(impl, parent_id, error.InvalidParentNode);
    const child = try checkNode(impl, child_id, error.InvalidChildNode);
    const index = std.mem.indexOfScalar(NodeId, impl.tree.children(parent), child) orelse return error.NotAChild;
    _ = impl.tree.removeChildAtIndex(parent, index) catch unreachable; // index is in bounds
}

export fn laffy_node_remove_child_at_index(tree: ?*LaffyTree, parent: u64, index: usize, out_removed: ?*u64) LaffyStatus {
    return toStatus(nodeRemoveChildAtIndex(tree, parent, index, out_removed));
}

fn nodeRemoveChildAtIndex(tree: ?*LaffyTree, parent_id: u64, index: usize, out_removed: ?*u64) CError!void {
    const impl = try implOf(tree);
    const parent = try checkNode(impl, parent_id, error.InvalidParentNode);
    const removed = impl.tree.removeChildAtIndex(parent, index) catch return error.ChildIndexOutOfBounds;
    if (out_removed) |out| out.* = removed.inner;
}

export fn laffy_node_remove_children_range(tree: ?*LaffyTree, parent: u64, start: usize, end: usize) LaffyStatus {
    return toStatus(nodeRemoveChildrenRange(tree, parent, start, end));
}

fn nodeRemoveChildrenRange(tree: ?*LaffyTree, parent_id: u64, start: usize, end: usize) CError!void {
    const impl = try implOf(tree);
    const parent = try checkNode(impl, parent_id, error.InvalidParentNode);
    if (start > end or end > impl.tree.childCount(parent)) return error.ChildIndexOutOfBounds;
    impl.tree.removeChildrenRange(parent, start, end);
}

export fn laffy_node_replace_child_at_index(tree: ?*LaffyTree, parent: u64, index: usize, new_child: u64, out_old_child: ?*u64) LaffyStatus {
    return toStatus(nodeReplaceChildAtIndex(tree, parent, index, new_child, out_old_child));
}

fn nodeReplaceChildAtIndex(tree: ?*LaffyTree, parent_id: u64, index: usize, new_child_id: u64, out_old_child: ?*u64) CError!void {
    const impl = try implOf(tree);
    const parent = try checkNode(impl, parent_id, error.InvalidParentNode);
    const children = impl.tree.children(parent);
    if (index >= children.len) return error.ChildIndexOutOfBounds;
    const old_child = children[index];
    _ = try checkNode(impl, new_child_id, error.InvalidChildNode);
    if (old_child.inner != new_child_id) {
        const new_child = try checkAttachable(impl, parent, new_child_id);
        _ = impl.tree.replaceChildAtIndex(parent, index, new_child) catch unreachable; // index is in bounds
    }
    if (out_old_child) |out| out.* = old_child.inner;
}

export fn laffy_node_set_children(tree: ?*LaffyTree, parent: u64, children: ?[*]const u64, child_count: usize) LaffyStatus {
    return toStatus(nodeSetChildren(tree, parent, children, child_count));
}

fn nodeSetChildren(tree: ?*LaffyTree, parent_id: u64, children_ptr: ?[*]const u64, child_count: usize) CError!void {
    const impl = try implOf(tree);
    const parent = try checkNode(impl, parent_id, error.InvalidParentNode);
    const ids = try cSlice(u64, children_ptr, child_count);
    const sorted = try checkChildList(impl, ids);
    defer impl.gpa.free(sorted);
    // Children may be taken from another parent (as upstream), but none may be `parent` itself or
    // one of its ancestors
    var current: ?NodeId = parent;
    while (current) |c| : (current = impl.tree.parent(c)) {
        if (std.sort.binarySearch(u64, sorted, c.inner, orderU64) != null) return error.WouldCreateCycle;
    }
    try impl.tree.setChildren(parent, @ptrCast(ids));
}

export fn laffy_node_child_count(tree: ?*LaffyTree, parent: u64, out_count: ?*usize) LaffyStatus {
    return toStatus(nodeChildCount(tree, parent, out_count));
}

fn nodeChildCount(tree: ?*LaffyTree, parent_id: u64, out_count: ?*usize) CError!void {
    const impl = try implOf(tree);
    const out = out_count orelse return error.InvalidArgument;
    const parent = try checkNode(impl, parent_id, error.InvalidParentNode);
    out.* = impl.tree.childCount(parent);
}

export fn laffy_node_child_at_index(tree: ?*LaffyTree, parent: u64, index: usize, out_child: ?*u64) LaffyStatus {
    return toStatus(nodeChildAtIndex(tree, parent, index, out_child));
}

fn nodeChildAtIndex(tree: ?*LaffyTree, parent_id: u64, index: usize, out_child: ?*u64) CError!void {
    const impl = try implOf(tree);
    const out = out_child orelse return error.InvalidArgument;
    const parent = try checkNode(impl, parent_id, error.InvalidParentNode);
    const child = impl.tree.childAtIndex(parent, index) catch return error.ChildIndexOutOfBounds;
    out.* = child.inner;
}

export fn laffy_node_parent(tree: ?*LaffyTree, node: u64, out_parent: ?*u64) LaffyStatus {
    return toStatus(nodeParent(tree, node, out_parent));
}

fn nodeParent(tree: ?*LaffyTree, id: u64, out_parent: ?*u64) CError!void {
    const impl = try implOf(tree);
    const out = out_parent orelse return error.InvalidArgument;
    const node = try checkNode(impl, id, error.InvalidInputNode);
    out.* = if (impl.tree.parent(node)) |p| p.inner else 0;
}

// ---------------------------------------------------------------------------------------------
// Exported functions: user data and measure functions

export fn laffy_node_set_context(tree: ?*LaffyTree, node: u64, user_data: ?*anyopaque) LaffyStatus {
    return toStatus(nodeSetContext(tree, node, user_data));
}

fn nodeSetContext(tree: ?*LaffyTree, id: u64, user_data: ?*anyopaque) CError!void {
    const impl = try implOf(tree);
    const node = try checkNode(impl, id, error.InvalidInputNode);
    impl.context(node).user_data = user_data;
    impl.tree.markDirty(node);
}

export fn laffy_node_get_context(tree: ?*LaffyTree, node: u64, out_user_data: ?*?*anyopaque) LaffyStatus {
    return toStatus(nodeGetContext(tree, node, out_user_data));
}

fn nodeGetContext(tree: ?*LaffyTree, id: u64, out_user_data: ?*?*anyopaque) CError!void {
    const impl = try implOf(tree);
    const out = out_user_data orelse return error.InvalidArgument;
    const node = try checkNode(impl, id, error.InvalidInputNode);
    out.* = impl.context(node).user_data;
}

export fn laffy_node_set_measure_func(tree: ?*LaffyTree, node: u64, measure: ?LaffyMeasureFunc) LaffyStatus {
    return toStatus(nodeSetMeasureFunc(tree, node, measure));
}

fn nodeSetMeasureFunc(tree: ?*LaffyTree, id: u64, measure: ?LaffyMeasureFunc) CError!void {
    const impl = try implOf(tree);
    const node = try checkNode(impl, id, error.InvalidInputNode);
    impl.context(node).measure = measure;
    impl.tree.markDirty(node);
}

// ---------------------------------------------------------------------------------------------
// Exported functions: layout

export fn laffy_tree_compute_layout(tree: ?*LaffyTree, node: u64, available_width: LaffyAvailableSpace, available_height: LaffyAvailableSpace) LaffyStatus {
    return toStatus(treeComputeLayout(tree, node, available_width, available_height));
}

fn treeComputeLayout(tree: ?*LaffyTree, id: u64, available_width: LaffyAvailableSpace, available_height: LaffyAvailableSpace) CError!void {
    const impl = try implOf(tree);
    const node = try checkNode(impl, id, error.InvalidInputNode);
    const available_space: Size(AvailableSpace) = .{
        .width = try toAvailableSpace(available_width),
        .height = try toAvailableSpace(available_height),
    };
    try impl.tree.computeLayoutWithMeasure(node, available_space, CMeasurer{});
}

fn toCLayout(l: Layout) LaffyLayout {
    const overflow = l.scrollable_overflow_rect.rect();
    const reversed = l.scrollable_overflow_rect.isReversed();
    return .{
        .order = l.order,
        .location = .{ .x = l.location.x, .y = l.location.y },
        .size = .{ .width = l.size.width, .height = l.size.height },
        .scrollable_overflow = .{ .left = overflow.left, .right = overflow.right, .top = overflow.top, .bottom = overflow.bottom },
        .scrollable_overflow_reversed_x = reversed.x,
        .scrollable_overflow_reversed_y = reversed.y,
        .scroll_width = l.scrollWidth(),
        .scroll_height = l.scrollHeight(),
        .scrollbar_size = .{ .width = l.scrollbar_size.width, .height = l.scrollbar_size.height },
        .border = .{ .left = l.border.left, .right = l.border.right, .top = l.border.top, .bottom = l.border.bottom },
        .padding = .{ .left = l.padding.left, .right = l.padding.right, .top = l.padding.top, .bottom = l.padding.bottom },
        .margin = .{ .left = l.margin.left, .right = l.margin.right, .top = l.margin.top, .bottom = l.margin.bottom },
    };
}

export fn laffy_node_get_layout(tree: ?*LaffyTree, node: u64, out_layout: ?*LaffyLayout) LaffyStatus {
    return toStatus(nodeGetLayout(tree, node, out_layout, false));
}

export fn laffy_node_get_unrounded_layout(tree: ?*LaffyTree, node: u64, out_layout: ?*LaffyLayout) LaffyStatus {
    return toStatus(nodeGetLayout(tree, node, out_layout, true));
}

fn nodeGetLayout(tree: ?*LaffyTree, id: u64, out_layout: ?*LaffyLayout, unrounded: bool) CError!void {
    const impl = try implOf(tree);
    const out = out_layout orelse return error.InvalidArgument;
    const node = try checkNode(impl, id, error.InvalidInputNode);
    out.* = toCLayout(if (unrounded) impl.tree.unroundedLayout(node).* else impl.tree.layout(node).*);
}

export fn laffy_node_mark_dirty(tree: ?*LaffyTree, node: u64) LaffyStatus {
    return toStatus(nodeMarkDirty(tree, node));
}

fn nodeMarkDirty(tree: ?*LaffyTree, id: u64) CError!void {
    const impl = try implOf(tree);
    const node = try checkNode(impl, id, error.InvalidInputNode);
    impl.tree.markDirty(node);
}

export fn laffy_node_is_dirty(tree: ?*LaffyTree, node: u64, out_dirty: ?*bool) LaffyStatus {
    return toStatus(nodeIsDirty(tree, node, out_dirty));
}

fn nodeIsDirty(tree: ?*LaffyTree, id: u64, out_dirty: ?*bool) CError!void {
    const impl = try implOf(tree);
    const out = out_dirty orelse return error.InvalidArgument;
    const node = try checkNode(impl, id, error.InvalidInputNode);
    out.* = impl.tree.dirty(node);
}

// ---------------------------------------------------------------------------------------------
// Exported functions: style

export fn laffy_node_reset_style(tree: ?*LaffyTree, node: u64) LaffyStatus {
    return toStatus(nodeResetStyle(tree, node));
}

fn nodeResetStyle(tree: ?*LaffyTree, id: u64) CError!void {
    const impl = try implOf(tree);
    const node = try checkNode(impl, id, error.InvalidInputNode);
    impl.tree.setStyle(node, .{});
    const ctx = impl.context(node);
    if (ctx.grid) |grid| {
        impl.freeGrid(grid);
        ctx.grid = null;
    }
}

const TemplateBuilder = struct {
    fn rows(arena: Allocator, style: *Style, components: []const LaffyGridTemplateComponent, names: []const LaffyLineNameSet) CError!void {
        style.grid_template_rows = try dupeTemplate(arena, components);
        style.grid_template_row_names = try dupeLineNameSets(arena, names);
    }
    fn columns(arena: Allocator, style: *Style, components: []const LaffyGridTemplateComponent, names: []const LaffyLineNameSet) CError!void {
        style.grid_template_columns = try dupeTemplate(arena, components);
        style.grid_template_column_names = try dupeLineNameSets(arena, names);
    }
};

export fn laffy_node_set_grid_template_rows(
    tree: ?*LaffyTree,
    node: u64,
    components: ?[*]const LaffyGridTemplateComponent,
    component_count: usize,
    line_names: ?[*]const LaffyLineNameSet,
    line_name_count: usize,
) LaffyStatus {
    const comps = cSlice(LaffyGridTemplateComponent, components, component_count) catch return .invalid_argument;
    const names = cSlice(LaffyLineNameSet, line_names, line_name_count) catch return .invalid_argument;
    return toStatus(updateGridStyle(tree, node, .template_rows, TemplateBuilder.rows, .{ comps, names }));
}

export fn laffy_node_set_grid_template_columns(
    tree: ?*LaffyTree,
    node: u64,
    components: ?[*]const LaffyGridTemplateComponent,
    component_count: usize,
    line_names: ?[*]const LaffyLineNameSet,
    line_name_count: usize,
) LaffyStatus {
    const comps = cSlice(LaffyGridTemplateComponent, components, component_count) catch return .invalid_argument;
    const names = cSlice(LaffyLineNameSet, line_names, line_name_count) catch return .invalid_argument;
    return toStatus(updateGridStyle(tree, node, .template_columns, TemplateBuilder.columns, .{ comps, names }));
}

const AutoTrackBuilder = struct {
    fn rows(arena: Allocator, style: *Style, tracks: []const LaffyTrackSizingFunction) CError!void {
        style.grid_auto_rows = try dupeTracks(arena, tracks);
    }
    fn columns(arena: Allocator, style: *Style, tracks: []const LaffyTrackSizingFunction) CError!void {
        style.grid_auto_columns = try dupeTracks(arena, tracks);
    }
};

export fn laffy_node_set_grid_auto_rows(tree: ?*LaffyTree, node: u64, tracks: ?[*]const LaffyTrackSizingFunction, track_count: usize) LaffyStatus {
    const t = cSlice(LaffyTrackSizingFunction, tracks, track_count) catch return .invalid_argument;
    return toStatus(updateGridStyle(tree, node, .auto_rows, AutoTrackBuilder.rows, .{t}));
}

export fn laffy_node_set_grid_auto_columns(tree: ?*LaffyTree, node: u64, tracks: ?[*]const LaffyTrackSizingFunction, track_count: usize) LaffyStatus {
    const t = cSlice(LaffyTrackSizingFunction, tracks, track_count) catch return .invalid_argument;
    return toStatus(updateGridStyle(tree, node, .auto_columns, AutoTrackBuilder.columns, .{t}));
}

fn buildTemplateAreas(arena: Allocator, style: *Style, areas: []const LaffyGridTemplateArea, row_count: u16, column_count: u16) CError!void {
    if (areas.len == 0 and row_count == 0 and column_count == 0) {
        style.grid_template_areas = null;
        return;
    }
    const out = try arena.alloc(GridTemplateArea, areas.len);
    for (areas, out) |area, *dst| {
        if (area.row_start < 1 or area.row_end <= area.row_start) return error.InvalidArgument;
        if (area.column_start < 1 or area.column_end <= area.column_start) return error.InvalidArgument;
        dst.* = .{
            .name = try dupeName(arena, area.name),
            .row_start = area.row_start,
            .row_end = area.row_end,
            .column_start = area.column_start,
            .column_end = area.column_end,
        };
    }
    style.grid_template_areas = .{ .areas = out, .row_count = row_count, .column_count = column_count };
}

export fn laffy_node_set_grid_template_areas(tree: ?*LaffyTree, node: u64, areas: ?[*]const LaffyGridTemplateArea, area_count: usize, row_count: u16, column_count: u16) LaffyStatus {
    const a = cSlice(LaffyGridTemplateArea, areas, area_count) catch return .invalid_argument;
    return toStatus(updateGridStyle(tree, node, .template_areas, buildTemplateAreas, .{ a, row_count, column_count }));
}

const PlacementBuilder = struct {
    fn row(arena: Allocator, style: *Style, start: LaffyGridPlacement, end: LaffyGridPlacement) CError!void {
        style.grid_row = .{ .start = try toPlacement(arena, start), .end = try toPlacement(arena, end) };
    }
    fn column(arena: Allocator, style: *Style, start: LaffyGridPlacement, end: LaffyGridPlacement) CError!void {
        style.grid_column = .{ .start = try toPlacement(arena, start), .end = try toPlacement(arena, end) };
    }
};

export fn laffy_node_set_grid_row(tree: ?*LaffyTree, node: u64, start: LaffyGridPlacement, end: LaffyGridPlacement) LaffyStatus {
    return toStatus(updateGridStyle(tree, node, .row, PlacementBuilder.row, .{ start, end }));
}

export fn laffy_node_set_grid_column(tree: ?*LaffyTree, node: u64, start: LaffyGridPlacement, end: LaffyGridPlacement) LaffyStatus {
    return toStatus(updateGridStyle(tree, node, .column, PlacementBuilder.column, .{ start, end }));
}

// ---------------------------------------------------------------------------------------------
// Exported functions: style setters and getters of the properties that are not lists
//
// Every function is generated at compile time from the name of the `Style` field and a codec
// that converts the field's value from and to its C representation. A codec has a C type `C`,
// `decode(C) CError!Field` (which validates) and `encode(Field) C`. The declarations of
// `style_api` are exported under their own names.

/// The name of the union tag that the unit stands for in the length-like style types
fn tagOfUnit(comptime unit: LaffyUnit) []const u8 {
    return if (unit == .fit_content_length) "fit_content_px" else @tagName(unit);
}

/// Converts between the `{unit, value}` struct `CType` and the length-like union `Value`
/// (`Dimension`, `LengthPercentage`, ...). A unit is accepted if and only if `Value` has the
/// matching tag. The C API cannot store `calc()` values, so a style never holds one.
fn UnitCodec(comptime CType: type, comptime Value: type) type {
    return struct {
        const C = CType;
        fn decode(v: CType) CError!Value {
            switch (try enumFromC(LaffyUnit, v.unit)) {
                inline else => |unit| {
                    const tag = comptime tagOfUnit(unit);
                    if (!@hasField(Value, tag)) return error.InvalidArgument;
                    if (@FieldType(Value, tag) == void) return @unionInit(Value, tag, {});
                    return @unionInit(Value, tag, try number(v.value));
                },
            }
        }
        fn encode(value: Value) CType {
            switch (value) {
                inline else => |payload, tag| {
                    const name = @tagName(tag);
                    if (comptime std.mem.endsWith(u8, name, "calc")) unreachable;
                    const unit: LaffyUnit = comptime if (std.mem.eql(u8, name, "fit_content_px")) .fit_content_length else @field(LaffyUnit, name);
                    return .{ .unit = @backingInt(unit), .value = if (@TypeOf(payload) == void) 0 else payload };
                },
            }
        }
    };
}

const DimensionCodec = UnitCodec(LaffyDimension, Dimension);
const LengthPercentageCodec = UnitCodec(LaffyLengthPercentage, LengthPercentage);
const LengthPercentageAutoCodec = UnitCodec(LaffyLengthPercentageAuto, LengthPercentageAuto);

/// Converts between the C enum `Source` (passed as an int) and the laffy enum `Target` with
/// the same tag names
fn EnumCodec(comptime Source: type, comptime Target: type) type {
    return struct {
        const C = c_int;
        fn decode(raw: c_int) CError!Target {
            return mapEnum(Target, Source, raw);
        }
        fn encode(value: Target) c_int {
            return switch (value) {
                inline else => |tag| @backingInt(@field(Source, @tagName(tag))),
            };
        }
    };
}

const BoolCodec = struct {
    const C = bool;
    fn decode(value: bool) CError!bool {
        return value;
    }
    fn encode(value: bool) bool {
        return value;
    }
};

/// A number that must be zero or more
const NonNegativeCodec = struct {
    const C = f32;
    fn decode(value: f32) CError!f32 {
        if (!(try number(value) >= 0)) return error.InvalidArgument;
        return value;
    }
    fn encode(value: f32) f32 {
        return value;
    }
};

/// A count that must be one or more
const LineCountCodec = struct {
    const C = u16;
    fn decode(value: u16) CError!u16 {
        if (value == 0) return error.InvalidArgument;
        return value;
    }
    fn encode(value: u16) u16 {
        return value;
    }
};

/// NaN stands for "no aspect ratio"
const AspectRatioCodec = struct {
    const C = f32;
    fn decode(value: f32) CError!?f32 {
        if (std.math.isNan(value)) return null;
        if (value > 0 and std.math.isFinite(value)) return value;
        return error.InvalidArgument;
    }
    fn encode(value: ?f32) f32 {
        return value orelse std.math.nan(f32);
    }
};

const ContainCodec = struct {
    const C = u32;
    fn decode(flags: u32) CError!laffy.Contain {
        if (flags & ~(contain_layout | contain_paint) != 0) return error.InvalidArgument;
        var contain = laffy.Contain.none;
        if (flags & contain_layout != 0) contain = contain.@"union"(laffy.Contain.layout);
        if (flags & contain_paint != 0) contain = contain.@"union"(laffy.Contain.paint);
        return contain;
    }
    fn encode(value: laffy.Contain) u32 {
        var flags: u32 = 0;
        if (value.inner & laffy.Contain.layout.inner != 0) flags |= contain_layout;
        if (value.inner & laffy.Contain.paint.inner != 0) flags |= contain_paint;
        return flags;
    }
};

/// Encodes a grid placement. Line names are stored NUL-terminated (see `dupeName`), so they
/// can be returned to C as is. Placements are set by `laffy_node_set_grid_row` / `_column`,
/// which copy the names, so there is no `decode`.
const PlacementCodec = struct {
    const C = LaffyGridPlacement;
    fn encode(value: GridPlacement) LaffyGridPlacement {
        const kind = struct {
            fn of(k: LaffyGridPlacementKind) c_int {
                return @backingInt(k);
            }
        }.of;
        return switch (value) {
            .auto => .{ .kind = kind(.auto), .line = 0, .span = 0, .name = null },
            .line => |line| .{ .kind = kind(.line), .line = line.inner, .span = 0, .name = null },
            .span => |span| .{ .kind = kind(.span), .line = 0, .span = span, .name = null },
            .named_line => |named| .{ .kind = kind(.named_line), .line = named.index, .span = 0, .name = @ptrCast(named.name.ptr) },
            .named_span => |named| .{ .kind = kind(.named_span), .line = 0, .span = named.count, .name = @ptrCast(named.name.ptr) },
        };
    }
};

fn styleFor(tree: ?*LaffyTree, id: u64) CError!*const Style {
    const impl = try implOf(tree);
    const node = try checkNode(impl, id, error.InvalidInputNode);
    return impl.tree.style(node);
}

/// Generates the setter and getter of a style field that has a single C value
fn Property(comptime field: []const u8, comptime Codec: type) type {
    return struct {
        fn set(tree: ?*LaffyTree, node: u64, value: Codec.C) callconv(.c) LaffyStatus {
            return toStatus(updateStyle(tree, node, apply, .{value}));
        }
        fn apply(style: *Style, value: Codec.C) CError!void {
            @field(style, field) = try Codec.decode(value);
        }
        fn get(tree: ?*LaffyTree, node: u64, out: ?*Codec.C) callconv(.c) LaffyStatus {
            return toStatus(read(tree, node, out));
        }
        fn read(tree: ?*LaffyTree, node: u64, out: ?*Codec.C) CError!void {
            const style = try styleFor(tree, node);
            const dst = out orelse return error.InvalidArgument;
            dst.* = Codec.encode(@field(style, field));
        }
    };
}

/// Generates the setter and getter of a style field made of two parts (`Size`, `Point` or
/// `Line`), named `first` and `second` in the field's type
fn PairProperty(comptime field: []const u8, comptime first: []const u8, comptime second: []const u8, comptime Codec: type) type {
    return struct {
        fn set(tree: ?*LaffyTree, node: u64, a: Codec.C, b: Codec.C) callconv(.c) LaffyStatus {
            return toStatus(updateStyle(tree, node, apply, .{ a, b }));
        }
        fn apply(style: *Style, a: Codec.C, b: Codec.C) CError!void {
            var value = @field(style, field);
            @field(value, first) = try Codec.decode(a);
            @field(value, second) = try Codec.decode(b);
            @field(style, field) = value;
        }
        fn get(tree: ?*LaffyTree, node: u64, out_first: ?*Codec.C, out_second: ?*Codec.C) callconv(.c) LaffyStatus {
            return toStatus(read(tree, node, out_first, out_second));
        }
        fn read(tree: ?*LaffyTree, node: u64, out_first: ?*Codec.C, out_second: ?*Codec.C) CError!void {
            const style = try styleFor(tree, node);
            const a = out_first orelse return error.InvalidArgument;
            const b = out_second orelse return error.InvalidArgument;
            const value = @field(style, field);
            a.* = Codec.encode(@field(value, first));
            b.* = Codec.encode(@field(value, second));
        }
    };
}

/// Generates the setter and getter of a `Rect` style field; the edges are in CSS order
fn RectProperty(comptime field: []const u8, comptime Codec: type) type {
    return struct {
        fn set(tree: ?*LaffyTree, node: u64, top: Codec.C, right: Codec.C, bottom: Codec.C, left: Codec.C) callconv(.c) LaffyStatus {
            return toStatus(updateStyle(tree, node, apply, .{ top, right, bottom, left }));
        }
        fn apply(style: *Style, top: Codec.C, right: Codec.C, bottom: Codec.C, left: Codec.C) CError!void {
            @field(style, field) = .{
                .top = try Codec.decode(top),
                .right = try Codec.decode(right),
                .bottom = try Codec.decode(bottom),
                .left = try Codec.decode(left),
            };
        }
        fn get(tree: ?*LaffyTree, node: u64, out_top: ?*Codec.C, out_right: ?*Codec.C, out_bottom: ?*Codec.C, out_left: ?*Codec.C) callconv(.c) LaffyStatus {
            return toStatus(read(tree, node, out_top, out_right, out_bottom, out_left));
        }
        fn read(tree: ?*LaffyTree, node: u64, out_top: ?*Codec.C, out_right: ?*Codec.C, out_bottom: ?*Codec.C, out_left: ?*Codec.C) CError!void {
            const style = try styleFor(tree, node);
            const top = out_top orelse return error.InvalidArgument;
            const right = out_right orelse return error.InvalidArgument;
            const bottom = out_bottom orelse return error.InvalidArgument;
            const left = out_left orelse return error.InvalidArgument;
            const value = @field(style, field);
            top.* = Codec.encode(value.top);
            right.* = Codec.encode(value.right);
            bottom.* = Codec.encode(value.bottom);
            left.* = Codec.encode(value.left);
        }
    };
}

/// Generates the setter and getter of an alignment field: a keyword of the C enum `Keyword`
/// and a safety. `decode` is `toAlignItems`, `toAlignSelf` or `toAlignContent`. An unset
/// `align-self` / `justify-self` reads as `auto` with the default safety.
fn AlignProperty(comptime field: []const u8, comptime Keyword: type, comptime decode: anytype) type {
    return struct {
        fn set(tree: ?*LaffyTree, node: u64, keyword: c_int, safety: c_int) callconv(.c) LaffyStatus {
            return toStatus(updateStyle(tree, node, apply, .{ keyword, safety }));
        }
        fn apply(style: *Style, keyword: c_int, safety: c_int) CError!void {
            @field(style, field) = try decode(keyword, safety);
        }
        fn get(tree: ?*LaffyTree, node: u64, out_keyword: ?*c_int, out_safety: ?*c_int) callconv(.c) LaffyStatus {
            return toStatus(read(tree, node, out_keyword, out_safety));
        }
        fn read(tree: ?*LaffyTree, node: u64, out_keyword: ?*c_int, out_safety: ?*c_int) CError!void {
            const style = try styleFor(tree, node);
            const keyword = out_keyword orelse return error.InvalidArgument;
            const safety = out_safety orelse return error.InvalidArgument;
            const stored = @field(style, field);
            const value = if (@typeInfo(@TypeOf(stored)) == .optional) stored else @as(?@TypeOf(stored), stored);
            if (value) |v| {
                keyword.* = switch (v.keyword) {
                    inline else => |tag| @backingInt(@field(Keyword, @tagName(tag))),
                };
                safety.* = switch (v.safety) {
                    inline else => |tag| @backingInt(@field(LaffyAlignmentSafety, @tagName(tag))),
                };
            } else {
                keyword.* = @backingInt(LaffyAlignItems.auto);
                safety.* = @backingInt(LaffyAlignmentSafety.default);
            }
        }
    };
}

/// The properties, by the suffix of their function names (`laffy_node_set_<name>` and
/// `laffy_node_get_<name>`)
const properties = .{
    .display = Property("display", EnumCodec(LaffyDisplay, laffy.Display)),
    .box_sizing = Property("box_sizing", EnumCodec(LaffyBoxSizing, laffy.BoxSizing)),
    .direction = Property("direction", EnumCodec(LaffyDirection, laffy.Direction)),
    .item_is_table = Property("item_is_table", BoolCodec),
    .item_is_replaced = Property("item_is_replaced", BoolCodec),
    .item_is_compressible_replaced = Property("item_is_compressible_replaced", BoolCodec),
    .overflow = PairProperty("overflow", "x", "y", EnumCodec(LaffyOverflow, laffy.Overflow)),
    .scrollbar_width = Property("scrollbar_width", NonNegativeCodec),
    .contain = Property("contain", ContainCodec),
    .float = Property("float", EnumCodec(LaffyFloat, laffy.Float)),
    .clear = Property("clear", EnumCodec(LaffyClear, laffy.Clear)),
    .position = Property("position", EnumCodec(LaffyPosition, laffy.Position)),
    .inset = RectProperty("inset", LengthPercentageAutoCodec),
    .size = PairProperty("size", "width", "height", DimensionCodec),
    .min_size = PairProperty("min_size", "width", "height", LengthPercentageAutoCodec),
    .max_size = PairProperty("max_size", "width", "height", LengthPercentageAutoCodec),
    .aspect_ratio = Property("aspect_ratio", AspectRatioCodec),
    .margin = RectProperty("margin", LengthPercentageAutoCodec),
    .padding = RectProperty("padding", LengthPercentageCodec),
    .border = RectProperty("border", LengthPercentageCodec),
    .gap = PairProperty("gap", "width", "height", LengthPercentageCodec),
    .align_items = AlignProperty("align_items", LaffyAlignItems, toAlignItems),
    .justify_items = AlignProperty("justify_items", LaffyAlignItems, toAlignItems),
    .align_self = AlignProperty("align_self", LaffyAlignItems, toAlignSelf),
    .justify_self = AlignProperty("justify_self", LaffyAlignItems, toAlignSelf),
    .align_content = AlignProperty("align_content", LaffyAlignContent, toAlignContent),
    .justify_content = AlignProperty("justify_content", LaffyAlignContent, toAlignContent),
    .text_align = Property("text_align", EnumCodec(LaffyTextAlign, laffy.TextAlign)),
    .flex_direction = Property("flex_direction", EnumCodec(LaffyFlexDirection, laffy.FlexDirection)),
    .flex_wrap = Property("flex_wrap", EnumCodec(LaffyFlexWrap, laffy.FlexWrap)),
    .flex_line_count = Property("flex_line_count", LineCountCodec),
    .flex_basis = Property("flex_basis", DimensionCodec),
    .flex_grow = Property("flex_grow", NonNegativeCodec),
    .flex_shrink = Property("flex_shrink", NonNegativeCodec),
    .grid_auto_flow = Property("grid_auto_flow", EnumCodec(LaffyGridAutoFlow, laffy.GridAutoFlow)),
};

/// Getters of the grid placements (their setters copy names, see `laffy_node_set_grid_row`)
const placement_getters = .{
    .grid_row = PairProperty("grid_row", "start", "end", PlacementCodec),
    .grid_column = PairProperty("grid_column", "start", "end", PlacementCodec),
};

comptime {
    for (@typeInfo(@TypeOf(properties)).@"struct".field_names) |name| {
        @export(&@field(properties, name).set, .{ .name = "laffy_node_set_" ++ name });
        @export(&@field(properties, name).get, .{ .name = "laffy_node_get_" ++ name });
    }
    for (@typeInfo(@TypeOf(placement_getters)).@"struct".field_names) |name| {
        @export(&@field(placement_getters, name).get, .{ .name = "laffy_node_get_" ++ name });
    }
}

// ---------------------------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn newTestTree(gpa: Allocator) !*LaffyTree {
    return treeHandle(try createTree(gpa));
}

fn styleOf(tree: *LaffyTree, node: u64) *const Style {
    const impl: *TreeImpl = @ptrCast(@alignCast(tree));
    return impl.tree.style(.{ .inner = node });
}

fn lpa(v: f32) LaffyLengthPercentageAuto {
    return .{ .unit = @backingInt(LaffyUnit.length), .value = v };
}
fn lp(v: f32) LaffyLengthPercentage {
    return .{ .unit = @backingInt(LaffyUnit.length), .value = v };
}
fn dim(v: f32) LaffyDimension {
    return .{ .unit = @backingInt(LaffyUnit.length), .value = v };
}
fn unitValue(comptime T: type, unit: LaffyUnit, v: f32) T {
    return .{ .unit = @backingInt(unit), .value = v };
}
fn trackFr(v: f32) LaffyTrackSizingFunction {
    return .{ .min = unitValue(LaffyMinTrackSizing, .auto, 0), .max = unitValue(LaffyMaxTrackSizing, .fr, v) };
}
fn trackLength(v: f32) LaffyTrackSizingFunction {
    return .{ .min = unitValue(LaffyMinTrackSizing, .length, v), .max = unitValue(LaffyMaxTrackSizing, .length, v) };
}
fn single(track: LaffyTrackSizingFunction) LaffyGridTemplateComponent {
    return .{
        .kind = @backingInt(LaffyGridTemplateComponentKind.single),
        .track = track,
        .repetition_kind = 0,
        .repetition_count = 0,
        .repeat_tracks = null,
        .repeat_track_count = 0,
        .repeat_line_names = null,
        .repeat_line_name_count = 0,
    };
}
fn placement(kind: LaffyGridPlacementKind, line: i16, span: u16, name: ?[*:0]const u8) LaffyGridPlacement {
    return .{ .kind = @backingInt(kind), .line = line, .span = span, .name = name };
}
const max_content_space: LaffyAvailableSpace = .{ .tag = @backingInt(LaffyAvailableSpaceTag.max_content), .value = 0 };
fn definite(v: f32) LaffyAvailableSpace {
    return .{ .tag = @backingInt(LaffyAvailableSpaceTag.definite), .value = v };
}

test "tree and node lifecycle" {
    const tree = try newTestTree(testing.allocator);
    defer laffy_tree_free(tree);

    var a: u64 = 0;
    var b: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &a));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &b));
    var root: u64 = 0;
    const kids = [_]u64{ a, b };
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new_with_children(tree, &kids, kids.len, &root));

    var count: usize = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_child_count(tree, root, &count));
    try testing.expectEqual(@as(usize, 2), count);
    var child: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_child_at_index(tree, root, 1, &child));
    try testing.expectEqual(b, child);
    var parent: u64 = 99;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_parent(tree, a, &parent));
    try testing.expectEqual(root, parent);
    try testing.expectEqual(LaffyStatus.ok, laffy_node_parent(tree, root, &parent));
    try testing.expectEqual(@as(u64, 0), parent);

    var c: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &c));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_insert_child_at_index(tree, root, 0, c));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_child_at_index(tree, root, 0, &child));
    try testing.expectEqual(c, child);

    var old: u64 = 0;
    var d: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &d));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_replace_child_at_index(tree, root, 0, d, &old));
    try testing.expectEqual(c, old);
    // Replacing a child with itself is a no-op
    try testing.expectEqual(LaffyStatus.ok, laffy_node_replace_child_at_index(tree, root, 0, d, &old));
    try testing.expectEqual(d, old);

    try testing.expectEqual(LaffyStatus.ok, laffy_node_remove_child(tree, root, d));
    try testing.expectEqual(LaffyStatus.not_a_child, laffy_node_remove_child(tree, root, d));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_add_child(tree, root, d));
    var removed: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_remove_child_at_index(tree, root, 2, &removed));
    try testing.expectEqual(d, removed);
    try testing.expectEqual(LaffyStatus.ok, laffy_node_remove_children_range(tree, root, 0, 1));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_child_count(tree, root, &count));
    try testing.expectEqual(@as(usize, 1), count);

    const new_kids = [_]u64{ c, d, a };
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_children(tree, root, &new_kids, new_kids.len));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_child_count(tree, root, &count));
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqual(LaffyStatus.ok, laffy_node_parent(tree, b, &parent));
    try testing.expectEqual(@as(u64, 0), parent);

    var total: usize = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_tree_total_node_count(tree, &total));
    try testing.expectEqual(@as(usize, 5), total);
    try testing.expectEqual(LaffyStatus.ok, laffy_node_remove(tree, root));
    try testing.expect(!laffy_tree_contains_node(tree, root));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_parent(tree, c, &parent));
    try testing.expectEqual(@as(u64, 0), parent);
    try testing.expectEqual(LaffyStatus.ok, laffy_tree_clear(tree));
    try testing.expectEqual(LaffyStatus.ok, laffy_tree_total_node_count(tree, &total));
    try testing.expectEqual(@as(usize, 0), total);
}

test "error statuses" {
    const tree = try newTestTree(testing.allocator);
    defer laffy_tree_free(tree);

    var a: u64 = 0;
    var b: u64 = 0;
    var root: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &a));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &b));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new_with_children(tree, &[_]u64{a}, 1, &root));

    // Stale and made-up ids
    var stale: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &stale));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_remove(tree, stale));
    var reused: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &reused));
    try testing.expect(reused != stale); // the slot is reused with a new generation
    const bogus = [_]u64{ stale, 0, 0xdead_beef_0000_0001, std.math.maxInt(u64) };
    var layout: LaffyLayout = undefined;
    var count: usize = 0;
    var out: u64 = 0;
    var dirty: bool = false;
    for (bogus) |id| {
        try testing.expectEqual(LaffyStatus.invalid_input_node, laffy_node_remove(tree, id));
        try testing.expectEqual(LaffyStatus.invalid_input_node, laffy_node_get_layout(tree, id, &layout));
        try testing.expectEqual(LaffyStatus.invalid_input_node, properties.size.set(tree, id, dim(1), dim(1)));
        try testing.expectEqual(LaffyStatus.invalid_input_node, laffy_node_set_grid_auto_rows(tree, id, null, 0));
        try testing.expectEqual(LaffyStatus.invalid_input_node, laffy_node_mark_dirty(tree, id));
        try testing.expectEqual(LaffyStatus.invalid_input_node, laffy_node_is_dirty(tree, id, &dirty));
        try testing.expectEqual(LaffyStatus.invalid_input_node, laffy_node_parent(tree, id, &out));
        try testing.expectEqual(LaffyStatus.invalid_input_node, laffy_tree_compute_layout(tree, id, max_content_space, max_content_space));
        try testing.expectEqual(LaffyStatus.invalid_parent_node, laffy_node_child_count(tree, id, &count));
        try testing.expectEqual(LaffyStatus.invalid_parent_node, laffy_node_add_child(tree, id, b));
        try testing.expectEqual(LaffyStatus.invalid_child_node, laffy_node_add_child(tree, root, id));
        try testing.expectEqual(LaffyStatus.invalid_child_node, laffy_node_set_children(tree, root, &[_]u64{id}, 1));
        try testing.expectEqual(LaffyStatus.invalid_child_node, laffy_node_new_with_children(tree, &[_]u64{id}, 1, &out));
        try testing.expectEqual(LaffyStatus.invalid_child_node, laffy_node_replace_child_at_index(tree, root, 0, id, null));
        try testing.expectEqual(LaffyStatus.invalid_child_node, laffy_node_remove_child(tree, root, id));
        try testing.expect(!laffy_tree_contains_node(tree, id));
    }

    // Child indices
    try testing.expectEqual(LaffyStatus.child_index_out_of_bounds, laffy_node_child_at_index(tree, root, 1, &out));
    try testing.expectEqual(LaffyStatus.child_index_out_of_bounds, laffy_node_remove_child_at_index(tree, root, 1, null));
    try testing.expectEqual(LaffyStatus.child_index_out_of_bounds, laffy_node_replace_child_at_index(tree, root, 1, b, null));
    try testing.expectEqual(LaffyStatus.child_index_out_of_bounds, laffy_node_insert_child_at_index(tree, root, 2, b));
    try testing.expectEqual(LaffyStatus.child_index_out_of_bounds, laffy_node_remove_children_range(tree, root, 0, 2));
    try testing.expectEqual(LaffyStatus.child_index_out_of_bounds, laffy_node_remove_children_range(tree, root, 1, 0));

    // Tree-shape invariants
    try testing.expectEqual(LaffyStatus.child_has_parent, laffy_node_add_child(tree, b, a));
    try testing.expectEqual(LaffyStatus.child_has_parent, laffy_node_new_with_children(tree, &[_]u64{a}, 1, &out));
    try testing.expectEqual(LaffyStatus.would_create_cycle, laffy_node_add_child(tree, a, root));
    try testing.expectEqual(LaffyStatus.would_create_cycle, laffy_node_add_child(tree, b, b));
    try testing.expectEqual(LaffyStatus.would_create_cycle, laffy_node_set_children(tree, a, &[_]u64{root}, 1));
    try testing.expectEqual(LaffyStatus.would_create_cycle, laffy_node_set_children(tree, a, &[_]u64{a}, 1));
    try testing.expectEqual(LaffyStatus.would_create_cycle, laffy_node_replace_child_at_index(tree, root, 0, root, null));
    try testing.expectEqual(LaffyStatus.invalid_argument, laffy_node_set_children(tree, root, &[_]u64{ b, b }, 2));
    try testing.expectEqual(LaffyStatus.invalid_argument, laffy_node_new_with_children(tree, &[_]u64{ b, b }, 2, &out));

    // NULL pointers and bad values
    try testing.expectEqual(LaffyStatus.invalid_argument, laffy_node_new(null, &out));
    try testing.expectEqual(LaffyStatus.invalid_argument, laffy_node_new(tree, null));
    try testing.expectEqual(LaffyStatus.invalid_argument, laffy_node_set_children(tree, root, null, 1));
    try testing.expectEqual(LaffyStatus.invalid_argument, laffy_node_get_layout(tree, root, null));
    try testing.expectEqual(LaffyStatus.invalid_argument, properties.display.set(tree, root, 99));
    try testing.expectEqual(LaffyStatus.invalid_argument, properties.display.set(tree, root, -1));
    try testing.expectEqual(LaffyStatus.invalid_argument, properties.size.set(tree, root, unitValue(LaffyDimension, .fr, 1), dim(1)));
    try testing.expectEqual(LaffyStatus.invalid_argument, properties.size.set(tree, root, .{ .unit = 1234, .value = 1 }, dim(1)));
    try testing.expectEqual(LaffyStatus.invalid_argument, properties.size.set(tree, root, dim(std.math.nan(f32)), dim(1)));
    try testing.expectEqual(LaffyStatus.invalid_argument, properties.padding.set(tree, root, unitValue(LaffyLengthPercentage, .auto, 0), lp(0), lp(0), lp(0)));
    try testing.expectEqual(LaffyStatus.invalid_argument, properties.flex_grow.set(tree, root, -1));
    try testing.expectEqual(LaffyStatus.invalid_argument, properties.flex_line_count.set(tree, root, 0));
    try testing.expectEqual(LaffyStatus.invalid_argument, properties.aspect_ratio.set(tree, root, 0));
    try testing.expectEqual(LaffyStatus.invalid_argument, properties.contain.set(tree, root, 4));
    try testing.expectEqual(LaffyStatus.invalid_argument, properties.align_items.set(tree, root, @backingInt(LaffyAlignItems.auto), 0));
    try testing.expectEqual(LaffyStatus.invalid_argument, properties.align_content.set(tree, root, 0, 3));
    try testing.expectEqual(LaffyStatus.invalid_argument, laffy_tree_compute_layout(tree, root, .{ .tag = 7, .value = 0 }, max_content_space));
    try testing.expectEqual(LaffyStatus.invalid_argument, laffy_node_set_grid_row(tree, root, placement(.named_line, 1, 0, null), placement(.auto, 0, 0, null)));
    // Grid templates: empty repeat, zero count, wrong number of repeat line name sets
    const tracks = [_]LaffyTrackSizingFunction{trackLength(10)};
    var repeat = single(trackLength(0));
    repeat.kind = @backingInt(LaffyGridTemplateComponentKind.repeat);
    repeat.repetition_kind = @backingInt(LaffyRepetitionKind.count);
    repeat.repetition_count = 2;
    try testing.expectEqual(LaffyStatus.invalid_argument, laffy_node_set_grid_template_columns(tree, root, &[_]LaffyGridTemplateComponent{repeat}, 1, null, 0));
    repeat.repeat_tracks = &tracks;
    repeat.repeat_track_count = 1;
    const one_set = [_]LaffyLineNameSet{.{ .names = null, .count = 0 }};
    repeat.repeat_line_names = &one_set;
    repeat.repeat_line_name_count = 1;
    try testing.expectEqual(LaffyStatus.invalid_argument, laffy_node_set_grid_template_columns(tree, root, &[_]LaffyGridTemplateComponent{repeat}, 1, null, 0));
    repeat.repeat_line_name_count = 0;
    repeat.repetition_count = 0;
    try testing.expectEqual(LaffyStatus.invalid_argument, laffy_node_set_grid_template_columns(tree, root, &[_]LaffyGridTemplateComponent{repeat}, 1, null, 0));
    const bad_area = [_]LaffyGridTemplateArea{.{ .name = "a", .row_start = 2, .row_end = 2, .column_start = 1, .column_end = 2 }};
    try testing.expectEqual(LaffyStatus.invalid_argument, laffy_node_set_grid_template_areas(tree, root, &bad_area, 1, 2, 2));

    // A failed setter leaves the style unchanged
    try testing.expectEqual(Style{}, styleOf(tree, root).*);

    try testing.expectEqualStrings("child index out of bounds", std.mem.span(laffy_status_string(@backingInt(LaffyStatus.child_index_out_of_bounds))));
    try testing.expectEqualStrings("unknown status", std.mem.span(laffy_status_string(1000)));
}

test "scalar style setters round-trip" {
    const tree = try newTestTree(testing.allocator);
    defer laffy_tree_free(tree);
    var n: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &n));
    const ok = LaffyStatus.ok;

    try testing.expectEqual(ok, properties.display.set(tree, n, @backingInt(LaffyDisplay.grid)));
    try testing.expectEqual(ok, properties.item_is_table.set(tree, n, true));
    try testing.expectEqual(ok, properties.item_is_replaced.set(tree, n, true));
    try testing.expectEqual(ok, properties.item_is_compressible_replaced.set(tree, n, true));
    try testing.expectEqual(ok, properties.box_sizing.set(tree, n, @backingInt(LaffyBoxSizing.content_box)));
    try testing.expectEqual(ok, properties.direction.set(tree, n, @backingInt(LaffyDirection.rtl)));
    try testing.expectEqual(ok, properties.overflow.set(tree, n, @backingInt(LaffyOverflow.clip), @backingInt(LaffyOverflow.scroll)));
    try testing.expectEqual(ok, properties.scrollbar_width.set(tree, n, 7));
    try testing.expectEqual(ok, properties.contain.set(tree, n, contain_layout | contain_paint));
    try testing.expectEqual(ok, properties.float.set(tree, n, @backingInt(LaffyFloat.right)));
    try testing.expectEqual(ok, properties.clear.set(tree, n, @backingInt(LaffyClear.both)));
    try testing.expectEqual(ok, properties.position.set(tree, n, @backingInt(LaffyPosition.sticky)));
    try testing.expectEqual(ok, properties.inset.set(tree, n, lpa(1), unitValue(LaffyLengthPercentageAuto, .percent, 0.5), unitValue(LaffyLengthPercentageAuto, .auto, 0), lpa(4)));
    try testing.expectEqual(ok, properties.size.set(tree, n, unitValue(LaffyDimension, .fit_content_length, 30), unitValue(LaffyDimension, .stretch, 0)));
    try testing.expectEqual(ok, properties.min_size.set(tree, n, lpa(5), unitValue(LaffyLengthPercentageAuto, .percent, 0.25)));
    try testing.expectEqual(ok, properties.max_size.set(tree, n, unitValue(LaffyLengthPercentageAuto, .auto, 0), lpa(500)));
    try testing.expectEqual(ok, properties.aspect_ratio.set(tree, n, 1.5));
    try testing.expectEqual(ok, properties.margin.set(tree, n, lpa(1), lpa(2), unitValue(LaffyLengthPercentageAuto, .auto, 0), lpa(4)));
    try testing.expectEqual(ok, properties.padding.set(tree, n, lp(5), lp(6), unitValue(LaffyLengthPercentage, .percent, 0.1), lp(8)));
    try testing.expectEqual(ok, properties.border.set(tree, n, lp(9), lp(10), lp(11), lp(12)));
    try testing.expectEqual(ok, properties.align_items.set(tree, n, @backingInt(LaffyAlignItems.center), @backingInt(LaffyAlignmentSafety.safe)));
    try testing.expectEqual(ok, properties.justify_items.set(tree, n, @backingInt(LaffyAlignItems.self_end), @backingInt(LaffyAlignmentSafety.default)));
    try testing.expectEqual(ok, properties.align_self.set(tree, n, @backingInt(LaffyAlignItems.baseline), @backingInt(LaffyAlignmentSafety.unsafe)));
    try testing.expectEqual(ok, properties.justify_self.set(tree, n, @backingInt(LaffyAlignItems.stretch), 0));
    try testing.expectEqual(ok, properties.align_content.set(tree, n, @backingInt(LaffyAlignContent.space_evenly), 0));
    try testing.expectEqual(ok, properties.justify_content.set(tree, n, @backingInt(LaffyAlignContent.flex_end), @backingInt(LaffyAlignmentSafety.safe)));
    try testing.expectEqual(ok, properties.gap.set(tree, n, lp(3), unitValue(LaffyLengthPercentage, .percent, 0.2)));
    try testing.expectEqual(ok, properties.text_align.set(tree, n, @backingInt(LaffyTextAlign.legacy_center)));
    try testing.expectEqual(ok, properties.flex_direction.set(tree, n, @backingInt(LaffyFlexDirection.column_reverse)));
    try testing.expectEqual(ok, properties.flex_wrap.set(tree, n, @backingInt(LaffyFlexWrap.balance_reverse)));
    try testing.expectEqual(ok, properties.flex_line_count.set(tree, n, 3));
    try testing.expectEqual(ok, properties.flex_basis.set(tree, n, unitValue(LaffyDimension, .content, 0)));
    try testing.expectEqual(ok, properties.flex_grow.set(tree, n, 2));
    try testing.expectEqual(ok, properties.flex_shrink.set(tree, n, 0.5));
    try testing.expectEqual(ok, properties.grid_auto_flow.set(tree, n, @backingInt(LaffyGridAutoFlow.column_dense)));

    const expected: Style = .{
        .display = .grid,
        .item_is_table = true,
        .item_is_replaced = true,
        .item_is_compressible_replaced = true,
        .box_sizing = .content_box,
        .direction = .rtl,
        .overflow = .{ .x = .clip, .y = .scroll },
        .scrollbar_width = 7,
        .contain = laffy.Contain.content,
        .float = .right,
        .clear = .both,
        .position = .sticky,
        .inset = .{ .top = .fromLength(1), .right = .fromPercent(0.5), .bottom = .auto, .left = .fromLength(4) },
        .size = .{ .width = .fitContentPx(30), .height = .stretch },
        .min_size = .{ .width = .fromLength(5), .height = .fromPercent(0.25) },
        .max_size = .{ .width = .auto, .height = .fromLength(500) },
        .aspect_ratio = 1.5,
        .margin = .{ .top = .fromLength(1), .right = .fromLength(2), .bottom = .auto, .left = .fromLength(4) },
        .padding = .{ .top = .fromLength(5), .right = .fromLength(6), .bottom = .fromPercent(0.1), .left = .fromLength(8) },
        .border = .{ .top = .fromLength(9), .right = .fromLength(10), .bottom = .fromLength(11), .left = .fromLength(12) },
        .align_items = AlignItems.safe_center,
        .justify_items = AlignItems.self_end,
        .align_self = AlignItems.baseline.withSafety(.unsafe),
        .justify_self = AlignItems.stretch,
        .align_content = AlignContent.space_evenly,
        .justify_content = AlignContent.safe_flex_end,
        .gap = .{ .width = .fromLength(3), .height = .fromPercent(0.2) },
        .text_align = .legacy_center,
        .flex_direction = .column_reverse,
        .flex_wrap = .balance_reverse,
        .flex_line_count = 3,
        .flex_basis = .content,
        .flex_grow = 2,
        .flex_shrink = 0.5,
        .grid_auto_flow = .column_dense,
    };
    try testing.expectEqual(expected, styleOf(tree, n).*);

    // Unsetting
    try testing.expectEqual(ok, properties.align_self.set(tree, n, @backingInt(LaffyAlignItems.auto), 0));
    try testing.expectEqual(@as(?AlignItems, null), styleOf(tree, n).align_self);
    try testing.expectEqual(ok, properties.aspect_ratio.set(tree, n, std.math.nan(f32)));
    try testing.expectEqual(@as(?f32, null), styleOf(tree, n).aspect_ratio);
    try testing.expectEqual(ok, properties.contain.set(tree, n, 0));
    try testing.expectEqual(laffy.Contain.none, styleOf(tree, n).contain);
    try testing.expectEqual(ok, laffy_node_reset_style(tree, n));
    try testing.expectEqual(Style{}, styleOf(tree, n).*);

    // Every unit maps to the expected `Dimension`
    const units = [_]struct { LaffyUnit, Dimension }{
        .{ .length, .fromLength(2) },                     .{ .percent, .fromPercent(2) },
        .{ .auto, .auto },                                .{ .min_content, .min_content },
        .{ .max_content, .max_content },                  .{ .fit_content_length, .fitContentPx(2) },
        .{ .fit_content_percent, .fitContentPercent(2) }, .{ .fit_content, .fit_content },
        .{ .stretch, .stretch },                          .{ .content, .content },
    };
    for (units) |entry| {
        try testing.expectEqual(ok, properties.flex_basis.set(tree, n, unitValue(LaffyDimension, entry[0], 2)));
        try testing.expectEqual(entry[1], styleOf(tree, n).flex_basis);
    }
}

fn expectTrack(expected: TrackSizingFunction, actual: TrackSizingFunction) !void {
    try testing.expect(expected.eql(actual));
}

test "style getters read back what the setters stored" {
    const tree = try newTestTree(testing.allocator);
    defer laffy_tree_free(tree);
    var n: u64 = 0;
    const ok = LaffyStatus.ok;
    try testing.expectEqual(ok, laffy_node_new(tree, &n));

    // Defaults
    var int_a: c_int = -1;
    var int_b: c_int = -1;
    var float: f32 = -1;
    var flag = true;
    try testing.expectEqual(ok, properties.display.get(tree, n, &int_a));
    try testing.expectEqual(@backingInt(LaffyDisplay.flex), int_a);
    try testing.expectEqual(ok, properties.item_is_table.get(tree, n, &flag));
    try testing.expect(!flag);
    try testing.expectEqual(ok, properties.aspect_ratio.get(tree, n, &float));
    try testing.expect(std.math.isNan(float));
    try testing.expectEqual(ok, properties.align_self.get(tree, n, &int_a, &int_b));
    try testing.expectEqual(@backingInt(LaffyAlignItems.auto), int_a);
    try testing.expectEqual(@backingInt(LaffyAlignmentSafety.default), int_b);
    try testing.expectEqual(ok, properties.flex_shrink.get(tree, n, &float));
    try testing.expectEqual(@as(f32, 1), float);

    // Enums, bools, numbers and flags
    try testing.expectEqual(ok, properties.position.set(tree, n, @backingInt(LaffyPosition.sticky)));
    try testing.expectEqual(ok, properties.position.get(tree, n, &int_a));
    try testing.expectEqual(@backingInt(LaffyPosition.sticky), int_a);
    try testing.expectEqual(ok, properties.overflow.set(tree, n, @backingInt(LaffyOverflow.clip), @backingInt(LaffyOverflow.scroll)));
    try testing.expectEqual(ok, properties.overflow.get(tree, n, &int_a, &int_b));
    try testing.expectEqual(@backingInt(LaffyOverflow.clip), int_a);
    try testing.expectEqual(@backingInt(LaffyOverflow.scroll), int_b);
    try testing.expectEqual(ok, properties.item_is_replaced.set(tree, n, true));
    flag = false;
    try testing.expectEqual(ok, properties.item_is_replaced.get(tree, n, &flag));
    try testing.expect(flag);
    try testing.expectEqual(ok, properties.aspect_ratio.set(tree, n, 1.5));
    try testing.expectEqual(ok, properties.aspect_ratio.get(tree, n, &float));
    try testing.expectEqual(@as(f32, 1.5), float);
    var flags: u32 = 99;
    try testing.expectEqual(ok, properties.contain.set(tree, n, contain_paint));
    try testing.expectEqual(ok, properties.contain.get(tree, n, &flags));
    try testing.expectEqual(contain_paint, flags);
    var count: u16 = 0;
    try testing.expectEqual(ok, properties.flex_line_count.set(tree, n, 3));
    try testing.expectEqual(ok, properties.flex_line_count.get(tree, n, &count));
    try testing.expectEqual(@as(u16, 3), count);

    // Alignment
    try testing.expectEqual(ok, properties.align_self.set(tree, n, @backingInt(LaffyAlignItems.baseline), @backingInt(LaffyAlignmentSafety.unsafe)));
    try testing.expectEqual(ok, properties.align_self.get(tree, n, &int_a, &int_b));
    try testing.expectEqual(@backingInt(LaffyAlignItems.baseline), int_a);
    try testing.expectEqual(@backingInt(LaffyAlignmentSafety.unsafe), int_b);
    try testing.expectEqual(ok, properties.justify_content.set(tree, n, @backingInt(LaffyAlignContent.space_evenly), @backingInt(LaffyAlignmentSafety.safe)));
    try testing.expectEqual(ok, properties.justify_content.get(tree, n, &int_a, &int_b));
    try testing.expectEqual(@backingInt(LaffyAlignContent.space_evenly), int_a);
    try testing.expectEqual(@backingInt(LaffyAlignmentSafety.safe), int_b);

    // Every unit a dimension accepts survives the round trip
    const units = [_]LaffyUnit{ .length, .percent, .auto, .min_content, .max_content, .fit_content_length, .fit_content_percent, .fit_content, .stretch, .content };
    for (units) |unit| {
        const has_value = switch (unit) {
            .length, .percent, .fit_content_length, .fit_content_percent => true,
            else => false,
        };
        const value: f32 = if (has_value) 0.25 else 0;
        try testing.expectEqual(ok, properties.size.set(tree, n, unitValue(LaffyDimension, unit, value), dim(7)));
        var width: LaffyDimension = undefined;
        var height: LaffyDimension = undefined;
        try testing.expectEqual(ok, properties.size.get(tree, n, &width, &height));
        try testing.expectEqual(unitValue(LaffyDimension, unit, value), width);
        try testing.expectEqual(dim(7), height);
    }

    // Rectangles are top, right, bottom, left
    var edges: [4]LaffyLengthPercentageAuto = undefined;
    try testing.expectEqual(ok, properties.margin.set(tree, n, lpa(1), lpa(2), unitValue(LaffyLengthPercentageAuto, .auto, 0), unitValue(LaffyLengthPercentageAuto, .percent, 0.5)));
    try testing.expectEqual(ok, properties.margin.get(tree, n, &edges[0], &edges[1], &edges[2], &edges[3]));
    try testing.expectEqual(lpa(1), edges[0]);
    try testing.expectEqual(lpa(2), edges[1]);
    try testing.expectEqual(unitValue(LaffyLengthPercentageAuto, .auto, 0), edges[2]);
    try testing.expectEqual(unitValue(LaffyLengthPercentageAuto, .percent, 0.5), edges[3]);
    try testing.expect(styleOf(tree, n).margin.left.eql(.fromPercent(0.5)));

    // Grid placements, including names
    var start: LaffyGridPlacement = undefined;
    var end: LaffyGridPlacement = undefined;
    try testing.expectEqual(ok, laffy_node_set_grid_row(
        tree,
        n,
        .{ .kind = @backingInt(LaffyGridPlacementKind.named_line), .line = -2, .span = 0, .name = "header" },
        .{ .kind = @backingInt(LaffyGridPlacementKind.named_span), .line = 0, .span = 3, .name = "footer" },
    ));
    try testing.expectEqual(ok, placement_getters.grid_row.get(tree, n, &start, &end));
    try testing.expectEqual(@backingInt(LaffyGridPlacementKind.named_line), start.kind);
    try testing.expectEqual(@as(i16, -2), start.line);
    try testing.expectEqualStrings("header", std.mem.span(start.name.?));
    try testing.expectEqual(@backingInt(LaffyGridPlacementKind.named_span), end.kind);
    try testing.expectEqual(@as(u16, 3), end.span);
    try testing.expectEqualStrings("footer", std.mem.span(end.name.?));
    try testing.expectEqual(ok, placement_getters.grid_column.get(tree, n, &start, &end));
    try testing.expectEqual(@backingInt(LaffyGridPlacementKind.auto), start.kind);
    try testing.expectEqual(@as(?[*:0]const u8, null), start.name);

    // Failures leave the out-parameters untouched
    int_a = 77;
    try testing.expectEqual(LaffyStatus.invalid_input_node, properties.display.get(tree, 0, &int_a));
    try testing.expectEqual(LaffyStatus.invalid_argument, properties.display.get(tree, n, null));
    try testing.expectEqual(LaffyStatus.invalid_argument, properties.display.get(null, n, &int_a));
    try testing.expectEqual(LaffyStatus.invalid_argument, properties.overflow.get(tree, n, &int_a, null));
    try testing.expectEqual(@as(c_int, 77), int_a);
}

test "grid setters round-trip and copy their data" {
    const tree = try newTestTree(testing.allocator);
    defer laffy_tree_free(tree);
    var n: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &n));

    // Mutable C buffers, overwritten after the call to prove the data was copied
    var name_a = "alpha".*;
    var name_b = "beta".*;
    const names_0 = [_]?[*:0]const u8{&name_a};
    const names_1 = [_]?[*:0]const u8{&name_b};
    const repeat_names = [_]LaffyLineNameSet{
        .{ .names = &names_0, .count = 1 },
        .{ .names = null, .count = 0 },
    };
    const repeat_tracks = [_]LaffyTrackSizingFunction{.{
        .min = unitValue(LaffyMinTrackSizing, .length, 20),
        .max = unitValue(LaffyMaxTrackSizing, .fit_content_percent, 0.5),
    }};
    var repeat = single(trackLength(0));
    repeat.kind = @backingInt(LaffyGridTemplateComponentKind.repeat);
    repeat.repetition_kind = @backingInt(LaffyRepetitionKind.auto_fill);
    repeat.repeat_tracks = &repeat_tracks;
    repeat.repeat_track_count = 1;
    repeat.repeat_line_names = &repeat_names;
    repeat.repeat_line_name_count = 2;
    const components = [_]LaffyGridTemplateComponent{ single(trackFr(1)), repeat, single(trackLength(10)) };
    const template_names = [_]LaffyLineNameSet{ .{ .names = &names_1, .count = 1 }, .{ .names = null, .count = 0 } };

    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_template_columns(tree, n, &components, components.len, &template_names, template_names.len));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_template_rows(tree, n, &components, 1, null, 0));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_auto_rows(tree, n, &[_]LaffyTrackSizingFunction{ trackFr(2), trackLength(4) }, 2));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_auto_columns(tree, n, &[_]LaffyTrackSizingFunction{trackLength(6)}, 1));
    var area_name = "header".*;
    const areas = [_]LaffyGridTemplateArea{.{ .name = &area_name, .row_start = 1, .row_end = 2, .column_start = 1, .column_end = 4 }};
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_template_areas(tree, n, &areas, 1, 3, 3));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_row(tree, n, placement(.named_line, -2, 0, &name_a), placement(.named_span, 0, 3, &name_b)));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_column(tree, n, placement(.line, -1, 0, null), placement(.span, 0, 2, null)));

    @memset(&name_a, 'x');
    @memset(&name_b, 'y');
    @memset(&area_name, 'z');

    const style = styleOf(tree, n);
    try testing.expectEqual(@as(usize, 3), style.grid_template_columns.len);
    try expectTrack(TrackSizingFunction.fromFr(1), style.grid_template_columns[0].single);
    const rep = style.grid_template_columns[1].repeat;
    try testing.expectEqual(laffy.RepetitionCount.auto_fill, rep.count);
    try testing.expectEqual(@as(usize, 1), rep.tracks.len);
    try expectTrack(.{ .min = .fromLength(20), .max = .fitContentPercent(0.5) }, rep.tracks[0]);
    try testing.expectEqual(@as(usize, 2), rep.line_names.len);
    try testing.expectEqualStrings("alpha", rep.line_names[0][0]);
    try testing.expectEqual(@as(usize, 0), rep.line_names[1].len);
    try expectTrack(TrackSizingFunction.fromLength(10), style.grid_template_columns[2].single);
    try testing.expectEqual(@as(usize, 2), style.grid_template_column_names.len);
    try testing.expectEqualStrings("beta", style.grid_template_column_names[0][0]);
    try testing.expectEqual(@as(usize, 1), style.grid_template_rows.len);
    try testing.expectEqual(@as(usize, 0), style.grid_template_row_names.len);
    try testing.expectEqual(@as(usize, 2), style.grid_auto_rows.len);
    try expectTrack(TrackSizingFunction.fromFr(2), style.grid_auto_rows[0]);
    try expectTrack(TrackSizingFunction.fromLength(6), style.grid_auto_columns[0]);
    const template_areas = style.grid_template_areas.?;
    try testing.expectEqual(@as(u16, 3), template_areas.row_count);
    try testing.expectEqualStrings("header", template_areas.areas[0].name);
    try testing.expectEqual(@as(u16, 4), template_areas.areas[0].column_end);
    try testing.expect(style.grid_row.start.eql(.{ .named_line = .{ .name = "alpha", .index = -2 } }));
    try testing.expect(style.grid_row.end.eql(.{ .named_span = .{ .name = "beta", .count = 3 } }));
    try testing.expect(style.grid_column.start.eql(GridPlacement.fromLineIndex(-1)));
    try testing.expect(style.grid_column.end.eql(.{ .span = 2 }));

    // Replacing properties frees the old data (checked by the leak-detecting allocator)
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_template_columns(tree, n, &components, 2, null, 0));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_template_columns(tree, n, null, 0, null, 0));
    try testing.expectEqual(@as(usize, 0), styleOf(tree, n).grid_template_columns.len);
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_template_areas(tree, n, null, 0, 0, 0));
    try testing.expectEqual(@as(?laffy.GridTemplateAreas, null), styleOf(tree, n).grid_template_areas);
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_row(tree, n, placement(.auto, 0, 0, null), placement(.auto, 0, 0, null)));

    // A failed grid setter keeps the previous value
    const bad = [_]LaffyTrackSizingFunction{.{ .min = unitValue(LaffyMinTrackSizing, .fr, 1), .max = unitValue(LaffyMaxTrackSizing, .fr, 1) }};
    try testing.expectEqual(LaffyStatus.invalid_argument, laffy_node_set_grid_auto_rows(tree, n, &bad, 1));
    try testing.expectEqual(@as(usize, 2), styleOf(tree, n).grid_auto_rows.len);

    // Node removal frees the data of the removed node; tree destruction frees the rest
    var m: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &m));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_auto_rows(tree, m, &[_]LaffyTrackSizingFunction{trackFr(2)}, 1));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_remove(tree, m));
    var k: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &k));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_auto_rows(tree, k, &[_]LaffyTrackSizingFunction{trackFr(2)}, 1));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_reset_style(tree, k));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_auto_rows(tree, k, &[_]LaffyTrackSizingFunction{trackFr(2)}, 1));
}

test "grid data is freed on clear" {
    const tree = try newTestTree(testing.allocator);
    defer laffy_tree_free(tree);
    var n: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &n));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_auto_rows(tree, n, &[_]LaffyTrackSizingFunction{trackFr(2)}, 1));
    try testing.expectEqual(LaffyStatus.ok, laffy_tree_clear(tree));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &n));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_auto_columns(tree, n, &[_]LaffyTrackSizingFunction{trackFr(2)}, 1));
}

test "flex layout through the C API" {
    const tree = try newTestTree(testing.allocator);
    defer laffy_tree_free(tree);
    var a: u64 = 0;
    var b: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &a));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &b));
    try testing.expectEqual(LaffyStatus.ok, properties.flex_grow.set(tree, a, 1));
    try testing.expectEqual(LaffyStatus.ok, properties.size.set(tree, b, dim(50), dim(20)));
    var root: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new_with_children(tree, &[_]u64{ a, b }, 2, &root));
    try testing.expectEqual(LaffyStatus.ok, properties.size.set(tree, root, dim(200), dim(100)));
    try testing.expectEqual(LaffyStatus.ok, properties.gap.set(tree, root, lp(10), lp(0)));
    var dirty = false;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_is_dirty(tree, root, &dirty));
    try testing.expect(dirty);
    try testing.expectEqual(LaffyStatus.ok, laffy_tree_compute_layout(tree, root, max_content_space, max_content_space));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_is_dirty(tree, root, &dirty));
    try testing.expect(!dirty);
    var layout: LaffyLayout = undefined;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_get_layout(tree, a, &layout));
    try testing.expectEqual(@as(f32, 140), layout.size.width);
    try testing.expectEqual(@as(f32, 100), layout.size.height);
    try testing.expectEqual(LaffyStatus.ok, laffy_node_get_layout(tree, b, &layout));
    try testing.expectEqual(@as(f32, 150), layout.location.x);
    try testing.expectEqual(@as(u32, 1), layout.order);
}

const MeasureState = struct {
    calls: usize = 0,
    last_known_width: f32 = 0,
    last_available_width: LaffyAvailableSpace = undefined,
};

fn testMeasure(user_data: ?*anyopaque, node: u64, known_width: f32, known_height: f32, available_width: LaffyAvailableSpace, available_height: LaffyAvailableSpace) callconv(.c) LaffySize {
    _ = node;
    _ = available_height;
    const state: *MeasureState = @ptrCast(@alignCast(user_data.?));
    state.calls += 1;
    state.last_known_width = known_width;
    state.last_available_width = available_width;
    return .{
        .width = if (std.math.isNan(known_width)) 42 else known_width,
        .height = if (std.math.isNan(known_height)) 24 else known_height,
    };
}

test "measure functions" {
    const tree = try newTestTree(testing.allocator);
    defer laffy_tree_free(tree);
    var state: MeasureState = .{};
    var leaf: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &leaf));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_context(tree, leaf, &state));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_measure_func(tree, leaf, &testMeasure));
    var ud: ?*anyopaque = null;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_get_context(tree, leaf, &ud));
    try testing.expectEqual(@as(?*anyopaque, &state), ud);

    try testing.expectEqual(LaffyStatus.ok, laffy_tree_compute_layout(tree, leaf, definite(300), max_content_space));
    var layout: LaffyLayout = undefined;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_get_layout(tree, leaf, &layout));
    try testing.expectEqual(@as(f32, 42), layout.size.width);
    try testing.expectEqual(@as(f32, 24), layout.size.height);
    try testing.expect(state.calls >= 1);
    try testing.expect(std.math.isNan(state.last_known_width));
    try testing.expectEqual(@backingInt(LaffyAvailableSpaceTag.definite), state.last_available_width.tag);
    try testing.expectEqual(@as(f32, 300), state.last_available_width.value);

    // Without the measure function the leaf is empty
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_measure_func(tree, leaf, null));
    try testing.expectEqual(LaffyStatus.ok, laffy_tree_compute_layout(tree, leaf, definite(300), max_content_space));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_get_layout(tree, leaf, &layout));
    try testing.expectEqual(@as(f32, 0), layout.size.width);
}

test "grid placement edge values do not panic" {
    const tree = try newTestTree(testing.allocator);
    defer laffy_tree_free(tree);
    var item: u64 = 0;
    var item2: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &item));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &item2));
    var root: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new_with_children(tree, &[_]u64{ item, item2 }, 2, &root));
    try testing.expectEqual(LaffyStatus.ok, properties.display.set(tree, root, @backingInt(LaffyDisplay.grid)));
    // Line 0 and span 0 are invalid CSS and fall back to auto / 1; extreme lines are clamped
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_row(tree, item, placement(.line, 0, 0, null), placement(.span, 0, 0, null)));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_column(tree, item, placement(.line, std.math.minInt(i16), 0, null), placement(.line, std.math.maxInt(i16), 0, null)));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_row(tree, item2, placement(.named_line, 0, 0, "nope"), placement(.named_span, 0, 0, "nope")));
    const areas = [_]LaffyGridTemplateArea{.{ .name = "big", .row_start = 1, .row_end = std.math.maxInt(u16), .column_start = 1, .column_end = 3 }};
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_template_areas(tree, root, &areas, 1, 1, 1));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_column(tree, item2, placement(.named_line, 0, 0, "big"), placement(.auto, 0, 0, null)));
    try testing.expectEqual(LaffyStatus.ok, laffy_tree_compute_layout(tree, root, definite(100), definite(100)));
}

const CountingAllocator = struct {
    live: usize = 0,
    total: usize = 0,

    fn alloc(user_data: ?*anyopaque, size: usize, alignment: usize) callconv(.c) ?*anyopaque {
        const self: *CountingAllocator = @ptrCast(@alignCast(user_data.?));
        const block = testing.allocator.rawAlloc(size, .fromByteUnits(alignment), @returnAddress()) orelse return null;
        self.live += 1;
        self.total += 1;
        return @ptrCast(block);
    }

    fn free(user_data: ?*anyopaque, ptr: ?*anyopaque, size: usize, alignment: usize) callconv(.c) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(user_data.?));
        const p: [*]u8 = @ptrCast(ptr.?);
        testing.allocator.rawFree(p[0..size], .fromByteUnits(alignment), @returnAddress());
        self.live -= 1;
    }
};

test "custom C allocator" {
    var counter: CountingAllocator = .{};
    const c_alloc: LaffyAllocator = .{ .user_data = &counter, .alloc = &CountingAllocator.alloc, .free = &CountingAllocator.free };
    var tree: ?*LaffyTree = null;
    try testing.expectEqual(LaffyStatus.ok, laffy_tree_new_with_allocator(&c_alloc, &tree));
    var n: u64 = 0;
    try testing.expectEqual(LaffyStatus.ok, laffy_node_new(tree, &n));
    try testing.expectEqual(LaffyStatus.ok, laffy_node_set_grid_auto_rows(tree, n, &[_]LaffyTrackSizingFunction{trackFr(2)}, 1));
    try testing.expectEqual(LaffyStatus.ok, laffy_tree_compute_layout(tree, n, max_content_space, max_content_space));
    try testing.expect(counter.live > 0);
    laffy_tree_free(tree);
    try testing.expectEqual(@as(usize, 0), counter.live);
    try testing.expect(counter.total > 0);

    const missing: LaffyAllocator = .{ .user_data = null, .alloc = null, .free = &CountingAllocator.free };
    try testing.expectEqual(LaffyStatus.invalid_argument, laffy_tree_new_with_allocator(&missing, &tree));
    laffy_tree_free(null);
}

/// A scenario that touches every allocating path; run under allocation failure at every index
fn allocationScenario(gpa: Allocator) !void {
    const impl = createTree(gpa) catch return;
    const tree = treeHandle(impl);
    defer laffy_tree_free(tree);
    var nodes: [24]u64 = undefined;
    for (&nodes) |*n| {
        const status = laffy_node_new(tree, n);
        if (status == .out_of_memory) return;
        try testing.expectEqual(LaffyStatus.ok, status);
    }
    const allowed = [_]LaffyStatus{ .ok, .out_of_memory };
    var root: u64 = 0;
    var status = laffy_node_new_with_children(tree, nodes[0..20], 20, &root);
    try testing.expect(std.mem.indexOfScalar(LaffyStatus, &allowed, status) != null);
    if (status != .ok) return;
    status = properties.display.set(tree, root, @backingInt(LaffyDisplay.grid));
    try testing.expectEqual(LaffyStatus.ok, status);
    const name = "a";
    const names = [_]?[*:0]const u8{name};
    const sets = [_]LaffyLineNameSet{ .{ .names = &names, .count = 1 }, .{ .names = &names, .count = 1 } };
    var repeat = single(trackLength(0));
    repeat.kind = @backingInt(LaffyGridTemplateComponentKind.repeat);
    repeat.repetition_kind = @backingInt(LaffyRepetitionKind.count);
    repeat.repetition_count = 3;
    const tracks = [_]LaffyTrackSizingFunction{trackFr(1)};
    repeat.repeat_tracks = &tracks;
    repeat.repeat_track_count = 1;
    repeat.repeat_line_names = &sets;
    repeat.repeat_line_name_count = 2;
    status = laffy_node_set_grid_template_columns(tree, root, &[_]LaffyGridTemplateComponent{repeat}, 1, &sets, 2);
    try testing.expect(std.mem.indexOfScalar(LaffyStatus, &allowed, status) != null);
    status = laffy_node_set_grid_column(tree, nodes[0], placement(.named_line, 2, 0, name), placement(.span, 0, 2, null));
    try testing.expect(std.mem.indexOfScalar(LaffyStatus, &allowed, status) != null);
    status = laffy_node_set_children(tree, nodes[20], nodes[21..24], 3);
    try testing.expect(std.mem.indexOfScalar(LaffyStatus, &allowed, status) != null);
    status = laffy_node_add_child(tree, root, nodes[20]);
    try testing.expect(std.mem.indexOfScalar(LaffyStatus, &allowed, status) != null);
    status = laffy_tree_compute_layout(tree, root, definite(300), max_content_space);
    try testing.expect(std.mem.indexOfScalar(LaffyStatus, &allowed, status) != null);
}

test "allocation failures map to out-of-memory without leaks" {
    var fail_index: usize = 0;
    while (fail_index < 400) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        try allocationScenario(failing.allocator());
        if (!failing.has_induced_failure) break;
    }
}
