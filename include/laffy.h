/*
 * laffy.h: the C API of laffy, a Zig port of the taffy UI layout library (flexbox, CSS grid,
 * block and float layout).
 *
 * The API wraps laffy's built-in node tree (taffy's `TaffyTree`): create a tree, create nodes,
 * give each node a style through the `laffy_node_set_*` functions, arrange the nodes into a
 * hierarchy, compute the layout of a root node, and read back each node's layout.
 *
 * Conventions
 * -----------
 *
 * Units. Lengths are in abstract layout units ("pixels"); laffy never scales them. Percentages
 * are fractions: 50% is 0.5, not 50. Percentages resolve against the parent's size as in CSS
 * (padding and border percentages resolve against the parent's width on both axes).
 *
 * Edges. Rectangles (margin, padding, border, inset) are given in the order left, right, top,
 * bottom, as in taffy's `Rect`. Sizes are width then height. A gap is (column gap, row gap).
 *
 * NaN. NaN is never a valid style value: passing NaN in a length, percentage, fr value or
 * definite available space is LAFFY_STATUS_INVALID_ARGUMENT. NaN is used only to mean "none" or
 * "unknown": the aspect ratio setter takes NaN to clear the aspect ratio, and a measure
 * function receives NaN for a known dimension that is not known.
 *
 * Node ids. Nodes are identified by uint64_t ids that are unique within a tree. An id stays
 * invalid after its node is removed, even if the storage is reused. LAFFY_NODE_NONE (0) is never
 * a valid id. Every function validates every id it is given: an id that is not (or no longer) in
 * the tree is reported with an error status, never undefined behaviour.
 *
 * Errors. Functions that can fail return a LaffyStatus; results are written through
 * out-parameters, which are left untouched on failure. A failing function has no effect (in
 * particular a failed style setter leaves the style unchanged). Passing NULL where a pointer is
 * required, an array pointer that is NULL with a non-zero count, or an out-of-range enum value
 * is LAFFY_STATUS_INVALID_ARGUMENT. The one exception is the LaffyTree handle itself: it must be
 * NULL or a live tree; a freed or garbage handle is undefined behaviour.
 *
 * Tree shape. laffy keeps the node hierarchy a forest: a node has at most one parent and
 * appears at most once among its parent's children, and a node can never become its own
 * ancestor. Operations that would break this fail (LAFFY_STATUS_CHILD_HAS_PARENT,
 * LAFFY_STATUS_WOULD_CREATE_CYCLE, LAFFY_STATUS_INVALID_ARGUMENT for duplicate children).
 * Detach a node (laffy_node_remove_child*) before attaching it elsewhere; the exception is
 * laffy_node_set_children, which, like taffy, takes the new children from their old parents.
 *
 * Ownership. The tree owns all of its memory. Data passed in arrays and strings (grid tracks,
 * line names, area names) is copied before the setter returns, so the caller may free or reuse
 * it immediately; the copy is freed when the property is set again, when the style is reset,
 * when the node is removed, when the tree is cleared and when the tree is freed. Strings are
 * NUL-terminated and compared bytewise (use UTF-8). The user data pointer of a node is never
 * dereferenced or freed by laffy.
 *
 * Thread safety. A tree is not thread-safe: calls on one tree must not run concurrently. Calls
 * on different trees may run concurrently, provided their allocators are thread-safe (the
 * default allocator is). A measure function must not call back into the tree being laid out.
 *
 * ABI stability. LAFFY_ABI_VERSION is bumped on any incompatible change to a type layout, an
 * enum value or a function signature; compare it with laffy_abi_version() at runtime to detect
 * a mismatched library.
 */
#ifndef LAFFY_H
#define LAFFY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LAFFY_ABI_VERSION 1u

/* The id that is never a valid node; returned by laffy_node_parent for a node without parent. */
#define LAFFY_NODE_NONE ((uint64_t)0)

/* ------------------------------------------------------------------------------------------ */
/* Status codes                                                                                */

typedef enum LaffyStatus {
    LAFFY_STATUS_OK = 0,
    /* An allocation failed. The operation had no effect, except that a failed layout leaves the
     * layouts of the nodes it visited unspecified (compute it again). */
    LAFFY_STATUS_OUT_OF_MEMORY = 1,
    /* A NULL pointer, an out-of-range enum value, a NaN, or a value the property does not accept */
    LAFFY_STATUS_INVALID_ARGUMENT = 2,
    /* The node id is not in the tree (it was removed, or never existed) */
    LAFFY_STATUS_INVALID_INPUT_NODE = 3,
    /* The parent node id is not in the tree */
    LAFFY_STATUS_INVALID_PARENT_NODE = 4,
    /* A child node id is not in the tree */
    LAFFY_STATUS_INVALID_CHILD_NODE = 5,
    /* The parent has no child at the index (or the range is not within its children) */
    LAFFY_STATUS_CHILD_INDEX_OUT_OF_BOUNDS = 6,
    /* laffy_node_remove_child: the node is not a child of the parent */
    LAFFY_STATUS_NOT_A_CHILD = 7,
    /* The node to attach already has a parent; detach it first */
    LAFFY_STATUS_CHILD_HAS_PARENT = 8,
    /* The node to attach is the parent itself or one of its ancestors */
    LAFFY_STATUS_WOULD_CREATE_CYCLE = 9
} LaffyStatus;

/* The version of the C ABI the library was built with (LAFFY_ABI_VERSION) */
uint32_t laffy_abi_version(void);

/* A static, human-readable description of a status ("unknown status" for other values) */
const char *laffy_status_string(LaffyStatus status);

/* ------------------------------------------------------------------------------------------ */
/* Style values                                                                                */

/* The unit of a style value. Each value type below accepts only the units listed with it. */
typedef enum LaffyUnit {
    LAFFY_UNIT_LENGTH = 0,              /* value: the length */
    LAFFY_UNIT_PERCENT = 1,             /* value: a fraction (0.5 is 50%) */
    LAFFY_UNIT_AUTO = 2,                /* value ignored */
    LAFFY_UNIT_MIN_CONTENT = 3,         /* value ignored */
    LAFFY_UNIT_MAX_CONTENT = 4,         /* value ignored */
    LAFFY_UNIT_FIT_CONTENT_LENGTH = 5,  /* fit-content(<length>); value: the length limit */
    LAFFY_UNIT_FIT_CONTENT_PERCENT = 6, /* fit-content(<percent>); value: the fraction limit */
    LAFFY_UNIT_FIT_CONTENT = 7,         /* the fit-content keyword; value ignored */
    LAFFY_UNIT_STRETCH = 8,             /* value ignored */
    LAFFY_UNIT_CONTENT = 9,             /* value ignored */
    LAFFY_UNIT_FR = 10                  /* value: the flex factor */
} LaffyUnit;

/* LENGTH, PERCENT. Used by padding, border and gap. */
typedef struct LaffyLengthPercentage {
    LaffyUnit unit;
    float value;
} LaffyLengthPercentage;

/* LENGTH, PERCENT, AUTO. Used by margin, inset, min size and max size. */
typedef struct LaffyLengthPercentageAuto {
    LaffyUnit unit;
    float value;
} LaffyLengthPercentageAuto;

/* LENGTH, PERCENT, AUTO, MIN_CONTENT, MAX_CONTENT, FIT_CONTENT_LENGTH, FIT_CONTENT_PERCENT,
 * FIT_CONTENT, STRETCH, CONTENT. Used by size and flex basis. */
typedef struct LaffyDimension {
    LaffyUnit unit;
    float value;
} LaffyDimension;

/* The minimum of a grid track: LENGTH, PERCENT, AUTO, MIN_CONTENT, MAX_CONTENT */
typedef struct LaffyMinTrackSizing {
    LaffyUnit unit;
    float value;
} LaffyMinTrackSizing;

/* The maximum of a grid track: LENGTH, PERCENT, AUTO, MIN_CONTENT, MAX_CONTENT,
 * FIT_CONTENT_LENGTH, FIT_CONTENT_PERCENT, FR */
typedef struct LaffyMaxTrackSizing {
    LaffyUnit unit;
    float value;
} LaffyMaxTrackSizing;

/* A grid track: minmax(min, max). A plain `1fr` is minmax(auto, 1fr), a plain `10px` is
 * minmax(10px, 10px), fit-content(x) is minmax(auto, fit-content(x)); see the helpers below. */
typedef struct LaffyTrackSizingFunction {
    LaffyMinTrackSizing min;
    LaffyMaxTrackSizing max;
} LaffyTrackSizingFunction;

static inline LaffyLengthPercentage laffy_lp_length(float v) { LaffyLengthPercentage r; r.unit = LAFFY_UNIT_LENGTH; r.value = v; return r; }
static inline LaffyLengthPercentage laffy_lp_percent(float v) { LaffyLengthPercentage r; r.unit = LAFFY_UNIT_PERCENT; r.value = v; return r; }

static inline LaffyLengthPercentageAuto laffy_lpa_length(float v) { LaffyLengthPercentageAuto r; r.unit = LAFFY_UNIT_LENGTH; r.value = v; return r; }
static inline LaffyLengthPercentageAuto laffy_lpa_percent(float v) { LaffyLengthPercentageAuto r; r.unit = LAFFY_UNIT_PERCENT; r.value = v; return r; }
static inline LaffyLengthPercentageAuto laffy_lpa_auto(void) { LaffyLengthPercentageAuto r; r.unit = LAFFY_UNIT_AUTO; r.value = 0.0f; return r; }

static inline LaffyDimension laffy_dimension(LaffyUnit unit, float v) { LaffyDimension r; r.unit = unit; r.value = v; return r; }
static inline LaffyDimension laffy_dim_length(float v) { return laffy_dimension(LAFFY_UNIT_LENGTH, v); }
static inline LaffyDimension laffy_dim_percent(float v) { return laffy_dimension(LAFFY_UNIT_PERCENT, v); }
static inline LaffyDimension laffy_dim_auto(void) { return laffy_dimension(LAFFY_UNIT_AUTO, 0.0f); }

static inline LaffyTrackSizingFunction laffy_track_minmax(LaffyUnit min_unit, float min_value, LaffyUnit max_unit, float max_value) {
    LaffyTrackSizingFunction r;
    r.min.unit = min_unit;
    r.min.value = min_value;
    r.max.unit = max_unit;
    r.max.value = max_value;
    return r;
}
static inline LaffyTrackSizingFunction laffy_track_length(float v) { return laffy_track_minmax(LAFFY_UNIT_LENGTH, v, LAFFY_UNIT_LENGTH, v); }
static inline LaffyTrackSizingFunction laffy_track_percent(float v) { return laffy_track_minmax(LAFFY_UNIT_PERCENT, v, LAFFY_UNIT_PERCENT, v); }
static inline LaffyTrackSizingFunction laffy_track_fr(float v) { return laffy_track_minmax(LAFFY_UNIT_AUTO, 0.0f, LAFFY_UNIT_FR, v); }
static inline LaffyTrackSizingFunction laffy_track_auto(void) { return laffy_track_minmax(LAFFY_UNIT_AUTO, 0.0f, LAFFY_UNIT_AUTO, 0.0f); }
static inline LaffyTrackSizingFunction laffy_track_min_content(void) { return laffy_track_minmax(LAFFY_UNIT_MIN_CONTENT, 0.0f, LAFFY_UNIT_MIN_CONTENT, 0.0f); }
static inline LaffyTrackSizingFunction laffy_track_max_content(void) { return laffy_track_minmax(LAFFY_UNIT_MAX_CONTENT, 0.0f, LAFFY_UNIT_MAX_CONTENT, 0.0f); }
static inline LaffyTrackSizingFunction laffy_track_fit_content(float limit) { return laffy_track_minmax(LAFFY_UNIT_AUTO, 0.0f, LAFFY_UNIT_FIT_CONTENT_LENGTH, limit); }

/* Keyword enums. Their values match taffy's variants. */

typedef enum LaffyDisplay {
    LAFFY_DISPLAY_BLOCK = 0,
    LAFFY_DISPLAY_FLOW_ROOT = 1,
    LAFFY_DISPLAY_FLEX = 2, /* the default */
    LAFFY_DISPLAY_GRID = 3,
    LAFFY_DISPLAY_NONE = 4
} LaffyDisplay;

typedef enum LaffyPosition {
    LAFFY_POSITION_STATIC = 0, /* the default */
    LAFFY_POSITION_RELATIVE = 1,
    LAFFY_POSITION_ABSOLUTE = 2,
    LAFFY_POSITION_FIXED = 3,
    LAFFY_POSITION_STICKY = 4 /* laid out as static; insets are left to the caller */
} LaffyPosition;

typedef enum LaffyBoxSizing {
    LAFFY_BOX_SIZING_BORDER_BOX = 0, /* the default */
    LAFFY_BOX_SIZING_CONTENT_BOX = 1
} LaffyBoxSizing;

typedef enum LaffyDirection {
    LAFFY_DIRECTION_LTR = 0, /* the default */
    LAFFY_DIRECTION_RTL = 1
} LaffyDirection;

typedef enum LaffyOverflow {
    LAFFY_OVERFLOW_VISIBLE = 0, /* the default */
    LAFFY_OVERFLOW_CLIP = 1,
    LAFFY_OVERFLOW_HIDDEN = 2,
    LAFFY_OVERFLOW_SCROLL = 3
} LaffyOverflow;

typedef enum LaffyFloat {
    LAFFY_FLOAT_LEFT = 0,
    LAFFY_FLOAT_RIGHT = 1,
    LAFFY_FLOAT_NONE = 2 /* the default */
} LaffyFloat;

typedef enum LaffyClear {
    LAFFY_CLEAR_LEFT = 0,
    LAFFY_CLEAR_RIGHT = 1,
    LAFFY_CLEAR_BOTH = 2,
    LAFFY_CLEAR_NONE = 3 /* the default */
} LaffyClear;

/* Legacy `text-align` behaviour of block containers (`<center>`, `<div align=...>`) */
typedef enum LaffyTextAlign {
    LAFFY_TEXT_ALIGN_AUTO = 0, /* the default */
    LAFFY_TEXT_ALIGN_LEGACY_LEFT = 1,
    LAFFY_TEXT_ALIGN_LEGACY_RIGHT = 2,
    LAFFY_TEXT_ALIGN_LEGACY_CENTER = 3
} LaffyTextAlign;

typedef enum LaffyFlexDirection {
    LAFFY_FLEX_DIRECTION_ROW = 0, /* the default */
    LAFFY_FLEX_DIRECTION_COLUMN = 1,
    LAFFY_FLEX_DIRECTION_ROW_REVERSE = 2,
    LAFFY_FLEX_DIRECTION_COLUMN_REVERSE = 3
} LaffyFlexDirection;

typedef enum LaffyFlexWrap {
    LAFFY_FLEX_WRAP_NO_WRAP = 0, /* the default */
    LAFFY_FLEX_WRAP_WRAP = 1,
    LAFFY_FLEX_WRAP_WRAP_REVERSE = 2,
    LAFFY_FLEX_WRAP_BALANCE = 3,
    LAFFY_FLEX_WRAP_BALANCE_REVERSE = 4
} LaffyFlexWrap;

typedef enum LaffyGridAutoFlow {
    LAFFY_GRID_AUTO_FLOW_ROW = 0, /* the default */
    LAFFY_GRID_AUTO_FLOW_COLUMN = 1,
    LAFFY_GRID_AUTO_FLOW_ROW_DENSE = 2,
    LAFFY_GRID_AUTO_FLOW_COLUMN_DENSE = 3
} LaffyGridAutoFlow;

/* align-items, justify-items, align-self, justify-self */
typedef enum LaffyAlignItems {
    LAFFY_ALIGN_ITEMS_NORMAL = 0, /* the default of align-items / justify-items */
    LAFFY_ALIGN_ITEMS_START = 1,
    LAFFY_ALIGN_ITEMS_END = 2,
    LAFFY_ALIGN_ITEMS_FLEX_START = 3,
    LAFFY_ALIGN_ITEMS_FLEX_END = 4,
    LAFFY_ALIGN_ITEMS_SELF_START = 5,
    LAFFY_ALIGN_ITEMS_SELF_END = 6,
    LAFFY_ALIGN_ITEMS_CENTER = 7,
    LAFFY_ALIGN_ITEMS_BASELINE = 8,
    LAFFY_ALIGN_ITEMS_STRETCH = 9,
    /* Only for align-self / justify-self (and their default): use the parent's align-items /
     * justify-items. Invalid for align-items / justify-items. */
    LAFFY_ALIGN_ITEMS_AUTO = 10
} LaffyAlignItems;

/* align-content, justify-content */
typedef enum LaffyAlignContent {
    LAFFY_ALIGN_CONTENT_NORMAL = 0, /* the default */
    LAFFY_ALIGN_CONTENT_START = 1,
    LAFFY_ALIGN_CONTENT_END = 2,
    LAFFY_ALIGN_CONTENT_FLEX_START = 3,
    LAFFY_ALIGN_CONTENT_FLEX_END = 4,
    LAFFY_ALIGN_CONTENT_CENTER = 5,
    LAFFY_ALIGN_CONTENT_STRETCH = 6,
    LAFFY_ALIGN_CONTENT_SPACE_BETWEEN = 7,
    LAFFY_ALIGN_CONTENT_SPACE_EVENLY = 8,
    LAFFY_ALIGN_CONTENT_SPACE_AROUND = 9
} LaffyAlignContent;

/* The overflow-position modifier of an alignment (`safe center`, `unsafe end`) */
typedef enum LaffyAlignmentSafety {
    LAFFY_ALIGNMENT_SAFETY_DEFAULT = 0, /* no modifier */
    LAFFY_ALIGNMENT_SAFETY_UNSAFE = 1,
    LAFFY_ALIGNMENT_SAFETY_SAFE = 2
} LaffyAlignmentSafety;

/* Flags for laffy_node_set_contain (the layout-affecting parts of the CSS `contain` property) */
#define LAFFY_CONTAIN_NONE 0u
#define LAFFY_CONTAIN_LAYOUT 1u
#define LAFFY_CONTAIN_PAINT 2u
#define LAFFY_CONTAIN_CONTENT (LAFFY_CONTAIN_LAYOUT | LAFFY_CONTAIN_PAINT)

/* Grid templates ---------------------------------------------------------------------------- */

/* A set of names for one grid line, e.g. `[header-start main]` */
typedef struct LaffyLineNameSet {
    const char *const *names; /* `count` NUL-terminated strings (may be NULL if count is 0) */
    size_t count;
} LaffyLineNameSet;

typedef enum LaffyGridTemplateComponentKind {
    LAFFY_GRID_TEMPLATE_SINGLE = 0, /* one track */
    LAFFY_GRID_TEMPLATE_REPEAT = 1  /* repeat(...) */
} LaffyGridTemplateComponentKind;

typedef enum LaffyRepetitionKind {
    LAFFY_REPETITION_COUNT = 0,     /* repeat(<repetition_count>, ...); the count must be >= 1 */
    LAFFY_REPETITION_AUTO_FILL = 1, /* repeat(auto-fill, ...) */
    LAFFY_REPETITION_AUTO_FIT = 2   /* repeat(auto-fit, ...) */
} LaffyRepetitionKind;

/* One entry of grid-template-rows / grid-template-columns: a track or a repeat(). */
typedef struct LaffyGridTemplateComponent {
    LaffyGridTemplateComponentKind kind;
    /* SINGLE: the track */
    LaffyTrackSizingFunction track;
    /* REPEAT: the repetition */
    LaffyRepetitionKind repetition_kind;
    uint16_t repetition_count;
    /* REPEAT: the repeated tracks (at least 1, at most 65535) */
    const LaffyTrackSizingFunction *repeat_tracks;
    size_t repeat_track_count;
    /* REPEAT: the line names inside the repetition. Either none (count 0) or exactly
     * repeat_track_count + 1 sets: set i names line i of each repetition, e.g.
     * repeat(2, [a] 10px [b]) has the sets {a}, {b}. */
    const LaffyLineNameSet *repeat_line_names;
    size_t repeat_line_name_count;
} LaffyGridTemplateComponent;

static inline LaffyGridTemplateComponent laffy_grid_track(LaffyTrackSizingFunction track) {
    LaffyGridTemplateComponent r;
    r.kind = LAFFY_GRID_TEMPLATE_SINGLE;
    r.track = track;
    r.repetition_kind = LAFFY_REPETITION_COUNT;
    r.repetition_count = 0;
    r.repeat_tracks = NULL;
    r.repeat_track_count = 0;
    r.repeat_line_names = NULL;
    r.repeat_line_name_count = 0;
    return r;
}

/* repeat(kind/count, tracks...) with optional line names (NULL, 0 for none) */
static inline LaffyGridTemplateComponent laffy_grid_repeat(LaffyRepetitionKind kind, uint16_t count, const LaffyTrackSizingFunction *tracks, size_t track_count,
                                                           const LaffyLineNameSet *line_names, size_t line_name_count) {
    LaffyGridTemplateComponent r = laffy_grid_track(laffy_track_auto());
    r.kind = LAFFY_GRID_TEMPLATE_REPEAT;
    r.repetition_kind = kind;
    r.repetition_count = count;
    r.repeat_tracks = tracks;
    r.repeat_track_count = track_count;
    r.repeat_line_names = line_names;
    r.repeat_line_name_count = line_name_count;
    return r;
}

/* A named area of grid-template-areas, in 1-based grid lines: an area covering the first row
 * and the first two columns has row_start 1, row_end 2, column_start 1, column_end 3.
 * Requires 1 <= start < end on both axes. */
typedef struct LaffyGridTemplateArea {
    const char *name;
    uint16_t row_start;
    uint16_t row_end;
    uint16_t column_start;
    uint16_t column_end;
} LaffyGridTemplateArea;

/* Grid item placement --------------------------------------------------------------------- */

typedef enum LaffyGridPlacementKind {
    LAFFY_GRID_PLACEMENT_AUTO = 0,       /* auto */
    LAFFY_GRID_PLACEMENT_LINE = 1,       /* <line>: 1-based, negative counts from the end; 0 acts as auto */
    LAFFY_GRID_PLACEMENT_SPAN = 2,       /* span <span>; 0 acts as 1 */
    LAFFY_GRID_PLACEMENT_NAMED_LINE = 3, /* <line> <name>; line 0 means just <name> */
    LAFFY_GRID_PLACEMENT_NAMED_SPAN = 4  /* span <span> <name> */
} LaffyGridPlacementKind;

/* One end of grid-row / grid-column. `name` is required for the named kinds and ignored
 * otherwise. */
typedef struct LaffyGridPlacement {
    LaffyGridPlacementKind kind;
    int16_t line;
    uint16_t span;
    const char *name;
} LaffyGridPlacement;

static inline LaffyGridPlacement laffy_grid_placement(LaffyGridPlacementKind kind, int16_t line, uint16_t span, const char *name) {
    LaffyGridPlacement r;
    r.kind = kind;
    r.line = line;
    r.span = span;
    r.name = name;
    return r;
}
static inline LaffyGridPlacement laffy_grid_auto(void) { return laffy_grid_placement(LAFFY_GRID_PLACEMENT_AUTO, 0, 0, NULL); }
static inline LaffyGridPlacement laffy_grid_line(int16_t line) { return laffy_grid_placement(LAFFY_GRID_PLACEMENT_LINE, line, 0, NULL); }
static inline LaffyGridPlacement laffy_grid_span(uint16_t span) { return laffy_grid_placement(LAFFY_GRID_PLACEMENT_SPAN, 0, span, NULL); }
static inline LaffyGridPlacement laffy_grid_named_line(const char *name, int16_t index) { return laffy_grid_placement(LAFFY_GRID_PLACEMENT_NAMED_LINE, index, 0, name); }
static inline LaffyGridPlacement laffy_grid_named_span(const char *name, uint16_t count) { return laffy_grid_placement(LAFFY_GRID_PLACEMENT_NAMED_SPAN, 0, count, name); }

/* ------------------------------------------------------------------------------------------ */
/* Layout types                                                                                */

typedef enum LaffyAvailableSpaceTag {
    LAFFY_AVAILABLE_SPACE_DEFINITE = 0,    /* value: the space (not NaN) */
    LAFFY_AVAILABLE_SPACE_MIN_CONTENT = 1, /* lay out under a min-content constraint; value ignored */
    LAFFY_AVAILABLE_SPACE_MAX_CONTENT = 2  /* lay out under a max-content constraint; value ignored */
} LaffyAvailableSpaceTag;

typedef struct LaffyAvailableSpace {
    LaffyAvailableSpaceTag tag;
    float value;
} LaffyAvailableSpace;

static inline LaffyAvailableSpace laffy_available_definite(float v) { LaffyAvailableSpace r; r.tag = LAFFY_AVAILABLE_SPACE_DEFINITE; r.value = v; return r; }
static inline LaffyAvailableSpace laffy_available_min_content(void) { LaffyAvailableSpace r; r.tag = LAFFY_AVAILABLE_SPACE_MIN_CONTENT; r.value = 0.0f; return r; }
static inline LaffyAvailableSpace laffy_available_max_content(void) { LaffyAvailableSpace r; r.tag = LAFFY_AVAILABLE_SPACE_MAX_CONTENT; r.value = 0.0f; return r; }

typedef struct LaffyPoint {
    float x;
    float y;
} LaffyPoint;

typedef struct LaffySize {
    float width;
    float height;
} LaffySize;

typedef struct LaffyRect {
    float left;
    float right;
    float top;
    float bottom;
} LaffyRect;

/* The computed layout of a node. Positions are relative to the parent's border box (for an
 * absolutely positioned node: to its containing block). */
typedef struct LaffyLayout {
    /* Paint order: nodes with a higher order should be drawn on top */
    uint32_t order;
    /* The top-left corner of the border box */
    LaffyPoint location;
    /* The size of the border box */
    LaffySize size;
    /* The scrollable overflow rectangle (CSS "scrollable overflow"), relative to the node's
     * border box origin; replaces upstream taffy's `content_size` */
    LaffyRect scrollable_overflow;
    /* Whether the scroll origin is at the right / bottom edge (e.g. RTL or reversed flex) */
    bool scrollable_overflow_reversed_x;
    bool scrollable_overflow_reversed_y;
    /* The reachable scroll range in each axis (0 if the content fits) */
    float scroll_width;
    float scroll_height;
    /* Space reserved for scrollbars (overflow: scroll) */
    LaffySize scrollbar_size;
    /* Resolved border, padding and margin */
    LaffyRect border;
    LaffyRect padding;
    LaffyRect margin;
} LaffyLayout;

/* Measures the content of a leaf node (a node without children). Returns the size of the
 * content box. `known_width` / `known_height` are NaN when not known; when known, the result in
 * that axis should normally equal it. `user_data` is the node's user data
 * (laffy_node_set_context). Must not call any laffy function on the tree being laid out. */
typedef LaffySize (*LaffyMeasureFunc)(void *user_data, uint64_t node, float known_width, float known_height, LaffyAvailableSpace available_width,
                                      LaffyAvailableSpace available_height);

/* A custom allocator. `alloc` returns `size` bytes (size is never 0) aligned to `alignment` (a
 * power of two), or NULL on failure. `free` releases a block; it receives the same size and
 * alignment that were passed to `alloc`. Both functions are required. */
typedef struct LaffyAllocator {
    void *user_data;
    void *(*alloc)(void *user_data, size_t size, size_t alignment);
    void (*free)(void *user_data, void *ptr, size_t size, size_t alignment);
} LaffyAllocator;

/* ------------------------------------------------------------------------------------------ */
/* Trees                                                                                       */

typedef struct LaffyTree LaffyTree;

/* Create an empty tree using the C allocator (malloc/free). Rounding is enabled. */
LaffyStatus laffy_tree_new(LaffyTree **out_tree);

/* Create an empty tree that allocates all of its memory with `allocator` (copied; the struct
 * need not outlive the call, but its functions and user data must outlive the tree). */
LaffyStatus laffy_tree_new_with_allocator(const LaffyAllocator *allocator, LaffyTree **out_tree);

/* Free the tree, all of its nodes and all data copied into it. NULL is ignored. */
void laffy_tree_free(LaffyTree *tree);

/* Remove every node. All node ids of the tree become invalid. */
LaffyStatus laffy_tree_clear(LaffyTree *tree);

/* Enable or disable rounding of layout values to whole units (enabled by default). With
 * rounding disabled, laffy_node_get_layout returns the unrounded layout. */
LaffyStatus laffy_tree_enable_rounding(LaffyTree *tree);
LaffyStatus laffy_tree_disable_rounding(LaffyTree *tree);

LaffyStatus laffy_tree_total_node_count(LaffyTree *tree, size_t *out_count);

/* Whether `node` is a valid id of this tree (false for NULL trees) */
bool laffy_tree_contains_node(LaffyTree *tree, uint64_t node);

/* ------------------------------------------------------------------------------------------ */
/* Nodes and children                                                                          */

/* Create a node with the default style, no children and no parent */
LaffyStatus laffy_node_new(LaffyTree *tree, uint64_t *out_node);

/* Create a node with the default style and the given children (which must have no parent and
 * be distinct) */
LaffyStatus laffy_node_new_with_children(LaffyTree *tree, const uint64_t *children, size_t child_count, uint64_t *out_node);

/* Remove a node from the tree and free its data. It is detached from its parent; its children
 * stay in the tree, without parent. */
LaffyStatus laffy_node_remove(LaffyTree *tree, uint64_t node);

/* Append `child` (which must have no parent) to `parent`'s children */
LaffyStatus laffy_node_add_child(LaffyTree *tree, uint64_t parent, uint64_t child);

/* Insert `child` (which must have no parent) at `index` (0..child count) */
LaffyStatus laffy_node_insert_child_at_index(LaffyTree *tree, uint64_t parent, size_t index, uint64_t child);

/* Detach `child` from `parent` (the child stays in the tree) */
LaffyStatus laffy_node_remove_child(LaffyTree *tree, uint64_t parent, uint64_t child);

/* Detach the child at `index`; `out_removed` (may be NULL) receives its id */
LaffyStatus laffy_node_remove_child_at_index(LaffyTree *tree, uint64_t parent, size_t index, uint64_t *out_removed);

/* Detach the children with indices in [start, end) */
LaffyStatus laffy_node_remove_children_range(LaffyTree *tree, uint64_t parent, size_t start, size_t end);

/* Replace the child at `index` by `new_child` (which must have no parent, unless it is already
 * that child, which is a no-op). The old child is detached; `out_old_child` (may be NULL)
 * receives its id. */
LaffyStatus laffy_node_replace_child_at_index(LaffyTree *tree, uint64_t parent, size_t index, uint64_t new_child, uint64_t *out_old_child);

/* Replace all children of `parent`. The previous children are detached. The new children must
 * be distinct and must not be `parent` or one of its ancestors; a new child that has another
 * parent is moved. */
LaffyStatus laffy_node_set_children(LaffyTree *tree, uint64_t parent, const uint64_t *children, size_t child_count);

LaffyStatus laffy_node_child_count(LaffyTree *tree, uint64_t parent, size_t *out_count);

LaffyStatus laffy_node_child_at_index(LaffyTree *tree, uint64_t parent, size_t index, uint64_t *out_child);

/* The parent of `node`, or LAFFY_NODE_NONE */
LaffyStatus laffy_node_parent(LaffyTree *tree, uint64_t node, uint64_t *out_parent);

/* ------------------------------------------------------------------------------------------ */
/* User data and measure functions                                                             */

/* Set the node's user data pointer (passed to its measure function; never dereferenced by
 * laffy). Marks the node dirty. */
LaffyStatus laffy_node_set_context(LaffyTree *tree, uint64_t node, void *user_data);
LaffyStatus laffy_node_get_context(LaffyTree *tree, uint64_t node, void **out_user_data);

/* Set (or clear, with NULL) the node's measure function. It is used only while the node has no
 * children; a leaf without measure function has empty content. Marks the node dirty. */
LaffyStatus laffy_node_set_measure_func(LaffyTree *tree, uint64_t node, LaffyMeasureFunc measure);

/* ------------------------------------------------------------------------------------------ */
/* Layout                                                                                      */

/* Compute the layout of `node` and its descendants within the available space. Any node can
 * be the root of a layout; its location is relative to nothing (normally 0, 0). Only dirty
 * parts of the tree are recomputed. */
LaffyStatus laffy_tree_compute_layout(LaffyTree *tree, uint64_t node, LaffyAvailableSpace available_width, LaffyAvailableSpace available_height);

/* The layout computed by the last laffy_tree_compute_layout covering the node (rounded unless
 * rounding is disabled). Zero before the first layout. */
LaffyStatus laffy_node_get_layout(LaffyTree *tree, uint64_t node, LaffyLayout *out_layout);

/* The layout before rounding */
LaffyStatus laffy_node_get_unrounded_layout(LaffyTree *tree, uint64_t node, LaffyLayout *out_layout);

/* Mark the node and its ancestors as needing layout. Style, children and measure function
 * changes do this automatically; call it when the content measured by a measure function
 * changes. */
LaffyStatus laffy_node_mark_dirty(LaffyTree *tree, uint64_t node);
LaffyStatus laffy_node_is_dirty(LaffyTree *tree, uint64_t node, bool *out_dirty);

/* ------------------------------------------------------------------------------------------ */
/* Style                                                                                       */
/*                                                                                             */
/* Every setter changes one property (group) of the node's style and marks the node dirty.     */
/* Defaults are those of taffy's Style::DEFAULT (display: flex, flex-shrink: 1, etc.).         */

/* Reset every property to its default (and free the node's copied grid data) */
LaffyStatus laffy_node_reset_style(LaffyTree *tree, uint64_t node);

/* Box generation and sizing */
LaffyStatus laffy_node_set_display(LaffyTree *tree, uint64_t node, LaffyDisplay display);
LaffyStatus laffy_node_set_box_sizing(LaffyTree *tree, uint64_t node, LaffyBoxSizing box_sizing);
LaffyStatus laffy_node_set_direction(LaffyTree *tree, uint64_t node, LaffyDirection direction);
/* Whether the node is display: table (affects block layout of its parent; default false) */
LaffyStatus laffy_node_set_item_is_table(LaffyTree *tree, uint64_t node, bool is_table);
/* Whether the node is a replaced element such as an image (default false) */
LaffyStatus laffy_node_set_item_is_replaced(LaffyTree *tree, uint64_t node, bool is_replaced);
/* Whether the node is a compressible replaced element such as a form control (default false) */
LaffyStatus laffy_node_set_item_is_compressible_replaced(LaffyTree *tree, uint64_t node, bool is_compressible_replaced);

/* Overflow and containment */
LaffyStatus laffy_node_set_overflow(LaffyTree *tree, uint64_t node, LaffyOverflow x, LaffyOverflow y);
/* Space reserved for the scrollbar of overflow: scroll nodes (>= 0; default 0) */
LaffyStatus laffy_node_set_scrollbar_width(LaffyTree *tree, uint64_t node, float width);
/* A combination of LAFFY_CONTAIN_* flags */
LaffyStatus laffy_node_set_contain(LaffyTree *tree, uint64_t node, uint32_t flags);

/* Floats */
LaffyStatus laffy_node_set_float(LaffyTree *tree, uint64_t node, LaffyFloat float_value);
LaffyStatus laffy_node_set_clear(LaffyTree *tree, uint64_t node, LaffyClear clear);

/* Positioning */
LaffyStatus laffy_node_set_position(LaffyTree *tree, uint64_t node, LaffyPosition position);
/* Default: auto on every edge */
LaffyStatus laffy_node_set_inset(LaffyTree *tree, uint64_t node, LaffyLengthPercentageAuto left, LaffyLengthPercentageAuto right, LaffyLengthPercentageAuto top,
                                 LaffyLengthPercentageAuto bottom);

/* Size (default auto), min size (default auto), max size (default auto) */
LaffyStatus laffy_node_set_size(LaffyTree *tree, uint64_t node, LaffyDimension width, LaffyDimension height);
LaffyStatus laffy_node_set_min_size(LaffyTree *tree, uint64_t node, LaffyLengthPercentageAuto width, LaffyLengthPercentageAuto height);
LaffyStatus laffy_node_set_max_size(LaffyTree *tree, uint64_t node, LaffyLengthPercentageAuto width, LaffyLengthPercentageAuto height);
/* Preferred width / height ratio (> 0 and finite), or NaN for none (the default) */
LaffyStatus laffy_node_set_aspect_ratio(LaffyTree *tree, uint64_t node, float ratio);

/* Spacing (all default 0) */
LaffyStatus laffy_node_set_margin(LaffyTree *tree, uint64_t node, LaffyLengthPercentageAuto left, LaffyLengthPercentageAuto right, LaffyLengthPercentageAuto top,
                                  LaffyLengthPercentageAuto bottom);
LaffyStatus laffy_node_set_padding(LaffyTree *tree, uint64_t node, LaffyLengthPercentage left, LaffyLengthPercentage right, LaffyLengthPercentage top,
                                   LaffyLengthPercentage bottom);
LaffyStatus laffy_node_set_border(LaffyTree *tree, uint64_t node, LaffyLengthPercentage left, LaffyLengthPercentage right, LaffyLengthPercentage top,
                                  LaffyLengthPercentage bottom);
/* Gap between flex items / grid tracks: width is the column gap, height the row gap */
LaffyStatus laffy_node_set_gap(LaffyTree *tree, uint64_t node, LaffyLengthPercentage width, LaffyLengthPercentage height);

/* Alignment. LAFFY_ALIGN_ITEMS_AUTO is accepted only by the *_self setters. */
LaffyStatus laffy_node_set_align_items(LaffyTree *tree, uint64_t node, LaffyAlignItems keyword, LaffyAlignmentSafety safety);
LaffyStatus laffy_node_set_justify_items(LaffyTree *tree, uint64_t node, LaffyAlignItems keyword, LaffyAlignmentSafety safety);
LaffyStatus laffy_node_set_align_self(LaffyTree *tree, uint64_t node, LaffyAlignItems keyword, LaffyAlignmentSafety safety);
LaffyStatus laffy_node_set_justify_self(LaffyTree *tree, uint64_t node, LaffyAlignItems keyword, LaffyAlignmentSafety safety);
LaffyStatus laffy_node_set_align_content(LaffyTree *tree, uint64_t node, LaffyAlignContent keyword, LaffyAlignmentSafety safety);
LaffyStatus laffy_node_set_justify_content(LaffyTree *tree, uint64_t node, LaffyAlignContent keyword, LaffyAlignmentSafety safety);

/* Block containers */
LaffyStatus laffy_node_set_text_align(LaffyTree *tree, uint64_t node, LaffyTextAlign text_align);

/* Flexbox containers */
LaffyStatus laffy_node_set_flex_direction(LaffyTree *tree, uint64_t node, LaffyFlexDirection direction);
LaffyStatus laffy_node_set_flex_wrap(LaffyTree *tree, uint64_t node, LaffyFlexWrap wrap);
/* The minimum number of lines of a multi-line (balanced) container; >= 1, default 1 */
LaffyStatus laffy_node_set_flex_line_count(LaffyTree *tree, uint64_t node, uint16_t count);

/* Flexbox items */
LaffyStatus laffy_node_set_flex_basis(LaffyTree *tree, uint64_t node, LaffyDimension basis);
/* >= 0; default 0 */
LaffyStatus laffy_node_set_flex_grow(LaffyTree *tree, uint64_t node, float grow);
/* >= 0; default 1 */
LaffyStatus laffy_node_set_flex_shrink(LaffyTree *tree, uint64_t node, float shrink);

/* Grid containers. All arrays and strings are copied.
 *
 * grid-template-rows / grid-template-columns: the components and the line names between them.
 * `line_names` holds one set per line, in order (line 1 before the first component, then one
 * after each component); pass NULL, 0 for no names. Pass no components to clear the template. */
LaffyStatus laffy_node_set_grid_template_rows(LaffyTree *tree, uint64_t node, const LaffyGridTemplateComponent *components, size_t component_count,
                                              const LaffyLineNameSet *line_names, size_t line_name_count);
LaffyStatus laffy_node_set_grid_template_columns(LaffyTree *tree, uint64_t node, const LaffyGridTemplateComponent *components, size_t component_count,
                                                 const LaffyLineNameSet *line_names, size_t line_name_count);
/* grid-auto-rows / grid-auto-columns (default: none, which acts as auto) */
LaffyStatus laffy_node_set_grid_auto_rows(LaffyTree *tree, uint64_t node, const LaffyTrackSizingFunction *tracks, size_t track_count);
LaffyStatus laffy_node_set_grid_auto_columns(LaffyTree *tree, uint64_t node, const LaffyTrackSizingFunction *tracks, size_t track_count);
LaffyStatus laffy_node_set_grid_auto_flow(LaffyTree *tree, uint64_t node, LaffyGridAutoFlow flow);
/* grid-template-areas: the named areas plus the size of the area template in tracks (which may
 * be larger than the areas because of `.` cells). No areas and a 0 x 0 template means `none`
 * (the default). */
LaffyStatus laffy_node_set_grid_template_areas(LaffyTree *tree, uint64_t node, const LaffyGridTemplateArea *areas, size_t area_count, uint16_t row_count,
                                               uint16_t column_count);

/* Grid items: grid-row / grid-column as start / end placements (default auto / auto) */
LaffyStatus laffy_node_set_grid_row(LaffyTree *tree, uint64_t node, LaffyGridPlacement start, LaffyGridPlacement end);
LaffyStatus laffy_node_set_grid_column(LaffyTree *tree, uint64_t node, LaffyGridPlacement start, LaffyGridPlacement end);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* LAFFY_H */
