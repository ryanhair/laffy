//! laffy benchmark suite: `zig build bench -- [filter] [--verify] [--profile-relayout=<ms>] [--profile-full=<ms>]`.
//!
//! Every workload is built deterministically (splitmix64 with fixed seeds, no clocks) and is mirrored
//! exactly by `benches/taffy-compare/src/main.rs`; keep the two files in step. See `benches/README.md`.
//!
//! For each workload we report the median time of a full layout of a freshly built tree, the median
//! time of a relayout after marking one leaf dirty, and the bytes allocated by a full layout.
const std = @import("std");
const laffy = @import("laffy");

const Allocator = std.mem.Allocator;
const Style = laffy.Style;
const Size = laffy.Size;
const Rect = laffy.Rect;
const NodeId = laffy.NodeId;
const Dimension = laffy.Dimension;
const LengthPercentage = laffy.LengthPercentage;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const AvailableSpace = laffy.AvailableSpace;
const GridTemplateComponent = laffy.GridTemplateComponent;
const MinTrackSizingFunction = laffy.MinTrackSizingFunction;
const MaxTrackSizingFunction = laffy.MaxTrackSizingFunction;
const Tree = laffy.TaffyTree(void);

// Methodology constants; the Rust side uses the same values.
const full_warmup = 3;
const full_runs = 21;
const relayout_warmup = 5;
const relayout_runs = 51;
const seed: u64 = 12345;

// --- Deterministic PRNG (splitmix64), mirrored in the Rust program ---

const Rng = struct {
    state: u64,

    fn next(self: *Rng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    /// Uniform f32 in [0, 1)
    fn unit(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() >> 40)) / 16777216.0;
    }

    /// Uniform f32 in [lo, hi)
    fn range(self: *Rng, lo: f32, hi: f32) f32 {
        const u = self.unit();
        return lo + u * (hi - lo);
    }

    /// Uniform integer in 1..=4
    fn oneToFour(self: *Rng) usize {
        return 1 + @as(usize, @intCast(self.next() % 4));
    }
};

// --- Tree builder ---

const Builder = struct {
    tree: Tree,
    /// Holds grid track lists (borrowed by styles) and scratch child lists
    arena: std.heap.ArenaAllocator,
    rng: Rng = .{ .state = seed },
    root: NodeId = undefined,
    /// Every node in creation order (root included, at the point it was created)
    nodes: std.ArrayList(NodeId) = .empty,
    /// Nodes created with `leaf`, in creation order
    leaves: std.ArrayList(NodeId) = .empty,
    available: Size(AvailableSpace) = .{ .width = .max_content, .height = .max_content },

    fn init(gpa: Allocator) !Builder {
        return .{ .tree = try Tree.init(gpa), .arena = .init(gpa) };
    }

    fn deinit(self: *Builder) void {
        self.tree.deinit();
        self.arena.deinit();
    }

    fn scratch(self: *Builder) Allocator {
        return self.arena.allocator();
    }

    fn leaf(self: *Builder, style: Style) !NodeId {
        const id = try self.tree.newLeaf(style);
        try self.nodes.append(self.scratch(), id);
        try self.leaves.append(self.scratch(), id);
        return id;
    }

    fn container(self: *Builder, style: Style, children: []const NodeId) !NodeId {
        const id = try self.tree.newWithChildren(style, children);
        try self.nodes.append(self.scratch(), id);
        return id;
    }

    /// Upstream creates the root first (as a leaf) and attaches children later
    fn rootLeaf(self: *Builder, style: Style) !void {
        self.root = try self.tree.newLeaf(style);
        try self.nodes.append(self.scratch(), self.root);
    }

    fn setRootChildren(self: *Builder, children: []const NodeId) !void {
        try self.tree.setChildren(self.root, children);
    }

    fn layout(self: *Builder) !void {
        try self.tree.computeLayout(self.root, self.available);
    }
};

// --- Style generators ---

fn randomDimension(rng: *Rng) Dimension {
    const r = rng.unit();
    if (r < 0.2) return .auto;
    if (r < 0.8) return Dimension.fromLength(rng.range(0.0, 500.0));
    return Dimension.fromPercent(rng.range(0.0, 1.0));
}

fn randomSizeStyle(rng: *Rng) Style {
    const w = randomDimension(rng);
    const h = randomDimension(rng);
    return .{ .size = .{ .width = w, .height = h } };
}

const auto_style: Style = .{
    .flex_grow = 1.0,
    .margin = Rect(LengthPercentageAuto).fromLength(10.0),
};

const chain_style: Style = .{
    .flex_direction = .row,
    .flex_grow = 1.0,
    .margin = Rect(LengthPercentageAuto).fromLength(10.0),
};

const Gen = enum { random_size, auto, block };

fn genLeaf(b: *Builder, gen: Gen) Style {
    switch (gen) {
        .random_size => return randomSizeStyle(&b.rng),
        .auto => return auto_style,
        .block => {
            const h = b.rng.range(5.0, 50.0);
            const mt = b.rng.range(0.0, 8.0);
            const mb = b.rng.range(0.0, 8.0);
            return .{
                .display = .block,
                .size = .{ .width = .auto, .height = Dimension.fromLength(h) },
                .margin = .{
                    .left = LengthPercentageAuto.zero,
                    .right = LengthPercentageAuto.zero,
                    .top = LengthPercentageAuto.fromLength(mt),
                    .bottom = LengthPercentageAuto.fromLength(mb),
                },
            };
        },
    }
}

fn genContainer(b: *Builder, gen: Gen) Style {
    switch (gen) {
        .random_size => return randomSizeStyle(&b.rng),
        .auto => return auto_style,
        .block => {
            const mt = b.rng.range(0.0, 8.0);
            const mb = b.rng.range(0.0, 8.0);
            return .{
                .display = .block,
                .padding = Rect(LengthPercentage).fromLength(4.0),
                .margin = .{
                    .left = LengthPercentageAuto.zero,
                    .right = LengthPercentageAuto.zero,
                    .top = LengthPercentageAuto.fromLength(mt),
                    .bottom = LengthPercentageAuto.fromLength(mb),
                },
            };
        },
    }
}

// --- Workload builders ---

/// Upstream `build_deep_tree`
fn buildDeepTree(b: *Builder, gen: Gen, max_nodes: u32, branching: u32) ![]NodeId {
    const out = try b.scratch().alloc(NodeId, if (max_nodes <= branching) max_nodes else branching);
    if (max_nodes <= branching) {
        for (out) |*slot| slot.* = try b.leaf(genLeaf(b, gen));
        return out;
    }
    for (out) |*slot| {
        const remaining = (max_nodes - branching) / branching;
        const children = try buildDeepTree(b, gen, remaining, branching);
        slot.* = try b.container(genContainer(b, gen), children);
    }
    return out;
}

fn deepHierarchy(b: *Builder, gen: Gen, node_count: u32, branching: u32) !void {
    try b.rootLeaf(if (gen == .block) .{ .display = .block } else .{});
    const children = try buildDeepTree(b, gen, node_count, branching);
    try b.setRootChildren(children);
}

/// Upstream `build_flat_hierarchy`
fn flatHierarchy(b: *Builder, gen: Gen, target: u32) !void {
    try b.rootLeaf(if (gen == .block) .{ .display = .block } else .{});
    var children: std.ArrayList(NodeId) = .empty;
    while (b.tree.totalNodeCount() < target) {
        const count = b.rng.oneToFour();
        const sub = try b.scratch().alloc(NodeId, count);
        for (sub) |*slot| slot.* = try b.leaf(genLeaf(b, gen));
        const node = try b.container(genContainer(b, gen), sub);
        try children.append(b.scratch(), node);
    }
    try b.setRootChildren(children.items);
}

fn superDeep(b: *Builder, depth: u32, nodes_per_level: u32) !void {
    try b.rootLeaf(.{});
    var children: std.ArrayList(NodeId) = .empty;
    var level: u32 = 0;
    while (level < depth) : (level += 1) {
        const node = try b.container(chain_style, children.items);
        children.clearRetainingCapacity();
        try children.append(b.scratch(), node);
        var i: u32 = 1;
        while (i < nodes_per_level) : (i += 1) try children.append(b.scratch(), try b.leaf(chain_style));
    }
    try b.setRootChildren(children.items);
}

fn randomTrack(rng: *Rng) GridTemplateComponent {
    const s = rng.unit();
    if (s < 0.1) return GridTemplateComponent.auto;
    if (s < 0.2) return GridTemplateComponent.min_content;
    if (s < 0.3) return GridTemplateComponent.max_content;
    if (s < 0.5) return GridTemplateComponent.fromFr(1.0);
    if (s < 0.6) return laffy.style_helpers.minmax(GridTemplateComponent, MinTrackSizingFunction.fromLength(0.0), MaxTrackSizingFunction.fromFr(1.0));
    if (s < 0.8) return GridTemplateComponent.fromLength(40.0);
    return GridTemplateComponent.fromPercent(0.3);
}

fn randomGridStyle(b: *Builder, columns: usize, rows: usize) !Style {
    const cols = try b.scratch().alloc(GridTemplateComponent, columns);
    for (cols) |*c| c.* = randomTrack(&b.rng);
    const rws = try b.scratch().alloc(GridTemplateComponent, rows);
    for (rws) |*r| r.* = randomTrack(&b.rng);
    return .{ .display = .grid, .grid_template_columns = cols, .grid_template_rows = rws };
}

const grid_leaf: Style = .{ .size = Size(Dimension).fromLength(20.0) };

fn gridFlat(b: *Builder, cols: usize, rows: usize) !void {
    b.available = .{ .width = .{ .definite = 12000.0 }, .height = .{ .definite = 12000.0 } };
    const style = try randomGridStyle(b, cols, rows);
    const children = try b.scratch().alloc(NodeId, cols * rows);
    for (children) |*c| c.* = try b.leaf(grid_leaf);
    b.root = try b.container(style, children);
}

fn buildDeepGridTree(b: *Builder, levels: usize, tracks: usize) ![]NodeId {
    const child_count = tracks * tracks;
    const out = try b.scratch().alloc(NodeId, child_count);
    if (levels == 1) {
        for (out) |*slot| slot.* = try b.leaf(grid_leaf);
        return out;
    }
    for (out) |*slot| {
        const sub = try buildDeepGridTree(b, levels - 1, tracks);
        const style = try randomGridStyle(b, tracks, tracks);
        slot.* = try b.container(style, sub);
    }
    return out;
}

fn gridNested(b: *Builder, levels: usize, tracks: usize) !void {
    b.available = .{ .width = .{ .definite = 12000.0 }, .height = .{ .definite = 12000.0 } };
    const children = try buildDeepGridTree(b, levels, tracks);
    b.root = try b.container(.{}, children);
}

fn blockRootAvailable(b: *Builder) void {
    b.available = .{ .width = .{ .definite = 800.0 }, .height = .max_content };
}

// --- Workload table ---

const Workload = struct {
    name: []const u8,
    build: *const fn (*Builder) anyerror!void,
};

fn entry(comptime name: []const u8, comptime body: fn (*Builder) anyerror!void) Workload {
    return .{ .name = name, .build = body };
}

fn flexWide1k(b: *Builder) !void {
    try flatHierarchy(b, .random_size, 1_000);
}
fn flexWide10k(b: *Builder) !void {
    try flatHierarchy(b, .random_size, 10_000);
}
fn flexDeep4k(b: *Builder) !void {
    try deepHierarchy(b, .random_size, 4_000, 2);
}
fn flexDeep10k(b: *Builder) !void {
    try deepHierarchy(b, .random_size, 10_000, 2);
}
fn flexDeepAuto4k(b: *Builder) !void {
    try deepHierarchy(b, .auto, 4_000, 2);
}
fn flexDeepAuto10k(b: *Builder) !void {
    try deepHierarchy(b, .auto, 10_000, 2);
}
fn flexChain100(b: *Builder) !void {
    try superDeep(b, 100, 3);
}
fn flexChain1000(b: *Builder) !void {
    try superDeep(b, 1000, 3);
}
fn gridFlat31(b: *Builder) !void {
    try gridFlat(b, 31, 31);
}
fn gridFlat100(b: *Builder) !void {
    try gridFlat(b, 100, 100);
}
fn gridNested3x4(b: *Builder) !void {
    try gridNested(b, 4, 3);
}
fn gridNested2x7(b: *Builder) !void {
    try gridNested(b, 7, 2);
}
fn blockWide10k(b: *Builder) !void {
    blockRootAvailable(b);
    try flatHierarchy(b, .block, 10_000);
}
fn blockDeep10k(b: *Builder) !void {
    blockRootAvailable(b);
    try deepHierarchy(b, .block, 10_000, 4);
}

const workloads = [_]Workload{
    entry("flex-wide-1000", flexWide1k),
    entry("flex-wide-10000", flexWide10k),
    entry("flex-deep-4000", flexDeep4k),
    entry("flex-deep-10000", flexDeep10k),
    entry("flex-deep-auto-4000", flexDeepAuto4k),
    entry("flex-deep-auto-10000", flexDeepAuto10k),
    entry("flex-chain-100", flexChain100),
    entry("flex-chain-1000", flexChain1000),
    entry("grid-flat-31x31", gridFlat31),
    entry("grid-flat-100x100", gridFlat100),
    entry("grid-nested-3x3-d4", gridNested3x4),
    entry("grid-nested-2x2-d7", gridNested2x7),
    entry("block-wide-10000", blockWide10k),
    entry("block-deep-10000", blockDeep10k),
};

// --- Allocation counting ---

const CountingAllocator = struct {
    child: Allocator,
    total_bytes: u64 = 0,
    live: i64 = 0,
    peak: i64 = 0,
    count: u64 = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn reset(self: *CountingAllocator) void {
        self.* = .{ .child = self.child };
    }

    fn grow(self: *CountingAllocator, delta: usize) void {
        self.total_bytes += delta;
        self.count += 1;
        self.live += @intCast(delta);
        self.peak = @max(self.peak, self.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.grow(len);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.account(memory.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.account(memory.len, new_len);
        return p;
    }

    fn account(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            self.grow(new_len - old_len);
        } else {
            self.live -= @intCast(old_len - new_len);
        }
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.live -= @intCast(memory.len);
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

// --- Measurement ---

fn median(values: []u64) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[values.len / 2];
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).toNanoseconds();
}

fn timeFull(gpa: Allocator, io: std.Io, wl: Workload) !u64 {
    var samples: [full_runs]u64 = undefined;
    var run: usize = 0;
    while (run < full_warmup + full_runs) : (run += 1) {
        var b = try Builder.init(gpa);
        defer b.deinit();
        try wl.build(&b);
        const t0 = nowNs(io);
        try b.layout();
        const t1 = nowNs(io);
        if (run >= full_warmup) samples[run - full_warmup] = @intCast(t1 - t0);
    }
    return median(&samples);
}

fn timeRelayout(gpa: Allocator, io: std.Io, wl: Workload) !u64 {
    var b = try Builder.init(gpa);
    defer b.deinit();
    try wl.build(&b);
    try b.layout();
    const target = b.leaves.items[b.leaves.items.len / 2];
    var samples: [relayout_runs]u64 = undefined;
    var run: usize = 0;
    while (run < relayout_warmup + relayout_runs) : (run += 1) {
        b.tree.markDirty(target);
        const t0 = nowNs(io);
        try b.layout();
        const t1 = nowNs(io);
        if (run >= relayout_warmup) samples[run - relayout_warmup] = @intCast(t1 - t0);
    }
    return median(&samples);
}

/// Relayout timing for profiling: the median relayout time with and without rounding, followed
/// by `spin_ms` milliseconds of back-to-back relayouts for a sampling profiler to attach to.
fn profileRelayout(out: *std.Io.Writer, gpa: Allocator, io: std.Io, wl: Workload, spin_ms: u64) !void {
    var b = try Builder.init(gpa);
    defer b.deinit();
    try wl.build(&b);
    try b.layout();
    const target = b.leaves.items[b.leaves.items.len / 2];
    var medians: [2]u64 = undefined;
    for (&medians, [_]bool{ true, false }) |*result, rounding| {
        b.tree.config.use_rounding = rounding;
        var samples: [relayout_runs]u64 = undefined;
        var run: usize = 0;
        while (run < relayout_warmup + relayout_runs) : (run += 1) {
            b.tree.markDirty(target);
            const t0 = nowNs(io);
            try b.layout();
            const t1 = nowNs(io);
            if (run >= relayout_warmup) samples[run - relayout_warmup] = @intCast(t1 - t0);
        }
        result.* = median(&samples);
    }
    b.tree.config.use_rounding = true;
    try out.print("{s:<22} relayout {d:>9.1} us, without rounding {d:>9.1} us\n", .{
        wl.name,
        @as(f64, @floatFromInt(medians[0])) / 1000.0,
        @as(f64, @floatFromInt(medians[1])) / 1000.0,
    });
    try out.flush();
    const start = nowNs(io);
    while (nowNs(io) - start < spin_ms * std.time.ns_per_ms) {
        b.tree.markDirty(target);
        try b.layout();
    }
}

/// Full layout for profiling: every leaf is marked dirty (which clears every cache in the tree)
/// and the tree is laid out again, repeatedly, for `spin_ms` milliseconds.
fn profileFull(out: *std.Io.Writer, gpa: Allocator, io: std.Io, wl: Workload, spin_ms: u64) !void {
    var b = try Builder.init(gpa);
    defer b.deinit();
    try wl.build(&b);
    try b.layout();
    var passes: u64 = 0;
    const start = nowNs(io);
    while (nowNs(io) - start < spin_ms * std.time.ns_per_ms) : (passes += 1) {
        for (b.leaves.items) |leaf| b.tree.markDirty(leaf);
        try b.layout();
    }
    const elapsed = nowNs(io) - start;
    try out.print("{s:<22} full layout of a built tree {d:>9.1} us\n", .{
        wl.name,
        @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(@max(passes, 1))) / 1000.0,
    });
    try out.flush();
}

const AllocStats = struct { total: u64, peak: u64, count: u64 };

fn measureAlloc(gpa: Allocator, wl: Workload) !AllocStats {
    var counting: CountingAllocator = .{ .child = gpa };
    var b = try Builder.init(counting.allocator());
    defer b.deinit();
    try wl.build(&b);
    counting.reset();
    try b.layout();
    return .{ .total = counting.total_bytes, .peak = @intCast(counting.peak), .count = counting.count };
}

/// Root size and a sum over every node of x + y + width + height (rounded layout), for checking
/// that two implementations produced the same tree and the same layout.
fn verify(out: *std.Io.Writer, gpa: Allocator, wl: Workload) !void {
    var b = try Builder.init(gpa);
    defer b.deinit();
    try wl.build(&b);
    try b.layout();
    var sum: f64 = 0;
    for (b.nodes.items) |id| {
        const l = b.tree.layout(id);
        sum += @as(f64, l.location.x) + l.location.y + l.size.width + l.size.height;
    }
    const root = b.tree.layout(b.root);
    try out.print("{s} nodes={d} root={d:.1}x{d:.1} checksum={d:.1}\n", .{
        wl.name, b.nodes.items.len, root.size.width, root.size.height, sum,
    });
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const io = init.io;
    const arena = init.arena.allocator();

    var out_buffer: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &out_writer.interface;

    var filter: ?[]const u8 = null;
    var do_verify = false;
    var profile_spin_ms: ?u64 = null;
    var profile_full_ms: ?u64 = null;
    const args = try init.minimal.args.toSlice(arena);
    for (args[1..]) |arg| {
        const a: []const u8 = arg;
        if (std.mem.eql(u8, a, "--verify")) {
            do_verify = true;
        } else if (std.mem.startsWith(u8, a, "--profile-relayout=")) {
            profile_spin_ms = try std.fmt.parseInt(u64, a["--profile-relayout=".len..], 10);
        } else if (std.mem.startsWith(u8, a, "--profile-full=")) {
            profile_full_ms = try std.fmt.parseInt(u64, a["--profile-full=".len..], 10);
        } else {
            filter = a;
        }
    }

    if (!do_verify and profile_spin_ms == null and profile_full_ms == null) {
        try out.print("{s:<22} {s:>7} {s:>12} {s:>12} {s:>11} {s:>11} {s:>9}\n", .{ "workload", "nodes", "full (us)", "relayout(us)", "alloc KiB", "peak KiB", "allocs" });
    }
    for (workloads) |wl| {
        if (filter) |f| if (std.mem.indexOf(u8, wl.name, f) == null) continue;
        if (do_verify) {
            try verify(out, gpa, wl);
            try out.flush();
            continue;
        }
        if (profile_spin_ms) |spin_ms| {
            try profileRelayout(out, gpa, io, wl, spin_ms);
            continue;
        }
        if (profile_full_ms) |spin_ms| {
            try profileFull(out, gpa, io, wl, spin_ms);
            continue;
        }
        var nodes: usize = 0;
        {
            var b = try Builder.init(gpa);
            defer b.deinit();
            try wl.build(&b);
            nodes = b.nodes.items.len;
        }
        const full = try timeFull(gpa, io, wl);
        const relayout = try timeRelayout(gpa, io, wl);
        const mem = try measureAlloc(gpa, wl);
        try out.print("{s:<22} {d:>7} {d:>12.1} {d:>12.1} {d:>11.1} {d:>11.1} {d:>9}\n", .{
            wl.name,
            nodes,
            @as(f64, @floatFromInt(full)) / 1000.0,
            @as(f64, @floatFromInt(relayout)) / 1000.0,
            @as(f64, @floatFromInt(mem.total)) / 1024.0,
            @as(f64, @floatFromInt(mem.peak)) / 1024.0,
            mem.count,
        });
        try out.flush();
    }
    try out.flush();
}
