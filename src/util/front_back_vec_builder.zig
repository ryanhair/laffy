//! A fixed-capacity list builder that can be filled from both ends
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Builds a slice of a fixed length that is known up front by pushing items to either its front or its back.
///
/// Items pushed to the front end up at the start of the slice in the order that they were pushed. Items pushed to the
/// back end up at the end of the slice in the reverse of the order that they were pushed. This allows a list of items
/// to be partitioned into two groups in a single pass and with a single allocation.
///
/// Exactly `capacity` items must be pushed before calling `intoSlice`, which panics otherwise.
pub fn FrontBackVecBuilder(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The underlying storage, of length `capacity`
        buffer: []T,
        /// The number of items pushed to the front. The slots `0..front_len` are initialized.
        front_len: usize = 0,
        /// The number of items pushed to the back. The slots `(capacity - back_len)..capacity` are initialized.
        back_len: usize = 0,

        /// Create a new `FrontBackVecBuilder` that will contain exactly `capacity` items
        pub fn withCapacity(gpa: Allocator, capacity: usize) Allocator.Error!Self {
            return .{ .buffer = try gpa.alloc(T, capacity) };
        }

        /// Free the storage (only needed if `intoSlice` is not called)
        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.buffer);
            self.* = undefined;
        }

        /// Add an item after the items that have already been pushed to the front.
        pub fn pushFront(self: *Self, value: T) void {
            self.buffer[self.front_len] = value;
            self.front_len += 1;
        }

        /// Add an item before the items that have already been pushed to the back.
        pub fn pushBack(self: *Self, value: T) void {
            self.buffer[self.buffer.len - self.back_len - 1] = value;
            self.back_len += 1;
        }

        /// Returns the completed slice (owned by the caller, allocated with the allocator passed to
        /// `withCapacity`), along with the number of items that were pushed to the front (which is also
        /// the index of the first item that was pushed to the back).
        ///
        /// Panics if the total number of items that have been pushed is not exactly `capacity`.
        pub fn intoSlice(self: Self) struct { []T, usize } {
            if (self.front_len + self.back_len != self.buffer.len) {
                @panic("the number of items pushed to a FrontBackVecBuilder must equal its capacity");
            }
            return .{ self.buffer, self.front_len };
        }
    };
}

const testing = std.testing;

test "front items keep their order and back items are reversed" {
    var builder = try FrontBackVecBuilder(u32).withCapacity(testing.allocator, 6);
    for (0..6) |value| {
        if (value % 2 == 0) {
            builder.pushFront(@intCast(value));
        } else {
            builder.pushBack(@intCast(value));
        }
    }
    const slice, const front_len = builder.intoSlice();
    defer testing.allocator.free(slice);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 4, 5, 3, 1 }, slice);
    try testing.expectEqual(@as(usize, 3), front_len);
}

test "only front or only back" {
    var front = try FrontBackVecBuilder(u8).withCapacity(testing.allocator, 2);
    front.pushFront(1);
    front.pushFront(2);
    const front_slice, const front_len = front.intoSlice();
    defer testing.allocator.free(front_slice);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, front_slice);
    try testing.expectEqual(@as(usize, 2), front_len);

    var back = try FrontBackVecBuilder(u8).withCapacity(testing.allocator, 2);
    back.pushBack(1);
    back.pushBack(2);
    const back_slice, const back_len = back.intoSlice();
    defer testing.allocator.free(back_slice);
    try testing.expectEqualSlices(u8, &.{ 2, 1 }, back_slice);
    try testing.expectEqual(@as(usize, 0), back_len);

    var empty = try FrontBackVecBuilder(u8).withCapacity(testing.allocator, 0);
    const empty_slice, _ = empty.intoSlice();
    defer testing.allocator.free(empty_slice);
    try testing.expectEqual(@as(usize, 0), empty_slice.len);
}
