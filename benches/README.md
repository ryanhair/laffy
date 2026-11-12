# Benchmarks

Two programs build the same 14 workloads with the same styles and the same deterministic
parameters and time them the same way:

- `benches/bench.zig`, run with `zig build bench`: laffy (built in ReleaseFast, linked against libc so
  the allocator is malloc).
- `benches/taffy-compare/`, a separate Cargo crate that is not part of the Zig build: upstream taffy at
  commit `d0345bac609a10b25278ecc0850e862be9504e74` (the commit laffy tracks), built with the release profile
  (`opt-level=3`, thin LTO, one codegen unit) and the system allocator (malloc).

## Running

```sh
zig build bench                       # all workloads
zig build bench -- flex               # only workloads whose name contains "flex"
zig build bench -- --verify           # print root size and a layout checksum per workload

cd benches/taffy-compare
cargo run --release                   # same table, taffy
cargo run --release -- grid           # same filter argument
cargo run --release -- --verify       # same checksums
```

`--verify` output from both sides must be byte-identical (`diff` them). It prints the node count, the
root size and the sum of `x + y + width + height` over every node's rounded layout, which is a strong check
that both sides built an equivalent tree and computed the same layout.

## Methodology

- Workloads mirror the shapes in taffy's own `benches/` (wide tree, deep hierarchy, super-deep chain, random grid,
  nested grid) plus a block case. Randomness is a splitmix64 generator with a fixed seed (12345) implemented
  identically in both programs; nothing depends on the clock. Random style generation follows upstream's
  (`random_dimension`, `random_grid_track`). "nodes" in the table is the actual node count, including the root;
  upstream's deep-tree recursion rounds down, so `deep-4000` really has 3071 nodes.
- Workloads: `flex-wide-N` (2-level hierarchy of 1 to 4 leaves per container, random sizes), `flex-deep-N`
  (binary hierarchy, random sizes), `flex-deep-auto-N` (binary hierarchy, `flex_grow: 1`, margin 10, auto size),
  `flex-chain-D` (D levels with 3 nodes per level, row direction, `flex_grow: 1`, margin 10), `grid-flat-CxR`
  (C by R items of 20x20 in a grid with random tracks: auto, min/max-content, fr, minmax(0, fr), 40px, 30%),
  `grid-nested-TxT-dL` (L levels of T by T grids with random tracks, 20x20 leaves), `block-wide-N` and
  `block-deep-N` (block containers with padding 4 and random vertical margins, leaves with random heights, so
  margin collapsing is exercised; root available width is 800).
- Full layout: for each run a fresh tree is built (not timed), then `computeLayout` on the root is timed. 3
  warm-up runs, then the median of 21 runs. Rounding is on (the default), so the timing includes `roundLayout`.
- Relayout: the tree is laid out once; then, 5 warm-up and 51 measured times, one leaf (the middle one in creation
  order) is marked dirty and `computeLayout` is timed. The median is reported. `markDirty` itself is not timed.
- Allocation: a separate pass builds the tree, resets the counters and lays it out once. It reports total bytes
  requested, peak live bytes above the pre-layout baseline, and the number of allocation calls (growing
  reallocs count). laffy uses a counting wrapper around the C allocator; the Rust program uses a counting
  `#[global_allocator]` that is switched on only for this pass (the flag check stays on the timed path, as one
  relaxed atomic load per allocation).
- Both sides run on one thread, one process at a time, on a quiet machine.

## Machine

Apple M1 Max, 10 cores, 32 GiB, macOS 26.3 (Darwin 25.3.0, arm64). Zig 0.17.1, rustc 1.99.1.
Date: 2026-11-12. Each program was run twice, alternating; the table shows the mean of the two runs.
The machine was not isolated from background tasks and no frequency pinning was done.

## Results

Times are medians in microseconds (mean of two program runs). Ratio is laffy / taffy, so above 1 means laffy is slower.

| workload | nodes | laffy full | taffy full | ratio | laffy relayout | taffy relayout | ratio | alloc KiB, laffy / taffy |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| flex-wide-1000 | 1001 | 504 | 399 | 1.26 | 64 | 48 | 1.34 | 1102 / 544 |
| flex-wide-10000 | 10001 | 5427 | 4240 | 1.28 | 1119 | 584 | 1.92 | 11180 / 5532 |
| flex-deep-4000 | 3071 | 1731 | 1318 | 1.31 | 67 | 46 | 1.44 | 4138 / 1743 |
| flex-deep-10000 | 8191 | 4658 | 3543 | 1.31 | 168 | 113 | 1.49 | 10552 / 4553 |
| flex-deep-auto-4000 | 3071 | 4428 | 3125 | 1.42 | 82 | 55 | 1.48 | 10927 / 4601 |
| flex-deep-auto-10000 | 8191 | 11018 | 7928 | 1.39 | 186 | 125 | 1.48 | 28015 / 12089 |
| flex-chain-100 | 301 | 354 | 257 | 1.38 | 159 | 111 | 1.42 | 825 / 431 |
| flex-chain-1000 | 3001 | 3754 | 2683 | 1.40 | 1666 | 1162 | 1.43 | 8334 / 4354 |
| grid-flat-31x31 | 962 | 391 | 280 | 1.39 | 349 | 257 | 1.36 | 568 / 363 |
| grid-flat-100x100 | 10001 | 4417 | 3666 | 1.20 | 3821 | 2958 | 1.29 | 5736 / 3704 |
| grid-nested-3x3-d4 | 7381 | 10297 | 7167 | 1.44 | 189 | 143 | 1.32 | 26220 / 13919 |
| grid-nested-2x2-d7 | 21845 | 37053 | 32291 | 1.15 | 977 | 708 | 1.38 | 99361 / 45922 |
| block-wide-10000 | 10002 | 2113 | 4350 | 0.49 | 558 | 463 | 1.21 | 5887 / 4975 |
| block-deep-10000 | 9557 | 5016 | 4279 | 1.17 | 223 | 137 | 1.62 | 6100 / 6997 |

`--verify` output was byte-identical between the two programs for all 14 workloads (node counts, root sizes and
per-node layout checksums), so the trees and the computed layouts are equivalent.

## Reading the results

- For full layouts laffy is about 1.15 to 1.45 times slower than taffy, with one outlier in the other direction
  (`block-wide-10000`, about twice as fast; I did not find out why, and it is a single workload, so do not read much
  into it). The gap is steady across flex, grid and block, which points to a uniform per-node cost rather than a
  problem in one algorithm.
- Relayout after dirtying one leaf is slower in relative terms (1.3 to 1.9 times; 1.9 on `flex-wide-10000`, 1.6 on
  `block-deep-10000`). A relayout re-runs the parents of the dirty leaf (the root has about 3,300 children in the wide
  case), re-reads cache entries of every clean child, and then rounds the whole tree again, so it measures cache
  lookup, child iteration and `roundLayout` more than it measures the algorithms. A sampling profile of the
  `flex-wide-10000` relayout (laffy only) shows the time in `computeFlexboxLayout` (about 35%), `roundLayoutInner`
  (about 30%), `cacheGet` (about 10%) and `maybeResolve`; there is no allocator time at all. It is a
  memory-bound walk over large per-node records, not an allocation or missing-inline problem I could point at,
  and nothing in it can be fixed in a few lines without a structural change (for example the layout of `NodeData`).
  That is documented here and not changed. No file under `src/` was modified.
- Memory: laffy requests about 2 times the bytes taffy does for flexbox and grid layouts (the allocation call counts
  are identical on the flex workloads and higher on grid, e.g. 76 calls against 14 on `grid-flat-31x31`).
  Same count, double the bytes, suggests larger element types and Zig's `ArrayList` growth policy
  (`minimum + minimum / 2 + 128 / @sizeOf(T)` on first growth) against `Vec`'s doubling from a small minimum.
  I did not verify this. It does not look like the main source of the time gap, because the sampled relayout has no
  allocator time, but a full layout does allocate, so it may contribute a little there. A scratch arena per layout
  pass (the design in `PLAN.md`) would remove most of the allocator cost.
- Peak live bytes during layout are small compared with the tree itself on all the deep workloads (a few KiB), and
  larger on wide and grid ones; see the raw tables printed by each program.

## Caveats

- Wall-clock medians on a laptop: run-to-run differences of up to about 10% were seen on a single side
  (for example `flex-wide-10000` relayout 562 and 605 us for taffy in two runs, 1088 and 1150 us for laffy), and
  `block-wide-10000` on taffy moved from 3.9 to 4.8 ms between runs. The 1.2 to 1.4 ratios are consistent across
  the workloads and both runs, small differences between workloads (say 1.31 against 1.39) are not.
- The two sides do not use the same allocator code path or the same structures: both call the system malloc, but
  taffy's `Vec`/`SmallVec` and slotmap storage differ from laffy's `ArrayList` and `SlotMap`, and the trees are
  built by different code, so heap layout (and so cache behaviour) is not identical.
- The Rust build uses thin LTO and one codegen unit, the Zig build is a single compilation unit in ReleaseFast.
  Neither side uses CPU-specific flags.
- Counting the allocations costs the Rust side a relaxed atomic load per allocation during the timed passes.
- The full-layout figure includes first-touch of freshly built memory (the tree is built just before each run), unlike
  upstream's own benchmark, which re-dirties and re-lays out one long-lived tree.
