//! UI node types and related data structures.
//!
//! Layouts are composed of multiple nodes, which live in a tree-like data structure.
const std = @import("std");

/// A type representing the id of a single node in a tree of nodes
///
/// Internally it is a wrapper around a u64 and a `NodeId` can be converted to and from
/// a u64 if needed.
///
/// For nodes of the built-in `TaffyTree`, the low 32 bits hold the slot index and the high 32 bits
/// the slot generation (see `util/slot_map.zig`), like the `slotmap` keys upstream uses.
pub const NodeId = packed struct(u64) {
    inner: u64,

    /// Create a new NodeId from a u64 value
    pub fn new(val: u64) NodeId {
        return .{ .inner = val };
    }

    /// Upstream `From<u64> for NodeId`
    pub fn fromU64(raw: u64) NodeId {
        return .{ .inner = raw };
    }

    /// Upstream `From<NodeId> for u64`
    pub fn toU64(self: NodeId) u64 {
        return self.inner;
    }

    /// Upstream `From<usize> for NodeId`
    pub fn fromUsize(raw: usize) NodeId {
        return .{ .inner = @intCast(raw) };
    }

    /// Upstream `From<NodeId> for usize` (truncating on targets where usize is narrower than 64 bits)
    pub fn toUsize(self: NodeId) usize {
        return @truncate(self.inner);
    }

    /// Equality (upstream derived `PartialEq`)
    pub fn eql(self: NodeId, other: NodeId) bool {
        return self.inner == other.inner;
    }

    /// Upstream derived `Debug`: `NodeId(<value>)`
    pub fn format(self: NodeId, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("NodeId({d})", .{self.inner});
    }
};

test "NodeId conversions" {
    const id = NodeId.new(42);
    try std.testing.expectEqual(@as(u64, 42), id.toU64());
    try std.testing.expectEqual(@as(usize, 42), id.toUsize());
    try std.testing.expect(NodeId.fromU64(42).eql(id));
    try std.testing.expect(NodeId.fromUsize(42) == id);
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f}", .{id});
    try std.testing.expectEqualStrings("NodeId(42)", w.buffered());
}
