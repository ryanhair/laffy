//! Port of upstream's fixture runner (`tests/xml.rs`, `run_xml_test`) as a library.
//!
//! `runFixtureFile` runs one fixture and `runGroup` runs a whole group directory. Neither
//! aborts on a mismatch or on a malformed fixture: those are reported as failures with a
//! message. Only `error.OutOfMemory` is propagated.
//!
//! Comparison semantics follow upstream's `impl PartialEq for OutputNode`:
//!   - node ids, `location` and `size` agree within 0.1 on every axis;
//!   - `scroll_width`/`scroll_height` are compared (within 0.1) only when the fixture gives both;
//!   - `resolved-rows`/`resolved-columns` are compared only when the fixture gives them and the
//!     tree reports them (grid containers, through their detailed grid info): line names exactly,
//!     track sizes within 0.1;
//!   - children are compared pairwise and must have the same length.
//!
//! The actual tree is read through `TaffyTree.children`, exactly like upstream, so hoisted
//! out-of-flow children are not reordered in the output.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const laffy = @import("laffy");
const xml = @import("xml.zig");
const style_parse = @import("style_parse.zig");
const measure = @import("measure.zig");

const Size = laffy.Size;
const Point = laffy.Point;
const NodeId = laffy.NodeId;
const AvailableSpace = laffy.AvailableSpace;
const Tree = laffy.TaffyTree(measure.TestNodeContext);

/// The comparison tolerance for positions, sizes and scroll sizes.
const tolerance: f32 = 0.1;

/// Which container layout algorithms are ported. A fixture with a container node that needs an
/// algorithm marked `false` here is skipped (reported as such, neither passed nor failed) instead
/// of running, because the unported algorithm would panic and abort the whole process.
/// Flip a flag when the algorithm lands in `TaffyTree` (the `TODO(milestone-N)` panics in
/// `src/tree/taffy_tree.zig`).
pub const ported = struct {
    pub const flex = true;
    pub const block = true;
    pub const grid = true;
};

/// Directory holding the fixtures, relative to the project root.
pub const default_fixtures_root = "tests/fixtures/xml";

const OutputNode = struct {
    node_id: NodeId,
    location: Point(f32),
    size: Size(f32),
    scroll_size: ?Size(f32),
    resolved_rows: ?[]const u8,
    resolved_columns: ?[]const u8,
    children: std.ArrayList(OutputNode) = .empty,
};

fn near(a: f32, b: f32) bool {
    return @abs(a - b) < tolerance;
}

// ---------------------------------------------------------------------------------------------
// Resolved track lists
// ---------------------------------------------------------------------------------------------

const TrackToken = union(enum) {
    /// A bracketed group of line names, as the raw text between the brackets
    names: []const u8,
    size: f32,
};

/// Splits a resolved track list (`[foo] 10px 20.5px [bar baz]` or `none`) into tokens. Returns null
/// for text that upstream's parser would panic on.
fn parseTrackList(arena: Allocator, input_raw: []const u8) Allocator.Error!?[]const TrackToken {
    const input = std.mem.trim(u8, input_raw, &std.ascii.whitespace);
    var tokens: std.ArrayList(TrackToken) = .empty;
    if (std.mem.eql(u8, input, "none")) return tokens.items;
    var rest = input;
    while (rest.len > 0) {
        rest = std.mem.trimStart(u8, rest, &std.ascii.whitespace);
        if (rest.len == 0) break;
        if (rest[0] == '[') {
            const end = std.mem.indexOfScalar(u8, rest[1..], ']') orelse return null;
            try tokens.append(arena, .{ .names = rest[1..][0..end] });
            rest = rest[1..][end + 1 ..];
        } else {
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            const tok = rest[0..end];
            if (!std.mem.endsWith(u8, tok, "px")) return null;
            const size = std.fmt.parseFloat(f32, tok[0 .. tok.len - 2]) catch return null;
            try tokens.append(arena, .{ .size = size });
            rest = rest[end..];
        }
    }
    return tokens.items;
}

fn namesEql(a: []const u8, b: []const u8) bool {
    var ia = std.mem.tokenizeAny(u8, a, &std.ascii.whitespace);
    var ib = std.mem.tokenizeAny(u8, b, &std.ascii.whitespace);
    while (true) {
        const x = ia.next();
        const y = ib.next();
        if (x == null and y == null) return true;
        if (x == null or y == null) return false;
        if (!std.mem.eql(u8, x.?, y.?)) return false;
    }
}

fn trackListsMatch(arena: Allocator, expected: []const u8, actual: []const u8) Allocator.Error!bool {
    const e = (try parseTrackList(arena, expected)) orelse return false;
    const a = (try parseTrackList(arena, actual)) orelse return false;
    if (e.len != a.len) return false;
    for (e, a) |x, y| {
        switch (x) {
            .size => |xs| switch (y) {
                .size => |ys| if (!near(xs, ys)) return false,
                .names => return false,
            },
            .names => |xn| switch (y) {
                .names => |yn| if (!namesEql(xn, yn)) return false,
                .size => return false,
            },
        }
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------------------------

fn optionalTrackListsMatch(arena: Allocator, expected: ?[]const u8, actual: ?[]const u8) Allocator.Error!bool {
    // Only asserted when both the expectation and the computed value are available
    if (expected != null and actual != null) return trackListsMatch(arena, expected.?, actual.?);
    return true;
}

/// Compares the fields of one node, ignoring its children.
fn selfMatches(arena: Allocator, expected: *const OutputNode, actual: *const OutputNode) Allocator.Error!bool {
    // Only assert scroll sizes when both the expectation and the computed value are available
    const scroll_ok = if (expected.scroll_size != null and actual.scroll_size != null)
        near(expected.scroll_size.?.width, actual.scroll_size.?.width) and
            near(expected.scroll_size.?.height, actual.scroll_size.?.height)
    else
        true;
    return expected.node_id == actual.node_id and
        near(expected.location.x, actual.location.x) and
        near(expected.location.y, actual.location.y) and
        near(expected.size.width, actual.size.width) and
        near(expected.size.height, actual.size.height) and
        scroll_ok and
        try optionalTrackListsMatch(arena, expected.resolved_rows, actual.resolved_rows) and
        try optionalTrackListsMatch(arena, expected.resolved_columns, actual.resolved_columns);
}

fn treesMatch(arena: Allocator, expected: *const OutputNode, actual: *const OutputNode) Allocator.Error!bool {
    if (!try selfMatches(arena, expected, actual)) return false;
    if (expected.children.items.len != actual.children.items.len) return false;
    for (expected.children.items, actual.children.items) |*e, *a| {
        if (!try treesMatch(arena, e, a)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Printing
// ---------------------------------------------------------------------------------------------

fn writeMetrics(w: *Io.Writer, node: *const OutputNode) Io.Writer.Error!void {
    try w.print("[x: {d:<4} y: {d:<4} w: {d:<4} h: {d:<4}]", .{ node.location.x, node.location.y, node.size.width, node.size.height });
    if (node.scroll_size) |s| try w.print(" [scroll_w: {d:<4} scroll_h: {d:<4}]", .{ s.width, s.height });
    if (node.resolved_rows) |r| try w.print(" [rows: {s}]", .{r});
    if (node.resolved_columns) |c| try w.print(" [columns: {s}]", .{c});
}

/// Prints a tree like upstream's `OutputNode::write_tree`. When `other` is given, nodes whose own
/// fields differ from the corresponding node of `other` are marked.
fn writeTree(arena: Allocator, w: *Io.Writer, node: *const OutputNode, other: ?*const OutputNode) (Io.Writer.Error || Allocator.Error)!void {
    try w.writeAll("TREE\n");
    var counter: usize = 0;
    try printNode(arena, w, node, other, false, "", &counter);
}

fn printNode(
    arena: Allocator,
    w: *Io.Writer,
    node: *const OutputNode,
    other: ?*const OutputNode,
    has_sibling: bool,
    lines: []const u8,
    counter: *usize,
) (Io.Writer.Error || Allocator.Error)!void {
    const fork = if (has_sibling) "├── " else "└── ";
    try w.print("{s}{s} #{d} ", .{ lines, fork, counter.* });
    counter.* += 1;
    try writeMetrics(w, node);
    if (other) |o| {
        if (!try selfMatches(arena, node, o)) try w.writeAll("   <-- differs");
    }
    try w.writeByte('\n');

    const bar = if (has_sibling) "│   " else "    ";
    const new_lines = try std.mem.concat(arena, u8, &.{ lines, bar });
    for (node.children.items, 0..) |*child, i| {
        const child_other: ?*const OutputNode = if (other) |o|
            (if (i < o.children.items.len) &o.children.items[i] else null)
        else
            null;
        try printNode(arena, w, child, child_other, i + 1 < node.children.items.len, new_lines, counter);
    }
}

// ---------------------------------------------------------------------------------------------
// Fixture handling
// ---------------------------------------------------------------------------------------------

/// Why a fixture could not be run (reported as a failure message).
const Problem = struct {
    message: []const u8,
};

const Built = struct {
    tree: Tree,
    expected: OutputNode,
    root_id: NodeId,
    available_space: Size(AvailableSpace),
};

const BuildError = error{ OutOfMemory, Malformed };

const Builder = struct {
    arena: Allocator,
    tree: *Tree,
    /// Set when a fixture is malformed (the message lives in the arena)
    problem: ?Problem = null,
    /// The first unported algorithm a laid-out container needs (`"flex"`, `"block"` or `"grid"`)
    unported: ?[]const u8 = null,

    fn fail(self: *Builder, comptime fmt: []const u8, args: anytype) BuildError {
        self.problem = .{ .message = std.fmt.allocPrint(self.arena, fmt, args) catch "out of memory while formatting message" };
        return error.Malformed;
    }

    fn parseNodeOrFail(self: *Builder, element: xml.Element) BuildError!style_parse.Node {
        var diag: style_parse.Diagnostic = .{};
        return style_parse.parseNode(self.arena, element, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnknownAttribute => return self.fail("<{s}>: unknown attribute '{s}'", .{ element.tag, diag.attribute }),
            error.InvalidAttribute => return self.fail("<{s}>: invalid value '{s}' for attribute '{s}'", .{ element.tag, diag.value, diag.attribute }),
        };
    }

    fn floatAttr(self: *Builder, element: xml.Element, name: []const u8) BuildError!f32 {
        const text = element.attribute(name) orelse return self.fail("<{s}> in <expectations> has no '{s}' attribute", .{ element.tag, name });
        return std.fmt.parseFloat(f32, text) catch self.fail("<{s}> in <expectations>: invalid number '{s}' for '{s}'", .{ element.tag, text, name });
    }

    fn buildExpectations(self: *Builder, element: xml.Element, node_id: NodeId) BuildError!OutputNode {
        const scroll_w: ?f32 = if (element.attribute("scroll_width")) |t| std.fmt.parseFloat(f32, t) catch null else null;
        const scroll_h: ?f32 = if (element.attribute("scroll_height")) |t| std.fmt.parseFloat(f32, t) catch null else null;
        const scroll_size: ?Size(f32) = if (scroll_w != null and scroll_h != null)
            .{ .width = scroll_w.?, .height = scroll_h.? }
        else
            null;
        return .{
            .node_id = node_id,
            .location = .{ .x = try self.floatAttr(element, "x"), .y = try self.floatAttr(element, "y") },
            .size = .{ .width = try self.floatAttr(element, "width"), .height = try self.floatAttr(element, "height") },
            .scroll_size = scroll_size,
            .resolved_rows = element.attribute("resolved-rows"),
            .resolved_columns = element.attribute("resolved-columns"),
        };
    }

    /// Upstream `construct_tree`
    fn constructTree(self: *Builder, input: xml.Element, expected_x: xml.Element, parent: ?NodeId, hidden_in: bool) BuildError!OutputNode {
        const node = try self.parseNodeOrFail(input);
        const hidden = hidden_in or node.style.display == .none;
        if (node.has_children) {
            if (!hidden and self.unported == null) {
                self.unported = switch (node.style.display) {
                    .none => null,
                    .flex => if (ported.flex) null else "flex",
                    .block, .flow_root => if (ported.block) null else "block",
                    .grid => if (ported.grid) null else "grid",
                };
            }
            const tnode = try self.tree.newWithChildren(node.style, &.{});
            var expected = try self.buildExpectations(expected_x, tnode);
            if (parent) |p| try self.tree.addChild(p, tnode);

            const n = @min(input.children.len, expected_x.children.len);
            for (input.children[0..n], expected_x.children[0..n]) |child, child_expected| {
                try expected.children.append(self.arena, try self.constructTree(child, child_expected, tnode, hidden));
            }
            return expected;
        } else {
            const tnode = if (node.text) |text|
                try self.tree.newLeafWithContext(node.style, measure.TestNodeContext.ahemText(text, switch (node.writing_mode) {
                    .horizontal => .horizontal,
                    .vertical => .vertical,
                }))
            else
                try self.tree.newLeaf(node.style);
            if (parent) |p| try self.tree.addChild(p, tnode);
            return self.buildExpectations(expected_x, tnode);
        }
    }

    /// Upstream `get_computed_expectations`
    fn computedExpectations(self: *Builder, node_id: NodeId) BuildError!OutputNode {
        const layout = self.tree.getFinalLayout(node_id);
        const scroll_size: Size(f32) = .{ .width = layout.scrollWidth(), .height = layout.scrollHeight() };
        var rows: ?[]const u8 = null;
        var columns: ?[]const u8 = null;
        // Upstream `get_resolved_track_lists`: the resolved value of grid-template-rows/columns for
        // grid containers, as exposed through `DetailedGridInfo`
        switch (self.tree.detailedLayoutInfo(node_id).*) {
            .grid => |info| {
                rows = try info.gridTemplateRows(self.arena, 1.0);
                columns = try info.gridTemplateColumns(self.arena, 1.0);
            },
            .none => {},
        }
        var output: OutputNode = .{
            .node_id = node_id,
            .location = layout.location,
            .size = layout.size,
            .scroll_size = scroll_size,
            .resolved_rows = rows,
            .resolved_columns = columns,
        };
        for (self.tree.children(node_id)) |child_id| {
            try output.children.append(self.arena, try self.computedExpectations(child_id));
        }
        return output;
    }
};

fn parseBool(text: []const u8) ?bool {
    if (std.mem.eql(u8, text, "true")) return true;
    if (std.mem.eql(u8, text, "false")) return false;
    return null;
}

pub const Outcome = enum { passed, failed, skipped };

/// Runs the fixture whose XML text is `source`. Returns the outcome. On a failure or skip, appends a
/// human readable explanation (with the expected and actual trees for a layout mismatch) to
/// `report`.
pub fn runFixtureSource(gpa: Allocator, source: []const u8, report: *Io.Writer) (Allocator.Error || Io.Writer.Error)!Outcome {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const doc = xml.parse(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try report.print("XML parse error: {s}\n", .{@errorName(err)});
            return .failed;
        },
    };
    const root = doc.root;

    const use_rounding: bool = if (root.attribute("use-rounding")) |t| parseBool(t) orelse {
        try report.print("invalid use-rounding '{s}'\n", .{t});
        return .failed;
    } else true;
    const viewport = root.firstChild("viewport") orelse {
        try report.writeAll("missing <viewport>\n");
        return .failed;
    };
    const input = root.firstChild("input") orelse {
        try report.writeAll("missing <input>\n");
        return .failed;
    };
    const expectations = root.firstChild("expectations") orelse {
        try report.writeAll("missing <expectations>\n");
        return .failed;
    };
    if (input.children.len == 0 or expectations.children.len == 0) {
        try report.writeAll("<input> or <expectations> has no element\n");
        return .failed;
    }

    var available_space: Size(AvailableSpace) = .{ .width = .max_content, .height = .max_content };
    inline for (.{ "width", "height" }) |name| {
        if (viewport.attribute(name)) |text| {
            const parsed = style_parse.parseAvailableSpace(text) catch {
                try report.print("invalid <viewport> {s} '{s}'\n", .{ name, text });
                return .failed;
            };
            @field(available_space, name) = parsed;
        }
    }

    var tree = try Tree.init(gpa);
    defer tree.deinit();
    if (use_rounding) tree.enableRounding() else tree.disableRounding();

    var builder: Builder = .{ .arena = arena, .tree = &tree };
    const expected = builder.constructTree(input.children[0], expectations.children[0], null, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => {
            try report.print("malformed fixture: {s}\n", .{builder.problem.?.message});
            return .failed;
        },
    };

    if (builder.unported) |algorithm| {
        try report.print("SKIPPED: needs the {s} algorithm, which is not ported yet\n", .{algorithm});
        return .skipped;
    }

    try tree.computeLayoutWithMeasure(expected.node_id, available_space, measure.TestMeasurer{});

    const actual = builder.computedExpectations(expected.node_id) catch return error.OutOfMemory;

    if (try treesMatch(arena, &expected, &actual)) return .passed;

    try report.writeAll("EXPECTED\n");
    try writeTree(arena, report, &expected, &actual);
    try report.writeAll("ACTUAL\n");
    try writeTree(arena, report, &actual, &expected);
    return .failed;
}

/// Runs the fixture file at `path` (relative to the working directory). See `runFixtureSource`.
pub fn runFixtureFile(gpa: Allocator, io: Io, path: []const u8, report: *Io.Writer) (Allocator.Error || Io.Writer.Error)!Outcome {
    const source = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try report.print("cannot read fixture: {s}\n", .{@errorName(err)});
            return .failed;
        },
    };
    defer gpa.free(source);
    return runFixtureSource(gpa, source, report);
}

pub const Failure = struct {
    /// The fixture name (file name without `.xml`)
    name: []const u8,
    /// Explanation and expected/actual diff
    report: []const u8,
};

pub const GroupResult = struct {
    group: []const u8,
    passed: usize = 0,
    total: usize = 0,
    /// Fixtures that were not run because they need an unported algorithm (see `ported`)
    skipped: usize = 0,
    failures: std.ArrayList(Failure) = .empty,

    pub fn deinit(self: *GroupResult, gpa: Allocator) void {
        for (self.failures.items) |f| {
            gpa.free(f.name);
            gpa.free(f.report);
        }
        self.failures.deinit(gpa);
        self.* = undefined;
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Runs every fixture of `group` under `fixtures_root` (default `default_fixtures_root`) whose name
/// contains `filter` (if given). Fixtures run in name order.
pub fn runGroup(
    gpa: Allocator,
    io: Io,
    group: []const u8,
    filter: ?[]const u8,
    fixtures_root: []const u8,
) !GroupResult {
    var result: GroupResult = .{ .group = group };
    errdefer result.deinit(gpa);

    const dir_path = try std.fs.path.join(gpa, &.{ fixtures_root, group });
    defer gpa.free(dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".xml")) continue;
        const stem = entry.name[0 .. entry.name.len - ".xml".len];
        if (filter) |f| if (std.mem.indexOf(u8, stem, f) == null) continue;
        try names.append(gpa, try gpa.dupe(u8, stem));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    for (names.items) |stem| {
        const file_path = try std.fmt.allocPrint(gpa, "{s}/{s}.xml", .{ dir_path, stem });
        defer gpa.free(file_path);

        var report: Io.Writer.Allocating = .init(gpa);
        defer report.deinit();
        result.total += 1;
        const outcome = try runFixtureFile(gpa, io, file_path, &report.writer);
        if (outcome == .passed) {
            result.passed += 1;
        } else if (outcome == .skipped) {
            result.skipped += 1;
        } else {
            const name = try gpa.dupe(u8, stem);
            errdefer gpa.free(name);
            const text = try report.toOwnedSlice();
            errdefer gpa.free(text);
            try result.failures.append(gpa, .{ .name = name, .report = text });
        }
    }
    return result;
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

fn runSourceForTest(source: []const u8, report: *Io.Writer.Allocating) !Outcome {
    return runFixtureSource(testing.allocator, source, &report.writer);
}

const fixture_template =
    \\<test name="t" use-rounding="true">
    \\  <viewport width="max-content" height="max-content"/>
    \\  <input><div width="10px" height="20px"/></input>
    \\  <expectations><node x="0" y="0" width="{s}" height="20" scroll_width="0" scroll_height="0"/></expectations>
    \\</test>
;

test "a matching fixture passes" {
    var report: Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();
    const src = try std.fmt.allocPrint(testing.allocator, fixture_template, .{"10"});
    defer testing.allocator.free(src);
    try testing.expectEqual(Outcome.passed, try runSourceForTest(src, &report));
    try testing.expectEqual(@as(usize, 0), report.written().len);
}

test "tolerance is 0.1" {
    var report: Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();
    const src = try std.fmt.allocPrint(testing.allocator, fixture_template, .{"10.05"});
    defer testing.allocator.free(src);
    try testing.expectEqual(Outcome.passed, try runSourceForTest(src, &report));
}

test "a mismatch fails with a diff" {
    var report: Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();
    const src = try std.fmt.allocPrint(testing.allocator, fixture_template, .{"11"});
    defer testing.allocator.free(src);
    try testing.expectEqual(Outcome.failed, try runSourceForTest(src, &report));
    try testing.expect(std.mem.indexOf(u8, report.written(), "EXPECTED") != null);
    try testing.expect(std.mem.indexOf(u8, report.written(), "<-- differs") != null);
}

test "malformed fixtures fail without aborting" {
    var report: Io.Writer.Allocating = .init(testing.allocator);
    defer report.deinit();
    try testing.expectEqual(Outcome.failed, try runSourceForTest("<test><input>", &report));
    try testing.expectEqual(Outcome.failed, try runSourceForTest("<test><viewport/><input><div bogus=\"1\"/></input><expectations><node/></expectations></test>", &report));
    try testing.expectEqual(Outcome.failed, try runSourceForTest("<test><viewport/><input><div/></input><expectations><node x=\"0\"/></expectations></test>", &report));
}

test "track lists compare names exactly and sizes with tolerance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(try trackListsMatch(arena, "[a b] 10px 20.5px", "[a  b] 10.05px 20.5px"));
    try testing.expect(!try trackListsMatch(arena, "[a] 10px", "[b] 10px"));
    try testing.expect(!try trackListsMatch(arena, "10px", "10px 10px"));
    try testing.expect(try trackListsMatch(arena, "none", "none"));
}
