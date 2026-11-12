/*
 * End-to-end test of the laffy C API (C99). Run with `zig build c-test`.
 *
 * Every tree is created with a counting allocator (laffy_tree_new_with_allocator); after each
 * tree is freed the test asserts that every block allocated by laffy was freed, with matching
 * sizes, so leaks fail the test.
 */
#include "laffy.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

#define CHECK(cond)                                                                                                                                  \
    do {                                                                                                                                             \
        if (!(cond)) {                                                                                                                               \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond);                                                                 \
            failures++;                                                                                                                              \
        }                                                                                                                                            \
    } while (0)

#define CHECK_STATUS(expr, expected)                                                                                                                 \
    do {                                                                                                                                             \
        LaffyStatus status_ = (expr);                                                                                                                \
        if (status_ != (expected)) {                                                                                                                 \
            fprintf(stderr, "%s:%d: %s returned %d (%s), expected %s\n", __FILE__, __LINE__, #expr, (int)status_, laffy_status_string(status_),   \
                    #expected);                                                                                                                      \
            failures++;                                                                                                                              \
        }                                                                                                                                            \
    } while (0)

#define OK(expr) CHECK_STATUS(expr, LAFFY_STATUS_OK)

#define CHECK_FLOAT(actual, expected)                                                                                                                \
    do {                                                                                                                                             \
        float actual_ = (actual);                                                                                                                    \
        float expected_ = (expected);                                                                                                                \
        if (actual_ != expected_) {                                                                                                                  \
            fprintf(stderr, "%s:%d: %s is %g, expected %g\n", __FILE__, __LINE__, #actual, (double)actual_, (double)expected_);                     \
            failures++;                                                                                                                              \
        }                                                                                                                                            \
    } while (0)

/* --- Counting allocator ------------------------------------------------------------------- */

typedef struct Counter {
    size_t live_blocks;
    size_t live_bytes;
    size_t total_blocks;
} Counter;

/* Over-allocates so that any power-of-two alignment can be honoured with plain malloc (C99 has
 * no aligned_alloc). The original pointer is stored just before the aligned block. */
static void *counting_alloc(void *user_data, size_t size, size_t alignment) {
    Counter *counter = (Counter *)user_data;
    size_t header = sizeof(void *);
    unsigned char *raw;
    uintptr_t aligned;
    if (alignment < sizeof(void *)) alignment = sizeof(void *);
    raw = (unsigned char *)malloc(size + alignment + header);
    if (raw == NULL) return NULL;
    aligned = ((uintptr_t)(raw + header) + (alignment - 1)) & ~(uintptr_t)(alignment - 1);
    ((void **)aligned)[-1] = raw;
    counter->live_blocks++;
    counter->live_bytes += size;
    counter->total_blocks++;
    return (void *)aligned;
}

static void counting_free(void *user_data, void *ptr, size_t size, size_t alignment) {
    Counter *counter = (Counter *)user_data;
    (void)alignment;
    CHECK(ptr != NULL);
    CHECK(counter->live_blocks > 0);
    CHECK(counter->live_bytes >= size);
    counter->live_blocks--;
    counter->live_bytes -= size;
    free(((void **)ptr)[-1]);
}

static LaffyTree *new_tree(Counter *counter) {
    LaffyAllocator allocator;
    LaffyTree *tree = NULL;
    memset(counter, 0, sizeof *counter);
    allocator.user_data = counter;
    allocator.alloc = counting_alloc;
    allocator.free = counting_free;
    OK(laffy_tree_new_with_allocator(&allocator, &tree));
    CHECK(tree != NULL);
    return tree;
}

static void free_tree(LaffyTree *tree, Counter *counter) {
    laffy_tree_free(tree);
    CHECK(counter->total_blocks > 0);
    if (counter->live_blocks != 0 || counter->live_bytes != 0) {
        fprintf(stderr, "leak: %lu blocks (%lu bytes) still allocated\n", (unsigned long)counter->live_blocks, (unsigned long)counter->live_bytes);
        failures++;
    }
}

static LaffyLayout layout_of(LaffyTree *tree, uint64_t node) {
    LaffyLayout layout;
    memset(&layout, 0, sizeof layout);
    OK(laffy_node_get_layout(tree, node, &layout));
    return layout;
}

#define CHECK_BOX(tree, node, ex, ey, ew, eh)                                                                                                            \
    do {                                                                                                                                             \
        LaffyLayout l_ = layout_of((tree), (node));                                                                                                  \
        CHECK_FLOAT(l_.location.x, (ex));                                                                                                             \
        CHECK_FLOAT(l_.location.y, (ey));                                                                                                             \
        CHECK_FLOAT(l_.size.width, (ew));                                                                                                             \
        CHECK_FLOAT(l_.size.height, (eh));                                                                                                            \
    } while (0)

/* --- Flexbox --------------------------------------------------------------------------------- */

static void test_flexbox(void) {
    Counter counter;
    LaffyTree *tree = new_tree(&counter);
    uint64_t a, b, c, root, children[3];
    uint64_t d, e, root2, children2[2];
    bool dirty = false;

    /* Row with grow: 300 wide, 10px column gap; A (50, grow 1), B (50, grow 2), C (20, fixed) */
    OK(laffy_node_new(tree, &a));
    OK(laffy_node_new(tree, &b));
    OK(laffy_node_new(tree, &c));
    OK(laffy_node_set_size(tree, a, laffy_dim_length(50), laffy_dim_auto()));
    OK(laffy_node_set_flex_grow(tree, a, 1));
    OK(laffy_node_set_size(tree, b, laffy_dim_length(50), laffy_dim_auto()));
    OK(laffy_node_set_flex_grow(tree, b, 2));
    OK(laffy_node_set_size(tree, c, laffy_dim_length(20), laffy_dim_auto()));
    children[0] = a;
    children[1] = b;
    children[2] = c;
    OK(laffy_node_new_with_children(tree, children, 3, &root));
    OK(laffy_node_set_display(tree, root, LAFFY_DISPLAY_FLEX));
    OK(laffy_node_set_flex_direction(tree, root, LAFFY_FLEX_DIRECTION_ROW));
    OK(laffy_node_set_size(tree, root, laffy_dim_length(300), laffy_dim_length(100)));
    OK(laffy_node_set_gap(tree, root, laffy_lp_length(10), laffy_lp_length(0)));

    OK(laffy_tree_compute_layout(tree, root, laffy_available_max_content(), laffy_available_max_content()));
    /* Free space 300 - 2*10 - 120 = 160, shared 1:2. Rounded edges: 0..103.33, 113.33..270, 280..300 */
    CHECK_BOX(tree, root, 0, 0, 300, 100);
    CHECK_BOX(tree, a, 0, 0, 103, 100);
    CHECK_BOX(tree, b, 113, 0, 157, 100);
    CHECK_BOX(tree, c, 280, 0, 20, 100);
    {
        LaffyLayout unrounded;
        OK(laffy_node_get_unrounded_layout(tree, a, &unrounded));
        CHECK(fabsf(unrounded.size.width - 310.0f / 3.0f) < 1e-3f);
    }

    /* Relayout after a style change: 400 wide, free space 260 */
    OK(laffy_node_is_dirty(tree, root, &dirty));
    CHECK(!dirty);
    OK(laffy_node_set_size(tree, root, laffy_dim_length(400), laffy_dim_length(100)));
    OK(laffy_node_is_dirty(tree, root, &dirty));
    CHECK(dirty);
    OK(laffy_tree_compute_layout(tree, root, laffy_available_max_content(), laffy_available_max_content()));
    CHECK_BOX(tree, a, 0, 0, 137, 100);
    CHECK_BOX(tree, b, 147, 0, 223, 100);
    CHECK_BOX(tree, c, 380, 0, 20, 100);

    /* Row with shrink: 200 wide, 10px gap; D (150, shrink 1), E (150, shrink 3).
     * Overflow 110 is shared by scaled shrink factors 150:450: D 122.5, E 67.5 */
    OK(laffy_node_new(tree, &d));
    OK(laffy_node_new(tree, &e));
    OK(laffy_node_set_size(tree, d, laffy_dim_length(150), laffy_dim_length(40)));
    OK(laffy_node_set_size(tree, e, laffy_dim_length(150), laffy_dim_length(40)));
    OK(laffy_node_set_flex_shrink(tree, e, 3));
    children2[0] = d;
    children2[1] = e;
    OK(laffy_node_new(tree, &root2));
    OK(laffy_node_set_children(tree, root2, children2, 2));
    OK(laffy_node_set_size(tree, root2, laffy_dim_length(200), laffy_dim_auto()));
    OK(laffy_node_set_gap(tree, root2, laffy_lp_length(10), laffy_lp_length(0)));
    OK(laffy_node_set_padding(tree, root2, laffy_lp_length(0), laffy_lp_length(0), laffy_lp_length(5), laffy_lp_length(5)));
    OK(laffy_tree_compute_layout(tree, root2, laffy_available_definite(1000), laffy_available_definite(1000)));
    CHECK_BOX(tree, root2, 0, 0, 200, 50);
    CHECK_BOX(tree, d, 0, 5, 123, 40);
    CHECK_BOX(tree, e, 133, 5, 67, 40);
    {
        LaffyLayout l = layout_of(tree, root2);
        CHECK_FLOAT(l.padding.top, 5);
        CHECK_FLOAT(l.padding.bottom, 5);
        CHECK_FLOAT(l.padding.left, 0);
    }

    free_tree(tree, &counter);
}

/* --- Grid ------------------------------------------------------------------------------------ */

static void test_grid(void) {
    Counter counter;
    LaffyTree *tree = new_tree(&counter);
    uint64_t item1, item2, item3, root, children[3], child;
    size_t count = 0;

    /* grid-template-columns: [left] 100px repeat(2, [mid] 1fr) [right]; column gap 10
     * grid-template-rows: 50px 1fr; size 400 x 200 */
    {
        /* Strings in a mutable buffer that is clobbered after the call: the tree keeps copies */
        char names_buffer[3][8];
        const char *left_names[1];
        const char *mid_names[1];
        const char *right_names[1];
        LaffyLineNameSet template_names[3];
        LaffyLineNameSet repeat_names[2];
        LaffyTrackSizingFunction repeat_tracks[1];
        LaffyGridTemplateComponent columns[2];
        LaffyGridTemplateComponent rows[2];

        strcpy(names_buffer[0], "left");
        strcpy(names_buffer[1], "mid");
        strcpy(names_buffer[2], "right");
        left_names[0] = names_buffer[0];
        mid_names[0] = names_buffer[1];
        right_names[0] = names_buffer[2];

        template_names[0].names = left_names; /* line 1 */
        template_names[0].count = 1;
        template_names[1].names = NULL; /* after 100px */
        template_names[1].count = 0;
        template_names[2].names = right_names; /* after the repeat */
        template_names[2].count = 1;
        repeat_names[0].names = mid_names; /* [mid] 1fr [] */
        repeat_names[0].count = 1;
        repeat_names[1].names = NULL;
        repeat_names[1].count = 0;
        repeat_tracks[0] = laffy_track_fr(1);
        columns[0] = laffy_grid_track(laffy_track_length(100));
        columns[1] = laffy_grid_repeat(LAFFY_REPETITION_COUNT, 2, repeat_tracks, 1, repeat_names, 2);
        rows[0] = laffy_grid_track(laffy_track_length(50));
        rows[1] = laffy_grid_track(laffy_track_fr(1));

        OK(laffy_node_new(tree, &root));
        OK(laffy_node_set_display(tree, root, LAFFY_DISPLAY_GRID));
        OK(laffy_node_set_size(tree, root, laffy_dim_length(400), laffy_dim_length(200)));
        OK(laffy_node_set_gap(tree, root, laffy_lp_length(10), laffy_lp_length(0)));
        OK(laffy_node_set_grid_template_columns(tree, root, columns, 2, template_names, 3));
        OK(laffy_node_set_grid_template_rows(tree, root, rows, 2, NULL, 0));

        /* item1: grid-column: mid 2 / right (the third column); grid-row: 1 / span 2 */
        OK(laffy_node_new(tree, &item1));
        OK(laffy_node_set_grid_column(tree, item1, laffy_grid_named_line(names_buffer[1], 2), laffy_grid_named_line(names_buffer[2], 0)));
        OK(laffy_node_set_grid_row(tree, item1, laffy_grid_line(1), laffy_grid_span(2)));
        /* item2: grid-column: left / span 2; grid-row: 2 */
        OK(laffy_node_new(tree, &item2));
        OK(laffy_node_set_grid_column(tree, item2, laffy_grid_named_line(names_buffer[0], 0), laffy_grid_span(2)));
        OK(laffy_node_set_grid_row(tree, item2, laffy_grid_line(2), laffy_grid_auto()));
        /* item3: auto-placed into the first free cell (row 1, column 1) */
        OK(laffy_node_new(tree, &item3));

        memset(names_buffer, 'x', sizeof names_buffer);
    }

    children[0] = item1;
    children[1] = item2;
    children[2] = item3;
    OK(laffy_node_set_children(tree, root, children, 3));
    OK(laffy_node_child_count(tree, root, &count));
    CHECK(count == 3);
    OK(laffy_node_child_at_index(tree, root, 2, &child));
    CHECK(child == item3);

    OK(laffy_tree_compute_layout(tree, root, laffy_available_definite(800), laffy_available_definite(600)));
    /* Columns: 0..100, 110..250, 260..400 (1fr = (400 - 100 - 20) / 2 = 140); rows 0..50, 50..200 */
    CHECK_BOX(tree, root, 0, 0, 400, 200);
    CHECK_BOX(tree, item1, 260, 0, 140, 200);
    CHECK_BOX(tree, item2, 0, 50, 250, 150);
    CHECK_BOX(tree, item3, 0, 0, 100, 50);

    /* Replacing the template frees the old copy; repeat(auto-fill, 90px) in 400px with 10px gaps = 4 columns */
    {
        LaffyTrackSizingFunction track = laffy_track_length(90);
        LaffyGridTemplateComponent columns[1];
        columns[0] = laffy_grid_repeat(LAFFY_REPETITION_AUTO_FILL, 0, &track, 1, NULL, 0);
        OK(laffy_node_set_grid_template_columns(tree, root, columns, 1, NULL, 0));
        OK(laffy_node_set_grid_column(tree, item1, laffy_grid_line(-2), laffy_grid_auto()));
        OK(laffy_node_set_grid_column(tree, item2, laffy_grid_line(1), laffy_grid_span(2)));
    }
    OK(laffy_tree_compute_layout(tree, root, laffy_available_definite(800), laffy_available_definite(600)));
    /* Columns: 0..90, 100..190, 200..290, 300..390. item1 is in the last column (line -2 to -1) */
    CHECK_BOX(tree, item1, 300, 0, 90, 200);
    CHECK_BOX(tree, item2, 0, 50, 190, 150);
    CHECK_BOX(tree, item3, 0, 0, 90, 50);

    free_tree(tree, &counter);
}

/* --- Block ----------------------------------------------------------------------------------- */

static void test_block(void) {
    Counter counter;
    LaffyTree *tree = new_tree(&counter);
    uint64_t first, second, root;

    /* A 200px-wide block container. first: height 50, margin-bottom 20; second: height 30,
     * margin-top 10 (collapses with the 20 above), margin-left 15 */
    OK(laffy_node_new(tree, &first));
    OK(laffy_node_set_display(tree, first, LAFFY_DISPLAY_BLOCK));
    OK(laffy_node_set_size(tree, first, laffy_dim_auto(), laffy_dim_length(50)));
    OK(laffy_node_set_margin(tree, first, laffy_lpa_length(0), laffy_lpa_length(0), laffy_lpa_length(0), laffy_lpa_length(20)));
    OK(laffy_node_new(tree, &second));
    OK(laffy_node_set_display(tree, second, LAFFY_DISPLAY_BLOCK));
    OK(laffy_node_set_size(tree, second, laffy_dim_auto(), laffy_dim_length(30)));
    OK(laffy_node_set_margin(tree, second, laffy_lpa_length(15), laffy_lpa_length(0), laffy_lpa_length(10), laffy_lpa_length(0)));
    OK(laffy_node_new(tree, &root));
    OK(laffy_node_set_display(tree, root, LAFFY_DISPLAY_BLOCK));
    OK(laffy_node_set_size(tree, root, laffy_dim_length(200), laffy_dim_auto()));
    OK(laffy_node_add_child(tree, root, first));
    OK(laffy_node_insert_child_at_index(tree, root, 1, second));

    OK(laffy_tree_compute_layout(tree, root, laffy_available_max_content(), laffy_available_max_content()));
    CHECK_BOX(tree, root, 0, 0, 200, 100);
    CHECK_BOX(tree, first, 0, 0, 200, 50);
    CHECK_BOX(tree, second, 15, 70, 185, 30);
    {
        LaffyLayout l = layout_of(tree, second);
        CHECK_FLOAT(l.margin.left, 15);
        CHECK_FLOAT(l.margin.top, 10);
        CHECK_FLOAT(l.margin.right, 0);
    }

    free_tree(tree, &counter);
}

/* --- Measure functions ----------------------------------------------------------------------- */

typedef struct TextContent {
    float min_content_width; /* the longest word */
    float max_content_width; /* the whole text on one line */
    float line_height;
    int calls;
    uint64_t node;
} TextContent;

/* A text-like leaf: wraps to two lines when narrower than its max-content width */
static LaffySize measure_text(void *user_data, uint64_t node, float known_width, float known_height, LaffyAvailableSpace available_width,
                              LaffyAvailableSpace available_height) {
    TextContent *text = (TextContent *)user_data;
    LaffySize size;
    float width;
    (void)available_height;
    text->calls++;
    CHECK(node == text->node);
    if (!isnan(known_width)) {
        width = known_width;
    } else if (available_width.tag == LAFFY_AVAILABLE_SPACE_MIN_CONTENT) {
        width = text->min_content_width;
    } else if (available_width.tag == LAFFY_AVAILABLE_SPACE_MAX_CONTENT) {
        width = text->max_content_width;
    } else {
        width = available_width.value;
        if (width > text->max_content_width) width = text->max_content_width;
        if (width < text->min_content_width) width = text->min_content_width;
    }
    size.width = width;
    size.height = !isnan(known_height) ? known_height : (width < text->max_content_width ? 2 * text->line_height : text->line_height);
    return size;
}

static void test_measure(void) {
    Counter counter;
    LaffyTree *tree = new_tree(&counter);
    uint64_t leaf, root;
    TextContent text;
    void *user_data = NULL;

    text.min_content_width = 40;
    text.max_content_width = 80;
    text.line_height = 30;
    text.calls = 0;

    OK(laffy_node_new(tree, &leaf));
    text.node = leaf;
    OK(laffy_node_set_context(tree, leaf, &text));
    OK(laffy_node_set_measure_func(tree, leaf, measure_text));
    OK(laffy_node_get_context(tree, leaf, &user_data));
    CHECK(user_data == &text);

    /* As a root under max-content: one line */
    OK(laffy_tree_compute_layout(tree, leaf, laffy_available_max_content(), laffy_available_max_content()));
    CHECK_BOX(tree, leaf, 0, 0, 80, 30);
    CHECK(text.calls > 0);

    /* In a 50px-wide flex row: the item shrinks from 80 to 50 (its min-content width is 40) and
     * wraps to two lines; the container takes the item's height */
    OK(laffy_node_new_with_children(tree, &leaf, 1, &root));
    OK(laffy_node_set_size(tree, root, laffy_dim_length(50), laffy_dim_auto()));
    OK(laffy_tree_compute_layout(tree, root, laffy_available_max_content(), laffy_available_max_content()));
    CHECK_BOX(tree, root, 0, 0, 50, 60);
    CHECK_BOX(tree, leaf, 0, 0, 50, 60);

    /* Content change: mark dirty and relayout */
    text.max_content_width = 45;
    OK(laffy_node_mark_dirty(tree, leaf));
    OK(laffy_tree_compute_layout(tree, root, laffy_available_max_content(), laffy_available_max_content()));
    CHECK_BOX(tree, leaf, 0, 0, 45, 30);

    free_tree(tree, &counter);
}

/* --- Errors and teardown --------------------------------------------------------------------- */

static void test_errors(void) {
    Counter counter;
    LaffyTree *tree = new_tree(&counter);
    uint64_t root, child, removed, out = 12345;
    LaffyLayout layout;
    LaffyLengthPercentage auto_padding;
    size_t total = 0;

    OK(laffy_node_new(tree, &child));
    OK(laffy_node_new_with_children(tree, &child, 1, &root));
    OK(laffy_node_new(tree, &removed));
    OK(laffy_node_remove(tree, removed));
    CHECK(!laffy_tree_contains_node(tree, removed));
    CHECK(laffy_tree_contains_node(tree, root));

    /* A removed node id */
    CHECK_STATUS(laffy_node_get_layout(tree, removed, &layout), LAFFY_STATUS_INVALID_INPUT_NODE);
    CHECK_STATUS(laffy_node_set_size(tree, removed, laffy_dim_length(1), laffy_dim_length(1)), LAFFY_STATUS_INVALID_INPUT_NODE);
    CHECK_STATUS(laffy_node_remove(tree, removed), LAFFY_STATUS_INVALID_INPUT_NODE);
    CHECK_STATUS(laffy_tree_compute_layout(tree, removed, laffy_available_max_content(), laffy_available_max_content()), LAFFY_STATUS_INVALID_INPUT_NODE);
    CHECK_STATUS(laffy_node_add_child(tree, root, removed), LAFFY_STATUS_INVALID_CHILD_NODE);
    CHECK_STATUS(laffy_node_child_count(tree, removed, &total), LAFFY_STATUS_INVALID_PARENT_NODE);
    CHECK_STATUS(laffy_node_get_layout(tree, LAFFY_NODE_NONE, &layout), LAFFY_STATUS_INVALID_INPUT_NODE);

    /* Out-of-bounds child indices (out-parameters are left untouched) */
    CHECK_STATUS(laffy_node_child_at_index(tree, root, 1, &out), LAFFY_STATUS_CHILD_INDEX_OUT_OF_BOUNDS);
    CHECK(out == 12345);
    CHECK_STATUS(laffy_node_insert_child_at_index(tree, root, 5, removed), LAFFY_STATUS_CHILD_INDEX_OUT_OF_BOUNDS);
    CHECK_STATUS(laffy_node_remove_child_at_index(tree, root, 1, NULL), LAFFY_STATUS_CHILD_INDEX_OUT_OF_BOUNDS);

    /* Tree-shape and argument errors */
    CHECK_STATUS(laffy_node_add_child(tree, child, root), LAFFY_STATUS_WOULD_CREATE_CYCLE);
    CHECK_STATUS(laffy_node_add_child(tree, root, child), LAFFY_STATUS_CHILD_HAS_PARENT);
    CHECK_STATUS(laffy_node_set_display(tree, root, (LaffyDisplay)42), LAFFY_STATUS_INVALID_ARGUMENT);
    CHECK_STATUS(laffy_node_set_size(tree, root, laffy_dim_length(NAN), laffy_dim_auto()), LAFFY_STATUS_INVALID_ARGUMENT);
    auto_padding.unit = LAFFY_UNIT_AUTO; /* padding cannot be auto */
    auto_padding.value = 0;
    CHECK_STATUS(laffy_node_set_padding(tree, root, laffy_lp_length(0), laffy_lp_length(0), laffy_lp_length(0), auto_padding), LAFFY_STATUS_INVALID_ARGUMENT);
    CHECK_STATUS(laffy_node_new(NULL, &out), LAFFY_STATUS_INVALID_ARGUMENT);
    CHECK_STATUS(laffy_node_new(tree, NULL), LAFFY_STATUS_INVALID_ARGUMENT);
    CHECK(strcmp(laffy_status_string(LAFFY_STATUS_CHILD_INDEX_OUT_OF_BOUNDS), "child index out of bounds") == 0);

    /* The tree is still usable after errors */
    OK(laffy_tree_total_node_count(tree, &total));
    CHECK(total == 2);
    OK(laffy_tree_disable_rounding(tree));
    OK(laffy_tree_compute_layout(tree, root, laffy_available_definite(10), laffy_available_definite(10)));
    OK(laffy_tree_enable_rounding(tree));
    OK(laffy_tree_clear(tree));
    OK(laffy_tree_total_node_count(tree, &total));
    CHECK(total == 0);

    free_tree(tree, &counter);
    laffy_tree_free(NULL);
}

static void test_default_allocator(void) {
    LaffyTree *tree = NULL;
    uint64_t node;
    OK(laffy_tree_new(&tree));
    OK(laffy_node_new(tree, &node));
    OK(laffy_node_set_size(tree, node, laffy_dim_length(12), laffy_dim_percent(0.5f)));
    OK(laffy_tree_compute_layout(tree, node, laffy_available_definite(100), laffy_available_definite(100)));
    CHECK_BOX(tree, node, 0, 0, 12, 50);
    laffy_tree_free(tree);
}

int main(void) {
    CHECK(laffy_abi_version() == LAFFY_ABI_VERSION);
    test_flexbox();
    test_grid();
    test_block();
    test_measure();
    test_errors();
    test_default_allocator();
    if (failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("laffy C API: all checks passed\n");
    return 0;
}
