//! Code for resolving name grid lines and areas
//!
//! Map iteration order: upstream stores named lines and areas in hash maps. Every use of those
//! maps here is a keyed lookup, an insertion, or an order-independent per-value operation (sorting
//! and deduplicating each name's line list), so the iteration order of the std hash maps used in
//! laffy cannot affect results. (Upstream's `Debug` impl iterates the maps; laffy's `format`
//! does too, and only its output order differs.)
//!
//! String ownership: names are borrowed `[]const u8` slices of the container's style (see
//! `style/grid.zig`), including the area names derived from `<name>-start`/`<name>-end` line names
//! (which are sub-slices of the line names). The maps own only their storage.
const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("../../../geometry.zig");
const AbsoluteAxis = geometry.AbsoluteAxis;
const Line = geometry.Line;
const style_grid = @import("../../../style/grid.zig");
const GridAreaAxis = style_grid.GridAreaAxis;
const GridAreaEnd = style_grid.GridAreaEnd;
const GridPlacement = style_grid.GridPlacement;
const NonNamedGridPlacement = style_grid.NonNamedGridPlacement;
const LayoutError = @import("../../../tree/layout.zig").LayoutError;
const coordinates = @import("coordinates.zig");
const GridLine = coordinates.GridLine;
const OriginZeroLine = coordinates.OriginZeroLine;
const max_grid_tracks = coordinates.max_grid_tracks;

/// The one-indexed line positions of a single grid line name (upstream `SmallVec<[u32; 4]>`)
pub const LinePositions = std.ArrayList(u32);

/// Map from a grid line name to its one-indexed line positions
pub const NamedGridLinesMap = std.StringHashMapUnmanaged(LinePositions);

/// Free a named line map and every line list it holds
fn deinitLinesMap(gpa: Allocator, map: *NamedGridLinesMap) void {
    var it = map.valueIterator();
    while (it.next()) |lines| lines.deinit(gpa);
    map.deinit(gpa);
}

/// The one-indexed positions of the first line that starts and the first line that ends a named grid area in
/// each axis, i.e. the first line named `<area-name>-start`/`<area-name>-end` (explicitly or by
/// `grid-template-areas`). A value of 0 means that there is no such line.
pub const AreaLines = struct {
    /// The first line that starts the area in the row axis
    row_start: u32 = 0,
    /// The first line that ends the area in the row axis
    row_end: u32 = 0,
    /// The first line that starts the area in the column axis
    column_start: u32 = 0,
    /// The first line that ends the area in the column axis
    column_end: u32 = 0,

    /// The line for the passed edge of the area (if there is one)
    fn line(self: *const AreaLines, axis: GridAreaAxis, end: GridAreaEnd) ?*const u32 {
        const line_ptr: *const u32 = switch (axis) {
            .row => switch (end) {
                .start => &self.row_start,
                .end => &self.row_end,
            },
            .column => switch (end) {
                .start => &self.column_start,
                .end => &self.column_end,
            },
        };
        return if (line_ptr.* != 0) line_ptr else null;
    }

    /// The line for the passed edge of the area (0 if there is none)
    fn lineMut(self: *AreaLines, axis: GridAreaAxis, end: GridAreaEnd) *u32 {
        return switch (axis) {
            .row => switch (end) {
                .start => &self.row_start,
                .end => &self.row_end,
            },
            .column => switch (end) {
                .start => &self.column_start,
                .end => &self.column_end,
            },
        };
    }
};

/// Map from the name of a grid area to the lines of its edges.
///
/// This is how the `<area-name>-start` and `<area-name>-end` line names that `grid-template-areas` implicitly
/// generates are represented: storing them as line names would require allocating a string for each of them.
pub const GridAreasMap = std.StringHashMapUnmanaged(AreaLines);

/// The result of `splitAreaEdgeName`
const AreaEdgeName = struct { area_name: []const u8, end: GridAreaEnd };

/// Split a line name of the form `<area-name>-start` or `<area-name>-end` into the area name and the edge
fn splitAreaEdgeName(name: []const u8) ?AreaEdgeName {
    if (std.mem.endsWith(u8, name, "-start")) {
        return .{ .area_name = name[0 .. name.len - "-start".len], .end = .start };
    } else if (std.mem.endsWith(u8, name, "-end")) {
        return .{ .area_name = name[0 .. name.len - "-end".len], .end = .end };
    } else {
        return null;
    }
}

/// Resolver for named placements in one grid axis
const NamedLineResolverAxis = struct {
    /// Named lines and their one-indexed positions
    lines: *const NamedGridLinesMap,
    /// The edges of named grid areas (in both axes)
    areas: *const GridAreasMap,
    /// The axis being resolved
    axis: GridAreaAxis,
    /// Number of explicit tracks in this axis
    explicit_track_count: u16,

    /// The line for the passed edge of the named grid area in this axis (if there is one)
    fn areaLine(self: NamedLineResolverAxis, area_name: []const u8, end: GridAreaEnd) ?*const u32 {
        const area = self.areas.getPtr(area_name) orelse return null;
        return area.line(self.axis, end);
    }

    /// Resolve named lines and spans into numeric placements
    fn resolveLineNames(self: NamedLineResolverAxis, line: Line(GridPlacement)) Line(NonNamedGridPlacement) {
        const start_line_resolved: GridPlacement = switch (line.start) {
            .named_line => |named| .{ .line = self.findNamedLine(named.name, named.index, .start) },
            else => line.start,
        };
        const end_line_resolved: GridPlacement = switch (line.end) {
            .named_line => |named| .{ .line = self.findNamedLine(named.name, named.index, .end) },
            else => line.end,
        };

        // If both the *-start and *-end values of its grid-placement properties specify a line, its grid span is implicit.
        // If it has an explicit span value, its grid span is explicit.
        // Otherwise, its grid span is automatic:
        //   - if it is subgridded in that axis, its grid span is determined from its <line-name-list>;
        //   - otherwise its grid span is 1.
        //
        // <https://drafts.csswg.org/css-grid-2/#grid-span>
        if (start_line_resolved == .line and end_line_resolved == .named_span and start_line_resolved.line.asI16() != 0) {
            const start_line = start_line_resolved.line;
            const named = end_line_resolved.named_span;
            const after_start_line = start_line.intoOriginZeroLine(self.explicit_track_count).add(@as(u16, 1));
            const end_line = self.nthLineForwards(self.linesNamed(named.name), after_start_line, @max(named.count, 1));
            return .{
                .start = .{ .line = start_line },
                .end = .{ .line = end_line.intoGridLine(self.explicit_track_count) },
            };
        }
        if (start_line_resolved == .named_span and end_line_resolved == .line and end_line_resolved.line.asI16() != 0) {
            const end_line = end_line_resolved.line;
            const named = start_line_resolved.named_span;
            const before_end_line = end_line.intoOriginZeroLine(self.explicit_track_count).sub(@as(u16, 1));
            const start_line = self.nthLineBackwards(self.linesNamed(named.name), before_end_line, @max(named.count, 1));
            return .{
                .start = .{ .line = start_line.intoGridLine(self.explicit_track_count) },
                .end = .{ .line = end_line },
            };
        }
        return .{ .start = toNonNamed(start_line_resolved), .end = toNonNamed(end_line_resolved) };
    }

    /// Convert a placement whose named lines have been resolved into a `NonNamedGridPlacement`
    fn toNonNamed(placement: GridPlacement) NonNamedGridPlacement {
        return switch (placement) {
            .auto => .auto,
            .line => |grid_line| .{ .line = grid_line },
            .span => |span| .{ .span = span },
            .named_span => .{ .span = 1 },
            .named_line => unreachable,
        };
    }

    /// Resolve the grid line for a named grid line (`<custom-ident>` or `<integer> <custom-ident>`).
    /// An index of 0 is used to represent "no index specified".
    ///
    /// <https://drafts.csswg.org/css-grid-2/#line-placement>
    fn findNamedLine(self: NamedLineResolverAxis, name: []const u8, idx: i16, end: GridAreaEnd) GridLine {
        // A `<custom-ident>` on its own first attempts to match the edge of a named grid area:
        // the first line named `<custom-ident>-start` (or `<custom-ident>-end` for an end line).
        // Otherwise it is treated as if the integer 1 had been specified along with it.
        if (idx == 0) {
            if (self.areaLine(name, end)) |first_line| {
                return OriginZeroLine.clamped(ozLine(first_line.*)).intoGridLine(self.explicit_track_count);
            }
        }

        const lines = self.linesNamed(name);
        const line = if (idx >= 0)
            self.nthLineForwards(lines, OriginZeroLine.from(0), @max(@as(i32, idx), 1))
        else
            self.nthLineBackwards(lines, self.lastExplicitLine(), -@as(i32, idx));
        return line.intoGridLine(self.explicit_track_count);
    }

    /// The sorted line numbers of the lines with the passed name
    ///
    /// A line generated by a grid area is included in the lines of its name if any line has been explicitly
    /// given the same name. Otherwise it is found from the area's edges.
    fn linesNamed(self: NamedLineResolverAxis, name: []const u8) []const u32 {
        if (self.lines.getPtr(name)) |lines| return lines.items;
        const edge = splitAreaEdgeName(name) orelse return &.{};
        const area_line = self.areaLine(edge.area_name, edge.end) orelse return &.{};
        return @as(*const [1]u32, area_line);
    }

    /// The line at the end edge of the explicit grid
    fn lastExplicitLine(self: NamedLineResolverAxis) OriginZeroLine {
        return OriginZeroLine.from(@bitCast(self.explicit_track_count));
    }

    /// Find the `n`th line in `lines` (searching forwards) that is not before `first_line`.
    ///
    /// If there are not enough such lines, then all implicit lines after the explicit grid are
    /// assumed to be in `lines` for the purpose of counting
    ///
    /// <https://drafts.csswg.org/css-grid-2/#grid-placement-int>
    fn nthLineForwards(self: NamedLineResolverAxis, all_lines: []const u32, first_line_oz: OriginZeroLine, n: i32) OriginZeroLine {
        const first_line: i32 = @max(first_line_oz.inner, 0);
        const lines = all_lines[partitionPoint(all_lines, first_line, false)..];
        const index: usize = @intCast(n - 1);
        const line: i32 = if (index < lines.len)
            ozLine(lines[index])
        else
            @max(first_line, @as(i32, self.lastExplicitLine().inner) + 1) + (n - @as(i32, @intCast(lines.len))) - 1;
        return OriginZeroLine.clamped(line);
    }

    /// Find the `n`th line in `lines` (searching backwards) that is not after `last_line`.
    ///
    /// If there are not enough such lines, then all implicit lines before the explicit grid are
    /// assumed to be in `lines` for the purpose of counting
    ///
    /// <https://drafts.csswg.org/css-grid-2/#grid-placement-int>
    fn nthLineBackwards(self: NamedLineResolverAxis, all_lines: []const u32, last_line_oz: OriginZeroLine, n: i32) OriginZeroLine {
        const last_line: i32 = @min(last_line_oz.inner, self.lastExplicitLine().inner);
        const lines = all_lines[0..partitionPoint(all_lines, last_line, true)];
        const n_usize: usize = @intCast(n);
        const line: i32 = if (lines.len >= n_usize)
            ozLine(lines[lines.len - n_usize])
        else
            @min(last_line, -1) - (n - @as(i32, @intCast(lines.len))) + 1;
        return OriginZeroLine.clamped(line);
    }

    /// The index of the first line for which `oz_line(line) < bound` (or `<= bound` if `inclusive`)
    /// is false (upstream `partition_point`; `lines` is sorted)
    fn partitionPoint(lines: []const u32, bound: i32, inclusive: bool) usize {
        var lo: usize = 0;
        var hi: usize = lines.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const value = ozLine(lines[mid]);
            const pred = if (inclusive) value <= bound else value < bound;
            if (pred) lo = mid + 1 else hi = mid;
        }
        return lo;
    }
};

/// The named line maps store lines as 1-based "CSS Grid Line" numbers (which are always within the
/// explicit grid). Convert one to OriginZero coordinates.
fn ozLine(line: u32) i32 {
    return @as(i32, @bitCast(line)) - 1;
}

/// A (1-indexed line number, name) pair of a line named in the track template
pub const LineNamePair = struct {
    line: u32,
    name: []const u8,
};

/// Utility function to create or update an entry in a line name map
///
/// `areas` must already contain the edges of the areas defined by `grid-template-areas`
fn upsertLineNameMap(
    gpa: Allocator,
    map: *NamedGridLinesMap,
    areas: *GridAreasMap,
    axis: GridAreaAxis,
    key: []const u8,
    value: u32,
) LayoutError!void {
    // A line named `foo-start` or `foo-end` is also an edge of the (implicitly) named area `foo`. Record it as such
    // if it is the first such line. If `foo` is also an area defined by `grid-template-areas`, then the line which
    // that area generated also has this name.
    var area_line: u32 = 0;
    if (splitAreaEdgeName(key)) |edge_name| {
        // The key is only created if the area is not already in the map
        const gop = try areas.getOrPut(gpa, edge_name.area_name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const edge = gop.value_ptr.lineMut(axis, edge_name.end);
        area_line = edge.*;
        edge.* = if (edge.* == 0) value else @min(edge.*, value);
    }

    if (map.getPtr(key)) |lines| {
        try lines.append(gpa, value);
    } else {
        // Until this entry is created, the only line that can have been recorded for this edge is the area's own
        var lines: LinePositions = .empty;
        errdefer lines.deinit(gpa);
        if (area_line == 0) {
            try lines.append(gpa, value);
        } else {
            try lines.appendSlice(gpa, &.{ area_line, value });
        }
        try map.put(gpa, key, lines);
    }
}

/// Resolver that takes grid lines names and area names as input and can then be used to
/// resolve line names of grid placement properties into line numbers.
pub const NamedLineResolver = struct {
    /// Map of row line names to line numbers. Each line name may correspond to multiple lines
    /// so we store a list
    row_lines: NamedGridLinesMap = .empty,
    /// Map of column line names to line numbers. Each line name may correspond to multiple lines
    /// so we store a list
    column_lines: NamedGridLinesMap = .empty,
    /// Map of area names to the lines of the area's edges
    areas: GridAreasMap = .empty,
    /// Number of columns implied by grid area definitions
    area_column_count: u16 = 0,
    /// Number of rows implied by grid area definitions
    area_row_count: u16 = 0,
    /// The number of explicit columns in the grid. This is an *input* to the `NamedLineResolver` and is
    /// used when computing the fallback line when a non-existent named line is specified.
    explicit_column_count: u16 = 0,
    /// The number of explicit rows in the grid. This is an *input* to the `NamedLineResolver` and is
    /// used when computing the fallback line when a non-existent named line is specified.
    explicit_row_count: u16 = 0,
    /// The (1-indexed line number, name) pairs of every column line named in the track template,
    /// in source order (excludes the implicit names generated by `grid-template-areas`)
    column_line_name_pairs: std.ArrayList(LineNamePair) = .empty,
    /// The (1-indexed line number, name) pairs of every row line named in the track template,
    /// in source order (excludes the implicit names generated by `grid-template-areas`)
    row_line_name_pairs: std.ArrayList(LineNamePair) = .empty,

    /// Free the resolver's memory (maps already moved out by `populateDetailedLineResolvers` are empty)
    pub fn deinit(self: *NamedLineResolver, gpa: Allocator) void {
        deinitLinesMap(gpa, &self.row_lines);
        deinitLinesMap(gpa, &self.column_lines);
        self.areas.deinit(gpa);
        self.column_line_name_pairs.deinit(gpa);
        self.row_line_name_pairs.deinit(gpa);
    }

    /// Create and initialise a new `NamedLineResolver`
    pub fn new(
        gpa: Allocator,
        style: anytype,
        column_auto_repetitions: u16,
        row_auto_repetitions: u16,
    ) LayoutError!NamedLineResolver {
        var self: NamedLineResolver = .{};
        errdefer self.deinit(gpa);

        // The size of the area template may be larger than the extents of the named areas
        // due to unnamed (`.`) cells, so it is taken from the style rather than being derived
        // from the areas themselves.
        self.area_column_count = style.getGridTemplateAreaColumnCount();
        self.area_row_count = style.getGridTemplateAreaRowCount();
        if (style.getGridTemplateAreas()) |area_list| {
            for (area_list) |area| {
                const lines: AreaLines = .{
                    .row_start = area.row_start,
                    .row_end = area.row_end,
                    .column_start = area.column_start,
                    .column_end = area.column_end,
                };
                try self.areas.put(gpa, area.name, lines);
            }
        }

        try collectAxisLineNames(gpa, &self.column_lines, &self.areas, &self.column_line_name_pairs, .column, style.getGridTemplateColumns(), style.getGridTemplateColumnNames(), column_auto_repetitions);
        try collectAxisLineNames(gpa, &self.row_lines, &self.areas, &self.row_line_name_pairs, .row, style.getGridTemplateRows(), style.getGridTemplateRowNames(), row_auto_repetitions);

        // Sort and dedup lines for each column name
        sortAndDedupLines(&self.column_lines);
        // Sort and dedup lines for each row name
        sortAndDedupLines(&self.row_lines);

        return self;
    }

    /// Record the line names of one axis' track template (upstream inlines this loop once per axis)
    fn collectAxisLineNames(
        gpa: Allocator,
        lines_map: *NamedGridLinesMap,
        areas: *GridAreasMap,
        pairs: *std.ArrayList(LineNamePair),
        axis: GridAreaAxis,
        maybe_tracks: anytype,
        maybe_line_names: ?[]const []const []const u8,
        auto_repetitions: u16,
    ) LayoutError!void {
        var current_line: u32 = 0;
        const tracks = maybe_tracks orelse return;
        const line_names_list = maybe_line_names orelse return;
        var track_index: usize = 0;
        for (line_names_list) |line_names| {
            current_line += 1;
            for (line_names) |line_name| {
                try pairs.append(gpa, .{ .line = current_line, .name = line_name });
                try upsertLineNameMap(gpa, lines_map, areas, axis, line_name, current_line);
            }

            const next_track = if (track_index < tracks.len) tracks[track_index] else null;
            track_index += 1;
            if (next_track) |track| switch (track) {
                .repeat => |repeat| {
                    const repeat_count: u16 = switch (repeat.getCount()) {
                        .count => |count| count,
                        .auto_fill, .auto_fit => auto_repetitions,
                    };

                    // Line name sets are positional: set `i` names the `i`th line of each
                    // repetition, and the final line name set of each repetition collapses
                    // with the first line name set of the following one. An empty list means
                    // the repetition's lines are unnamed; any other length must be exactly
                    // `track_count + 1` (one set per line, including both edge lines).
                    const repeat_line_names = repeat.getLinesNames();
                    const line_name_set_count: u32 = @intCast(repeat_line_names.len);
                    const lines_per_repetition: u32 = repeat.getTrackCount();
                    if (!(line_name_set_count == 0 or line_name_set_count == lines_per_repetition + 1)) {
                        std.debug.panic(
                            "grid template repetition must have no line name sets or exactly track count + 1 of them ({d} tracks but {d} line name sets)",
                            .{ lines_per_repetition, line_name_set_count },
                        );
                    }

                    for (0..repeat_count) |_| {
                        for (repeat_line_names, 0..) |line_name_set, offset| {
                            const line = current_line + @as(u32, @intCast(offset));
                            for (line_name_set) |line_name| {
                                try pairs.append(gpa, .{ .line = line, .name = line_name });
                                try upsertLineNameMap(gpa, lines_map, areas, axis, line_name, line);
                            }
                        }
                        current_line += lines_per_repetition;

                        // Names for lines beyond the maximum track limit are never resolvable:
                        // stop generating them (the explicit grid is clamped to MAX_GRID_TRACKS)
                        if (current_line > max_grid_tracks) {
                            break;
                        }
                    }
                    // Last line name set collapses with following line name set
                    if (repeat_count > 0) {
                        current_line -|= 1;
                    }
                },
                .single => {},
            };
        }
    }

    /// Sort and dedup the line list of every name in `map`
    fn sortAndDedupLines(map: *NamedGridLinesMap) void {
        var it = map.valueIterator();
        while (it.next()) |lines| {
            std.mem.sort(u32, lines.items, {}, std.sort.asc(u32));
            // dedup
            if (lines.items.len > 1) {
                var write: usize = 1;
                for (lines.items[1..]) |value| {
                    if (value != lines.items[write - 1]) {
                        lines.items[write] = value;
                        write += 1;
                    }
                }
                lines.shrinkRetainingCapacity(write);
            }
        }
    }

    fn lessThanLine(_: void, a: LineNamePair, b: LineNamePair) bool {
        return a.line < b.line;
    }

    /// Build the per-line name groups of the explicit grid in the passed axis as a
    /// `GridLineNames`, with `repeat()`s expanded. Only names given explicitly in the track
    /// template are included; the implicit `<name>-start`/`<name>-end` names generated by
    /// `grid-template-areas` are omitted (matching the resolved value of
    /// `grid-template-rows`/`grid-template-columns` in browsers) but remain resolvable for
    /// placement via `GridLineNames.resolveLineNames`.
    ///
    /// Line indices are relative to the explicit grid (line 0 = start of the first explicit track).
    pub fn detailedLineNames(self: *const NamedLineResolver, gpa: Allocator, axis: AbsoluteAxis) LayoutError!GridLineNames {
        const pairs: []const LineNamePair, const explicit_track_count: u16 = switch (axis) {
            .horizontal => .{ self.column_line_name_pairs.items, self.explicit_column_count },
            .vertical => .{ self.row_line_name_pairs.items, self.explicit_row_count },
        };

        if (pairs.len == 0) {
            return .{};
        }

        // Stable sort by line number preserves the source order of names within each line
        const sorted_pairs = try gpa.dupe(LineNamePair, pairs);
        defer gpa.free(sorted_pairs);
        std.mem.sort(LineNamePair, sorted_pairs, {}, lessThanLine);

        const line_count = @as(usize, explicit_track_count) + 1;
        var line_names = try GridLineNames.withCapacity(gpa, sorted_pairs.len, line_count + 1);
        errdefer line_names.deinit(gpa);
        var pair_index: usize = 0;
        var line: u32 = 1;
        while (line <= line_count) : (line += 1) {
            try line_names.startLine(gpa);
            while (pair_index < sorted_pairs.len) {
                const pair = sorted_pairs[pair_index];
                if (pair.line != line) {
                    break;
                }
                pair_index += 1;
                if (!line_names.currentLineContains(pair.name)) {
                    try line_names.pushName(gpa, pair.name);
                }
            }
        }
        return line_names;
    }

    /// Resolve named lines for both the `start` and `end` of a row-axis grid placement
    pub inline fn resolveRowNames(self: *const NamedLineResolver, line: Line(GridPlacement)) Line(NonNamedGridPlacement) {
        return self.resolveLineNames(line, .row);
    }

    /// Resolve named lines for both the `start` and `end` of a column-axis grid placement
    pub inline fn resolveColumnNames(self: *const NamedLineResolver, line: Line(GridPlacement)) Line(NonNamedGridPlacement) {
        return self.resolveLineNames(line, .column);
    }

    /// Resolve named lines for both the `start` and `end` of a grid placement
    pub inline fn resolveLineNames(self: *const NamedLineResolver, line: Line(GridPlacement), axis: GridAreaAxis) Line(NonNamedGridPlacement) {
        const lines: *const NamedGridLinesMap, const explicit_track_count: u16 = switch (axis) {
            .row => .{ &self.row_lines, self.explicit_row_count },
            .column => .{ &self.column_lines, self.explicit_column_count },
        };
        const resolver: NamedLineResolverAxis = .{ .lines = lines, .areas = &self.areas, .axis = axis, .explicit_track_count = explicit_track_count };
        return resolver.resolveLineNames(line);
    }

    /// Move the row and column line-name maps into the detailed grid information, and return the grid area map
    /// for the same purpose (the resolver keeps only its line name pairs, which `deinit` frees)
    pub fn populateDetailedLineResolvers(self: *NamedLineResolver, gpa: Allocator, rows: *GridLineNames, columns: *GridLineNames) GridAreasMap {
        deinitLinesMap(gpa, &rows.resolver);
        rows.resolver = self.row_lines;
        self.row_lines = .empty;
        deinitLinesMap(gpa, &columns.resolver);
        columns.resolver = self.column_lines;
        self.column_lines = .empty;
        const areas = self.areas;
        self.areas = .empty;
        return areas;
    }

    /// Get the number of columns defined by the grid areas
    pub inline fn areaColumnCount(self: *const NamedLineResolver) u16 {
        return self.area_column_count;
    }

    /// Get the number of rows defined by the grid areas
    pub inline fn areaRowCount(self: *const NamedLineResolver) u16 {
        return self.area_row_count;
    }

    /// Set the number of columns in the explicit grid
    pub inline fn setExplicitColumnCount(self: *NamedLineResolver, count: u16) void {
        self.explicit_column_count = count;
    }

    /// Set the number of rows in the explicit grid
    pub inline fn setExplicitRowCount(self: *NamedLineResolver, count: u16) void {
        self.explicit_row_count = count;
    }

    /// Debug representation (upstream `Debug`). Map entries are printed in hash map order.
    pub fn format(self: *const NamedLineResolver, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("Grid Areas (row-start / column-start / row-end / column-end):\n");
        var areas_it = self.areas.iterator();
        while (areas_it.next()) |entry| {
            const area = entry.value_ptr.*;
            try w.print("{s}: {d} / {d} / {d} / {d}\n", .{ entry.key_ptr.*, area.row_start, area.column_start, area.row_end, area.column_end });
        }
        inline for (.{ .{ "Grid Rows:\n", "row_lines" }, .{ "Grid Columns:\n", "column_lines" } }) |section| {
            try w.writeAll(section[0]);
            var it = @field(self, section[1]).iterator();
            while (it.next()) |entry| {
                try w.print("{s}: ", .{entry.key_ptr.*});
                for (entry.value_ptr.items) |line| try w.print("{d}  ", .{line});
                try w.writeByte('\n');
            }
        }
    }
};

/// The names of each explicit grid line in a single axis, stored in CSR (compressed sparse
/// row) format: a single flat list of names plus a list of offsets into it (one more offset
/// than there are lines). The names of line `i` (0-indexed) are `names[offsets[i]..offsets[i + 1]]`.
///
/// Line indices here are relative to the explicit grid; `DetailedGridTracksInfo` provides
/// accessors with indices relative to the full grid (including implicit tracks).
///
/// Iterate over per-line name groups with `GridLineNames.iter`, or access a single line's
/// names with `GridLineNames.line`. A grid with no named lines is represented by two empty
/// lists (see `GridLineNames.isEmpty`).
///
/// Names are borrowed from the grid container's style. Free with `deinit` (using the allocator
/// the info was built with).
pub const GridLineNames = struct {
    /// The names of every grid line in the axis, concatenated in line order
    names: std.ArrayList([]const u8) = .empty,
    /// Offsets into `names`: line `i`'s names are `names[offsets[i]..offsets[i + 1]]`.
    /// Either empty (no named lines) or of length `line count + 1`.
    offsets: std.ArrayList(u32) = .empty,
    /// Named line lookup used to resolve arbitrary grid placements
    resolver: NamedGridLinesMap = .empty,

    /// Free the line names' memory
    pub fn deinit(self: *GridLineNames, gpa: Allocator) void {
        self.names.deinit(gpa);
        self.offsets.deinit(gpa);
        deinitLinesMap(gpa, &self.resolver);
        self.* = .{};
    }

    /// Create an empty `GridLineNames` with pre-allocated capacity
    pub fn withCapacity(gpa: Allocator, name_capacity: usize, offset_capacity: usize) LayoutError!GridLineNames {
        var self: GridLineNames = .{};
        errdefer self.deinit(gpa);
        try self.offsets.ensureTotalCapacity(gpa, offset_capacity);
        self.offsets.appendAssumeCapacity(0);
        try self.names.ensureTotalCapacity(gpa, name_capacity);
        return self;
    }

    /// Start a new (initially empty) line
    pub fn startLine(self: *GridLineNames, gpa: Allocator) LayoutError!void {
        try self.offsets.append(gpa, @intCast(self.names.items.len));
    }

    /// Append a name to the current (last) line
    pub fn pushName(self: *GridLineNames, gpa: Allocator, name: []const u8) LayoutError!void {
        try self.names.append(gpa, name);
        self.offsets.items[self.offsets.items.len - 1] = @intCast(self.names.items.len);
    }

    /// Whether the current (last) line already contains the passed name
    pub fn currentLineContains(self: *const GridLineNames, name: []const u8) bool {
        for (self.line(self.lineCount() -% 1)) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    /// Resolve named lines and spans using the retained line-name map and the passed grid area map
    pub fn resolveLineNames(
        self: *const GridLineNames,
        line_placement: Line(GridPlacement),
        areas: *const GridAreasMap,
        axis: GridAreaAxis,
        explicit_track_count: u16,
    ) Line(NonNamedGridPlacement) {
        const resolver: NamedLineResolverAxis = .{ .lines = &self.resolver, .areas = areas, .axis = axis, .explicit_track_count = explicit_track_count };
        return resolver.resolveLineNames(line_placement);
    }

    /// Whether the axis has any named lines at all
    pub fn isEmpty(self: *const GridLineNames) bool {
        return self.names.items.len == 0;
    }

    /// The number of grid lines represented (zero if the grid has no named lines)
    pub fn lineCount(self: *const GridLineNames) usize {
        return self.offsets.items.len -| 1;
    }

    /// The names of the line with the passed 0-indexed line index.
    /// Returns an empty slice if the line has no names or the index is out of range.
    pub fn line(self: *const GridLineNames, line_index: usize) []const []const u8 {
        const offsets = self.offsets.items;
        if (line_index < offsets.len and line_index +% 1 < offsets.len) {
            return self.names.items[offsets[line_index]..offsets[line_index + 1]];
        }
        return &.{};
    }

    /// Iterate over the name group (`[]const []const u8`) of each grid line in line order
    pub fn iter(self: *const GridLineNames) GridLineNamesIter {
        return self.iterPadded(0, 0);
    }

    /// Iterate over the name group of each grid line in line order, additionally
    /// yielding `leading_empty` empty groups before the stored lines and `trailing_empty`
    /// empty groups after them (representing unnamed implicit grid lines)
    pub fn iterPadded(self: *const GridLineNames, leading_empty: usize, trailing_empty: usize) GridLineNamesIter {
        return .{ .names = self.names.items, .offsets = self.offsets.items, .leading_empty = leading_empty, .trailing_empty = trailing_empty };
    }

    /// Equality of the per-line names (upstream derived `PartialEq` also compares the resolver map)
    pub fn eqlNames(self: *const GridLineNames, other: *const GridLineNames) bool {
        if (!std.mem.eql(u32, self.offsets.items, other.offsets.items)) return false;
        if (self.names.items.len != other.names.items.len) return false;
        for (self.names.items, other.names.items) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        }
        return true;
    }
};

/// Iterator over the per-line name groups of a `GridLineNames`. Yields one `[]const []const u8`
/// per grid line (which is empty for unnamed lines)
pub const GridLineNamesIter = struct {
    /// The flat name storage being iterated over
    names: []const []const u8,
    /// The offsets into `names` (adjacent pairs bound each line)
    offsets: []const u32,
    /// Index of the next adjacent pair of offsets
    window: usize = 0,
    /// Number of (unnamed, implicit) lines remaining before the stored lines
    leading_empty: usize,
    /// Number of (unnamed, implicit) lines remaining after the stored lines
    trailing_empty: usize,

    pub fn next(self: *GridLineNamesIter) ?[]const []const u8 {
        if (self.leading_empty > 0) {
            self.leading_empty -= 1;
            return &.{};
        }
        if (self.window + 1 < self.offsets.len) {
            defer self.window += 1;
            return self.names[self.offsets[self.window]..self.offsets[self.window + 1]];
        }
        if (self.trailing_empty > 0) {
            self.trailing_empty -= 1;
            return &.{};
        }
        return null;
    }

    /// The number of groups remaining (upstream `ExactSizeIterator::len`)
    pub fn len(self: *const GridLineNamesIter) usize {
        const windows = (self.offsets.len -| 1) -| self.window;
        return self.leading_empty + windows + self.trailing_empty;
    }
};

// ---------------------------------------------------------------------------------------------
// Tests

const testing = std.testing;
const Style = @import("../../../style.zig").Style;
const GridTemplateArea = style_grid.GridTemplateArea;
const min_oz_line = coordinates.min_oz_line;
const max_oz_line = coordinates.max_oz_line;

fn testResolver(explicit_track_count: u16) !NamedLineResolver {
    var resolver = try NamedLineResolver.new(testing.allocator, &Style.default, 0, 0);
    resolver.setExplicitColumnCount(explicit_track_count);
    return resolver;
}

fn resolvedStartLine(resolver: *const NamedLineResolver, placement: GridPlacement) !i16 {
    const resolved = resolver.resolveColumnNames(.{ .start = placement, .end = .auto });
    return switch (resolved.start) {
        .line => |l| l.asI16(),
        else => error.ExpectedResolvedLine,
    };
}

fn resolvedEndLine(resolver: *const NamedLineResolver, placement: GridPlacement) !i16 {
    const resolved = resolver.resolveColumnNames(.{ .start = .auto, .end = placement });
    return switch (resolved.end) {
        .line => |l| l.asI16(),
        else => error.ExpectedResolvedLine,
    };
}

fn namedLine(name: []const u8, index: i16) GridPlacement {
    return .{ .named_line = .{ .name = name, .index = index } };
}

test "extreme missing named line indices do not overflow" {
    // Lines are clamped to the limits of the grid, in the same way as `GridLine.intoOriginZeroLine`
    var resolver = try testResolver(10_000);
    defer resolver.deinit(testing.allocator);
    try testing.expectEqual(OriginZeroLine.from(max_oz_line).intoGridLine(10_000).asI16(), try resolvedStartLine(&resolver, namedLine("missing", std.math.maxInt(i16))));
    try testing.expectEqual(OriginZeroLine.from(min_oz_line).intoGridLine(10_000).asI16(), try resolvedStartLine(&resolver, namedLine("missing", std.math.minInt(i16))));
}

test "large named span does not wrap negative" {
    var resolver = try testResolver(10_000);
    defer resolver.deinit(testing.allocator);
    const resolved = resolver.resolveColumnNames(.{
        .start = .{ .line = GridLine.from(1) },
        .end = .{ .named_span = .{ .name = "missing", .count = std.math.maxInt(u16) } },
    });
    try testing.expectEqual(NonNamedGridPlacement{ .line = OriginZeroLine.from(max_oz_line).intoGridLine(10_000) }, resolved.end);
}

test "area lines saturate when converted to grid lines" {
    const areas = [_]GridTemplateArea{.{ .name = "area", .row_start = 1, .row_end = 2, .column_start = std.math.maxInt(u16), .column_end = std.math.maxInt(u16) }};
    var style: Style = .{};
    style.grid_template_areas = .{ .areas = &areas, .row_count = 1, .column_count = std.math.maxInt(u16) };
    var resolver = try NamedLineResolver.new(testing.allocator, &style, 0, 0);
    defer resolver.deinit(testing.allocator);
    try testing.expectEqual(OriginZeroLine.from(max_oz_line).intoGridLine(0).asI16(), try resolvedStartLine(&resolver, namedLine("area-start", 1)));
    try testing.expectEqual(OriginZeroLine.from(max_oz_line).intoGridLine(0).asI16(), try resolvedStartLine(&resolver, namedLine("area", 0)));
}

const test_area = [_]GridTemplateArea{.{ .name = "area", .row_start = 1, .row_end = 2, .column_start = 2, .column_end = 4 }};

/// A resolver for a grid with 4 explicit columns, the passed names for each of the 5 column lines, and a
/// single grid area named "area" which spans columns 2 and 3 (lines 2 to 4)
fn areaResolver(column_line_names: *const [5][]const []const u8) !NamedLineResolver {
    var style: Style = .{};
    style.grid_template_column_names = column_line_names;
    style.grid_template_areas = .{ .areas = &test_area, .row_count = 1, .column_count = 4 };
    var resolver = try NamedLineResolver.new(testing.allocator, &style, 0, 0);
    resolver.setExplicitColumnCount(4);
    resolver.setExplicitRowCount(1);
    return resolver;
}

test "bare ident resolves to area edge" {
    var resolver = try areaResolver(&.{ &.{}, &.{}, &.{}, &.{}, &.{} });
    defer resolver.deinit(testing.allocator);
    try testing.expectEqual(@as(i16, 2), try resolvedStartLine(&resolver, namedLine("area", 0)));
    try testing.expectEqual(@as(i16, 4), try resolvedEndLine(&resolver, namedLine("area", 0)));

    const rows = resolver.resolveRowNames(.{ .start = namedLine("area", 0), .end = namedLine("area", 0) });
    try testing.expectEqual(NonNamedGridPlacement{ .line = GridLine.from(1) }, rows.start);
    try testing.expectEqual(NonNamedGridPlacement{ .line = GridLine.from(2) }, rows.end);
}

test "bare ident resolves to edge of implicitly named area" {
    var resolver = try areaResolver(&.{ &.{}, &.{"foo-start"}, &.{"foo-start"}, &.{"foo-end"}, &.{"foo-end"} });
    defer resolver.deinit(testing.allocator);
    try testing.expectEqual(@as(i16, 2), try resolvedStartLine(&resolver, namedLine("foo", 0)));
    try testing.expectEqual(@as(i16, 4), try resolvedEndLine(&resolver, namedLine("foo", 0)));
}

test "area edges are lines named with start and end suffixes" {
    var resolver = try areaResolver(&.{ &.{}, &.{}, &.{}, &.{}, &.{} });
    defer resolver.deinit(testing.allocator);
    try testing.expectEqual(@as(i16, 2), try resolvedStartLine(&resolver, namedLine("area-start", 0)));
    try testing.expectEqual(@as(i16, 2), try resolvedStartLine(&resolver, namedLine("area-start", 1)));
    try testing.expectEqual(@as(i16, 4), try resolvedStartLine(&resolver, namedLine("area-end", 1)));
    try testing.expectEqual(@as(i16, 4), try resolvedStartLine(&resolver, namedLine("area-end", -1)));
    // There is only one such line, so the second is the first implicit line after the grid
    try testing.expectEqual(@as(i16, 6), try resolvedStartLine(&resolver, namedLine("area-start", 2)));
}

test "area edges are merged with explicitly named lines" {
    // The area's start edge is line 2 and its end edge is line 4
    var resolver = try areaResolver(&.{ &.{"area-start"}, &.{}, &.{"area-start"}, &.{"area-end"}, &.{"area-end"} });
    defer resolver.deinit(testing.allocator);
    try testing.expectEqual(@as(i16, 1), try resolvedStartLine(&resolver, namedLine("area-start", 1)));
    try testing.expectEqual(@as(i16, 2), try resolvedStartLine(&resolver, namedLine("area-start", 2)));
    try testing.expectEqual(@as(i16, 3), try resolvedStartLine(&resolver, namedLine("area-start", 3)));
    try testing.expectEqual(@as(i16, 3), try resolvedStartLine(&resolver, namedLine("area-start", -1)));
    try testing.expectEqual(@as(i16, 6), try resolvedStartLine(&resolver, namedLine("area-start", 4)));
    // The area's end edge has the same line number as an explicitly named line
    try testing.expectEqual(@as(i16, 4), try resolvedStartLine(&resolver, namedLine("area-end", 1)));
    try testing.expectEqual(@as(i16, 5), try resolvedStartLine(&resolver, namedLine("area-end", 2)));
    try testing.expectEqual(@as(i16, 6), try resolvedStartLine(&resolver, namedLine("area-end", 3)));
    // A bare ident matches the first line of the edge
    try testing.expectEqual(@as(i16, 1), try resolvedStartLine(&resolver, namedLine("area", 0)));
    try testing.expectEqual(@as(i16, 4), try resolvedEndLine(&resolver, namedLine("area", 0)));

    const span = resolver.resolveColumnNames(.{
        .start = .{ .line = GridLine.from(1) },
        .end = .{ .named_span = .{ .name = "area-start", .count = 2 } },
    });
    try testing.expectEqual(NonNamedGridPlacement{ .line = GridLine.from(3) }, span.end);
}

test "area edges are only matched by bare idents" {
    var resolver = try areaResolver(&.{ &.{}, &.{}, &.{}, &.{}, &.{} });
    defer resolver.deinit(testing.allocator);
    // There are no lines named "area", so these resolve to implicit lines after the grid
    try testing.expectEqual(@as(i16, 6), try resolvedStartLine(&resolver, namedLine("area", 1)));
    try testing.expectEqual(@as(i16, 7), try resolvedStartLine(&resolver, namedLine("area", 2)));

    const span = resolver.resolveColumnNames(.{
        .start = .{ .line = GridLine.from(1) },
        .end = .{ .named_span = .{ .name = "area", .count = 0 } },
    });
    try testing.expectEqual(NonNamedGridPlacement{ .line = GridLine.from(6) }, span.end);
}

test "area edge is the first line with the edge name" {
    // Explicit lines named after the area's edges which come after the area's generated lines (lines 2 and
    // 4) don't replace them
    {
        var resolver = try areaResolver(&.{ &.{}, &.{}, &.{"area-start"}, &.{}, &.{"area-end"} });
        defer resolver.deinit(testing.allocator);
        try testing.expectEqual(@as(i16, 2), try resolvedStartLine(&resolver, namedLine("area", 0)));
        try testing.expectEqual(@as(i16, 4), try resolvedEndLine(&resolver, namedLine("area", 0)));
        try testing.expectEqual(@as(i16, 2), try resolvedStartLine(&resolver, namedLine("area-start", 1)));
        try testing.expectEqual(@as(i16, 3), try resolvedStartLine(&resolver, namedLine("area-start", 2)));
        try testing.expectEqual(@as(i16, 5), try resolvedStartLine(&resolver, namedLine("area-end", 2)));
    }

    // An explicit line with the same number as the generated line is the same line
    {
        var resolver = try areaResolver(&.{ &.{}, &.{"area-start"}, &.{}, &.{"area-end"}, &.{} });
        defer resolver.deinit(testing.allocator);
        try testing.expectEqual(@as(i16, 2), try resolvedStartLine(&resolver, namedLine("area", 0)));
        try testing.expectEqual(@as(i16, 4), try resolvedEndLine(&resolver, namedLine("area", 0)));
        try testing.expectEqual(@as(i16, 2), try resolvedStartLine(&resolver, namedLine("area-start", 1)));
        try testing.expectEqual(@as(i16, 6), try resolvedStartLine(&resolver, namedLine("area-start", 2)));
        try testing.expectEqual(@as(i16, 6), try resolvedStartLine(&resolver, namedLine("area-end", 2)));
    }
}

test "detailed line names and iteration (laffy addition)" {
    const gpa = testing.allocator;
    const repeated = [_]style_grid.TrackSizingFunction{ style_grid.TrackSizingFunction.fromLength(10), style_grid.TrackSizingFunction.fromLength(20) };
    const columns = [_]style_grid.GridTemplateComponent{
        style_grid.GridTemplateComponent.fromLength(5),
        .{ .repeat = .{ .count = .{ .count = 2 }, .tracks = &repeated, .line_names = &.{ &.{"r-a"}, &.{"r-b"}, &.{"r-c"} } } },
    };
    var style: Style = .{};
    style.grid_template_columns = &columns;
    style.grid_template_column_names = &.{ &.{ "first", "x" }, &.{ "second", "x" }, &.{"last"} };
    var resolver = try NamedLineResolver.new(gpa, &style, 0, 0);
    defer resolver.deinit(gpa);
    resolver.setExplicitColumnCount(5);

    var names = try resolver.detailedLineNames(gpa, .horizontal);
    defer names.deinit(gpa);
    try testing.expectEqual(@as(usize, 6), names.lineCount());
    // Line 2 (index 1) carries "second", "x" and the first repetition's "r-a"
    try testing.expectEqual(@as(usize, 3), names.line(1).len);
    try testing.expectEqualStrings("r-a", names.line(1)[2]);
    try testing.expectEqualStrings("r-c", names.line(5)[0]);
    try testing.expectEqualStrings("last", names.line(5)[1]);
    try testing.expectEqual(@as(usize, 0), names.line(17).len);

    var it = names.iterPadded(1, 2);
    try testing.expectEqual(@as(usize, 9), it.len());
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 9), count);

    // "x" names lines 1 and 2; the second "x" line is line 2
    try testing.expectEqual(@as(i16, 2), try resolvedStartLine(&resolver, namedLine("x", 2)));

    var empty_rows = try resolver.detailedLineNames(gpa, .vertical);
    defer empty_rows.deinit(gpa);
    try testing.expect(empty_rows.isEmpty());
    try testing.expectEqual(@as(usize, 0), empty_rows.lineCount());

    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try w.print("{f}", .{&resolver});
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "Grid Columns:") != null);
}
