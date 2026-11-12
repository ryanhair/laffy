//! Style types for Block layout
//!

/// Used by block layout to implement the legacy behaviour of `<center>` and `<div align="left | right | center">`
pub const TextAlign = enum(u8) {
    /// No special legacy text align behaviour.
    auto,
    /// Corresponds to `-webkit-left` or `-moz-left` in browsers
    legacy_left,
    /// Corresponds to `-webkit-right` or `-moz-right` in browsers
    legacy_right,
    /// Corresponds to `-webkit-center` or `-moz-center` in browsers
    legacy_center,

    /// The default value
    pub const default: TextAlign = .auto;
};
