# laffy plan

laffy is a Zig port of [taffy](https://github.com/DioxusLabs/taffy). This file records the
decisions behind the port and the milestone roadmap.

## Upstream

- Tracks taffy 0.15.0, commit `d0345bac609a10b25278ecc0850e862be9504e74` (2026-11-11).
- The pin lives in `tests/fixtures/UPSTREAM`; `scripts/sync-fixtures.sh <ref>` moves it.
- Upstream size: about 30.6k lines of Rust. Flexbox 3.6k, grid about 9k, block 2k, float 0.9k,
  out-of-flow positioning 1k, style types about 6k, tree and cache about 3.5k.

## Decisions

1. **Faithful port first.** Mirror taffy's file layout and function names (in Zig casing) so that
   upstream changes can be applied file by file. Idiomatic cleanup comes after conformance.
2. **Full scope for v1.** Flexbox, grid, block and float, including out-of-flow positioning,
   `calc()`, content size and detailed grid info.
3. **Two public layers,** as upstream: a low-level generic tree API (bring your own tree) and a
   built-in tree equivalent to `TaffyTree`. A C ABI is optional and comes last.
4. **Zig 0.17.1,** pinned in `mise.toml` and `build.zig.zon`.

## Design mapping

| taffy (Rust) | laffy (Zig) |
| --- | --- |
| Tree traits (`LayoutPartialTree`, `LayoutFlexboxContainer`, ...) | Duck-typed `comptime Tree: type` parameters |
| `Vec` allocations during layout | Explicit allocator, scratch arena per layout pass |
| Infallible layout | `error{OutOfMemory}!void`, with explicit error sets because layout recurses through generic functions |
| `CompactLength` tagged pointer | `packed struct(u64)` holding tag, `f32` and calc pointer |
| `slotmap` in `TaffyTree` | Generational-index arena; `NodeId` stays `u64` |
| Cargo feature flags | Not ported initially; build options can be added later |
| `serde`, `strict_provenance` | Not ported |
| `parse` feature (cssparser) | Own CSS value parser, required by the fixture harness |

## Conformance

- `tests/fixtures/xml` holds 6,688 fixtures generated upstream from Chrome, copied verbatim. Each
  one gives input styles and the expected position and size of every node.
- Each source fixture appears in four variants: border-box or content-box, crossed with LTR or RTL.
- Every milestone is gated on the pass count of its fixture groups.
- Upstream also has 26 hand-written Rust test files (about 5.9k lines) covering caching, relayout,
  rounding and measure functions. These are ported by hand in milestone 5.

## Milestones

### 0. Scaffold (done)

- `build.zig`, `build.zig.zon`, pinned Zig, root module.
- Vendored fixtures and `scripts/sync-fixtures.sh`.
- MIT license with taffy attribution.

### 1. Core and test harness

- Geometry, style types, `CompactLength`, resolve and math helpers.
- `Layout`, `LayoutInput`, `LayoutOutput`, cache, tree interface.
- Leaf layout, rounding, built-in tree.
- Harness: minimal XML reader, CSS value parser, port of the test measure function (Ahem text,
  fixed and aspect-ratio nodes), runner that reports pass counts per group.
- Gate: `leaf` 60/60.

### 2. Flexbox

- Flexbox algorithm, out-of-flow positioning, alignment, scrollable overflow.
- Gate: `flex` 2,760/2,760.

### 3. Block and float

- Gate: `block` 1,124, `float` 192, `blockflex` 52.

### 4. Grid

- Placement, explicit and implicit grid, named lines and areas, track sizing, alignment, detailed
  grid info.
- Gate: `grid` 2,368, `blockgrid` 56, `gridflex` 44, `contain` 32.

### 5. Hand-written tests

- Port the 26 upstream test files, including `calc()` coverage.

### 6. Polish

- Benchmarks against taffy, documentation, CI, optional C ABI.

## Risks to check early

- **Float parity (checked on Zig 0.17.1, runtime values).** taffy wraps min, max and round in
  `util/sys.rs`, using Rust's `f32::max`, `f32::min` and `f32::round`. Zig's `@max` and `@min`
  return the non-NaN operand like Rust, and `@round` rounds ties away from zero like Rust, so the
  builtins can back laffy's wrappers directly. Comptime evaluation was not checked.
- **Recursive generics.** Zig cannot infer error sets across recursive generic calls, so every
  layout entry point declares its error set explicitly.
- **Harness parser scope.** Fixture attributes include full grid syntax such as
  `repeat(auto-fill, minmax(...))`, named lines and `calc()`. The parser grows with each algorithm.
- **Upstream churn.** taffy is under active development; re-sync fixtures at milestone boundaries
  rather than continuously.
