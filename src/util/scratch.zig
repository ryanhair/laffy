//! A stack-like scratch allocator for the temporary buffers that layout algorithms need.
//!
//! Memory is handed out by bumping an offset through a list of chunks. A layout algorithm takes a
//! `Mark` when it starts and releases back to it when it returns, which frees everything that it
//! (and the layout of its descendants) allocated in between. Chunks are kept for reuse, so after
//! the first layout pass a tree's scratch allocations normally cost no calls to the backing
//! allocator at all.
//!
//! Individual frees are honoured only for the most recent allocation; any other free is a no-op
//! until the enclosing mark is released. Memory must not be used after the mark it was allocated
//! under has been released. In builds with runtime safety, released memory is overwritten to make
//! such a bug visible.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Scratch = @This();

/// The allocator that chunks are obtained from
backing: Allocator,
/// All chunks owned by the allocator. Chunks before `current` are full (or were skipped),
/// chunks after it are free.
chunks: std.ArrayList([]align(chunk_alignment.toByteUnits()) u8) = .empty,
/// Index of the chunk that allocations are currently served from
current: usize = 0,
/// Number of bytes used in the current chunk
offset: usize = 0,

const chunk_alignment: Alignment = .@"16";
const min_chunk_size = 16 * 1024;
/// Chunk sizes double up to this size. Larger requests get a chunk of exactly their own size.
const max_chunk_growth = 1024 * 1024;

/// A position in the allocator that can be released back to
pub const Mark = struct {
    chunk: usize,
    offset: usize,
};

pub fn init(backing: Allocator) Scratch {
    return .{ .backing = backing };
}

pub fn deinit(self: *Scratch) void {
    for (self.chunks.items) |chunk| self.backing.free(chunk);
    self.chunks.deinit(self.backing);
    self.* = undefined;
}

/// The current position. Pass it to `release` to free everything allocated after this call.
pub fn mark(self: *const Scratch) Mark {
    return .{ .chunk = self.current, .offset = self.offset };
}

/// Free everything allocated since `to` was taken
pub fn release(self: *Scratch, to: Mark) void {
    std.debug.assert(to.chunk < self.current or (to.chunk == self.current and to.offset <= self.offset));
    if (std.debug.runtime_safety and self.chunks.items.len > 0) {
        var index = to.chunk;
        while (index <= self.current) : (index += 1) {
            const chunk = self.chunks.items[index];
            const start = if (index == to.chunk) to.offset else 0;
            const end = if (index == self.current) self.offset else chunk.len;
            @memset(chunk[start..end], undefined);
        }
    }
    self.current = to.chunk;
    self.offset = to.offset;
}

/// Give chunks back to the backing allocator until at most `limit` bytes are retained. Does
/// nothing while any allocation is live.
pub fn trim(self: *Scratch, limit: usize) void {
    if (self.current != 0 or self.offset != 0) return;
    var retained: usize = 0;
    var keep: usize = 0;
    for (self.chunks.items) |chunk| {
        if (retained + chunk.len > limit) break;
        retained += chunk.len;
        keep += 1;
    }
    for (self.chunks.items[keep..]) |chunk| self.backing.free(chunk);
    self.chunks.shrinkRetainingCapacity(keep);
}

pub fn allocator(self: *Scratch) Allocator {
    return .{ .ptr = self, .vtable = &vtable };
}

const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

/// The offset at which an allocation with the given alignment would start in `chunk`, if the
/// chunk were used from `from`
fn alignedOffset(chunk: []u8, from: usize, alignment: Alignment) usize {
    const base = @intFromPtr(chunk.ptr);
    return alignment.forward(base + from) - base;
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const self: *Scratch = @ptrCast(@alignCast(ctx));
    if (self.chunks.items.len > 0) {
        // Try the current chunk, then any free chunks after it
        var from = self.offset;
        var index = self.current;
        while (index < self.chunks.items.len) : (index += 1) {
            const chunk = self.chunks.items[index];
            const start = alignedOffset(chunk, from, alignment);
            if (start <= chunk.len and len <= chunk.len - start) {
                self.current = index;
                self.offset = start + len;
                return chunk.ptr + start;
            }
            from = 0;
        }
    }

    // No existing chunk fits: add one after the current chunk. Chunk sizes double (up to a
    // limit) so that the number of chunks stays small.
    const last_len = if (self.chunks.items.len > 0) self.chunks.items[self.chunks.items.len - 1].len else 0;
    const padding = if (alignment.compare(.gt, chunk_alignment)) alignment.toByteUnits() else 0;
    const needed = std.math.add(usize, len, padding) catch return null;
    const size = @max(needed, @max(min_chunk_size, @min(last_len *| 2, max_chunk_growth)));
    const chunk = self.backing.alignedAlloc(u8, chunk_alignment, size) catch return null;
    const insert_at = if (self.chunks.items.len == 0) 0 else self.current + 1;
    self.chunks.insert(self.backing, insert_at, chunk) catch {
        self.backing.free(chunk);
        return null;
    };
    const start = alignedOffset(chunk, 0, alignment);
    self.current = insert_at;
    self.offset = start + len;
    return chunk.ptr + start;
}

/// Whether `memory` is the most recent allocation
fn isLast(self: *const Scratch, memory: []u8) bool {
    if (self.chunks.items.len == 0) return false;
    const chunk = self.chunks.items[self.current];
    return @intFromPtr(memory.ptr) + memory.len == @intFromPtr(chunk.ptr) + self.offset;
}

fn resize(ctx: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
    const self: *Scratch = @ptrCast(@alignCast(ctx));
    if (!self.isLast(memory)) return new_len <= memory.len;
    const chunk = self.chunks.items[self.current];
    const start = @intFromPtr(memory.ptr) - @intFromPtr(chunk.ptr);
    if (new_len > chunk.len - start) return false;
    self.offset = start + new_len;
    return true;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(ctx, memory, alignment, new_len, ret_addr)) memory.ptr else null;
}

fn free(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
    const self: *Scratch = @ptrCast(@alignCast(ctx));
    if (!self.isLast(memory)) return;
    const chunk = self.chunks.items[self.current];
    self.offset = @intFromPtr(memory.ptr) - @intFromPtr(chunk.ptr);
}

/// The scratch memory of one layout algorithm invocation: everything allocated between `begin`
/// and `end` (including by the layout of descendants) is released by `end`.
///
/// `tree` is any tree with a `scratch(self) *Scratch` method.
pub const Frame = struct {
    scratch: *Scratch,
    start: Mark,

    pub fn begin(tree: anytype) Frame {
        const s: *Scratch = tree.scratch();
        return .{ .scratch = s, .start = s.mark() };
    }

    pub fn allocator(self: *const Frame) Allocator {
        return self.scratch.allocator();
    }

    pub fn end(self: *const Frame) void {
        self.scratch.release(self.start);
    }
};

/// The allocator for temporary buffers of a tree, for code that runs inside a `Frame` that one
/// of its callers began
pub fn allocatorOf(tree: anytype) Allocator {
    return tree.scratch().allocator();
}

const testing = std.testing;

test "allocations are released back to a mark and chunks are reused" {
    var scratch = Scratch.init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    const outer = try a.alloc(u32, 100);
    @memset(outer, 7);
    const start = scratch.mark();
    const big = try a.alloc(u8, 100_000);
    @memset(big, 1);
    const more = try a.alloc(u64, 10);
    @memset(more, 2);
    const chunk_count = scratch.chunks.items.len;
    try testing.expect(chunk_count >= 2);
    scratch.release(start);
    for (outer) |v| try testing.expectEqual(@as(u32, 7), v);

    // The same request is served from the existing chunks
    const again = try a.alloc(u8, 100_000);
    @memset(again, 3);
    try testing.expectEqual(chunk_count, scratch.chunks.items.len);
    try testing.expectEqual(big.ptr, again.ptr);
}

test "the most recent allocation can grow in place and be freed" {
    var scratch = Scratch.init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    var list: std.ArrayList(u32) = .empty;
    for (0..1000) |i| try list.append(a, @intCast(i));
    for (list.items, 0..) |v, i| try testing.expectEqual(@as(u32, @intCast(i)), v);
    const used = scratch.offset;
    try testing.expect(used < 2 * 1000 * @sizeOf(u32));

    const other = try a.alloc(u8, 16);
    a.free(other);
    try testing.expectEqual(used, scratch.offset);
    list.deinit(a);
    try testing.expectEqual(@as(usize, 0), scratch.offset);
}

test "alignment is respected" {
    var scratch = Scratch.init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    _ = try a.alloc(u8, 3);
    const wide = try a.alignedAlloc(u8, .@"64", 10);
    try testing.expect(std.mem.isAligned(@intFromPtr(wide.ptr), 64));
    const words = try a.alloc(u64, 4);
    try testing.expect(std.mem.isAligned(@intFromPtr(words.ptr), @alignOf(u64)));
}

test "allocation failure leaves the allocator usable" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var scratch = Scratch.init(failing.allocator());
    defer scratch.deinit();
    try testing.expectError(error.OutOfMemory, scratch.allocator().alloc(u8, 8));
    failing.fail_index = std.math.maxInt(usize);
    _ = try scratch.allocator().alloc(u8, 8);
}

test "trim gives large chunks back" {
    var scratch = Scratch.init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const start = scratch.mark();
    _ = try a.alloc(u8, 100);
    _ = try a.alloc(u8, 500_000);
    scratch.trim(64 * 1024);
    try testing.expectEqual(@as(usize, 2), scratch.chunks.items.len);
    scratch.release(start);
    scratch.trim(64 * 1024);
    try testing.expectEqual(@as(usize, 1), scratch.chunks.items.len);
    _ = try a.alloc(u8, 100);
}
