// Compile-only check that include/laffy.h is valid C++ with C linkage (`zig build c-test`).
#include "laffy.h"

static_assert(sizeof(LaffyDimension) == 8, "LaffyDimension is {int, float}");

extern "C" LaffyStatus laffy_header_check(LaffyTree *tree, uint64_t node) {
    LaffyTrackSizingFunction track = laffy_track_fr(1.0f);
    LaffyGridTemplateComponent component = laffy_grid_repeat(LAFFY_REPETITION_AUTO_FIT, 0, &track, 1, nullptr, 0);
    LaffyStatus status = laffy_node_set_grid_template_columns(tree, node, &component, 1, nullptr, 0);
    if (status != LAFFY_STATUS_OK) return status;
    return laffy_node_set_size(tree, node, laffy_dim_length(10.0f), laffy_dim_auto());
}
