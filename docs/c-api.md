# C API

laffy has a C ABI over its built-in node tree (taffy's `TaffyTree`), so that C, C++ and any
language with a C FFI can use it. The header is [`include/laffy.h`](../include/laffy.h); it is the
reference for every type and function. The implementation is `src/c_api.zig`.

## Building and linking

```sh
zig build                      # zig-out/lib/liblaffy.a and zig-out/include/laffy.h
zig build -Dlinkage=dynamic    # the shared library instead (liblaffy.so / .dylib, laffy.dll)
zig build -Doptimize=ReleaseFast
zig build c-test               # builds the library and runs tests/c/test_c_api.c against it
```

Cross-compile with `-Dtarget=...` as usual. The library links libc and allocates with `malloc`
unless you pass your own allocator.

Link the static library into a C or C++ program:

```sh
cc -std=c99 main.c -Izig-out/include zig-out/lib/liblaffy.a -lm -o main
```

or, after `zig build -Dlinkage=dynamic`, the shared library with `-Lzig-out/lib -llaffy` (the
macOS install name is `@rpath/liblaffy.dylib`). The header compiles as C99 and as C++11 (it has `extern "C"` guards).

From a Zig build you can also depend on this package and link its `laffy` library artifact
(`dep.artifact("laffy")`), which adds the header to the include path.

## Minimal example

```c
#include <stdio.h>
#include "laffy.h"

int main(void) {
    LaffyTree *tree;
    uint64_t a, b, root, children[2];
    LaffyLayout layout;

    if (laffy_tree_new(&tree) != LAFFY_STATUS_OK) return 1;

    laffy_node_new(tree, &a);
    laffy_node_set_flex_grow(tree, a, 1);
    laffy_node_new(tree, &b);
    laffy_node_set_size(tree, b, laffy_dim_length(50), laffy_dim_auto());

    children[0] = a;
    children[1] = b;
    laffy_node_new_with_children(tree, children, 2, &root);
    laffy_node_set_size(tree, root, laffy_dim_length(200), laffy_dim_length(100));
    laffy_node_set_gap(tree, root, laffy_lp_length(10), laffy_lp_length(0));

    laffy_tree_compute_layout(tree, root, laffy_available_max_content(), laffy_available_max_content());

    laffy_node_get_layout(tree, a, &layout);
    printf("a: %g x %g at (%g, %g)\n", layout.size.width, layout.size.height, layout.location.x, layout.location.y);
    /* a: 140 x 100 at (0, 0) */

    laffy_tree_free(tree);
    return 0;
}
```

Leaf nodes whose size depends on their content (text, images) get a measure function and a user
data pointer:

```c
static LaffySize measure(void *user_data, uint64_t node, float known_width, float known_height,
                         LaffyAvailableSpace available_width, LaffyAvailableSpace available_height) {
    /* known_* are NaN when unknown; return the content-box size */
}

laffy_node_set_context(tree, leaf, my_text);
laffy_node_set_measure_func(tree, leaf, measure);
/* when my_text changes: */
laffy_node_mark_dirty(tree, leaf);
```

Grid templates are arrays of components, with `laffy_grid_track` and `laffy_grid_repeat` helpers;
see `test_grid` in `tests/c/test_c_api.c` for `[left] 100px repeat(2, [mid] 1fr) [right]` with named
and spanning items.

## Conventions

- **Values.** Lengths are in layout units. Percentages are fractions (50% is `0.5`). Style values
  are `{unit, value}` structs (`LaffyDimension`, `LaffyLengthPercentage`, ...); each setter accepts
  only the units its CSS property allows. Rectangles are passed as left, right, top, bottom.
- **NaN** is never a valid style value. It means "none" for `laffy_node_set_aspect_ratio` and
  "unknown" for the known dimensions passed to a measure function.
- **Node ids** are `uint64_t`. `LAFFY_NODE_NONE` (0) is never valid; it is what
  `laffy_node_parent` reports for a node without parent.

## Errors

Every function that can fail returns a `LaffyStatus` and writes its results through
out-parameters, which are untouched on failure. A failed call has no effect (a failed style setter
leaves the style unchanged); the exception is a layout that runs out of memory, after which the
layout must be computed again.

- Every node id is validated. A removed, made-up or foreign id gives
  `LAFFY_STATUS_INVALID_INPUT_NODE`, `..._INVALID_PARENT_NODE` or `..._INVALID_CHILD_NODE`
  depending on the argument; it never crashes. Ids are generational, so the id of a removed node
  stays invalid after its storage is reused.
- Bad indices give `LAFFY_STATUS_CHILD_INDEX_OUT_OF_BOUNDS`; `laffy_node_remove_child` with a node
  that is not a child gives `LAFFY_STATUS_NOT_A_CHILD`.
- The hierarchy stays a forest: attaching a node that already has a parent gives
  `LAFFY_STATUS_CHILD_HAS_PARENT` (detach it first; `laffy_node_set_children` is the exception
  and moves children from their old parent, as in taffy), and making a node its own ancestor
  gives `LAFFY_STATUS_WOULD_CREATE_CYCLE`.
- NULL pointers, out-of-range enum values, NaN and values a property does not accept give
  `LAFFY_STATUS_INVALID_ARGUMENT`. The tree handle must be NULL or a live tree.
- Allocation failure gives `LAFFY_STATUS_OUT_OF_MEMORY`.
- `laffy_status_string` describes a status.

## Ownership

- The tree owns all of its memory; `laffy_tree_free` releases everything, including nodes that
  were never attached.
- Arrays and strings passed to setters (grid tracks, line names, area names, named grid lines) are
  copied before the call returns. The copy belongs to the node and is freed when the same property
  is set again, when the style is reset, when the node is removed, when the tree is cleared and
  when the tree is freed.
- `laffy_node_remove` removes one node. Its children stay in the tree without parent; remove them
  too if they are no longer needed (or free the whole tree).
- User data pointers are never dereferenced or freed by laffy.
- `laffy_tree_new_with_allocator` routes every allocation through your `alloc` / `free`
  functions; `free` gets the size and alignment of the allocation. The C test uses this to check
  that a tree frees every block it allocated.

## Thread safety

A tree must not be used from two threads at once. Different trees can be used concurrently if
their allocators are thread-safe (`malloc` is). A measure function must not call back into the
tree that is being laid out.

## Coverage of `Style`

Every field of laffy's `Style` has a setter. `grid_template_rows` / `grid_template_row_names`
(and the column pair) are set together, since they are one CSS property. `calc()` values are not
exposed, because the built-in tree resolves every `calc()` to zero. There are no style getters
yet.

## ABI stability

`LAFFY_ABI_VERSION` (and `laffy_abi_version()` at runtime) is bumped on any incompatible change to
a type layout, an enum value or a function signature. Enum values are fixed numbers and new values
are only appended.
