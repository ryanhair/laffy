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
zig build bench -- block-deep --profile-full=5000      # 5 s of full layouts of one built tree

benches/compare.sh                    # both libraries, one process per workload, as a Markdown table

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
Date: 2026-11-12. The table is the output of `benches/compare.sh`: each workload runs in its own process,
three times per library, alternating, and the best run is shown.
The machine was not isolated from background tasks and no frequency pinning was done.

## Results

Times are medians in microseconds (the best of three program runs). Ratio is laffy / taffy, so above 1 means
laffy is slower.

| workload | nodes | laffy full | taffy full | ratio | laffy relayout | taffy relayout | ratio | alloc KiB, laffy / taffy | allocation calls, laffy / taffy |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| flex-wide-1000 | 1001 | 358 | 384 | 0.93 | 37 | 46 | 0.80 | 105 / 544 | 2 / 1598 |
| flex-wide-10000 | 10001 | 3827 | 4134 | 0.93 | 421 | 588 | 0.72 | 1045 / 5532 | 2 / 16118 |
| flex-deep-4000 | 3071 | 1182 | 1303 | 0.91 | 6 | 45 | 0.13 | 16 / 1743 | 2 / 9260 |
| flex-deep-10000 | 8191 | 3116 | 3284 | 0.95 | 6 | 112 | 0.06 | 16 / 4553 | 2 / 18502 |
| flex-deep-auto-4000 | 3071 | 2763 | 3078 | 0.90 | 14 | 54 | 0.27 | 16 / 4601 | 2 / 24546 |
| flex-deep-auto-10000 | 8191 | 7108 | 7565 | 0.94 | 16 | 121 | 0.13 | 16 / 12089 | 2 / 49122 |
| flex-chain-100 | 301 | 239 | 253 | 0.94 | 102 | 110 | 0.93 | 112 / 431 | 4 / 1186 |
| flex-chain-1000 | 3001 | 2427 | 2634 | 0.92 | 1062 | 1146 | 0.93 | 1008 / 4354 | 7 / 11986 |
| grid-flat-31x31 | 962 | 284 | 276 | 1.03 | 246 | 252 | 0.98 | 1453 / 363 | 3 / 14 |
| grid-flat-100x100 | 10001 | 3500 | 3468 | 1.01 | 2716 | 2892 | 0.94 | 6064 / 3704 | 3 / 14 |
| grid-nested-3x3-d4 | 7381 | 6483 | 6674 | 0.97 | 45 | 140 | 0.32 | 48 / 13919 | 3 / 28651 |
| grid-nested-2x2-d7 | 21845 | 24459 | 25906 | 0.94 | 27 | 692 | 0.04 | 48 / 45922 | 3 / 180140 |
| block-wide-10000 | 10002 | 1514 | 1484 | 1.02 | 235 | 454 | 0.52 | 1441 / 4975 | 2 / 2870 |
| block-deep-10000 | 9557 | 1733 | 1510 | 1.15 | 2 | 127 | 0.02 | 16 / 6997 | 2 / 5461 |

`--verify` output was byte-identical between the two programs for all 14 workloads (node counts, root sizes and
per-node layout checksums), so the trees and the computed layouts are equivalent.

## Reading the results

- The table comes from `benches/compare.sh`, which runs every workload in its own process (best of three runs).
  A workload that runs after others in the same process is slower on both sides, by different amounts:
  `block-deep-10000` takes 1.5 ms alone and 3.9 ms at the end of the full suite on taffy, and 1.8 ms against
  4.6 ms on laffy. Earlier versions of this table were measured in one process and showed outliers
  (`block-wide-10000` at half of taffy's time, `grid-nested-3x3-d4` at 1.27 times) that were artefacts of that.
  The cause of the in-process slowdown was not investigated.
- Full layout is 0.90 to 1.04 times taffy's on thirteen of the fourteen workloads. `block-deep-10000` is 1.15
  times slower. A sampling profile (`zig build bench -- block-deep --profile-full=5000`) shows half of the time
  inside the block algorithm itself with no single hot spot; the cause is not known.
- Relayout after dirtying one leaf is much faster than taffy on the deep workloads (0.02 to 0.32) and faster on
  the wide ones (0.52 to 0.78). Rounding used to walk the whole tree after every layout, which was 97 percent of
  the `flex-deep-10000` relayout in a sampling profile. `TaffyTree` now stamps every node whose unrounded layout
  really changed (and its ancestors), and rounding skips a subtree in which nothing changed since it was last
  rounded against the same parent offset. What remains is the layout work itself: `flex-chain-*` and
  `grid-flat-*` relayouts re-run the algorithm of the dirty leaf's ancestors over all their children, as taffy
  does, and are level with it (0.92 to 0.98). `zig build bench -- --profile-relayout=0` prints the relayout
  time with and without rounding.
- Node size matters: padding every node of the tree by 512 bytes made full layout 1 to 25 percent slower. A
  `TaffyTree` node is 1,184 bytes (`Style` 512, `Cache` 344, two `Layout`s 184). The "full" column lays out a
  freshly built tree, and is also sensitive to how the tree's memory happens to be laid out: on
  `grid-flat-100x100` it moved by 7 percent in either direction with node sizes of 1,184, 1,216 and 1,280 bytes
  while repeated layouts of one built tree (`--profile-full`) moved by 2 percent.
- Memory: the temporary lists of the algorithms come from a scratch allocator owned by the tree
  (`src/util/scratch.zig`), which hands out memory from a few large chunks and releases it when each algorithm
  returns. A layout pass therefore makes only a handful of allocation calls. (Detailed grid info is off by
  default; with `enableDetailedGridInfo` every grid container allocates its info the first time it is laid out
  and reuses it afterwards.) The
  "alloc KiB" column for laffy is mostly the size of those chunks; on the flat grid workloads it is larger than
  taffy's total because chunk sizes grow in steps. The tree keeps up to 1 MiB of scratch chunks between layout
  passes and frees the rest.

## Caveats

- Wall-clock medians on a laptop: run-to-run differences of a few percent are normal even between isolated
  runs, so ratios within about 0.05 of each other should be read as equal.
- The two sides do not use the same allocator code path or the same structures: both call the system malloc, but
  taffy's `Vec`/`SmallVec` and slotmap storage differ from laffy's `ArrayList` and `SlotMap`, and the trees are
  built by different code, so heap layout (and so cache behaviour) is not identical.
- The Rust build uses thin LTO and one codegen unit, the Zig build is a single compilation unit in ReleaseFast.
  Neither side uses CPU-specific flags.
- Counting the allocations costs the Rust side a relaxed atomic load per allocation during the timed passes.
- The full-layout figure includes first-touch of freshly built memory (the tree is built just before each run), unlike
  upstream's own benchmark, which re-dirties and re-lays out one long-lived tree.
