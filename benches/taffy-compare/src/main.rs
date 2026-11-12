//! Builds the same workloads as `benches/bench.zig` (same trees, same styles, same deterministic
//! splitmix64 parameters) and times them the same way. Keep the two files in step.
//!
//! Usage: `cargo run --release -- [filter] [--verify]`
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering::Relaxed};
use std::time::Instant;
use taffy::prelude::*;

// Methodology constants; the Zig side uses the same values.
const FULL_WARMUP: usize = 3;
const FULL_RUNS: usize = 21;
const RELAYOUT_WARMUP: usize = 5;
const RELAYOUT_RUNS: usize = 51;
const SEED: u64 = 12345;

// --- Allocation counting (only active during the dedicated measurement pass) ---

struct Counting;
static COUNTING: AtomicBool = AtomicBool::new(false);
static TOTAL: AtomicU64 = AtomicU64::new(0);
static COUNT: AtomicU64 = AtomicU64::new(0);
static LIVE: AtomicI64 = AtomicI64::new(0);
static PEAK: AtomicI64 = AtomicI64::new(0);

fn note_grow(delta: usize) {
    TOTAL.fetch_add(delta as u64, Relaxed);
    COUNT.fetch_add(1, Relaxed);
    let live = LIVE.fetch_add(delta as i64, Relaxed) + delta as i64;
    PEAK.fetch_max(live, Relaxed);
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if COUNTING.load(Relaxed) {
            note_grow(layout.size());
        }
        System.alloc(layout)
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        if COUNTING.load(Relaxed) {
            LIVE.fetch_sub(layout.size() as i64, Relaxed);
        }
        System.dealloc(ptr, layout)
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if COUNTING.load(Relaxed) {
            if new_size > layout.size() {
                note_grow(new_size - layout.size());
            } else {
                LIVE.fetch_sub((layout.size() - new_size) as i64, Relaxed);
            }
        }
        System.realloc(ptr, layout, new_size)
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

// --- Deterministic PRNG (splitmix64), mirrored in bench.zig ---

struct Rng {
    state: u64,
}

impl Rng {
    fn next(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }
    /// Uniform f32 in [0, 1)
    fn unit(&mut self) -> f32 {
        (self.next() >> 40) as f32 / 16777216.0
    }
    /// Uniform f32 in [lo, hi)
    fn range(&mut self, lo: f32, hi: f32) -> f32 {
        let u = self.unit();
        lo + u * (hi - lo)
    }
    /// Uniform integer in 1..=4
    fn one_to_four(&mut self) -> usize {
        1 + (self.next() % 4) as usize
    }
}

// --- Tree builder ---

struct Builder {
    tree: TaffyTree,
    rng: Rng,
    root: NodeId,
    nodes: Vec<NodeId>,
    leaves: Vec<NodeId>,
    available: Size<AvailableSpace>,
}

impl Builder {
    fn new() -> Self {
        Builder {
            tree: TaffyTree::new(),
            rng: Rng { state: SEED },
            root: NodeId::new(0),
            nodes: Vec::new(),
            leaves: Vec::new(),
            available: Size::MAX_CONTENT,
        }
    }

    fn leaf(&mut self, style: Style) -> NodeId {
        let id = self.tree.new_leaf(style).unwrap();
        self.nodes.push(id);
        self.leaves.push(id);
        id
    }

    fn container(&mut self, style: Style, children: &[NodeId]) -> NodeId {
        let id = self.tree.new_with_children(style, children).unwrap();
        self.nodes.push(id);
        id
    }

    fn root_leaf(&mut self, style: Style) {
        self.root = self.tree.new_leaf(style).unwrap();
        self.nodes.push(self.root);
    }

    fn set_root_children(&mut self, children: &[NodeId]) {
        self.tree.set_children(self.root, children).unwrap();
    }

    fn layout(&mut self) {
        self.tree.compute_layout(self.root, self.available).unwrap();
    }
}

// --- Style generators ---

fn random_dimension(rng: &mut Rng) -> Dimension {
    let r = rng.unit();
    if r < 0.2 {
        auto()
    } else if r < 0.8 {
        length(rng.range(0.0, 500.0))
    } else {
        percent(rng.range(0.0, 1.0))
    }
}

fn random_size_style(rng: &mut Rng) -> Style {
    let w = random_dimension(rng);
    let h = random_dimension(rng);
    Style { size: Size { width: w, height: h }, ..Default::default() }
}

fn auto_style() -> Style {
    Style { flex_grow: 1.0, margin: length(10.0), ..Default::default() }
}

fn chain_style() -> Style {
    Style { flex_direction: FlexDirection::Row, flex_grow: 1.0, margin: length(10.0), ..Default::default() }
}

#[derive(Clone, Copy, PartialEq)]
enum Gen {
    RandomSize,
    Auto,
    Block,
}

fn vertical_margin(top: f32, bottom: f32) -> Rect<LengthPercentageAuto> {
    Rect { left: length(0.0), right: length(0.0), top: length(top), bottom: length(bottom) }
}

fn gen_leaf(b: &mut Builder, gen: Gen) -> Style {
    match gen {
        Gen::RandomSize => random_size_style(&mut b.rng),
        Gen::Auto => auto_style(),
        Gen::Block => {
            let h = b.rng.range(5.0, 50.0);
            let mt = b.rng.range(0.0, 8.0);
            let mb = b.rng.range(0.0, 8.0);
            Style {
                display: Display::Block,
                size: Size { width: auto(), height: length(h) },
                margin: vertical_margin(mt, mb),
                ..Default::default()
            }
        }
    }
}

fn gen_container(b: &mut Builder, gen: Gen) -> Style {
    match gen {
        Gen::RandomSize => random_size_style(&mut b.rng),
        Gen::Auto => auto_style(),
        Gen::Block => {
            let mt = b.rng.range(0.0, 8.0);
            let mb = b.rng.range(0.0, 8.0);
            Style {
                display: Display::Block,
                padding: length(4.0),
                margin: vertical_margin(mt, mb),
                ..Default::default()
            }
        }
    }
}

fn root_style(gen: Gen) -> Style {
    if gen == Gen::Block {
        Style { display: Display::Block, ..Default::default() }
    } else {
        Style::default()
    }
}

// --- Workload builders ---

/// Upstream `build_deep_tree`
fn build_deep_tree(b: &mut Builder, gen: Gen, max_nodes: u32, branching: u32) -> Vec<NodeId> {
    if max_nodes <= branching {
        return (0..max_nodes)
            .map(|_| {
                let s = gen_leaf(b, gen);
                b.leaf(s)
            })
            .collect();
    }
    (0..branching)
        .map(|_| {
            let remaining = (max_nodes - branching) / branching;
            let children = build_deep_tree(b, gen, remaining, branching);
            let s = gen_container(b, gen);
            b.container(s, &children)
        })
        .collect()
}

fn deep_hierarchy(b: &mut Builder, gen: Gen, node_count: u32, branching: u32) {
    b.root_leaf(root_style(gen));
    let children = build_deep_tree(b, gen, node_count, branching);
    b.set_root_children(&children);
}

/// Upstream `build_flat_hierarchy`
fn flat_hierarchy(b: &mut Builder, gen: Gen, target: u32) {
    b.root_leaf(root_style(gen));
    let mut children = Vec::new();
    while b.tree.total_node_count() < target as usize {
        let count = b.rng.one_to_four();
        let mut sub = Vec::with_capacity(count);
        for _ in 0..count {
            let s = gen_leaf(b, gen);
            sub.push(b.leaf(s));
        }
        let s = gen_container(b, gen);
        children.push(b.container(s, &sub));
    }
    b.set_root_children(&children);
}

fn super_deep(b: &mut Builder, depth: u32, nodes_per_level: u32) {
    b.root_leaf(Style::default());
    let mut children: Vec<NodeId> = Vec::new();
    for _ in 0..depth {
        let node = b.container(chain_style(), &children);
        children.clear();
        children.push(node);
        for _ in 1..nodes_per_level {
            children.push(b.leaf(chain_style()));
        }
    }
    b.set_root_children(&children);
}

fn random_track(rng: &mut Rng) -> GridTemplateComponent<String> {
    let s = rng.unit();
    if s < 0.1 {
        auto()
    } else if s < 0.2 {
        min_content()
    } else if s < 0.3 {
        max_content()
    } else if s < 0.5 {
        fr(1.0)
    } else if s < 0.6 {
        minmax(length(0.0), fr(1.0))
    } else if s < 0.8 {
        length(40.0)
    } else {
        percent(0.3)
    }
}

fn random_grid_style(b: &mut Builder, columns: usize, rows: usize) -> Style {
    let cols: Vec<_> = (0..columns).map(|_| random_track(&mut b.rng)).collect();
    let rws: Vec<_> = (0..rows).map(|_| random_track(&mut b.rng)).collect();
    Style {
        display: Display::Grid,
        grid_template_columns: cols,
        grid_template_rows: rws,
        ..Default::default()
    }
}

fn grid_leaf() -> Style {
    Style { size: length(20.0), ..Default::default() }
}

fn grid_flat(b: &mut Builder, cols: usize, rows: usize) {
    b.available = Size { width: AvailableSpace::Definite(12000.0), height: AvailableSpace::Definite(12000.0) };
    let style = random_grid_style(b, cols, rows);
    let children: Vec<NodeId> = (0..cols * rows).map(|_| b.leaf(grid_leaf())).collect();
    b.root = b.container(style, &children);
}

fn build_deep_grid_tree(b: &mut Builder, levels: usize, tracks: usize) -> Vec<NodeId> {
    let child_count = tracks * tracks;
    if levels == 1 {
        return (0..child_count).map(|_| b.leaf(grid_leaf())).collect();
    }
    (0..child_count)
        .map(|_| {
            let sub = build_deep_grid_tree(b, levels - 1, tracks);
            let style = random_grid_style(b, tracks, tracks);
            b.container(style, &sub)
        })
        .collect()
}

fn grid_nested(b: &mut Builder, levels: usize, tracks: usize) {
    b.available = Size { width: AvailableSpace::Definite(12000.0), height: AvailableSpace::Definite(12000.0) };
    let children = build_deep_grid_tree(b, levels, tracks);
    b.root = b.container(Style::default(), &children);
}

fn block_root_available(b: &mut Builder) {
    b.available = Size { width: AvailableSpace::Definite(800.0), height: AvailableSpace::MaxContent };
}

// --- Workload table ---

struct Workload {
    name: &'static str,
    build: fn(&mut Builder),
}

const WORKLOADS: &[Workload] = &[
    Workload { name: "flex-wide-1000", build: |b| flat_hierarchy(b, Gen::RandomSize, 1_000) },
    Workload { name: "flex-wide-10000", build: |b| flat_hierarchy(b, Gen::RandomSize, 10_000) },
    Workload { name: "flex-deep-4000", build: |b| deep_hierarchy(b, Gen::RandomSize, 4_000, 2) },
    Workload { name: "flex-deep-10000", build: |b| deep_hierarchy(b, Gen::RandomSize, 10_000, 2) },
    Workload { name: "flex-deep-auto-4000", build: |b| deep_hierarchy(b, Gen::Auto, 4_000, 2) },
    Workload { name: "flex-deep-auto-10000", build: |b| deep_hierarchy(b, Gen::Auto, 10_000, 2) },
    Workload { name: "flex-chain-100", build: |b| super_deep(b, 100, 3) },
    Workload { name: "flex-chain-1000", build: |b| super_deep(b, 1000, 3) },
    Workload { name: "grid-flat-31x31", build: |b| grid_flat(b, 31, 31) },
    Workload { name: "grid-flat-100x100", build: |b| grid_flat(b, 100, 100) },
    Workload { name: "grid-nested-3x3-d4", build: |b| grid_nested(b, 4, 3) },
    Workload { name: "grid-nested-2x2-d7", build: |b| grid_nested(b, 7, 2) },
    Workload {
        name: "block-wide-10000",
        build: |b| {
            block_root_available(b);
            flat_hierarchy(b, Gen::Block, 10_000)
        },
    },
    Workload {
        name: "block-deep-10000",
        build: |b| {
            block_root_available(b);
            deep_hierarchy(b, Gen::Block, 10_000, 4)
        },
    },
];

// --- Measurement ---

fn median(values: &mut [u64]) -> u64 {
    values.sort_unstable();
    values[values.len() / 2]
}

fn time_full(wl: &Workload) -> u64 {
    let mut samples = Vec::new();
    for run in 0..FULL_WARMUP + FULL_RUNS {
        let mut b = Builder::new();
        (wl.build)(&mut b);
        let t0 = Instant::now();
        b.layout();
        let ns = t0.elapsed().as_nanos() as u64;
        if run >= FULL_WARMUP {
            samples.push(ns);
        }
    }
    median(&mut samples)
}

fn time_relayout(wl: &Workload) -> u64 {
    let mut b = Builder::new();
    (wl.build)(&mut b);
    b.layout();
    let target = b.leaves[b.leaves.len() / 2];
    let mut samples = Vec::new();
    for run in 0..RELAYOUT_WARMUP + RELAYOUT_RUNS {
        b.tree.mark_dirty(target).unwrap();
        let t0 = Instant::now();
        b.layout();
        let ns = t0.elapsed().as_nanos() as u64;
        if run >= RELAYOUT_WARMUP {
            samples.push(ns);
        }
    }
    median(&mut samples)
}

fn measure_alloc(wl: &Workload) -> (u64, u64, u64) {
    let mut b = Builder::new();
    (wl.build)(&mut b);
    TOTAL.store(0, Relaxed);
    COUNT.store(0, Relaxed);
    LIVE.store(0, Relaxed);
    PEAK.store(0, Relaxed);
    COUNTING.store(true, Relaxed);
    b.layout();
    COUNTING.store(false, Relaxed);
    (TOTAL.load(Relaxed), PEAK.load(Relaxed) as u64, COUNT.load(Relaxed))
}

/// Root size and a sum over every node of x + y + width + height (rounded layout)
fn verify(wl: &Workload) {
    let mut b = Builder::new();
    (wl.build)(&mut b);
    b.layout();
    let mut sum = 0f64;
    for &id in &b.nodes {
        let l = b.tree.layout(id).unwrap();
        sum += l.location.x as f64 + l.location.y as f64 + l.size.width as f64 + l.size.height as f64;
    }
    let root = b.tree.layout(b.root).unwrap();
    println!(
        "{} nodes={} root={:.1}x{:.1} checksum={:.1}",
        wl.name,
        b.nodes.len(),
        root.size.width,
        root.size.height,
        sum
    );
}

fn main() {
    let mut filter: Option<String> = None;
    let mut do_verify = false;
    for arg in std::env::args().skip(1) {
        if arg == "--verify" {
            do_verify = true;
        } else {
            filter = Some(arg);
        }
    }

    if !do_verify {
        println!(
            "{:<22} {:>7} {:>12} {:>12} {:>11} {:>11} {:>9}",
            "workload", "nodes", "full (us)", "relayout(us)", "alloc KiB", "peak KiB", "allocs"
        );
    }
    for wl in WORKLOADS {
        if let Some(f) = &filter {
            if !wl.name.contains(f.as_str()) {
                continue;
            }
        }
        if do_verify {
            verify(wl);
            continue;
        }
        let nodes = {
            let mut b = Builder::new();
            (wl.build)(&mut b);
            b.nodes.len()
        };
        let full = time_full(wl);
        let relayout = time_relayout(wl);
        let (total, peak, count) = measure_alloc(wl);
        println!(
            "{:<22} {:>7} {:>12.1} {:>12.1} {:>11.1} {:>11.1} {:>9}",
            wl.name,
            nodes,
            full as f64 / 1000.0,
            relayout as f64 / 1000.0,
            total as f64 / 1024.0,
            peak as f64 / 1024.0,
            count
        );
    }
}
