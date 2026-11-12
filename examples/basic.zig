//! A minimal laffy example: a flexbox row with one fixed and one growing child.
const std = @import("std");
const laffy = @import("laffy");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var tree = try laffy.TaffyTree(void).init(gpa.allocator());
    defer tree.deinit();

    const sidebar = try tree.newLeaf(.{
        .size = .{ .width = .{ .length = 80 }, .height = .auto },
    });
    const content = try tree.newLeaf(.{ .flex_grow = 1 });
    const root = try tree.newWithChildren(.{
        .display = .flex,
        .size = .{ .width = .{ .length = 300 }, .height = .{ .length = 100 } },
        .gap = .{ .width = .{ .length = 10 }, .height = .zero },
    }, &.{ sidebar, content });

    try tree.computeLayout(root, .{ .width = .max_content, .height = .max_content });

    for ([_]struct { []const u8, laffy.NodeId }{ .{ "root", root }, .{ "sidebar", sidebar }, .{ "content", content } }) |entry| {
        const layout = tree.layout(entry[1]);
        std.debug.print("{s}: {d}x{d} at ({d}, {d})\n", .{
            entry[0], layout.size.width, layout.size.height, layout.location.x, layout.location.y,
        });
    }
}
