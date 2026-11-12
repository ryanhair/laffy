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
zig build bench -- flex-deep --profile-relayout=5000   # relayout time with and without rounding,
                                      # then 5 s of relayouts for a sampling profiler to attach to

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
Date: 2026-11-12 (table refreshed the same day after the changes described below). Each program was run twice, alternating; the table shows the mean of the two runs.
The machine was not isolated from background tasks and no frequency pinning was done.

## Results

Times are medians in microseconds (mean of two program runs). Ratio is laffy / taffy, so above 1 means laffy is slower.

| workload | nodes | laffy full | taffy full | ratio | laffy relayout | taffy relayout | ratio | alloc KiB, laffy / taffy | allocation calls, laffy / taffy |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| flex-wide-1000 | 1001 | 669 | 889 | 0.75 | 62 | 80 | 0.77 | 105 / 544 | 2 / 1598 |
| flex-wide-10000 | 10001 | 4154 | 4154 | 1.00 | 441 | 590 | 0.75 | 1045 / 5532 | 2 / 16118 |
| flex-deep-4000 | 3071 | 1266 | 1301 | 0.97 | 6 | 45 | 0.14 | 16 / 1743 | 2 / 9260 |
| flex-deep-10000 | 8191 | 3332 | 3552 | 0.94 | 7 | 110 | 0.06 | 16 / 4553 | 2 / 18502 |
| flex-deep-auto-4000 | 3071 | 3008 | 3091 | 0.97 | 16 | 54 | 0.29 | 16 / 4601 | 2 / 24546 |
| flex-deep-auto-10000 | 8191 | 7705 | 7600 | 1.01 | 18 | 122 | 0.14 | 16 / 12089 | 2 / 49122 |
| flex-chain-100 | 301 | 256 | 253 | 1.01 | 110 | 110 | 1.00 | 112 / 431 | 4 / 1186 |
| flex-chain-1000 | 3001 | 2625 | 2632 | 1.00 | 1144 | 1150 | 1.00 | 1008 / 4354 | 7 / 11986 |
| grid-flat-31x31 | 962 | 322 | 276 | 1.17 | 281 | 253 | 1.11 | 1462 / 363 | 7 / 14 |
| grid-flat-100x100 | 10001 | 3754 | 3493 | 1.07 | 3081 | 2898 | 1.06 | 6144 / 3704 | 7 / 14 |
| grid-nested-3x3-d4 | 7381 | 8478 | 6682 | 1.27 | 48 | 146 | 0.33 | 592 / 13919 | 3279 / 28651 |
| grid-nested-2x2-d7 | 21845 | 29194 | 31477 | 0.93 | 28 | 716 | 0.04 | 3375 / 45922 | 21843 / 180140 |
| block-wide-10000 | 10002 | 1914 | 4043 | 0.47 | 248 | 477 | 0.52 | 1441 / 4975 | 2 / 2870 |
| block-deep-10000 | 9557 | 4536 | 3961 | 1.15 | 3 | 133 | 0.02 | 16 / 6997 | 2 / 5461 |

`--verify` output was byte-identical between the two programs for all 14 workloads (node counts, root sizes and
per-node layout checksums), so the trees and the computed layouts are equivalent.

## Reading the results

- Full layout is within a few percent of taffy on the flexbox workloads (0.94 to 1.01, apart from the noisy
  `flex-wide-1000`) and close on the flat grids (1.07 and 1.17). `grid-nested-3x3-d4` (1.27) and
  `block-deep-10000` (1.15) are slower, and `block-wide-10000` is about twice as fast; the cause of neither
  outlier is known.
- Relayout after dirtying one leaf is much faster than taffy on the deep workloads (0.02 to 0.33) and faster on
  the wide ones (0.52 to 0.77). Rounding used to walk the whole tree after every layout, which was 97 percent of
  the `flex-deep-10000` relayout in a sampling profile. `TaffyTree` now stamps every node whose unrounded layout
  really changed (and its ancestors), and rounding skips a subtree in which nothing changed since it was last
  rounded against the same parent offset. What remains is the layout work itself: `flex-chain-*` and
  `grid-flat-*` relayouts re-run the algorithm of the dirty leaf's ancestors over all their children, as taffy
  does, and are level with it (1.00 to 1.11). `zig build bench -- --profile-relayout=0` prints the relayout
  time with and without rounding.
- Memory: the temporary lists of the algorithms come from a scratch allocator owned by the tree
  (`src/util/scratch.zig`), which hands out memory from a few large chunks and releases it when each algorithm
  returns. A layout pass therefore makes only a handful of allocation calls, apart from grids, which allocate
  their detailed grid info per container the first time they are laid out (and reuse it afterwards). The
  "alloc KiB" column for laffy is mostly the size of those chunks; on the flat grid workloads it is larger than
  taffy's total because chunk sizes grow in steps. The tree keeps up to 1 MiB of scratch chunks between layout
  passes and frees the rest.
- Changes since the first version of this table, which recorded a 1.15 to 1.45 slowdown on full layout and 1.2 to
  1.9 on relayout: functions are no longer force-inlined, the scratch allocator, and the rounding change above.

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
