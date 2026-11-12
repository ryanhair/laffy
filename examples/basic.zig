//! A minimal laffy example: a flexbox row with one fixed and one growing child.
const std = @import("std");
const laffy = @import("laffy");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var tree = try laffy.TaffyTree(void).init(gpa.allocator());
    defer tree.deinit();

    const sidebar = try tree.newLeaf(.{
        .size = .{ .width = laffy.Dimension.fromLength(80), .height = laffy.Dimension.auto },
    });
    const content = try tree.newLeaf(.{ .flex_grow = 1 });
    const root = try tree.newWithChildren(.{
        .display = .flex,
        .size = .{ .width = laffy.Dimension.fromLength(300), .height = laffy.Dimension.fromLength(100) },
        .gap = .{ .width = laffy.LengthPercentage.fromLength(10), .height = laffy.LengthPercentage.zero },
    }, &.{ sidebar, content });

    try tree.computeLayout(root, .{ .width = .max_content, .height = .max_content });

    for ([_]struct { []const u8, laffy.NodeId }{ .{ "root", root }, .{ "sidebar", sidebar }, .{ "content", content } }) |entry| {
        const layout = tree.layout(entry[1]);
        std.debug.print("{s}: {d}x{d} at ({d}, {d})\n", .{
            entry[0], layout.size.width, layout.size.height, layout.location.x, layout.location.y,
        });
    }
}
