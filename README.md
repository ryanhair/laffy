# laffy

A Zig port of [taffy](https://github.com/DioxusLabs/taffy), the UI layout library implementing
flexbox, CSS grid, block and float layout.

laffy tracks taffy 0.15.0 and is a faithful port: it passes all 6,688 of taffy's Chrome-generated
layout fixtures and the hand-written integration tests that can be expressed in Zig.

## Usage

Requires Zig 0.17.1. Add laffy as a dependency and import the `laffy` module.

```zig
const std = @import("std");
const laffy = @import("laffy");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var tree = try laffy.TaffyTree(void).init(gpa.allocator());
    defer tree.deinit();

    const sidebar = try tree.newLeaf(.{
        .size = .{ .width = .{ .length = 80 }, .height = .auto },
    });
    const content = try tree.newLeaf(.{ .flex_grow = 1 });
    const root = try tree.newWithChildren(.{
        .display = .flex,
        .size = .{ .width = .{ .length = 300 }, .height = .{ .length = 100 } },
        .gap = .{ .width = .{ .length = 10 }, .height = .zero },
    }, &.{ sidebar, content });

    try tree.computeLayout(root, .{ .width = .max_content, .height = .max_content });

    const layout = tree.layout(content);
    // content: 210x100 at (90, 0)
    std.debug.print("content: {d}x{d} at ({d}, {d})\n", .{
        layout.size.width, layout.size.height, layout.location.x, layout.location.y,
    });
}
```

This is `examples/basic.zig`; run it with `zig build example`.

There are two API layers, as in taffy:

- **`TaffyTree`**, a built-in node tree that stores styles, caches and layouts for you.
- **The low-level API**, for laying out your own tree type. Implement the methods documented in
  `src/tree/traits.zig` and call `computeFlexboxLayout`, `computeGridLayout`, `computeBlockLayout`
  and friends directly.

Leaf nodes such as text are sized by a measure function passed to `computeLayoutWithMeasure`.

A C API over `TaffyTree` is in `include/laffy.h`; see [docs/c-api.md](docs/c-api.md).

## Differences from taffy

- Names follow Zig conventions (`compute_layout` is `computeLayout`).
- Layout reads styles as plain `Style` fields. There are no style traits, so a custom tree
  provides a `Style` per node rather than its own style type.
- Trees take an allocator. Layout can fail only with `error.OutOfMemory`.
- `Style` borrows its grid track lists and line names as slices; keep them alive while in use.
- Lengths are tagged unions (`.{ .length = 10 }`, `.{ .percent = 0.5 }`, `.auto`), 8 bytes each.
  A `calc()` value holds a `u32` handle that the tree's `resolveCalcValue` interprets, not a
  pointer. 32-bit targets are supported.
- `TaffyTree` resolves `calc()` values to zero, as upstream's does. Custom trees can resolve them.
- Not ported: Cargo feature flags (everything is always on), `serde` support, and CSS string
  parsing of style values.

## Development

```sh
zig build test          # unit tests
zig build hand-written  # ports of taffy's hand-written integration tests
zig build fixtures      # all conformance fixtures, as a test
zig build conformance -- grid --filter auto_fill --verbose   # run and diff selected fixtures
zig build c-test        # C API end-to-end test
zig build bench         # benchmarks (see benches/README.md for a comparison with taffy)
```

Conformance fixtures are vendored unmodified in `tests/fixtures/xml`. The pinned upstream commit
is recorded in `tests/fixtures/UPSTREAM`; `scripts/sync-fixtures.sh <ref>` moves the pin. See
[PLAN.md](PLAN.md) for the porting conventions and project history.

## License

MIT. laffy is derived from taffy; see [LICENSE](LICENSE).
