//! Turns the style attributes of a fixture XML element into a `laffy.Style`.
//!
//! This ports the part of upstream taffy's test harness (`tests/xml.rs`, `build_style`,
//! `construct_tree`) that maps element attributes to style fields, together with the CSS value
//! parsing it relies on (taffy's `parse` feature: `src/util/parse.rs` and every `impl FromCss` in
//! `src/style/*.rs`). Upstream builds those parsers on the `cssparser` crate; here a small
//! hand-written tokenizer and recursive descent parser replace it. Case sensitivity, accepted
//! grammar and rejected inputs follow upstream:
//!
//!   - keyword enums, alignment keywords, `contain`, `minmax`/`repeat` function names: ASCII
//!     case-insensitive;
//!   - the sizing keywords (`auto`, `min-content`, ...), the `px` and `fr` units, `fit-content`,
//!     `span`, `auto-fit`/`auto-fill` and the `grid-auto-flow` keywords: case-sensitive.
//!
//! # Ownership
//!
//! `Style` borrows its grid track lists and line names as slices, and `calc()` values are
//! pointers to heap nodes. Everything these parsers allocate comes from the allocator the caller
//! passes in, and the returned values borrow from it. Pass an arena and keep it alive for as long
//! as the style (and any tree built from it) is used. Strings that the XML element owns (the text
//! content of a `Node`) are borrowed from the element instead.
//!
//! # Differences from upstream
//!
//!   - Upstream silently ignores attributes that the harness does not look at, because it reads
//!     attributes by name. Here an unrecognised attribute is an `error.UnknownAttribute`; every
//!     attribute that occurs in the vendored fixtures is recognised.
//!   - Upstream's `parse` feature has no `calc()` support at all (and `TaffyTree`'s
//!     `resolve_calc_value` just returns 0.0). `calc()` is an extension here: see `CalcNode`,
//!     `parseCalc` and `resolveCalc`.
//!   - `Node.text`: upstream's `input.text()` distinguishes `<text/>`-less elements (`None`) from
//!     whitespace-only text (`Some("")`), which `xml.Element` cannot. A leaf gets text when its
//!     trimmed text is non-empty or its tag is `text`; in the vendored fixtures this is exactly
//!     the set of elements upstream gives a text context.

const std = @import("std");
const Allocator = std.mem.Allocator;
const laffy = @import("laffy");
const xml = @import("xml.zig");

const Style = laffy.Style;
const Dimension = laffy.Dimension;
const LengthPercentage = laffy.LengthPercentage;
const LengthPercentageAuto = laffy.LengthPercentageAuto;
const AvailableSpace = laffy.AvailableSpace;
const MinTrackSizingFunction = laffy.MinTrackSizingFunction;
const MaxTrackSizingFunction = laffy.MaxTrackSizingFunction;
const TrackSizingFunction = laffy.TrackSizingFunction;
const GridTemplateComponent = laffy.GridTemplateComponent;
const GridPlacement = laffy.GridPlacement;
const RepetitionCount = laffy.RepetitionCount;
const AlignItems = laffy.AlignItems;
const AlignContent = laffy.AlignContent;

// ---------------------------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------------------------

/// Error of every value parser.
pub const ParseError = error{ InvalidValue, OutOfMemory };

/// Error of `parseStyle` and `parseNode`. When one of the first two is returned the
/// `Diagnostic` (if given) names the attribute.
pub const StyleError = error{ UnknownAttribute, InvalidAttribute, OutOfMemory };

/// Identifies the attribute that made `parseStyle` / `parseNode` fail. Both slices borrow from
/// the element.
pub const Diagnostic = struct {
    attribute: []const u8 = "",
    value: []const u8 = "",
};

// ---------------------------------------------------------------------------------------------
// Tokenizer (the subset of CSS Syntax Level 3 that the style grammars use)
// ---------------------------------------------------------------------------------------------

const Token = union(enum) {
    ident: []const u8,
    /// A number. `int_value` is set when the source had no fraction or exponent (cssparser's
    /// `int_value`), saturated to the `i32` range.
    number: struct { value: f32, int_value: ?i32 },
    /// A percentage; the payload is the fraction (`50%` is `0.5`).
    percentage: f32,
    dimension: struct { value: f32, unit: []const u8 },
    /// An identifier immediately followed by `(`; the `(` is consumed.
    function: []const u8,
    open_paren,
    open_square,
    close_paren,
    close_square,
    comma,
    delim: u8,
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c >= 0x80;
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn startsIdent(src: []const u8, i: usize) bool {
    if (i >= src.len) return false;
    const c = src[i];
    if (isNameStart(c)) return true;
    if (c == '-') {
        if (i + 1 >= src.len) return false;
        const n = src[i + 1];
        return isNameStart(n) or n == '-';
    }
    return false;
}

fn startsNumber(src: []const u8, i: usize) bool {
    if (i >= src.len) return false;
    const c = src[i];
    if (std.ascii.isDigit(c)) return true;
    if (c == '.') return i + 1 < src.len and std.ascii.isDigit(src[i + 1]);
    if (c == '+' or c == '-') {
        if (i + 1 >= src.len) return false;
        const n = src[i + 1];
        if (std.ascii.isDigit(n)) return true;
        return n == '.' and i + 2 < src.len and std.ascii.isDigit(src[i + 2]);
    }
    return false;
}

/// Splits `src` into tokens, skipping whitespace and comments. Tokens borrow from `src`.
fn tokenize(allocator: Allocator, src: []const u8) ParseError![]Token {
    var list: std.ArrayList(Token) = .empty;
    errdefer list.deinit(allocator);
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i = if (std.mem.indexOfPos(u8, src, i + 2, "*/")) |end| end + 2 else src.len;
            continue;
        }
        if (startsNumber(src, i)) {
            const start = i;
            if (src[i] == '+' or src[i] == '-') i += 1;
            while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
            var is_int = true;
            if (i + 1 < src.len and src[i] == '.' and std.ascii.isDigit(src[i + 1])) {
                is_int = false;
                i += 1;
                while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
            }
            if (i < src.len and (src[i] == 'e' or src[i] == 'E')) {
                var j = i + 1;
                if (j < src.len and (src[j] == '+' or src[j] == '-')) j += 1;
                if (j < src.len and std.ascii.isDigit(src[j])) {
                    while (j < src.len and std.ascii.isDigit(src[j])) j += 1;
                    is_int = false;
                    i = j;
                }
            }
            // cssparser parses into an f64 and narrows to f32 (percentages divide by 100 first)
            const value = std.fmt.parseFloat(f64, src[start..i]) catch return error.InvalidValue;
            const int_value: ?i32 = if (is_int)
                @intFromFloat(std.math.clamp(value, -2147483648.0, 2147483647.0))
            else
                null;
            if (i < src.len and src[i] == '%') {
                i += 1;
                try list.append(allocator, .{ .percentage = @floatCast(value / 100.0) });
            } else if (startsIdent(src, i)) {
                const unit_start = i;
                while (i < src.len and isNameChar(src[i])) i += 1;
                try list.append(allocator, .{ .dimension = .{ .value = @floatCast(value), .unit = src[unit_start..i] } });
            } else {
                try list.append(allocator, .{ .number = .{ .value = @floatCast(value), .int_value = int_value } });
            }
            continue;
        }
        if (startsIdent(src, i)) {
            const start = i;
            while (i < src.len and isNameChar(src[i])) i += 1;
            const name = src[start..i];
            if (i < src.len and src[i] == '(') {
                i += 1;
                try list.append(allocator, .{ .function = name });
            } else {
                try list.append(allocator, .{ .ident = name });
            }
            continue;
        }
        switch (c) {
            '(' => try list.append(allocator, .open_paren),
            ')' => try list.append(allocator, .close_paren),
            '[' => try list.append(allocator, .open_square),
            ']' => try list.append(allocator, .close_square),
            ',' => try list.append(allocator, .comma),
            // Escapes, strings and other constructs are not part of any style grammar
            '\\' => return error.InvalidValue,
            else => try list.append(allocator, .{ .delim = c }),
        }
        i += 1;
    }
    return list.toOwnedSlice(allocator);
}

/// A cursor over a token slice (cssparser's `Parser`). A nested block is a sub-parser over the
/// tokens between the brackets.
const Parser = struct {
    tokens: []const Token,
    pos: usize = 0,

    fn isExhausted(p: *const Parser) bool {
        return p.pos >= p.tokens.len;
    }

    fn peek(p: *const Parser) ?Token {
        return if (p.pos < p.tokens.len) p.tokens[p.pos] else null;
    }

    fn next(p: *Parser) ?Token {
        const t = p.peek() orelse return null;
        p.pos += 1;
        return t;
    }

    fn expectExhausted(p: *const Parser) ParseError!void {
        if (!p.isExhausted()) return error.InvalidValue;
    }

    fn expectComma(p: *Parser) ParseError!void {
        const t = p.next() orelse return error.InvalidValue;
        if (t != .comma) return error.InvalidValue;
    }

    /// Call right after consuming a `function`, `open_paren` or `open_square` token. Returns a
    /// parser over the block contents and moves `p` past the closing bracket (an unclosed block
    /// ends at the end of input, as in CSS).
    fn block(p: *Parser) Parser {
        var depth: usize = 1;
        var j = p.pos;
        while (j < p.tokens.len) : (j += 1) {
            switch (p.tokens[j]) {
                .function, .open_paren, .open_square => depth += 1,
                .close_paren, .close_square => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                else => {},
            }
        }
        const inner: Parser = .{ .tokens = p.tokens[p.pos..j] };
        p.pos = @min(j + 1, p.tokens.len);
        return inner;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn eqlIc(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Tokenizes `text`, runs `parse` and requires that all tokens were consumed
/// (upstream `parse_css_str_entirely`).
fn parseEntirely(
    allocator: Allocator,
    text: []const u8,
    comptime T: type,
    comptime parse: fn (Allocator, *Parser) ParseError!T,
) ParseError!T {
    const tokens = try tokenize(allocator, text);
    defer allocator.free(tokens);
    var p: Parser = .{ .tokens = tokens };
    const value = try parse(allocator, &p);
    try p.expectExhausted();
    return value;
}

// ---------------------------------------------------------------------------------------------
// calc()
// ---------------------------------------------------------------------------------------------

/// A node of a parsed `calc()` expression. `calc()` values in a `Style` are opaque pointers to
/// the root node (allocated from the caller's allocator), and `resolveCalc` evaluates them. The
/// zero-sized `_align` field makes the alignment 8 on every target, as `CompactLength.calc`
/// requires the low 3 pointer bits to be clear.
pub const CalcNode = struct {
    pub const Op = enum { px, percent, number, add, sub, mul, div };

    op: Op,
    /// The payload of `px` (pixels), `percent` (a fraction) and `number` nodes
    value: f32 = 0,
    lhs: ?*const CalcNode = null,
    rhs: ?*const CalcNode = null,
    _align: [0]u64 = .{},

    comptime {
        std.debug.assert(@alignOf(CalcNode) >= 8);
    }

    fn eval(node: *const CalcNode, basis: f32) f32 {
        return switch (node.op) {
            .px, .number => node.value,
            .percent => node.value * basis,
            .add => node.lhs.?.eval(basis) + node.rhs.?.eval(basis),
            .sub => node.lhs.?.eval(basis) - node.rhs.?.eval(basis),
            .mul => node.lhs.?.eval(basis) * node.rhs.?.eval(basis),
            .div => node.lhs.?.eval(basis) / node.rhs.?.eval(basis),
        };
    }
};

/// Evaluates a `calc()` value made by this file: the root `CalcNode` that `ptr` points to is
/// evaluated with percentages resolved against `basis`. Plug this into a tree's
/// `resolveCalcValue`. `ptr` must come from a style produced by this file.
pub fn resolveCalc(ptr: *const anyopaque, basis: f32) f32 {
    const node: *const CalcNode = @ptrCast(@alignCast(ptr));
    return node.eval(basis);
}

const CalcKind = enum { length, number };
const CalcExpr = struct { node: *const CalcNode, kind: CalcKind };

fn makeCalcNode(allocator: Allocator, node: CalcNode) ParseError!*const CalcNode {
    const ptr = try allocator.create(CalcNode);
    ptr.* = node;
    return ptr;
}

/// Parses the inside of `calc( ... )`: `sum := product (('+' | '-') product)*`,
/// `product := value (('*' | '/') value)*`, `value := number | <px> | <percentage> | '(' sum ')' |
/// calc( sum )`. Arithmetic must be dimensionally valid: lengths and percentages add to lengths,
/// `*` needs a number on one side and `/` a non-zero number on the right.
fn parseCalcSum(allocator: Allocator, p: *Parser) ParseError!CalcExpr {
    var lhs = try parseCalcProduct(allocator, p);
    while (true) {
        const t = p.peek() orelse break;
        if (t != .delim or (t.delim != '+' and t.delim != '-')) break;
        _ = p.next();
        const rhs = try parseCalcProduct(allocator, p);
        if (lhs.kind != rhs.kind) return error.InvalidValue;
        const op: CalcNode.Op = if (t.delim == '+') .add else .sub;
        lhs = .{ .node = try makeCalcNode(allocator, .{ .op = op, .lhs = lhs.node, .rhs = rhs.node }), .kind = lhs.kind };
    }
    return lhs;
}

fn parseCalcProduct(allocator: Allocator, p: *Parser) ParseError!CalcExpr {
    var lhs = try parseCalcValue(allocator, p);
    while (true) {
        const t = p.peek() orelse break;
        if (t != .delim or (t.delim != '*' and t.delim != '/')) break;
        _ = p.next();
        const rhs = try parseCalcValue(allocator, p);
        if (t.delim == '*') {
            if (lhs.kind == .length and rhs.kind == .length) return error.InvalidValue;
            const kind: CalcKind = if (lhs.kind == .length or rhs.kind == .length) .length else .number;
            lhs = .{ .node = try makeCalcNode(allocator, .{ .op = .mul, .lhs = lhs.node, .rhs = rhs.node }), .kind = kind };
        } else {
            if (rhs.kind != .number) return error.InvalidValue;
            if (rhs.node.op == .number and rhs.node.value == 0) return error.InvalidValue;
            lhs = .{ .node = try makeCalcNode(allocator, .{ .op = .div, .lhs = lhs.node, .rhs = rhs.node }), .kind = lhs.kind };
        }
    }
    return lhs;
}

fn parseCalcValue(allocator: Allocator, p: *Parser) ParseError!CalcExpr {
    const t = p.next() orelse return error.InvalidValue;
    switch (t) {
        .number => |n| return .{ .node = try makeCalcNode(allocator, .{ .op = .number, .value = n.value }), .kind = .number },
        .percentage => |v| return .{ .node = try makeCalcNode(allocator, .{ .op = .percent, .value = v }), .kind = .length },
        .dimension => |d| {
            if (!eql(d.unit, "px")) return error.InvalidValue;
            return .{ .node = try makeCalcNode(allocator, .{ .op = .px, .value = d.value }), .kind = .length };
        },
        .open_paren => return parseCalcBlock(allocator, p),
        .function => |name| {
            if (!eqlIc(name, "calc")) return error.InvalidValue;
            return parseCalcBlock(allocator, p);
        },
        else => return error.InvalidValue,
    }
}

fn parseCalcBlock(allocator: Allocator, p: *Parser) ParseError!CalcExpr {
    var inner = p.block();
    const expr = try parseCalcSum(allocator, &inner);
    try inner.expectExhausted();
    return expr;
}

/// Parses a complete `calc(...)` function (`text` is e.g. `calc(100% - 10px)`) and returns the
/// opaque pointer to store in a style with the `calc` constructors. The result must be a length.
pub fn parseCalc(allocator: Allocator, text: []const u8) ParseError!*const anyopaque {
    return parseEntirely(allocator, text, *const anyopaque, calcFromParser);
}

fn calcFromParser(allocator: Allocator, p: *Parser) ParseError!*const anyopaque {
    const t = p.next() orelse return error.InvalidValue;
    if (t != .function or !eqlIc(t.function, "calc")) return error.InvalidValue;
    return calcBody(allocator, p);
}

/// Parses the body of a `calc(` whose function token was just consumed from `p`.
fn calcBody(allocator: Allocator, p: *Parser) ParseError!*const anyopaque {
    const expr = try parseCalcBlock(allocator, p);
    if (expr.kind != .length) return error.InvalidValue;
    return expr.node;
}

// ---------------------------------------------------------------------------------------------
// Lengths and dimensions
// ---------------------------------------------------------------------------------------------

const LpValue = union(enum) { px: f32, percent: f32, calc: *const anyopaque };

/// Interprets `t` as `<length-percentage>` (`<n>px`, `<n>%` or `calc()`, the latter consuming its
/// block from `p`). Returns null, consuming nothing more, for any other token.
fn lpValue(allocator: Allocator, p: *Parser, t: Token) ParseError!?LpValue {
    switch (t) {
        .percentage => |v| return .{ .percent = v },
        .dimension => |d| return if (eql(d.unit, "px")) .{ .px = d.value } else null,
        .function => |name| {
            if (!eqlIc(name, "calc")) return null;
            return .{ .calc = try calcBody(allocator, p) };
        },
        else => return null,
    }
}

/// The argument of `fit-content(...)`: a length, a percentage or a `calc()`. Consumes the whole
/// block of the `fit-content(` function that was just read from `p`.
fn fitContentArg(allocator: Allocator, p: *Parser) ParseError!LpValue {
    var inner = p.block();
    const t = inner.next() orelse return error.InvalidValue;
    const arg = (try lpValue(allocator, &inner, t)) orelse return error.InvalidValue;
    try inner.expectExhausted();
    return arg;
}

fn lengthPercentageFrom(allocator: Allocator, p: *Parser) ParseError!LengthPercentage {
    const t = p.next() orelse return error.InvalidValue;
    const v = (try lpValue(allocator, p, t)) orelse return error.InvalidValue;
    return switch (v) {
        .px => |x| LengthPercentage.length(x),
        .percent => |x| LengthPercentage.percent(x),
        .calc => |c| LengthPercentage.calc(c),
    };
}

fn lengthPercentageAutoFrom(allocator: Allocator, p: *Parser) ParseError!LengthPercentageAuto {
    const t = p.next() orelse return error.InvalidValue;
    if (t == .ident and eql(t.ident, "auto")) return LengthPercentageAuto.auto;
    const v = (try lpValue(allocator, p, t)) orelse return error.InvalidValue;
    return switch (v) {
        .px => |x| LengthPercentageAuto.length(x),
        .percent => |x| LengthPercentageAuto.percent(x),
        .calc => |c| LengthPercentageAuto.calc(c),
    };
}

fn dimensionFrom(allocator: Allocator, p: *Parser) ParseError!Dimension {
    const t = p.next() orelse return error.InvalidValue;
    switch (t) {
        .ident => |id| {
            if (eql(id, "auto")) return Dimension.auto;
            if (eql(id, "min-content")) return Dimension.min_content;
            if (eql(id, "max-content")) return Dimension.max_content;
            if (eql(id, "fit-content")) return Dimension.fit_content;
            if (eql(id, "stretch")) return Dimension.stretch;
            if (eql(id, "content")) return Dimension.content;
            return error.InvalidValue;
        },
        .function => |name| if (eql(name, "fit-content")) {
            return switch (try fitContentArg(allocator, p)) {
                .px => |x| Dimension.fitContentPx(x),
                .percent => |x| Dimension.fitContentPercent(x),
                .calc => |c| Dimension.fitContentCalc(c),
            };
        },
        else => {},
    }
    const v = (try lpValue(allocator, p, t)) orelse return error.InvalidValue;
    return switch (v) {
        .px => |x| Dimension.length(x),
        .percent => |x| Dimension.percent(x),
        .calc => |c| Dimension.calc(c),
    };
}

/// `<n>px`, `<n>%` or `calc()`. Percentages are stored as fractions in [0, 1].
pub fn parseLengthPercentage(allocator: Allocator, text: []const u8) ParseError!LengthPercentage {
    return parseEntirely(allocator, text, LengthPercentage, lengthPercentageFrom);
}

/// `<length-percentage>` or `auto`.
pub fn parseLengthPercentageAuto(allocator: Allocator, text: []const u8) ParseError!LengthPercentageAuto {
    return parseEntirely(allocator, text, LengthPercentageAuto, lengthPercentageAutoFrom);
}

/// `<length-percentage>`, `auto`, `min-content`, `max-content`, `fit-content`, `stretch`,
/// `content` or `fit-content(<length-percentage>)`.
pub fn parseDimension(allocator: Allocator, text: []const u8) ParseError!Dimension {
    return parseEntirely(allocator, text, Dimension, dimensionFrom);
}

fn availableSpaceFrom(_: Allocator, p: *Parser) ParseError!AvailableSpace {
    const t = p.next() orelse return error.InvalidValue;
    switch (t) {
        .number => |n| if (n.value >= 0) return .{ .definite = n.value },
        // Any unit is accepted, as upstream does
        .dimension => |d| if (d.value >= 0) return .{ .definite = d.value },
        .ident => |id| {
            if (eql(id, "max-content")) return .max_content;
            if (eql(id, "min-content")) return .min_content;
        },
        else => {},
    }
    return error.InvalidValue;
}

/// A non-negative number or dimension (any unit), `max-content` or `min-content`. This is the
/// `width` / `height` of the `<viewport>` element.
pub fn parseAvailableSpace(text: []const u8) ParseError!AvailableSpace {
    // No allocation is needed, but the tokenizer wants an allocator: use a small stack buffer.
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    return parseEntirely(fba.allocator(), text, AvailableSpace, availableSpaceFrom) catch |err| switch (err) {
        error.OutOfMemory => error.InvalidValue,
        else => |e| e,
    };
}

// ---------------------------------------------------------------------------------------------
// Grid track sizing
// ---------------------------------------------------------------------------------------------

fn minTrackFrom(allocator: Allocator, p: *Parser) ParseError!MinTrackSizingFunction {
    const t = p.next() orelse return error.InvalidValue;
    if (t == .ident) {
        if (eql(t.ident, "auto")) return MinTrackSizingFunction.auto;
        if (eql(t.ident, "min-content")) return MinTrackSizingFunction.min_content;
        if (eql(t.ident, "max-content")) return MinTrackSizingFunction.max_content;
        return error.InvalidValue;
    }
    const v = (try lpValue(allocator, p, t)) orelse return error.InvalidValue;
    return switch (v) {
        .px => |x| MinTrackSizingFunction.length(x),
        .percent => |x| MinTrackSizingFunction.percent(x),
        .calc => |c| MinTrackSizingFunction.calc(c),
    };
}

fn maxTrackFrom(allocator: Allocator, p: *Parser) ParseError!MaxTrackSizingFunction {
    const t = p.next() orelse return error.InvalidValue;
    switch (t) {
        .ident => |id| {
            if (eql(id, "auto")) return MaxTrackSizingFunction.auto;
            if (eql(id, "min-content")) return MaxTrackSizingFunction.min_content;
            if (eql(id, "max-content")) return MaxTrackSizingFunction.max_content;
            return error.InvalidValue;
        },
        .dimension => |d| if (eql(d.unit, "fr")) {
            if (std.math.signbit(d.value)) return error.InvalidValue;
            return MaxTrackSizingFunction.fr(d.value);
        },
        .function => |name| if (eql(name, "fit-content")) {
            return switch (try fitContentArg(allocator, p)) {
                .px => |x| MaxTrackSizingFunction.fitContentPx(x),
                .percent => |x| MaxTrackSizingFunction.fitContentPercent(x),
                .calc => |c| MaxTrackSizingFunction.fitContentCalc(c),
            };
        },
        else => {},
    }
    const v = (try lpValue(allocator, p, t)) orelse return error.InvalidValue;
    return switch (v) {
        .px => |x| MaxTrackSizingFunction.length(x),
        .percent => |x| MaxTrackSizingFunction.percent(x),
        .calc => |c| MaxTrackSizingFunction.calc(c),
    };
}

fn trackSizingFunctionFrom(allocator: Allocator, p: *Parser) ParseError!TrackSizingFunction {
    if (p.peek()) |t| {
        if (t == .function and eqlIc(t.function, "minmax")) {
            _ = p.next();
            var inner = p.block();
            const min = try minTrackFrom(allocator, &inner);
            try inner.expectComma();
            const max = try maxTrackFrom(allocator, &inner);
            try inner.expectExhausted();
            return .{ .min = min, .max = max };
        }
    }
    // A single function is `minmax(min(max), max)`, where fr and fit-content mins become auto
    const max = try maxTrackFrom(allocator, p);
    return .{ .min = MinTrackSizingFunction.fromMax(max), .max = max };
}

pub fn parseMinTrackSizingFunction(allocator: Allocator, text: []const u8) ParseError!MinTrackSizingFunction {
    return parseEntirely(allocator, text, MinTrackSizingFunction, minTrackFrom);
}

pub fn parseMaxTrackSizingFunction(allocator: Allocator, text: []const u8) ParseError!MaxTrackSizingFunction {
    return parseEntirely(allocator, text, MaxTrackSizingFunction, maxTrackFrom);
}

/// `minmax(<min>, <max>)` or a single max track sizing function (whose min is derived).
pub fn parseTrackSizingFunction(allocator: Allocator, text: []const u8) ParseError!TrackSizingFunction {
    return parseEntirely(allocator, text, TrackSizingFunction, trackSizingFunctionFrom);
}

fn repetitionCountFrom(_: Allocator, p: *Parser) ParseError!RepetitionCount {
    const t = p.next() orelse return error.InvalidValue;
    switch (t) {
        .number => |n| if (n.int_value) |v| {
            if (v > 0) return .{ .count = saturatingU16(v) };
        },
        .ident => |id| {
            if (eql(id, "auto-fit")) return .auto_fit;
            if (eql(id, "auto-fill")) return .auto_fill;
        },
        else => {},
    }
    return error.InvalidValue;
}

/// A positive integer, `auto-fit` or `auto-fill`.
pub fn parseRepetitionCount(text: []const u8) ParseError!RepetitionCount {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    return parseEntirely(fba.allocator(), text, RepetitionCount, repetitionCountFrom) catch |err| switch (err) {
        error.OutOfMemory => error.InvalidValue,
        else => |e| e,
    };
}

fn saturatingU16(v: i32) u16 {
    return @intCast(std.math.clamp(v, 0, std.math.maxInt(u16)));
}

fn saturatingI16(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

/// The result of parsing a `grid-template-rows` / `grid-template-columns` value
/// (upstream `GridTemplateTracks`). `line_names` holds one set of names per line (so
/// `tracks.len + 1` sets), each possibly empty.
pub fn TrackList(comptime Track: type) type {
    return struct {
        tracks: []const Track = &.{},
        line_names: []const []const []const u8 = &.{},
    };
}

fn lineNamesFrom(allocator: Allocator, p: *Parser) ParseError![]const []const u8 {
    const t = p.peek() orelse return &.{};
    if (t != .open_square) return &.{};
    _ = p.next();
    var inner = p.block();
    var names: std.ArrayList([]const u8) = .empty;
    while (inner.next()) |n| {
        if (n != .ident) return error.InvalidValue;
        try names.append(allocator, try allocator.dupe(u8, n.ident));
    }
    return names.toOwnedSlice(allocator);
}

fn trackListFrom(
    comptime Track: type,
    allocator: Allocator,
    p: *Parser,
    comptime parseOne: fn (Allocator, *Parser) ParseError!Track,
) ParseError!TrackList(Track) {
    var tracks: std.ArrayList(Track) = .empty;
    var names: std.ArrayList([]const []const u8) = .empty;
    // Line name groups are positional: one group per line, empty when the source has no `[...]`
    try names.append(allocator, try lineNamesFrom(allocator, p));
    while (!p.isExhausted()) {
        try tracks.append(allocator, try parseOne(allocator, p));
        try names.append(allocator, try lineNamesFrom(allocator, p));
    }
    if (tracks.items.len == 0) return error.InvalidValue;
    return .{ .tracks = try tracks.toOwnedSlice(allocator), .line_names = try names.toOwnedSlice(allocator) };
}

fn templateComponentFrom(allocator: Allocator, p: *Parser) ParseError!GridTemplateComponent {
    if (p.peek()) |t| {
        if (t == .function and eqlIc(t.function, "repeat")) {
            _ = p.next();
            var inner = p.block();
            const count = try repetitionCountFrom(allocator, &inner);
            try inner.expectComma();
            const list = try trackListFrom(TrackSizingFunction, allocator, &inner, trackSizingFunctionFrom);
            return .{ .repeat = .{ .count = count, .tracks = list.tracks, .line_names = list.line_names } };
        }
    }
    return .{ .single = try trackSizingFunctionFrom(allocator, p) };
}

fn templateTracksFrom(allocator: Allocator, p: *Parser) ParseError!TrackList(GridTemplateComponent) {
    return trackListFrom(GridTemplateComponent, allocator, p, templateComponentFrom);
}

fn autoTracksFrom(allocator: Allocator, p: *Parser) ParseError![]const TrackSizingFunction {
    var tracks: std.ArrayList(TrackSizingFunction) = .empty;
    while (!p.isExhausted()) try tracks.append(allocator, try trackSizingFunctionFrom(allocator, p));
    if (tracks.items.len == 0) return error.InvalidValue;
    return tracks.toOwnedSlice(allocator);
}

/// A `grid-template-rows` / `grid-template-columns` value: a non-empty list of track sizing
/// functions and `repeat()`s with optional `[line names]` before, between and after them.
pub fn parseGridTemplateTracks(allocator: Allocator, text: []const u8) ParseError!TrackList(GridTemplateComponent) {
    return parseEntirely(allocator, text, TrackList(GridTemplateComponent), templateTracksFrom);
}

/// A `grid-auto-rows` / `grid-auto-columns` value: a non-empty list of track sizing functions.
pub fn parseGridAutoTracks(allocator: Allocator, text: []const u8) ParseError![]const TrackSizingFunction {
    return parseEntirely(allocator, text, []const TrackSizingFunction, autoTracksFrom);
}

// ---------------------------------------------------------------------------------------------
// Grid placement and auto-flow
// ---------------------------------------------------------------------------------------------

fn gridPlacementFrom(allocator: Allocator, p: *Parser) ParseError!GridPlacement {
    var span = false;
    var number: ?i32 = null;
    var ident: ?[]const u8 = null;
    while (p.next()) |t| {
        switch (t) {
            .ident => |s| {
                if (eql(s, "auto")) {
                    if (span or number != null or ident != null) return error.InvalidValue;
                    try p.expectExhausted();
                    return .auto;
                } else if (eql(s, "span")) {
                    if (span) return error.InvalidValue;
                    span = true;
                } else {
                    if (ident != null) return error.InvalidValue;
                    ident = s;
                }
            },
            .number => |n| {
                const v = n.int_value orelse return error.InvalidValue;
                if (v == 0 or number != null) return error.InvalidValue;
                number = v;
            },
            else => return error.InvalidValue,
        }
    }
    if (span) {
        const count: u16 = if (number) |n| saturatingU16(n) else 0;
        if (ident) |name| return .{ .named_span = .{ .name = try allocator.dupe(u8, name), .count = count } };
        return .{ .span = count };
    }
    if (number) |n| {
        if (ident) |name| return .{ .named_line = .{ .name = try allocator.dupe(u8, name), .index = saturatingI16(n) } };
        return GridPlacement.fromLineIndex(saturatingI16(n));
    }
    if (ident) |name| return .{ .named_line = .{ .name = try allocator.dupe(u8, name), .index = 0 } };
    return error.InvalidValue;
}

/// A `grid-row-start` / `grid-column-end` / ... value: `auto`, or `span`, a non-zero integer
/// and a line name in any order (each at most once, at least one present).
pub fn parseGridPlacement(allocator: Allocator, text: []const u8) ParseError!GridPlacement {
    return parseEntirely(allocator, text, GridPlacement, gridPlacementFrom);
}

fn gridAutoFlowFrom(_: Allocator, p: *Parser) ParseError!laffy.GridAutoFlow {
    const Axis = enum { row, column };
    var axis: ?Axis = null;
    var dense = false;
    var n: usize = 0;
    while (n < 2) : (n += 1) {
        const t = p.peek() orelse break;
        if (t != .ident) break;
        _ = p.next();
        if (eql(t.ident, "row")) {
            axis = .row;
        } else if (eql(t.ident, "column")) {
            axis = .column;
        } else if (eql(t.ident, "dense")) {
            dense = true;
        } else {
            return error.InvalidValue;
        }
    }
    const a = axis orelse return if (dense) .row_dense else error.InvalidValue;
    return switch (a) {
        .row => if (dense) .row_dense else .row,
        .column => if (dense) .column_dense else .column,
    };
}

/// `row`, `column`, `dense`, `row dense` or `column dense` (case-sensitive keywords; the two
/// keywords may come in either order and `row`/`column` may repeat, as upstream).
pub fn parseGridAutoFlow(text: []const u8) ParseError!laffy.GridAutoFlow {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    return parseEntirely(fba.allocator(), text, laffy.GridAutoFlow, gridAutoFlowFrom) catch |err| switch (err) {
        error.OutOfMemory => error.InvalidValue,
        else => |e| e,
    };
}

// ---------------------------------------------------------------------------------------------
// Keyword enums
// ---------------------------------------------------------------------------------------------

fn Kw(comptime T: type) type {
    return struct { name: []const u8, value: T };
}

/// Parses exactly one identifier and matches it ASCII case-insensitively
/// (upstream `impl_parse_for_keyword_enum!`).
fn parseKeyword(comptime T: type, comptime table: []const Kw(T), text: []const u8) ParseError!T {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const tokens = tokenize(fba.allocator(), text) catch return error.InvalidValue;
    if (tokens.len != 1 or tokens[0] != .ident) return error.InvalidValue;
    inline for (table) |entry| {
        if (eqlIc(tokens[0].ident, entry.name)) return entry.value;
    }
    return error.InvalidValue;
}

const display_table = [_]Kw(laffy.Display){
    .{ .name = "none", .value = .none },
    .{ .name = "flex", .value = .flex },
    .{ .name = "grid", .value = .grid },
    .{ .name = "block", .value = .block },
    .{ .name = "flow-root", .value = .flow_root },
};
pub fn parseDisplay(text: []const u8) ParseError!laffy.Display {
    return parseKeyword(laffy.Display, &display_table, text);
}

const position_table = [_]Kw(laffy.Position){
    .{ .name = "static", .value = .static },
    .{ .name = "relative", .value = .relative },
    .{ .name = "absolute", .value = .absolute },
    .{ .name = "fixed", .value = .fixed },
    .{ .name = "sticky", .value = .sticky },
};
pub fn parsePosition(text: []const u8) ParseError!laffy.Position {
    return parseKeyword(laffy.Position, &position_table, text);
}

const box_sizing_table = [_]Kw(laffy.BoxSizing){
    .{ .name = "border-box", .value = .border_box },
    .{ .name = "content-box", .value = .content_box },
};
pub fn parseBoxSizing(text: []const u8) ParseError!laffy.BoxSizing {
    return parseKeyword(laffy.BoxSizing, &box_sizing_table, text);
}

const overflow_table = [_]Kw(laffy.Overflow){
    .{ .name = "visible", .value = .visible },
    .{ .name = "hidden", .value = .hidden },
    .{ .name = "clip", .value = .clip },
    .{ .name = "scroll", .value = .scroll },
};
pub fn parseOverflow(text: []const u8) ParseError!laffy.Overflow {
    return parseKeyword(laffy.Overflow, &overflow_table, text);
}

const direction_table = [_]Kw(laffy.Direction){
    .{ .name = "ltr", .value = .ltr },
    .{ .name = "rtl", .value = .rtl },
};
pub fn parseDirection(text: []const u8) ParseError!laffy.Direction {
    return parseKeyword(laffy.Direction, &direction_table, text);
}

const flex_direction_table = [_]Kw(laffy.FlexDirection){
    .{ .name = "row", .value = .row },
    .{ .name = "column", .value = .column },
    .{ .name = "row-reverse", .value = .row_reverse },
    .{ .name = "column-reverse", .value = .column_reverse },
};
pub fn parseFlexDirection(text: []const u8) ParseError!laffy.FlexDirection {
    return parseKeyword(laffy.FlexDirection, &flex_direction_table, text);
}

const float_table = [_]Kw(laffy.Float){
    .{ .name = "left", .value = .left },
    .{ .name = "right", .value = .right },
    .{ .name = "none", .value = .none },
};
pub fn parseFloatStyle(text: []const u8) ParseError!laffy.Float {
    return parseKeyword(laffy.Float, &float_table, text);
}

const clear_table = [_]Kw(laffy.Clear){
    .{ .name = "left", .value = .left },
    .{ .name = "right", .value = .right },
    .{ .name = "both", .value = .both },
    .{ .name = "none", .value = .none },
};
pub fn parseClear(text: []const u8) ParseError!laffy.Clear {
    return parseKeyword(laffy.Clear, &clear_table, text);
}

const text_align_table = [_]Kw(laffy.TextAlign){
    .{ .name = "auto", .value = .auto },
    .{ .name = "-webkit-left", .value = .legacy_left },
    .{ .name = "-webkit-right", .value = .legacy_right },
    .{ .name = "-webkit-center", .value = .legacy_center },
};
pub fn parseTextAlign(text: []const u8) ParseError!laffy.TextAlign {
    return parseKeyword(laffy.TextAlign, &text_align_table, text);
}

fn flexWrapFrom(_: Allocator, p: *Parser) ParseError!laffy.FlexWrap {
    var wrap: ?laffy.FlexWrap = null;
    var balance = false;
    var is_first = true;
    while (true) {
        const t = p.peek() orelse break;
        if (t != .ident) {
            if (is_first) return error.InvalidValue;
            break;
        }
        _ = p.next();
        const id = t.ident;
        if (eqlIc(id, "nowrap")) {
            if (is_first) return .no_wrap;
            return error.InvalidValue;
        } else if (eqlIc(id, "wrap") or eqlIc(id, "wrap-reverse")) {
            if (wrap != null) return error.InvalidValue;
            wrap = if (eqlIc(id, "wrap")) .wrap else .wrap_reverse;
        } else if (eqlIc(id, "balance")) {
            if (balance) return error.InvalidValue;
            balance = true;
        } else {
            return error.InvalidValue;
        }
        is_first = false;
    }
    if (is_first) return error.InvalidValue;
    if (balance) return if (wrap == .wrap_reverse) .balance_reverse else .balance;
    return wrap orelse .no_wrap;
}

/// `nowrap`, or `wrap` / `wrap-reverse` and `balance` in either order (taffy's
/// `flexbox_balance` feature, on in its default features).
pub fn parseFlexWrap(text: []const u8) ParseError!laffy.FlexWrap {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    return parseEntirely(fba.allocator(), text, laffy.FlexWrap, flexWrapFrom) catch |err| switch (err) {
        error.OutOfMemory => error.InvalidValue,
        else => |e| e,
    };
}

fn containFrom(_: Allocator, p: *Parser) ParseError!laffy.Contain {
    // The ignored `style` keyword does not map to a flag but is still checked for duplicates
    const style_bit: u8 = 1 << 6;
    var flags = laffy.Contain.none;
    var seen: u8 = 0;
    while (true) {
        const t = p.next() orelse return error.InvalidValue;
        if (t != .ident) return error.InvalidValue;
        const id = t.ident;
        var flag: laffy.Contain = undefined;
        var bit: u8 = undefined;
        if (eqlIc(id, "none") or eqlIc(id, "content")) {
            if (seen != 0 or !p.isExhausted()) return error.InvalidValue;
            return if (eqlIc(id, "content")) laffy.Contain.content else laffy.Contain.none;
        } else if (eqlIc(id, "layout")) {
            flag = laffy.Contain.layout;
            bit = laffy.Contain.layout.inner;
        } else if (eqlIc(id, "paint")) {
            flag = laffy.Contain.paint;
            bit = laffy.Contain.paint.inner;
        } else if (eqlIc(id, "style")) {
            flag = laffy.Contain.none;
            bit = style_bit;
        } else {
            return error.InvalidValue;
        }
        if (seen & bit != 0) return error.InvalidValue;
        seen |= bit;
        flags = flags.@"union"(flag);
        if (p.isExhausted()) return flags;
    }
}

/// `none`, `content`, or one or more of `layout`, `paint` and `style` (`style` is accepted and
/// ignored; duplicates are rejected).
pub fn parseContain(text: []const u8) ParseError!laffy.Contain {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    return parseEntirely(fba.allocator(), text, laffy.Contain, containFrom) catch |err| switch (err) {
        error.OutOfMemory => error.InvalidValue,
        else => |e| e,
    };
}

// ---------------------------------------------------------------------------------------------
// Alignment
// ---------------------------------------------------------------------------------------------

const align_items_table = [_]Kw(laffy.AlignItemsKeyword){
    .{ .name = "normal", .value = .normal },
    .{ .name = "start", .value = .start },
    .{ .name = "end", .value = .end },
    .{ .name = "flex-start", .value = .flex_start },
    .{ .name = "flex-end", .value = .flex_end },
    .{ .name = "self-start", .value = .self_start },
    .{ .name = "self-end", .value = .self_end },
    .{ .name = "center", .value = .center },
    .{ .name = "baseline", .value = .baseline },
    .{ .name = "stretch", .value = .stretch },
};

const align_content_table = [_]Kw(laffy.AlignContentKeyword){
    .{ .name = "normal", .value = .normal },
    .{ .name = "start", .value = .start },
    .{ .name = "end", .value = .end },
    .{ .name = "flex-start", .value = .flex_start },
    .{ .name = "flex-end", .value = .flex_end },
    .{ .name = "center", .value = .center },
    .{ .name = "stretch", .value = .stretch },
    .{ .name = "space-between", .value = .space_between },
    .{ .name = "space-evenly", .value = .space_evenly },
    .{ .name = "space-around", .value = .space_around },
};

fn lookupIc(comptime K: type, comptime table: []const Kw(K), id: []const u8) ?K {
    inline for (table) |entry| {
        if (eqlIc(id, entry.name)) return entry.value;
    }
    return null;
}

fn identOf(t: ?Token) ParseError![]const u8 {
    const tok = t orelse return error.InvalidValue;
    if (tok != .ident) return error.InvalidValue;
    return tok.ident;
}

/// Shared body of the `AlignItems` and `AlignContent` grammars: `[safe | unsafe] <position>` or a
/// plain keyword. `safe` / `unsafe` only combine with the positional keywords, listed in
/// `positional` (so not with `normal`, `stretch`, `baseline` or the `space-*` keywords).
fn alignFrom(
    comptime T: type,
    comptime K: type,
    comptime table: []const Kw(K),
    comptime positional: []const K,
    p: *Parser,
) ParseError!T {
    const first = try identOf(p.next());
    if (eqlIc(first, "safe") or eqlIc(first, "unsafe")) {
        const kw = lookupIc(K, table, try identOf(p.next())) orelse return error.InvalidValue;
        const ok = inline for (positional) |k| {
            if (k == kw) break true;
        } else false;
        if (!ok) return error.InvalidValue;
        return .{ .keyword = kw, .safety = if (eqlIc(first, "safe")) .safe else .unsafe };
    }
    const kw = lookupIc(K, table, first) orelse return error.InvalidValue;
    return .{ .keyword = kw, .safety = .default };
}

fn alignItemsFrom(_: Allocator, p: *Parser) ParseError!AlignItems {
    return alignFrom(AlignItems, laffy.AlignItemsKeyword, &align_items_table, &.{ .start, .end, .flex_start, .flex_end, .self_start, .self_end, .center }, p);
}

fn alignContentFrom(_: Allocator, p: *Parser) ParseError!AlignContent {
    return alignFrom(AlignContent, laffy.AlignContentKeyword, &align_content_table, &.{ .start, .end, .flex_start, .flex_end, .center }, p);
}

/// `align-items` / `justify-items` / `align-self` / `justify-self` values (all `AlignItems`):
/// `normal`, `start`, `end`, `flex-start`, `flex-end`, `self-start`, `self-end`, `center`,
/// `baseline`, `stretch`, or `safe` / `unsafe` followed by one of the positional ones.
/// `auto` is not accepted here; see `parseSelfAlignment`.
pub fn parseAlignItems(text: []const u8) ParseError!AlignItems {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    return parseEntirely(fba.allocator(), text, AlignItems, alignItemsFrom) catch |err| switch (err) {
        error.OutOfMemory => error.InvalidValue,
        else => |e| e,
    };
}

/// `align-content` / `justify-content` values: `normal`, `start`, `end`, `flex-start`,
/// `flex-end`, `center`, `stretch`, `space-between`, `space-evenly`, `space-around`, or `safe` /
/// `unsafe` followed by one of the positional ones.
pub fn parseAlignContent(text: []const u8) ParseError!AlignContent {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    return parseEntirely(fba.allocator(), text, AlignContent, alignContentFrom) catch |err| switch (err) {
        error.OutOfMemory => error.InvalidValue,
        else => |e| e,
    };
}

/// An `align-self` / `justify-self` value, where `auto` (trimmed, ASCII case-insensitive) is
/// represented by null (upstream `parse_self_alignment`).
pub fn parseSelfAlignment(text: []const u8) ParseError!?AlignItems {
    if (eqlIc(std.mem.trim(u8, text, &std.ascii.whitespace), "auto")) return null;
    return try parseAlignItems(text);
}

// ---------------------------------------------------------------------------------------------
// Plain numbers (Rust's `FromStr` impls, used directly by the harness)
// ---------------------------------------------------------------------------------------------

/// Rust's `f32::from_str`: no surrounding whitespace, no digit separators, no hex floats.
pub fn parseRustF32(text: []const u8) ParseError!f32 {
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, '_') != null) return error.InvalidValue;
    const digits = if (text[0] == '+' or text[0] == '-') text[1..] else text;
    if (digits.len >= 2 and digits[0] == '0' and (digits[1] == 'x' or digits[1] == 'X')) return error.InvalidValue;
    return std.fmt.parseFloat(f32, text) catch error.InvalidValue;
}

/// Rust's `u16::from_str`: an optional `+` and decimal digits.
pub fn parseRustU16(text: []const u8) ParseError!u16 {
    const digits = if (text.len > 0 and text[0] == '+') text[1..] else text;
    if (digits.len == 0) return error.InvalidValue;
    for (digits) |c| if (!std.ascii.isDigit(c)) return error.InvalidValue;
    return std.fmt.parseInt(u16, digits, 10) catch error.InvalidValue;
}

/// Whether text is laid out horizontally or vertically (test helper `WritingMode`).
pub const WritingMode = enum {
    horizontal,
    vertical,
};

/// The helper crate's `WritingMode::from_str`: the text contains `vertical` or `horizontal`
/// (`vertical` wins), so `vertical-lr` is vertical.
pub fn parseWritingMode(text: []const u8) ParseError!WritingMode {
    if (std.mem.indexOf(u8, text, "vertical") != null) return .vertical;
    if (std.mem.indexOf(u8, text, "horizontal") != null) return .horizontal;
    return error.InvalidValue;
}

// ---------------------------------------------------------------------------------------------
// Element to Style
// ---------------------------------------------------------------------------------------------

/// Every attribute the harness reads, plus `writing-mode` (read by `parseNode`, not stored in
/// the style).
const Attr = enum {
    display,
    position,
    direction,
    @"box-sizing",
    @"overflow-x",
    @"overflow-y",
    @"scrollbar-width",
    float,
    clear,
    contain,
    @"writing-mode",
    @"text-align",
    @"align-content",
    @"align-items",
    @"align-self",
    @"justify-content",
    @"justify-items",
    @"justify-self",
    @"flex-direction",
    @"flex-wrap",
    @"flex-line-count",
    @"flex-basis",
    @"flex-grow",
    @"flex-shrink",
    @"aspect-ratio",
    width,
    height,
    @"min-width",
    @"min-height",
    @"max-width",
    @"max-height",
    top,
    left,
    right,
    bottom,
    @"margin-top",
    @"margin-left",
    @"margin-right",
    @"margin-bottom",
    @"padding-top",
    @"padding-left",
    @"padding-right",
    @"padding-bottom",
    @"border-top",
    @"border-left",
    @"border-right",
    @"border-bottom",
    @"row-gap",
    @"column-gap",
    @"grid-template-columns",
    @"grid-template-rows",
    @"grid-auto-columns",
    @"grid-auto-rows",
    @"grid-auto-flow",
    @"grid-column-start",
    @"grid-column-end",
    @"grid-row-start",
    @"grid-row-end",
};

fn applyAttribute(allocator: Allocator, style: *Style, attr: Attr, v: []const u8) ParseError!void {
    switch (attr) {
        .display => style.display = try parseDisplay(v),
        .position => style.position = try parsePosition(v),
        .direction => style.direction = try parseDirection(v),
        .@"box-sizing" => style.box_sizing = try parseBoxSizing(v),
        .@"overflow-x" => style.overflow.x = try parseOverflow(v),
        .@"overflow-y" => style.overflow.y = try parseOverflow(v),
        .@"scrollbar-width" => style.scrollbar_width = try parseRustF32(v),
        .float => style.float = try parseFloatStyle(v),
        .clear => style.clear = try parseClear(v),
        .contain => style.contain = try parseContain(v),
        // Not part of the style: see `parseNode`
        .@"writing-mode" => {},
        .@"text-align" => style.text_align = try parseTextAlign(v),
        .@"align-content" => style.align_content = try parseAlignContent(v),
        .@"align-items" => style.align_items = try parseAlignItems(v),
        .@"align-self" => style.align_self = try parseSelfAlignment(v),
        .@"justify-content" => style.justify_content = try parseAlignContent(v),
        .@"justify-items" => style.justify_items = try parseAlignItems(v),
        .@"justify-self" => style.justify_self = try parseSelfAlignment(v),
        .@"flex-direction" => style.flex_direction = try parseFlexDirection(v),
        .@"flex-wrap" => style.flex_wrap = try parseFlexWrap(v),
        .@"flex-line-count" => style.flex_line_count = try parseRustU16(v),
        .@"flex-basis" => style.flex_basis = try parseDimension(allocator, v),
        .@"flex-grow" => style.flex_grow = try parseRustF32(v),
        .@"flex-shrink" => style.flex_shrink = try parseRustF32(v),
        // Upstream uses `maybe_parse` here: an unparseable ratio silently becomes `None`
        .@"aspect-ratio" => style.aspect_ratio = parseRustF32(v) catch null,
        .width => style.size.width = try parseDimension(allocator, v),
        .height => style.size.height = try parseDimension(allocator, v),
        .@"min-width" => style.min_size.width = try parseLengthPercentageAuto(allocator, v),
        .@"min-height" => style.min_size.height = try parseLengthPercentageAuto(allocator, v),
        .@"max-width" => style.max_size.width = try parseLengthPercentageAuto(allocator, v),
        .@"max-height" => style.max_size.height = try parseLengthPercentageAuto(allocator, v),
        .top => style.inset.top = try parseLengthPercentageAuto(allocator, v),
        .left => style.inset.left = try parseLengthPercentageAuto(allocator, v),
        .right => style.inset.right = try parseLengthPercentageAuto(allocator, v),
        .bottom => style.inset.bottom = try parseLengthPercentageAuto(allocator, v),
        .@"margin-top" => style.margin.top = try parseLengthPercentageAuto(allocator, v),
        .@"margin-left" => style.margin.left = try parseLengthPercentageAuto(allocator, v),
        .@"margin-right" => style.margin.right = try parseLengthPercentageAuto(allocator, v),
        .@"margin-bottom" => style.margin.bottom = try parseLengthPercentageAuto(allocator, v),
        .@"padding-top" => style.padding.top = try parseLengthPercentage(allocator, v),
        .@"padding-left" => style.padding.left = try parseLengthPercentage(allocator, v),
        .@"padding-right" => style.padding.right = try parseLengthPercentage(allocator, v),
        .@"padding-bottom" => style.padding.bottom = try parseLengthPercentage(allocator, v),
        .@"border-top" => style.border.top = try parseLengthPercentage(allocator, v),
        .@"border-left" => style.border.left = try parseLengthPercentage(allocator, v),
        .@"border-right" => style.border.right = try parseLengthPercentage(allocator, v),
        .@"border-bottom" => style.border.bottom = try parseLengthPercentage(allocator, v),
        // `column-gap` is the width of the gap, `row-gap` the height
        .@"column-gap" => style.gap.width = try parseLengthPercentage(allocator, v),
        .@"row-gap" => style.gap.height = try parseLengthPercentage(allocator, v),
        .@"grid-template-columns" => {
            const list = try parseGridTemplateTracks(allocator, v);
            style.grid_template_columns = list.tracks;
            style.grid_template_column_names = list.line_names;
        },
        .@"grid-template-rows" => {
            const list = try parseGridTemplateTracks(allocator, v);
            style.grid_template_rows = list.tracks;
            style.grid_template_row_names = list.line_names;
        },
        .@"grid-auto-columns" => style.grid_auto_columns = try parseGridAutoTracks(allocator, v),
        .@"grid-auto-rows" => style.grid_auto_rows = try parseGridAutoTracks(allocator, v),
        .@"grid-auto-flow" => style.grid_auto_flow = try parseGridAutoFlow(v),
        .@"grid-column-start" => style.grid_column.start = try parseGridPlacement(allocator, v),
        .@"grid-column-end" => style.grid_column.end = try parseGridPlacement(allocator, v),
        .@"grid-row-start" => style.grid_row.start = try parseGridPlacement(allocator, v),
        .@"grid-row-end" => style.grid_row.end = try parseGridPlacement(allocator, v),
    }
}

/// Builds the `Style` for a list of attributes (upstream `build_style`). Absent attributes keep
/// the defaults that `build_style` uses, which are the `Style` field defaults. The result borrows
/// from `allocator` (and the attribute names/values are not retained).
///
/// Fails with `error.UnknownAttribute` for an attribute the harness does not know and
/// `error.InvalidAttribute` for a value that does not parse (upstream panics); in both cases
/// `diagnostic` (if not null) names the attribute and value.
pub fn parseStyle(allocator: Allocator, attributes: []const xml.Attribute, diagnostic: ?*Diagnostic) StyleError!Style {
    var style: Style = .{};
    for (attributes) |a| {
        const attr = std.meta.stringToEnum(Attr, a.name) orelse {
            if (diagnostic) |d| d.* = .{ .attribute = a.name, .value = a.value };
            return error.UnknownAttribute;
        };
        applyAttribute(allocator, &style, attr, a.value) catch |err| {
            if (diagnostic) |d| d.* = .{ .attribute = a.name, .value = a.value };
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidValue => error.InvalidAttribute,
            };
        };
    }
    return style;
}

/// What the upstream harness extracts from one `<div>` / `<text>` element of an `<input>` tree.
pub const Node = struct {
    style: Style,
    /// True when the element has child elements (upstream builds a container node, with no node
    /// context); false for a leaf.
    has_children: bool,
    /// The trimmed text content that becomes the node's Ahem text context (for the measure
    /// function), borrowed from the element. Null when upstream sets no context: containers and
    /// empty leaves. See the file comment for how an empty `<text>` is told apart.
    text: ?[]const u8,
    /// The `writing-mode` of a leaf (`horizontal` when absent). Upstream only reads it on leaves;
    /// containers always get `horizontal` here.
    writing_mode: WritingMode,
};

/// Builds the `Node` for an element (upstream `construct_tree`'s per-node work): the style via
/// `parseStyle`, plus the text content and writing mode of leaves.
pub fn parseNode(allocator: Allocator, element: xml.Element, diagnostic: ?*Diagnostic) StyleError!Node {
    const style = try parseStyle(allocator, element.attributes, diagnostic);
    if (element.children.len > 0) {
        return .{ .style = style, .has_children = true, .text = null, .writing_mode = .horizontal };
    }
    var writing_mode: WritingMode = .horizontal;
    if (element.attribute("writing-mode")) |v| {
        writing_mode = parseWritingMode(v) catch {
            if (diagnostic) |d| d.* = .{ .attribute = "writing-mode", .value = v };
            return error.InvalidAttribute;
        };
    }
    const has_text = element.text.len > 0 or std.mem.eql(u8, element.tag, "text");
    return .{
        .style = style,
        .has_children = false,
        .text = if (has_text) element.text else null,
        .writing_mode = writing_mode,
    };
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

const testing = std.testing;

fn expectInvalid(comptime parse: anytype, args: anytype) !void {
    try testing.expectError(error.InvalidValue, @call(.auto, parse, args));
}

test "tokenizer: numbers, percentages, dimensions, identifiers" {
    const a = testing.allocator;
    const tokens = try tokenize(a, "10px 50% -3 +.5 1e2 2.5fr -webkit-left --x repeat(");
    defer a.free(tokens);
    try testing.expectEqual(@as(usize, 9), tokens.len);
    try testing.expectEqual(@as(f32, 10), tokens[0].dimension.value);
    try testing.expectEqualStrings("px", tokens[0].dimension.unit);
    try testing.expectEqual(@as(f32, 0.5), tokens[1].percentage);
    try testing.expectEqual(@as(?i32, -3), tokens[2].number.int_value);
    try testing.expectEqual(@as(f32, 0.5), tokens[3].number.value);
    try testing.expectEqual(@as(?i32, null), tokens[3].number.int_value);
    try testing.expectEqual(@as(f32, 100), tokens[4].number.value);
    try testing.expectEqual(@as(?i32, null), tokens[4].number.int_value);
    try testing.expectEqualStrings("fr", tokens[5].dimension.unit);
    try testing.expectEqualStrings("-webkit-left", tokens[6].ident);
    try testing.expectEqualStrings("--x", tokens[7].ident);
    try testing.expectEqualStrings("repeat", tokens[8].function);
}

test "tokenizer: comments are skipped, escapes are rejected" {
    const a = testing.allocator;
    const tokens = try tokenize(a, "1px /* c */ 2px");
    defer a.free(tokens);
    try testing.expectEqual(@as(usize, 2), tokens.len);
    try testing.expectError(error.InvalidValue, tokenize(a, "a\\b"));
}

test "length-percentage" {
    const a = testing.allocator;
    try testing.expectEqual(LengthPercentage.length(10), try parseLengthPercentage(a, "10px"));
    try testing.expectEqual(LengthPercentage.length(-2.5), try parseLengthPercentage(a, " -2.5px "));
    try testing.expectEqual(LengthPercentage.length(0), try parseLengthPercentage(a, "0px"));
    // Percentages are fractions
    try testing.expectEqual(LengthPercentage.percent(0.5), try parseLengthPercentage(a, "50%"));
    try testing.expectEqual(LengthPercentage.percent(1), try parseLengthPercentage(a, "100%"));
    try testing.expectEqual(LengthPercentage.percent(0.25), try parseLengthPercentage(a, "25%"));
    // Units other than px, bare numbers, keywords and trailing tokens are rejected; the unit is
    // case-sensitive
    try expectInvalid(parseLengthPercentage, .{ a, "10em" });
    try expectInvalid(parseLengthPercentage, .{ a, "10PX" });
    try expectInvalid(parseLengthPercentage, .{ a, "10" });
    try expectInvalid(parseLengthPercentage, .{ a, "auto" });
    try expectInvalid(parseLengthPercentage, .{ a, "" });
    try expectInvalid(parseLengthPercentage, .{ a, "10px 20px" });
}

test "length-percentage-auto" {
    const a = testing.allocator;
    try testing.expectEqual(LengthPercentageAuto.auto, try parseLengthPercentageAuto(a, "auto"));
    try testing.expectEqual(LengthPercentageAuto.length(3), try parseLengthPercentageAuto(a, "3px"));
    try testing.expectEqual(LengthPercentageAuto.percent(0.2), try parseLengthPercentageAuto(a, "20%"));
    try expectInvalid(parseLengthPercentageAuto, .{ a, "AUTO" });
    try expectInvalid(parseLengthPercentageAuto, .{ a, "max-content" });
    try expectInvalid(parseLengthPercentageAuto, .{ a, "auto auto" });
}

test "dimension" {
    const a = testing.allocator;
    try testing.expectEqual(Dimension.auto, try parseDimension(a, "auto"));
    try testing.expectEqual(Dimension.length(200), try parseDimension(a, "200px"));
    try testing.expectEqual(Dimension.percent(0.5), try parseDimension(a, "50%"));
    try testing.expectEqual(Dimension.min_content, try parseDimension(a, "min-content"));
    try testing.expectEqual(Dimension.max_content, try parseDimension(a, "max-content"));
    try testing.expectEqual(Dimension.fit_content, try parseDimension(a, "fit-content"));
    try testing.expectEqual(Dimension.stretch, try parseDimension(a, "stretch"));
    try testing.expectEqual(Dimension.content, try parseDimension(a, "content"));
    try testing.expectEqual(Dimension.fitContentPx(30), try parseDimension(a, "fit-content(30px)"));
    try testing.expectEqual(Dimension.fitContentPercent(0.5), try parseDimension(a, "fit-content(50%)"));
    try expectInvalid(parseDimension, .{ a, "fit-content(auto)" });
    try expectInvalid(parseDimension, .{ a, "fit-content()" });
    try expectInvalid(parseDimension, .{ a, "fit-content(1px 2px)" });
    try expectInvalid(parseDimension, .{ a, "1fr" });
    try expectInvalid(parseDimension, .{ a, "foo" });
}

test "available space" {
    try testing.expectEqual(AvailableSpace.max_content, try parseAvailableSpace("max-content"));
    try testing.expectEqual(AvailableSpace.min_content, try parseAvailableSpace("min-content"));
    try testing.expectEqual(AvailableSpace{ .definite = 800 }, try parseAvailableSpace("800px"));
    try testing.expectEqual(AvailableSpace{ .definite = 12.5 }, try parseAvailableSpace("12.5"));
    try testing.expectEqual(AvailableSpace{ .definite = 0 }, try parseAvailableSpace("0"));
    try expectInvalid(parseAvailableSpace, .{"-1px"});
    try expectInvalid(parseAvailableSpace, .{"50%"});
    try expectInvalid(parseAvailableSpace, .{"auto"});
    try expectInvalid(parseAvailableSpace, .{""});
}

test "calc: representation and evaluation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const simple = try parseDimension(a, "calc(100% - 10px)");
    try testing.expect(simple.inner.isPlainCalc());
    try testing.expectEqual(@as(usize, 0), @intFromPtr(simple.inner.calcValue()) & 0b111);
    try testing.expectEqual(@as(f32, 190), resolveCalc(simple.inner.calcValue(), 200));
    try testing.expectEqual(@as(f32, 40), resolveCalc(simple.inner.calcValue(), 50));

    // Nested arithmetic, parentheses, nested calc(), precedence
    const nested = try parseLengthPercentage(a, "calc((50% + 10px) * 2 - 4px / 2)");
    try testing.expectEqual(@as(f32, 118), resolveCalc(nested.inner.calcValue(), 100));
    const inner_calc = try parseLengthPercentage(a, "calc(calc(10% + 1px) * 3 + 2 * (1px + 1px))");
    try testing.expectEqual(@as(f32, 37), resolveCalc(inner_calc.inner.calcValue(), 100));
    const prec = try parseLengthPercentageAuto(a, "calc(1px + 2px * 3 / 3 - 1px)");
    try testing.expectEqual(@as(f32, 2), resolveCalc(prec.inner.calcValue(), 0));
    const upper = try parseLengthPercentageAuto(a, "CALC(10px)");
    try testing.expectEqual(@as(f32, 10), resolveCalc(upper.inner.calcValue(), 0));

    // Direct entry point
    const raw = try parseCalc(a, "calc(25% + 5px)");
    try testing.expectEqual(@as(f32, 30), resolveCalc(raw, 100));

    // fit-content(calc()) and track functions
    const fit = try parseDimension(a, "fit-content(calc(10% + 70px))");
    try testing.expect(fit.isFitContentCalc());
    try testing.expectEqual(@as(f32, 100), resolveCalc(fit.calcValue(), 300));
    const track = try parseTrackSizingFunction(a, "minmax(calc(10px + 1px), calc(100% / 4))");
    try testing.expect(track.min.inner.isPlainCalc());
    try testing.expect(track.max.inner.isPlainCalc());
    try testing.expectEqual(@as(f32, 11), resolveCalc(track.min.inner.calcValue(), 0));
    try testing.expectEqual(@as(f32, 50), resolveCalc(track.max.inner.calcValue(), 200));
    const fit_track = try parseMaxTrackSizingFunction(a, "fit-content(calc(10px))");
    try testing.expect(fit_track.inner.isFitContentCalc());

    // Dimensionally invalid or malformed expressions
    try expectInvalid(parseDimension, .{ a, "calc(1px + 1)" });
    try expectInvalid(parseDimension, .{ a, "calc(1px * 1px)" });
    try expectInvalid(parseDimension, .{ a, "calc(1px / 1px)" });
    try expectInvalid(parseDimension, .{ a, "calc(1px / 0)" });
    try expectInvalid(parseDimension, .{ a, "calc(2)" });
    try expectInvalid(parseDimension, .{ a, "calc()" });
    try expectInvalid(parseDimension, .{ a, "calc(1px +)" });
    try expectInvalid(parseDimension, .{ a, "calc(1px+2px)" });
    try expectInvalid(parseDimension, .{ a, "calc(1em)" });
    try expectInvalid(parseDimension, .{ a, "calc(1px) 2px" });
}

test "track sizing functions" {
    const a = testing.allocator;
    try testing.expectEqual(MinTrackSizingFunction.length(10), try parseMinTrackSizingFunction(a, "10px"));
    try testing.expectEqual(MinTrackSizingFunction.percent(0.2), try parseMinTrackSizingFunction(a, "20%"));
    try testing.expectEqual(MinTrackSizingFunction.auto, try parseMinTrackSizingFunction(a, "auto"));
    try testing.expectEqual(MinTrackSizingFunction.min_content, try parseMinTrackSizingFunction(a, "min-content"));
    try testing.expectEqual(MinTrackSizingFunction.max_content, try parseMinTrackSizingFunction(a, "max-content"));
    try expectInvalid(parseMinTrackSizingFunction, .{ a, "1fr" });
    try expectInvalid(parseMinTrackSizingFunction, .{ a, "fit-content(10px)" });

    try testing.expectEqual(MaxTrackSizingFunction.fr(1.5), try parseMaxTrackSizingFunction(a, "1.5fr"));
    try testing.expectEqual(MaxTrackSizingFunction.fr(0), try parseMaxTrackSizingFunction(a, "0fr"));
    try testing.expectEqual(MaxTrackSizingFunction.fitContentPx(20), try parseMaxTrackSizingFunction(a, "fit-content(20px)"));
    try testing.expectEqual(MaxTrackSizingFunction.fitContentPercent(0.3), try parseMaxTrackSizingFunction(a, "fit-content(30%)"));
    try expectInvalid(parseMaxTrackSizingFunction, .{ a, "-1fr" });
    try expectInvalid(parseMaxTrackSizingFunction, .{ a, "1FR" });
    try expectInvalid(parseMaxTrackSizingFunction, .{ a, "stretch" });

    // A single value is minmax(auto-or-same, value): fr and fit-content mins become auto
    try testing.expect((try parseTrackSizingFunction(a, "40px")).eql(TrackSizingFunction.fromLength(40)));
    try testing.expect((try parseTrackSizingFunction(a, "50%")).eql(TrackSizingFunction.fromPercent(0.5)));
    try testing.expect((try parseTrackSizingFunction(a, "2fr")).eql(TrackSizingFunction.fromFr(2)));
    try testing.expect((try parseTrackSizingFunction(a, "auto")).eql(TrackSizingFunction.auto));
    try testing.expect((try parseTrackSizingFunction(a, "min-content")).eql(TrackSizingFunction.min_content));
    try testing.expect((try parseTrackSizingFunction(a, "fit-content(10px)")).eql(TrackSizingFunction.fitContent(LengthPercentage.length(10))));
    const mm = try parseTrackSizingFunction(a, "MinMax(10px, 1fr)");
    try testing.expectEqual(MinTrackSizingFunction.length(10), mm.min);
    try testing.expectEqual(MaxTrackSizingFunction.fr(1), mm.max);
    const mm2 = try parseTrackSizingFunction(a, "minmax(min-content, 20%)");
    try testing.expectEqual(MinTrackSizingFunction.min_content, mm2.min);
    try testing.expectEqual(MaxTrackSizingFunction.percent(0.2), mm2.max);
    try expectInvalid(parseTrackSizingFunction, .{ a, "minmax(1fr, 2px)" });
    try expectInvalid(parseTrackSizingFunction, .{ a, "minmax(1px)" });
    try expectInvalid(parseTrackSizingFunction, .{ a, "minmax(1px, 2px, 3px)" });
    try expectInvalid(parseTrackSizingFunction, .{ a, "minmax(1px 2px)" });
    try expectInvalid(parseTrackSizingFunction, .{ a, "repeat(2, 1px)" });
}

test "repetition count" {
    try testing.expectEqual(RepetitionCount{ .count = 3 }, try parseRepetitionCount("3"));
    try testing.expectEqual(RepetitionCount{ .count = std.math.maxInt(u16) }, try parseRepetitionCount("70000"));
    try testing.expectEqual(RepetitionCount.auto_fill, try parseRepetitionCount("auto-fill"));
    try testing.expectEqual(RepetitionCount.auto_fit, try parseRepetitionCount("auto-fit"));
    try expectInvalid(parseRepetitionCount, .{"0"});
    try expectInvalid(parseRepetitionCount, .{"-1"});
    try expectInvalid(parseRepetitionCount, .{"2.0"});
    try expectInvalid(parseRepetitionCount, .{"AUTO-FIT"});
    try expectInvalid(parseRepetitionCount, .{"2px"});
}

test "grid template tracks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Plain list: one (empty) name set per line
    const plain = try parseGridTemplateTracks(a, "40px 1fr auto");
    try testing.expectEqual(@as(usize, 3), plain.tracks.len);
    try testing.expectEqual(@as(usize, 4), plain.line_names.len);
    for (plain.line_names) |names| try testing.expectEqual(@as(usize, 0), names.len);
    try testing.expect(plain.tracks[0].single.eql(TrackSizingFunction.fromLength(40)));
    try testing.expect(plain.tracks[1].single.eql(TrackSizingFunction.fromFr(1)));
    try testing.expect(plain.tracks[2].single.eql(TrackSizingFunction.auto));

    // Named lines, several names per set
    const named = try parseGridTemplateTracks(a, "[row] 10px [row mid] 20px [row]");
    try testing.expectEqual(@as(usize, 2), named.tracks.len);
    try testing.expectEqual(@as(usize, 3), named.line_names.len);
    try testing.expectEqual(@as(usize, 1), named.line_names[0].len);
    try testing.expectEqualStrings("row", named.line_names[0][0]);
    try testing.expectEqual(@as(usize, 2), named.line_names[1].len);
    try testing.expectEqualStrings("row", named.line_names[1][0]);
    try testing.expectEqualStrings("mid", named.line_names[1][1]);
    try testing.expectEqualStrings("row", named.line_names[2][0]);

    // repeat() with an integer count and named lines inside
    const rep = try parseGridTemplateTracks(a, "[a] 40px repeat(3, [x] 10px [y] minmax(5px, 1fr) [z]) 20px");
    try testing.expectEqual(@as(usize, 3), rep.tracks.len);
    try testing.expectEqual(@as(usize, 4), rep.line_names.len);
    const r = rep.tracks[1].repeat;
    try testing.expectEqual(RepetitionCount{ .count = 3 }, r.count);
    try testing.expectEqual(@as(usize, 2), r.tracks.len);
    try testing.expectEqual(@as(usize, 3), r.line_names.len);
    try testing.expectEqualStrings("x", r.line_names[0][0]);
    try testing.expectEqualStrings("y", r.line_names[1][0]);
    try testing.expectEqualStrings("z", r.line_names[2][0]);
    try testing.expectEqual(MinTrackSizingFunction.length(5), r.tracks[1].min);
    try testing.expectEqual(MaxTrackSizingFunction.fr(1), r.tracks[1].max);
    try testing.expect(!rep.tracks[1].isAutoRepetition());

    // auto-fill and auto-fit
    const fill = try parseGridTemplateTracks(a, "repeat(auto-fill, 100px)");
    try testing.expectEqual(RepetitionCount.auto_fill, fill.tracks[0].repeat.count);
    try testing.expect(fill.tracks[0].isAutoRepetition());
    const fit = try parseGridTemplateTracks(a, "10px REPEAT(auto-fit, minmax(10px, 1fr) 20%)");
    try testing.expectEqual(RepetitionCount.auto_fit, fit.tracks[1].repeat.count);
    try testing.expectEqual(@as(usize, 2), fit.tracks[1].repeat.tracks.len);

    // minmax() and fit-content() members
    const mixed = try parseGridTemplateTracks(a, "min-content max-content fit-content(20px) auto 10px 20% minmax(2px, auto)");
    try testing.expectEqual(@as(usize, 7), mixed.tracks.len);
    try testing.expect(mixed.tracks[2].single.eql(TrackSizingFunction.fitContent(LengthPercentage.length(20))));
    try testing.expect(mixed.tracks[5].single.eql(TrackSizingFunction.fromPercent(0.2)));

    // Errors: empty, only names, nested/unnamed misuse, bad counts, bad contents
    try expectInvalid(parseGridTemplateTracks, .{ a, "" });
    try expectInvalid(parseGridTemplateTracks, .{ a, "[a]" });
    try expectInvalid(parseGridTemplateTracks, .{ a, "[a] [b] 10px" });
    try expectInvalid(parseGridTemplateTracks, .{ a, "[1] 10px" });
    try expectInvalid(parseGridTemplateTracks, .{ a, "repeat(2)" });
    try expectInvalid(parseGridTemplateTracks, .{ a, "repeat(2, )" });
    try expectInvalid(parseGridTemplateTracks, .{ a, "repeat(0, 10px)" });
    try expectInvalid(parseGridTemplateTracks, .{ a, "repeat(2, repeat(2, 10px))" });
    try expectInvalid(parseGridTemplateTracks, .{ a, "10px, 20px" });
    try expectInvalid(parseGridTemplateTracks, .{ a, "10px )" });
}

test "grid auto tracks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tracks = try parseGridAutoTracks(a, "10px minmax(1px, 2fr) auto");
    try testing.expectEqual(@as(usize, 3), tracks.len);
    try testing.expect(tracks[0].eql(TrackSizingFunction.fromLength(10)));
    try testing.expectEqual(MaxTrackSizingFunction.fr(2), tracks[1].max);
    try expectInvalid(parseGridAutoTracks, .{ a, "" });
    try expectInvalid(parseGridAutoTracks, .{ a, "[a] 10px" });
    try expectInvalid(parseGridAutoTracks, .{ a, "repeat(2, 10px)" });
}

test "grid placement" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expect((try parseGridPlacement(a, "auto")).eql(.auto));
    try testing.expect((try parseGridPlacement(a, "3")).eql(GridPlacement.fromLineIndex(3)));
    try testing.expect((try parseGridPlacement(a, "-2")).eql(GridPlacement.fromLineIndex(-2)));
    try testing.expect((try parseGridPlacement(a, "+4")).eql(GridPlacement.fromLineIndex(4)));
    try testing.expect((try parseGridPlacement(a, "span 2")).eql(.{ .span = 2 }));
    try testing.expect((try parseGridPlacement(a, "span")).eql(.{ .span = 0 }));
    try testing.expect((try parseGridPlacement(a, "span -3")).eql(.{ .span = 0 }));
    try testing.expect((try parseGridPlacement(a, "foo")).eql(.{ .named_line = .{ .name = "foo", .index = 0 } }));
    try testing.expect((try parseGridPlacement(a, "2 foo")).eql(.{ .named_line = .{ .name = "foo", .index = 2 } }));
    try testing.expect((try parseGridPlacement(a, "-1 mid")).eql(.{ .named_line = .{ .name = "mid", .index = -1 } }));
    try testing.expect((try parseGridPlacement(a, "bar -3")).eql(.{ .named_line = .{ .name = "bar", .index = -3 } }));
    try testing.expect((try parseGridPlacement(a, "span col")).eql(.{ .named_span = .{ .name = "col", .count = 0 } }));
    try testing.expect((try parseGridPlacement(a, "span 2 col")).eql(.{ .named_span = .{ .name = "col", .count = 2 } }));
    try testing.expect((try parseGridPlacement(a, "col span 2")).eql(.{ .named_span = .{ .name = "col", .count = 2 } }));
    // Saturation
    try testing.expect((try parseGridPlacement(a, "100000")).eql(GridPlacement.fromLineIndex(std.math.maxInt(i16))));
    try testing.expect((try parseGridPlacement(a, "-100000")).eql(GridPlacement.fromLineIndex(std.math.minInt(i16))));
    try testing.expect((try parseGridPlacement(a, "span 100000")).eql(.{ .span = std.math.maxInt(u16) }));

    // Errors
    try expectInvalid(parseGridPlacement, .{ a, "" });
    try expectInvalid(parseGridPlacement, .{ a, "0" });
    try expectInvalid(parseGridPlacement, .{ a, "1.5" });
    try expectInvalid(parseGridPlacement, .{ a, "2px" });
    try expectInvalid(parseGridPlacement, .{ a, "span span" });
    try expectInvalid(parseGridPlacement, .{ a, "auto 2" });
    try expectInvalid(parseGridPlacement, .{ a, "2 auto" });
    try expectInvalid(parseGridPlacement, .{ a, "1 2" });
    try expectInvalid(parseGridPlacement, .{ a, "a b" });
    // `span` is case-sensitive, so this is a line named SPAN
    try testing.expect((try parseGridPlacement(a, "SPAN 2")).eql(.{ .named_line = .{ .name = "SPAN", .index = 2 } }));
}

test "grid auto flow" {
    try testing.expectEqual(laffy.GridAutoFlow.row, try parseGridAutoFlow("row"));
    try testing.expectEqual(laffy.GridAutoFlow.column, try parseGridAutoFlow("column"));
    try testing.expectEqual(laffy.GridAutoFlow.row_dense, try parseGridAutoFlow("dense"));
    try testing.expectEqual(laffy.GridAutoFlow.row_dense, try parseGridAutoFlow("row dense"));
    try testing.expectEqual(laffy.GridAutoFlow.row_dense, try parseGridAutoFlow("dense row"));
    try testing.expectEqual(laffy.GridAutoFlow.column_dense, try parseGridAutoFlow("column dense"));
    try testing.expectEqual(laffy.GridAutoFlow.column_dense, try parseGridAutoFlow("dense column"));
    try expectInvalid(parseGridAutoFlow, .{""});
    try expectInvalid(parseGridAutoFlow, .{"sparse"});
    try expectInvalid(parseGridAutoFlow, .{"row column dense"});
    try expectInvalid(parseGridAutoFlow, .{"ROW"});
    try expectInvalid(parseGridAutoFlow, .{"dense 3"});
}

test "keyword enums are case-insensitive and need exactly one ident" {
    try testing.expectEqual(laffy.Display.grid, try parseDisplay("grid"));
    try testing.expectEqual(laffy.Display.flow_root, try parseDisplay(" Flow-Root "));
    try testing.expectEqual(laffy.Display.none, try parseDisplay("NONE"));
    try testing.expectEqual(laffy.Display.block, try parseDisplay("block"));
    try testing.expectEqual(laffy.Display.flex, try parseDisplay("flex"));
    try expectInvalid(parseDisplay, .{""});
    try expectInvalid(parseDisplay, .{"flex grid"});
    try expectInvalid(parseDisplay, .{"inline"});
    try expectInvalid(parseDisplay, .{"10px"});
    try testing.expectEqual(laffy.Position.sticky, try parsePosition("sticky"));
    try testing.expectEqual(laffy.Position.absolute, try parsePosition("absolute"));
    try testing.expectEqual(laffy.Position.fixed, try parsePosition("fixed"));
    try testing.expectEqual(laffy.Position.static, try parsePosition("static"));
    try testing.expectEqual(laffy.Position.relative, try parsePosition("relative"));
    try testing.expectEqual(laffy.BoxSizing.content_box, try parseBoxSizing("content-box"));
    try testing.expectEqual(laffy.BoxSizing.border_box, try parseBoxSizing("border-box"));
    try testing.expectEqual(laffy.Overflow.clip, try parseOverflow("clip"));
    try testing.expectEqual(laffy.Overflow.scroll, try parseOverflow("scroll"));
    try testing.expectEqual(laffy.Overflow.hidden, try parseOverflow("hidden"));
    try testing.expectEqual(laffy.Overflow.visible, try parseOverflow("visible"));
    try testing.expectEqual(laffy.Direction.rtl, try parseDirection("rtl"));
    try testing.expectEqual(laffy.Direction.ltr, try parseDirection("LTR"));
    try testing.expectEqual(laffy.FlexDirection.column_reverse, try parseFlexDirection("column-reverse"));
    try testing.expectEqual(laffy.FlexDirection.row_reverse, try parseFlexDirection("row-reverse"));
    try testing.expectEqual(laffy.Float.left, try parseFloatStyle("left"));
    try testing.expectEqual(laffy.Float.none, try parseFloatStyle("none"));
    try expectInvalid(parseFloatStyle, .{"both"});
    try testing.expectEqual(laffy.Clear.both, try parseClear("both"));
    try testing.expectEqual(laffy.Clear.right, try parseClear("right"));
    try expectInvalid(parseClear, .{"inline-start"});
    try testing.expectEqual(laffy.TextAlign.legacy_center, try parseTextAlign("-webkit-center"));
    try testing.expectEqual(laffy.TextAlign.legacy_left, try parseTextAlign("-webkit-left"));
    try testing.expectEqual(laffy.TextAlign.legacy_right, try parseTextAlign("-webkit-right"));
    try testing.expectEqual(laffy.TextAlign.auto, try parseTextAlign("auto"));
    try expectInvalid(parseTextAlign, .{"center"});
}

test "flex-wrap" {
    try testing.expectEqual(laffy.FlexWrap.no_wrap, try parseFlexWrap("nowrap"));
    try testing.expectEqual(laffy.FlexWrap.wrap, try parseFlexWrap("wrap"));
    try testing.expectEqual(laffy.FlexWrap.wrap_reverse, try parseFlexWrap("Wrap-Reverse"));
    try testing.expectEqual(laffy.FlexWrap.balance, try parseFlexWrap("balance"));
    try testing.expectEqual(laffy.FlexWrap.balance, try parseFlexWrap("wrap balance"));
    try testing.expectEqual(laffy.FlexWrap.balance, try parseFlexWrap("balance wrap"));
    try testing.expectEqual(laffy.FlexWrap.balance_reverse, try parseFlexWrap("wrap-reverse balance"));
    try testing.expectEqual(laffy.FlexWrap.balance_reverse, try parseFlexWrap("balance wrap-reverse"));
    try expectInvalid(parseFlexWrap, .{""});
    try expectInvalid(parseFlexWrap, .{"balance nowrap"});
    try expectInvalid(parseFlexWrap, .{"wrap wrap"});
    try expectInvalid(parseFlexWrap, .{"wrap wrap-reverse"});
    try expectInvalid(parseFlexWrap, .{"balance balance"});
    try expectInvalid(parseFlexWrap, .{"nowrap wrap"});
    try expectInvalid(parseFlexWrap, .{"wrap 1px"});
}

test "contain" {
    try testing.expect((try parseContain("none")).inner == laffy.Contain.none.inner);
    try testing.expect((try parseContain("content")).inner == laffy.Contain.content.inner);
    try testing.expect((try parseContain("layout")).inner == laffy.Contain.layout.inner);
    try testing.expect((try parseContain("Paint")).inner == laffy.Contain.paint.inner);
    try testing.expect((try parseContain("layout paint")).inner == laffy.Contain.content.inner);
    try testing.expect((try parseContain("paint layout style")).inner == laffy.Contain.content.inner);
    try testing.expect((try parseContain("style")).inner == laffy.Contain.none.inner);
    try expectInvalid(parseContain, .{""});
    try expectInvalid(parseContain, .{"layout layout"});
    try expectInvalid(parseContain, .{"style style"});
    try expectInvalid(parseContain, .{"layout none"});
    try expectInvalid(parseContain, .{"none layout"});
    try expectInvalid(parseContain, .{"content paint"});
    try expectInvalid(parseContain, .{"size"});
}

test "alignment" {
    try testing.expectEqual(AlignItems.normal, try parseAlignItems("normal"));
    try testing.expectEqual(AlignItems.flex_start, try parseAlignItems("FLEX-START"));
    try testing.expectEqual(AlignItems.baseline, try parseAlignItems("baseline"));
    try testing.expectEqual(AlignItems.stretch, try parseAlignItems("stretch"));
    try testing.expectEqual(AlignItems.self_end, try parseAlignItems("self-end"));
    try testing.expectEqual(AlignItems.safe_center, try parseAlignItems("safe center"));
    try testing.expectEqual(AlignItems.safe_self_start, try parseAlignItems("SAFE Self-Start"));
    const unsafe_end: AlignItems = .{ .keyword = .end, .safety = .unsafe };
    try testing.expectEqual(unsafe_end, try parseAlignItems("unsafe end"));
    try expectInvalid(parseAlignItems, .{"safe stretch"});
    try expectInvalid(parseAlignItems, .{"safe baseline"});
    try expectInvalid(parseAlignItems, .{"safe normal"});
    try expectInvalid(parseAlignItems, .{"unsafe"});
    try expectInvalid(parseAlignItems, .{"auto"});
    try expectInvalid(parseAlignItems, .{"space-between"});
    try expectInvalid(parseAlignItems, .{"start end"});

    try testing.expectEqual(AlignContent.normal, try parseAlignContent("normal"));
    try testing.expectEqual(AlignContent.space_between, try parseAlignContent("space-between"));
    try testing.expectEqual(AlignContent.space_evenly, try parseAlignContent("space-evenly"));
    try testing.expectEqual(AlignContent.space_around, try parseAlignContent("space-around"));
    try testing.expectEqual(AlignContent.stretch, try parseAlignContent("stretch"));
    try testing.expectEqual(AlignContent.safe_flex_end, try parseAlignContent("safe flex-end"));
    const unsafe_center: AlignContent = .{ .keyword = .center, .safety = .unsafe };
    try testing.expectEqual(unsafe_center, try parseAlignContent("unsafe center"));
    try expectInvalid(parseAlignContent, .{"self-start"});
    try expectInvalid(parseAlignContent, .{"baseline"});
    try expectInvalid(parseAlignContent, .{"safe space-between"});
    try expectInvalid(parseAlignContent, .{"auto"});

    // align-self / justify-self: `auto` is null
    try testing.expectEqual(@as(?AlignItems, null), try parseSelfAlignment("auto"));
    try testing.expectEqual(@as(?AlignItems, null), try parseSelfAlignment("  AUTO "));
    try testing.expectEqual(@as(?AlignItems, AlignItems.center), try parseSelfAlignment("center"));
    try expectInvalid(parseSelfAlignment, .{"nope"});
}

test "plain numbers and writing mode" {
    try testing.expectEqual(@as(f32, 15), try parseRustF32("15"));
    try testing.expectEqual(@as(f32, 0.5), try parseRustF32(".5"));
    try testing.expectEqual(@as(f32, -1.5), try parseRustF32("-1.5"));
    try testing.expectEqual(@as(f32, 1000), try parseRustF32("1e3"));
    try expectInvalid(parseRustF32, .{""});
    try expectInvalid(parseRustF32, .{" 1"});
    try expectInvalid(parseRustF32, .{"1px"});
    try expectInvalid(parseRustF32, .{"1_0"});
    try expectInvalid(parseRustF32, .{"0x10"});
    try testing.expectEqual(@as(u16, 10000), try parseRustU16("10000"));
    try testing.expectEqual(@as(u16, 3), try parseRustU16("+3"));
    try expectInvalid(parseRustU16, .{"65536"});
    try expectInvalid(parseRustU16, .{"-1"});
    try expectInvalid(parseRustU16, .{"1.0"});
    try expectInvalid(parseRustU16, .{""});
    try testing.expectEqual(WritingMode.vertical, try parseWritingMode("vertical-lr"));
    try testing.expectEqual(WritingMode.horizontal, try parseWritingMode("horizontal-tb"));
    try expectInvalid(parseWritingMode, .{"sideways"});
}

fn attrs(comptime pairs: anytype) []const xml.Attribute {
    const list = comptime blk: {
        var out: [pairs.len]xml.Attribute = undefined;
        for (pairs, 0..) |pair, i| out[i] = .{ .name = pair[0], .value = pair[1] };
        break :blk out;
    };
    return &list;
}

test "parseStyle: defaults and mapping" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const empty = try parseStyle(a, &.{}, null);
    const default: Style = .{};
    try testing.expect(std.meta.eql(empty, default));

    const s = try parseStyle(a, attrs(.{
        .{ "display", "grid" },
        .{ "width", "50%" },
        .{ "height", "max-content" },
        .{ "min-width", "5px" },
        .{ "max-height", "auto" },
        .{ "margin-left", "auto" },
        .{ "padding-top", "3px" },
        .{ "border-right", "2px" },
        .{ "top", "-4px" },
        .{ "column-gap", "7px" },
        .{ "row-gap", "9px" },
        .{ "aspect-ratio", "2" },
        .{ "flex-grow", "1.5" },
        .{ "flex-shrink", "0" },
        .{ "flex-basis", "20%" },
        .{ "flex-line-count", "3" },
        .{ "align-self", "auto" },
        .{ "justify-self", "end" },
        .{ "overflow-x", "scroll" },
        .{ "scrollbar-width", "15" },
        .{ "grid-template-columns", "[a] 40px 1fr" },
        .{ "grid-row-start", "span 2" },
        .{ "grid-column-end", "-1" },
        .{ "writing-mode", "vertical-lr" },
    }), null);
    try testing.expectEqual(laffy.Display.grid, s.display);
    try testing.expectEqual(Dimension.percent(0.5), s.size.width);
    try testing.expectEqual(Dimension.max_content, s.size.height);
    try testing.expectEqual(LengthPercentageAuto.length(5), s.min_size.width);
    try testing.expectEqual(LengthPercentageAuto.auto, s.max_size.height);
    try testing.expectEqual(LengthPercentageAuto.auto, s.margin.left);
    try testing.expectEqual(LengthPercentageAuto.zero, s.margin.right);
    try testing.expectEqual(LengthPercentage.length(3), s.padding.top);
    try testing.expectEqual(LengthPercentage.length(2), s.border.right);
    try testing.expectEqual(LengthPercentageAuto.length(-4), s.inset.top);
    try testing.expectEqual(LengthPercentageAuto.auto, s.inset.left);
    try testing.expectEqual(LengthPercentage.length(7), s.gap.width);
    try testing.expectEqual(LengthPercentage.length(9), s.gap.height);
    try testing.expectEqual(@as(?f32, 2), s.aspect_ratio);
    try testing.expectEqual(@as(f32, 1.5), s.flex_grow);
    try testing.expectEqual(@as(f32, 0), s.flex_shrink);
    try testing.expectEqual(Dimension.percent(0.2), s.flex_basis);
    try testing.expectEqual(@as(u16, 3), s.flex_line_count);
    try testing.expectEqual(@as(?AlignItems, null), s.align_self);
    try testing.expectEqual(@as(?AlignItems, AlignItems.end), s.justify_self);
    try testing.expectEqual(laffy.Overflow.scroll, s.overflow.x);
    try testing.expectEqual(laffy.Overflow.visible, s.overflow.y);
    try testing.expectEqual(@as(f32, 15), s.scrollbar_width);
    try testing.expectEqual(@as(usize, 2), s.grid_template_columns.len);
    try testing.expectEqual(@as(usize, 3), s.grid_template_column_names.len);
    try testing.expectEqual(@as(usize, 0), s.grid_template_rows.len);
    try testing.expect(s.grid_row.start.eql(.{ .span = 2 }));
    try testing.expect(s.grid_row.end.eql(.auto));
    try testing.expect(s.grid_column.end.eql(GridPlacement.fromLineIndex(-1)));
}

test "parseStyle: unparseable aspect-ratio is ignored, as upstream's maybe_parse" {
    const s = try parseStyle(testing.allocator, attrs(.{.{ "aspect-ratio", "16 / 9" }}), null);
    try testing.expectEqual(@as(?f32, null), s.aspect_ratio);
}

test "parseStyle: errors name the attribute" {
    var diag: Diagnostic = .{};
    try testing.expectError(error.UnknownAttribute, parseStyle(testing.allocator, attrs(.{
        .{ "width", "1px" },
        .{ "bogus", "x" },
    }), &diag));
    try testing.expectEqualStrings("bogus", diag.attribute);
    try testing.expectEqualStrings("x", diag.value);

    try testing.expectError(error.InvalidAttribute, parseStyle(testing.allocator, attrs(.{.{ "margin-top", "10em" }}), &diag));
    try testing.expectEqualStrings("margin-top", diag.attribute);
    try testing.expectEqualStrings("10em", diag.value);

    try testing.expectError(error.InvalidAttribute, parseStyle(testing.allocator, attrs(.{.{ "flex-grow", "lots" }}), &diag));
    try testing.expectEqualStrings("flex-grow", diag.attribute);
}

test "parseNode: leaves, containers and text" {
    var doc = try xml.parse(testing.allocator,
        \\<div display="flex">
        \\  <text writing-mode="vertical-lr" width="10px">
        \\    Hello World
        \\  </text>
        \\  <text>
        \\  </text>
        \\  <div width="5px"/>
        \\</div>
    );
    defer doc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = try parseNode(a, doc.root, null);
    try testing.expect(root.has_children);
    try testing.expectEqual(@as(?[]const u8, null), root.text);

    const t1 = try parseNode(a, doc.root.children[0], null);
    try testing.expect(!t1.has_children);
    try testing.expectEqualStrings("Hello World", t1.text.?);
    try testing.expectEqual(WritingMode.vertical, t1.writing_mode);
    try testing.expectEqual(Dimension.length(10), t1.style.size.width);

    // Whitespace-only <text> still has a (empty) text context
    const t2 = try parseNode(a, doc.root.children[1], null);
    try testing.expectEqualStrings("", t2.text.?);
    try testing.expectEqual(WritingMode.horizontal, t2.writing_mode);

    // A plain empty <div/> has none
    const d = try parseNode(a, doc.root.children[2], null);
    try testing.expectEqual(@as(?[]const u8, null), d.text);

    var bad = try xml.parse(testing.allocator, "<div writing-mode=\"diagonal\"/>");
    defer bad.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidAttribute, parseNode(a, bad.root, &diag));
    try testing.expectEqualStrings("writing-mode", diag.attribute);
}

fn checkElement(
    arena: Allocator,
    path: []const u8,
    element: xml.Element,
    failures: *usize,
) !void {
    if (std.mem.eql(u8, element.tag, "div") or std.mem.eql(u8, element.tag, "text")) {
        var diag: Diagnostic = .{};
        if (parseNode(arena, element, &diag)) |_| {} else |err| {
            failures.* += 1;
            if (failures.* <= 50) {
                std.debug.print("{s}: <{s}> {s}: attribute '{s}' value '{s}'\n", .{ path, element.tag, @errorName(err), diag.attribute, diag.value });
            }
        }
    } else {
        failures.* += 1;
        if (failures.* <= 50) std.debug.print("{s}: unexpected element <{s}> in <input>\n", .{ path, element.tag });
    }
    for (element.children) |child| try checkElement(arena, path, child, failures);
}

test "every style in every fixture parses" {
    const io = testing.io;
    const gpa = testing.allocator;

    var dir = try std.Io.Dir.cwd().openDir(io, "tests/fixtures/xml", .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var style_arena = std.heap.ArenaAllocator.init(gpa);
    defer style_arena.deinit();

    var fixtures: usize = 0;
    var failures: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".xml")) continue;
        const source = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(16 * 1024 * 1024));
        defer gpa.free(source);

        var doc = try xml.parse(gpa, source);
        defer doc.deinit();
        _ = style_arena.reset(.retain_capacity);

        const input = doc.root.firstChild("input") orelse {
            std.debug.print("{s}: no <input>\n", .{entry.path});
            failures += 1;
            continue;
        };
        for (input.children) |child| try checkElement(style_arena.allocator(), entry.path, child, &failures);
        fixtures += 1;
    }
    try testing.expect(fixtures > 6000);
    if (failures != 0) std.debug.print("{d} failures\n", .{failures});
    try testing.expectEqual(@as(usize, 0), failures);
}
