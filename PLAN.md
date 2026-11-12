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

- **Float parity (checked on Zig 0.17.1, runtime values).** Zig's `@max` and `@min` return the
  non-NaN operand, like Rust's `f32::max` and `f32::min`. taffy's `round` is `floor(value + 0.5)`
  (not round-half-away-from-zero), so laffy's `round` wrapper must be written the same way and
  must not use `@round`.
- **Recursive generics.** Zig cannot infer error sets across recursive generic calls, so every
  layout entry point declares its error set explicitly.
- **Harness parser scope.** Fixture attributes include full grid syntax such as
  `repeat(auto-fill, minmax(...))`, named lines and `calc()`. The parser grows with each algorithm.
- **Upstream churn.** taffy is under active development; re-sync fixtures at milestone boundaries
  rather than continuously.

## Porting conventions

These apply to every file in the port so that independently written pieces fit together.

- **Upstream reference.** Port from a checkout of taffy at the commit in `tests/fixtures/UPSTREAM`.
  Port behaviour exactly, including edge cases and the order of floating-point operations.
- **File layout.** Mirror upstream paths under `src/`, with `.zig` in place of `.rs`. A Rust
  `foo/mod.rs` becomes `foo.zig` next to the `foo/` directory. `src/root.zig` is `lib.rs`.
- **Naming.** Zig style: `PascalCase` types, `camelCase` functions, `snake_case` fields, variables
  and enum variants. Keep upstream names otherwise (`compute_flexbox_layout` becomes
  `computeFlexboxLayout`). Associated constants such as `Size::ZERO` become lower-case declarations
  (`Size(f32).zero`).
- **Generics.** `Size<T>` becomes `Size(T)`. `Option<T>` becomes `?T`.
- **Traits.** Tree traits become duck-typed `anytype` / `comptime Tree: type` parameters; the
  expected methods are documented in `src/tree/traits.zig`. Helper traits such as `MaybeMath` and
  `MaybeResolve` become free functions that dispatch on argument type at comptime.
- **Closures.** `map(|x| ...)` style helpers become explicit code at the call site, or take a
  `comptime` function parameter where that reads better.
- **Calc resolver.** Where upstream takes `calc: impl Fn(*const (), f32) -> f32`, laffy takes
  `calc: anytype` and calls `calc.resolveCalcValue(ptr, basis)`. Layout code passes the tree.
- **Errors and allocation.** Layout can fail only with `error{OutOfMemory}`. Declare that error set
  explicitly on every function in the layout call graph (inferred error sets do not work across
  the recursion). Temporary allocations use the scratch allocator the tree provides.
- **Not ported.** Cargo feature flags (everything is always on), `serde`, `strict_provenance`, and
  the `no_std` polyfills.
- **Tests.** Port upstream `#[cfg(test)]` unit tests as Zig `test` blocks in the same file.
- **Comments.** Carry over upstream doc comments, trimmed where they only describe Rust mechanics.
- **Tooling.** Zig 0.17.1. Run `zig build test` and `zig fmt` before finishing. When unsure of a
  std API, read the std source of the installed toolchain rather than guessing.

### Conventions established by the foundation layer

- **Maybe-math.** `maybeMin`, `maybeMax`, `maybeAdd`, `maybeSub(lhs, rhs)` and
  `maybeClamp(lhs, min, max)` in `src/util/math.zig` accept every upstream operand combination
  (`?f32`, `f32`, `AvailableSpace`, and `Size` of those).
- **Resolve.** `maybeResolve(value, context, calc)` and `resolveOrZero(value, context, calc)` in
  `src/util/resolve.zig`. `NoCalc` is the resolver for trees without `calc()` support.
- **Style accessors.** Upstream accessor `foo()` is `getFoo()` (Zig does not allow a method to
  share a field's name); `is_*` predicates stay `isFoo()`. `Style` implements all of them. The
  full interface lists and reusable defaults are documented at the top of `src/style.zig`.
- **Style ownership.** `Style` is a plain value (`.{}` is the default). Grid track lists and line
  or area names are borrowed slices; the caller keeps them alive.
- **Constants and constructors.** No-argument upstream constructors and constants are lower-case
  declarations (`Dimension.auto`, `Size(f32).zero`); constructors with arguments are functions
  (`Dimension.fromLength(10)`). Rust tuple-struct `.0` fields are named `inner`.
- **Comptime closures.** `map`, `zipMap` and similar take `comptime` functions and cannot capture
  runtime state; write the field-wise code out when a capture is needed.
- **Already ported ahead of schedule.** `src/compute/grid/types/coordinates.zig`.
