//! Contains functions for printing a debug representation of the tree
//!
//! `tree` arguments implement `PrintTree` (see `src/tree/traits.zig`).
const std = @import("std");
const NodeId = @import("../tree/node.zig").NodeId;

/// Prints a debug representation of the computed layout for a tree of nodes, starting with the
/// passed root node. Upstream prints to stdout; laffy prints to stderr (via `std.debug`), which
/// works without an `Io` instance and is captured by the test runner.
pub fn printTree(tree: anytype, root: NodeId) void {
    var buffer: [1024]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    writeTree(&stderr.file_writer.interface, tree, root) catch return;
}

/// Writes a debug representation of the computed layout to the writer, starting with the passed root node.
pub fn writeTree(writer: *std.Io.Writer, tree: anytype, root: NodeId) std.Io.Writer.Error!void {
    try writer.writeAll("TREE\n");
    try writeNode(writer, tree, root, false, &.{});
}

/// The maximum depth of the line-prefix stack (deeper levels are drawn without guide lines)
const max_depth = 256;

/// Recursive function that writes each node in the tree. `lines` holds one entry per ancestor
/// level: whether that ancestor had a following sibling (and so needs a guide line).
fn writeNode(
    writer: *std.Io.Writer,
    tree: anytype,
    node_id: NodeId,
    has_sibling: bool,
    lines: []const bool,
) std.Io.Writer.Error!void {
    const l = tree.getFinalLayout(node_id);
    const display = tree.getDebugLabel(node_id);
    const num_children = tree.childCount(node_id);

    for (lines) |bar| try writer.writeAll(if (bar) "│   " else "    ");
    const fork_string = if (has_sibling) "├── " else "└── ";
    try writer.print(
        "{s} {s} [x: {d: <4} y: {d: <4} w: {d: <4} h: {d: <4} overflow: l:{d} r:{d} t:{d} b:{d}, border: l:{d} r:{d} t:{d} b:{d}, padding: l:{d} r:{d} t:{d} b:{d}] ({f})\n",
        .{
            fork_string,
            display,
            l.location.x,
            l.location.y,
            l.size.width,
            l.size.height,
            l.scrollable_overflow_rect.left(),
            l.scrollable_overflow_rect.right(),
            l.scrollable_overflow_rect.top(),
            l.scrollable_overflow_rect.bottom(),
            l.border.left,
            l.border.right,
            l.border.top,
            l.border.bottom,
            l.padding.left,
            l.padding.right,
            l.padding.top,
            l.padding.bottom,
            node_id,
        },
    );

    var new_lines: [max_depth]bool = undefined;
    const depth = @min(lines.len, max_depth - 1);
    @memcpy(new_lines[0..depth], lines[0..depth]);
    new_lines[depth] = has_sibling;

    // Recurse into children
    var iter = tree.childIds(node_id);
    var index: usize = 0;
    while (iter.next()) |child| : (index += 1) {
        const child_has_sibling = index < num_children - 1;
        try writeNode(writer, tree, child, child_has_sibling, new_lines[0 .. depth + 1]);
    }
}
