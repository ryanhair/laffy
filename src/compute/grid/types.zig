//! Structs and enums that are used within the grid module
pub const cell_occupancy = @import("types/cell_occupancy.zig");
pub const coordinates = @import("types/coordinates.zig");
pub const grid_item = @import("types/grid_item.zig");
pub const grid_track = @import("types/grid_track.zig");
pub const grid_track_counts = @import("types/grid_track_counts.zig");
pub const named = @import("types/named.zig");

pub const CellOccupancyMatrix = cell_occupancy.CellOccupancyMatrix;
pub const CellOccupancyState = cell_occupancy.CellOccupancyState;
pub const GridLine = coordinates.GridLine;
pub const OriginZeroLine = coordinates.OriginZeroLine;
pub const max_grid_tracks = coordinates.max_grid_tracks;
pub const max_oz_line = coordinates.max_oz_line;
pub const min_oz_line = coordinates.min_oz_line;
pub const GridItem = grid_item.GridItem;
pub const TrackSizeEstimate = grid_item.TrackSizeEstimate;
pub const GridTrack = grid_track.GridTrack;
pub const GridTrackKind = grid_track.GridTrackKind;
pub const TrackCounts = grid_track_counts.TrackCounts;
pub const Range = grid_track_counts.Range;
pub const GridAreasMap = named.GridAreasMap;
pub const NamedLineResolver = named.NamedLineResolver;
pub const GridLineNames = named.GridLineNames;
pub const GridLineNamesIter = named.GridLineNamesIter;

test {
    _ = cell_occupancy;
    _ = coordinates;
    _ = grid_item;
    _ = grid_track;
    _ = grid_track_counts;
    _ = named;
}
