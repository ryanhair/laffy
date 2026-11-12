//! A small generational-index arena, replacing the `slotmap` crate that upstream's `TaffyTree` uses.
//!
//! Values live in slots of a growable array. A key packs the slot index (low 32 bits) and the
//! slot's generation (high 32 bits) into a `u64`, like `slotmap`'s `KeyData::as_ffi`. Removing a
//! value bumps its slot's generation and puts the slot on a free list (reused last-in, first-out),
//! so keys of removed values are detected as stale even after their slot is reused. Generation 0
//! is never used, so the key `0` is never valid.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// A generational arena of `T` values keyed by `u64`
pub fn SlotMap(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            /// The generation of the current (or, when vacant, the next) value
            generation: u32,
            /// The value, or the index of the next free slot when vacant
            payload: union { value: T, next_free: u32 },
            occupied: bool,
        };

        const no_free_slot = std.math.maxInt(u32);

        slots: std.ArrayList(Slot) = .empty,
        free_head: u32 = no_free_slot,
        len: usize = 0,

        pub const empty: Self = .{};

        /// Create an arena that can hold `capacity` values before reallocating
        pub fn initCapacity(gpa: Allocator, initial_capacity: usize) Allocator.Error!Self {
            return .{ .slots = try .initCapacity(gpa, initial_capacity) };
        }

        /// Free the arena's memory (values are not deinitialized)
        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.slots.deinit(gpa);
            self.* = .empty;
        }

        /// The number of values the arena can hold before reallocating
        pub fn capacity(self: *const Self) usize {
            return self.slots.capacity;
        }

        /// The number of values in the arena
        pub fn count(self: *const Self) usize {
            return self.len;
        }

        fn makeKey(index: u32, generation: u32) u64 {
            return @as(u64, generation) << 32 | index;
        }

        /// Insert a value and return its key
        pub fn insert(self: *Self, gpa: Allocator, value: T) Allocator.Error!u64 {
            if (self.free_head != no_free_slot) {
                const index = self.free_head;
                const slot = &self.slots.items[index];
                self.free_head = slot.payload.next_free;
                slot.payload = .{ .value = value };
                slot.occupied = true;
                self.len += 1;
                return makeKey(index, slot.generation);
            }
            if (self.slots.items.len >= no_free_slot) return error.OutOfMemory;
            const index: u32 = @intCast(self.slots.items.len);
            try self.slots.append(gpa, .{ .generation = 1, .payload = .{ .value = value }, .occupied = true });
            self.len += 1;
            return makeKey(index, 1);
        }

        /// The slot of a live key, or null if the key is invalid or stale
        fn slotOf(self: *const Self, key: u64) ?*Slot {
            const index: u32 = @truncate(key);
            const generation: u32 = @truncate(key >> 32);
            if (index >= self.slots.items.len) return null;
            const slot = &self.slots.items[index];
            if (!slot.occupied or slot.generation != generation) return null;
            return slot;
        }

        /// Whether `key` refers to a value in the arena
        pub fn contains(self: *const Self, key: u64) bool {
            return self.slotOf(key) != null;
        }

        /// A pointer to the value for `key`, or null if the key is invalid or stale. The pointer
        /// is invalidated by the next insertion.
        pub fn get(self: *const Self, key: u64) ?*T {
            const slot = self.slotOf(key) orelse return null;
            return &slot.payload.value;
        }

        /// Remove the value for `key` and return it, or null if the key is invalid or stale
        pub fn remove(self: *Self, key: u64) ?T {
            const slot = self.slotOf(key) orelse return null;
            const value = slot.payload.value;
            const index: u32 = @truncate(key);
            slot.occupied = false;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.payload = .{ .next_free = self.free_head };
            self.free_head = index;
            self.len -= 1;
            return value;
        }

        /// Remove every value (keeping the capacity). All existing keys become stale.
        pub fn clear(self: *Self) void {
            var iter = self.iterator();
            while (iter.next()) |entry| _ = self.remove(entry.key);
        }

        pub const Entry = struct { key: u64, value: *T };

        pub const Iterator = struct {
            map: *const Self,
            index: usize = 0,

            pub fn next(self: *Iterator) ?Entry {
                while (self.index < self.map.slots.items.len) {
                    const index = self.index;
                    self.index += 1;
                    const slot = &self.map.slots.items[index];
                    if (slot.occupied) {
                        return .{ .key = makeKey(@intCast(index), slot.generation), .value = &slot.payload.value };
                    }
                }
                return null;
            }
        };

        /// Iterate over the live values in slot order
        pub fn iterator(self: *const Self) Iterator {
            return .{ .map = self };
        }
    };
}

test "SlotMap insert, get, remove and stale keys" {
    const gpa = std.testing.allocator;
    var map: SlotMap(u32) = try .initCapacity(gpa, 4);
    defer map.deinit(gpa);
    try std.testing.expect(map.capacity() >= 4);

    const a = try map.insert(gpa, 10);
    const b = try map.insert(gpa, 20);
    try std.testing.expectEqual(@as(usize, 2), map.count());
    try std.testing.expectEqual(@as(u32, 10), map.get(a).?.*);
    try std.testing.expect(!map.contains(0));

    try std.testing.expectEqual(@as(?u32, 10), map.remove(a));
    try std.testing.expect(!map.contains(a));
    try std.testing.expectEqual(@as(?u32, null), map.remove(a));

    // The slot is reused with a new generation; the old key stays stale
    const c = try map.insert(gpa, 30);
    try std.testing.expectEqual(@as(u32, @truncate(a)), @as(u32, @truncate(c)));
    try std.testing.expect(c != a);
    try std.testing.expect(map.get(a) == null);
    try std.testing.expectEqual(@as(u32, 30), map.get(c).?.*);

    var iter = map.iterator();
    var sum: u32 = 0;
    while (iter.next()) |entry| sum += entry.value.*;
    try std.testing.expectEqual(@as(u32, 50), sum);

    map.clear();
    try std.testing.expectEqual(@as(usize, 0), map.count());
    try std.testing.expect(!map.contains(b));
    try std.testing.expect(!map.contains(c));
}
