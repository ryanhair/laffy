//! A minimal XML reader for the test harness.
//!
//! Supports elements, self-closing elements, single- and double-quoted
//! attributes, character data, the five predefined entities, numeric character
//! references, comments, CDATA sections, and skips the XML declaration,
//! processing instructions and a simple DOCTYPE. Namespaces are not
//! interpreted (a prefixed name is just a name).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ParseError = error{
    /// The input ended in the middle of a construct.
    UnexpectedEof,
    /// A closing tag did not match the element that is open.
    MismatchedTag,
    /// Any other syntax error.
    MalformedXml,
    OutOfMemory,
};

/// A single `name="value"` pair. The value has entities already decoded.
pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

/// An XML element. All slices are owned by the `Document` arena.
pub const Element = struct {
    /// The tag name.
    tag: []const u8,
    /// Attributes in document order.
    attributes: []const Attribute = &.{},
    /// Child elements in document order.
    children: []const Element = &.{},
    /// Character data directly inside this element (entities decoded),
    /// concatenated across any interleaved children, with surrounding
    /// whitespace trimmed.
    text: []const u8 = "",

    /// Returns the value of the attribute called `name`, or null if absent.
    pub fn attribute(self: Element, name: []const u8) ?[]const u8 {
        for (self.attributes) |attr| {
            if (std.mem.eql(u8, attr.name, name)) return attr.value;
        }
        return null;
    }

    /// Returns the first child element whose tag is `tag`, or null.
    pub fn firstChild(self: *const Element, tag: []const u8) ?*const Element {
        for (self.children) |*child| {
            if (std.mem.eql(u8, child.tag, tag)) return child;
        }
        return null;
    }
};

/// A parsed document. Owns all memory reachable from `root`.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: Element,

    /// Frees everything owned by the document.
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Parses `source` into a `Document`. `source` need not outlive the result.
pub fn parse(allocator: Allocator, source: []const u8) ParseError!Document {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var parser: Parser = .{ .arena = arena.allocator(), .src = source };
    parser.skipMisc() catch |err| return err;
    if (parser.pos >= source.len) return error.UnexpectedEof;
    const root = try parser.parseElement(0);
    try parser.skipMisc();
    if (parser.pos < source.len) return error.MalformedXml;
    return .{ .arena = arena, .root = root };
}

const max_depth = 512;

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,

    fn rest(self: *const Parser) []const u8 {
        return self.src[self.pos..];
    }

    fn startsWith(self: *const Parser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.rest(), prefix);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.src.len and std.ascii.isWhitespace(self.src[self.pos])) self.pos += 1;
    }

    /// Advances past the next occurrence of `terminator`.
    fn skipPast(self: *Parser, terminator: []const u8) ParseError!void {
        const idx = std.mem.indexOf(u8, self.rest(), terminator) orelse return error.UnexpectedEof;
        self.pos += idx + terminator.len;
    }

    /// Skips whitespace, comments, processing instructions and DOCTYPE.
    fn skipMisc(self: *Parser) ParseError!void {
        while (true) {
            self.skipWhitespace();
            if (self.startsWith("<!--")) {
                try self.skipPast("-->");
            } else if (self.startsWith("<?")) {
                try self.skipPast("?>");
            } else if (self.startsWith("<!DOCTYPE")) {
                try self.skipPast(">");
            } else return;
        }
    }

    fn isNameChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == ':' or c >= 0x80;
    }

    fn parseName(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        while (self.pos < self.src.len and isNameChar(self.src[self.pos])) self.pos += 1;
        if (self.pos == start) {
            return if (self.pos >= self.src.len) error.UnexpectedEof else error.MalformedXml;
        }
        const first = self.src[start];
        if (std.ascii.isDigit(first) or first == '-' or first == '.') return error.MalformedXml;
        return self.src[start..self.pos];
    }

    fn parseAttributeValue(self: *Parser) ParseError![]const u8 {
        if (self.pos >= self.src.len) return error.UnexpectedEof;
        const quote = self.src[self.pos];
        if (quote != '"' and quote != '\'') return error.MalformedXml;
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.pos >= self.src.len) return error.UnexpectedEof;
            const c = self.src[self.pos];
            if (c == quote) {
                self.pos += 1;
                return out.items;
            }
            if (c == '<') return error.MalformedXml;
            if (c == '&') {
                try self.parseReference(&out);
            } else {
                try out.append(self.arena, c);
                self.pos += 1;
            }
        }
    }

    /// Decodes the reference at `pos` (which is at '&') and appends it to `out`.
    fn parseReference(self: *Parser, out: *std.ArrayList(u8)) ParseError!void {
        const body_start = self.pos + 1;
        const semi = std.mem.indexOfScalarPos(u8, self.src, body_start, ';') orelse return error.UnexpectedEof;
        const body = self.src[body_start..semi];
        self.pos = semi + 1;

        if (std.mem.eql(u8, body, "lt")) return out.append(self.arena, '<');
        if (std.mem.eql(u8, body, "gt")) return out.append(self.arena, '>');
        if (std.mem.eql(u8, body, "amp")) return out.append(self.arena, '&');
        if (std.mem.eql(u8, body, "quot")) return out.append(self.arena, '"');
        if (std.mem.eql(u8, body, "apos")) return out.append(self.arena, '\'');

        if (body.len < 2 or body[0] != '#') return error.MalformedXml;
        const cp = if (body[1] == 'x')
            std.fmt.parseInt(u21, body[2..], 16)
        else
            std.fmt.parseInt(u21, body[1..], 10);
        const codepoint = cp catch return error.MalformedXml;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.MalformedXml;
        try out.appendSlice(self.arena, buf[0..len]);
    }

    fn parseElement(self: *Parser, depth: usize) ParseError!Element {
        if (depth >= max_depth) return error.MalformedXml;
        if (self.pos >= self.src.len) return error.UnexpectedEof;
        if (self.src[self.pos] != '<') return error.MalformedXml;
        self.pos += 1;

        const tag = try self.parseName();
        var attributes: std.ArrayList(Attribute) = .empty;

        // Attributes, then `>` or `/>`.
        while (true) {
            const had_space = self.pos < self.src.len and std.ascii.isWhitespace(self.src[self.pos]);
            self.skipWhitespace();
            if (self.pos >= self.src.len) return error.UnexpectedEof;
            switch (self.src[self.pos]) {
                '>' => {
                    self.pos += 1;
                    break;
                },
                '/' => {
                    self.pos += 1;
                    if (self.pos >= self.src.len) return error.UnexpectedEof;
                    if (self.src[self.pos] != '>') return error.MalformedXml;
                    self.pos += 1;
                    return .{ .tag = tag, .attributes = attributes.items };
                },
                else => {
                    if (!had_space) return error.MalformedXml;
                    const name = try self.parseName();
                    self.skipWhitespace();
                    if (self.pos >= self.src.len) return error.UnexpectedEof;
                    if (self.src[self.pos] != '=') return error.MalformedXml;
                    self.pos += 1;
                    self.skipWhitespace();
                    const value = try self.parseAttributeValue();
                    for (attributes.items) |existing| {
                        if (std.mem.eql(u8, existing.name, name)) return error.MalformedXml;
                    }
                    try attributes.append(self.arena, .{ .name = name, .value = value });
                },
            }
        }

        // Content.
        var children: std.ArrayList(Element) = .empty;
        var text: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.pos >= self.src.len) return error.UnexpectedEof;
            if (self.startsWith("</")) {
                self.pos += 2;
                const close = try self.parseName();
                if (!std.mem.eql(u8, close, tag)) return error.MismatchedTag;
                self.skipWhitespace();
                if (self.pos >= self.src.len) return error.UnexpectedEof;
                if (self.src[self.pos] != '>') return error.MalformedXml;
                self.pos += 1;
                break;
            } else if (self.startsWith("<!--")) {
                try self.skipPast("-->");
            } else if (self.startsWith("<![CDATA[")) {
                self.pos += "<![CDATA[".len;
                const start = self.pos;
                try self.skipPast("]]>");
                try text.appendSlice(self.arena, self.src[start .. self.pos - 3]);
            } else if (self.startsWith("<?")) {
                try self.skipPast("?>");
            } else if (self.src[self.pos] == '<') {
                try children.append(self.arena, try self.parseElement(depth + 1));
            } else if (self.src[self.pos] == '&') {
                try self.parseReference(&text);
            } else {
                const start = self.pos;
                while (self.pos < self.src.len and self.src[self.pos] != '<' and self.src[self.pos] != '&') self.pos += 1;
                try text.appendSlice(self.arena, self.src[start..self.pos]);
            }
        }

        return .{
            .tag = tag,
            .attributes = attributes.items,
            .children = children.items,
            .text = std.mem.trim(u8, text.items, &std.ascii.whitespace),
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "elements, nesting and child order" {
    var doc = try parse(testing.allocator, "<a><b/><c></c><b/></a>");
    defer doc.deinit();
    try testing.expectEqualStrings("a", doc.root.tag);
    try testing.expectEqual(@as(usize, 3), doc.root.children.len);
    try testing.expectEqualStrings("b", doc.root.children[0].tag);
    try testing.expectEqualStrings("c", doc.root.children[1].tag);
    try testing.expectEqualStrings("b", doc.root.children[2].tag);
}

test "attributes: quotes, order, lookup, whitespace" {
    var doc = try parse(testing.allocator, "<a  x=\"1\"\n y = '2' z=\"it's\" w='say \"hi\"' />");
    defer doc.deinit();
    const a = doc.root;
    try testing.expectEqual(@as(usize, 4), a.attributes.len);
    try testing.expectEqualStrings("x", a.attributes[0].name);
    try testing.expectEqualStrings("w", a.attributes[3].name);
    try testing.expectEqualStrings("1", a.attribute("x").?);
    try testing.expectEqualStrings("2", a.attribute("y").?);
    try testing.expectEqualStrings("it's", a.attribute("z").?);
    try testing.expectEqualStrings("say \"hi\"", a.attribute("w").?);
    try testing.expect(a.attribute("nope") == null);
}

test "text content is trimmed and concatenated" {
    var doc = try parse(testing.allocator, "<a>\n  hello <b/> world\n</a>");
    defer doc.deinit();
    try testing.expectEqualStrings("hello  world", doc.root.text);
    try testing.expectEqualStrings("", doc.root.children[0].text);
}

test "predefined entities and numeric references in text and attributes" {
    var doc = try parse(testing.allocator,
        \\<a v="&lt;&gt;&amp;&quot;&apos; &#65;&#x42;&#x20AC;">&lt;x&gt; &amp; &#67; &#x1F600;</a>
    );
    defer doc.deinit();
    try testing.expectEqualStrings("<>&\"' AB\u{20AC}", doc.root.attribute("v").?);
    try testing.expectEqualStrings("<x> & C \u{1F600}", doc.root.text);
}

test "comments, declaration, processing instructions, doctype are skipped" {
    var doc = try parse(testing.allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!-- leading -->
        \\<!DOCTYPE a>
        \\<a><!-- inner <b/> -->t<?pi stuff?><b/></a>
        \\<!-- trailing -->
        \\
    );
    defer doc.deinit();
    try testing.expectEqualStrings("a", doc.root.tag);
    try testing.expectEqualStrings("t", doc.root.text);
    try testing.expectEqual(@as(usize, 1), doc.root.children.len);
}

test "CDATA" {
    var doc = try parse(testing.allocator, "<a><![CDATA[<b> & ]]></a>");
    defer doc.deinit();
    try testing.expectEqualStrings("<b> &", doc.root.text);
}

test "firstChild" {
    var doc = try parse(testing.allocator, "<a><b n='1'/><c/><b n='2'/></a>");
    defer doc.deinit();
    try testing.expectEqualStrings("1", doc.root.firstChild("b").?.attribute("n").?);
    try testing.expect(doc.root.firstChild("c") != null);
    try testing.expect(doc.root.firstChild("d") == null);
}

test "error: unexpected eof" {
    const cases = [_][]const u8{
        "",
        "   ",
        "<a>",
        "<a",
        "<a x=",
        "<a x=\"1",
        "<a><b/>",
        "<a><!-- never closed </a>",
        "<a>&amp",
        "<a></a",
        "<?xml",
    };
    for (cases) |src| {
        try testing.expectError(error.UnexpectedEof, parse(testing.allocator, src));
    }
}

test "error: mismatched tag" {
    try testing.expectError(error.MismatchedTag, parse(testing.allocator, "<a></b>"));
    try testing.expectError(error.MismatchedTag, parse(testing.allocator, "<a><b></a></b>"));
}

test "error: malformed xml" {
    const cases = [_][]const u8{
        "text",
        "<>",
        "<a x=1/>",
        "<a x/>",
        "<a x=\"1\"y=\"2\"/>",
        "<a x=\"1\" x=\"2\"/>",
        "<a/><b/>",
        "<a/>junk",
        "<a>&bogus;</a>",
        "<a>&#xZZ;</a>",
        "<a>&#xD800;</a>",
        "<a x=\"<\"/>",
        "<a / >",
        "<1a/>",
    };
    for (cases) |src| {
        try testing.expectError(error.MalformedXml, parse(testing.allocator, src));
    }
}

test "error: excessive nesting is rejected, not a stack overflow" {
    const src = try testing.allocator.alloc(u8, 3 * 10_000);
    defer testing.allocator.free(src);
    for (0..10_000) |i| @memcpy(src[i * 3 ..][0..3], "<a>");
    try testing.expectError(error.MalformedXml, parse(testing.allocator, src));
}

test "error: out of memory" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, parse(failing.allocator(), "<a x='1'>t<b/></a>"));
}

test "no leaks when parse fails midway" {
    try testing.expectError(error.MismatchedTag, parse(testing.allocator, "<a x='1'><b>text</c></a>"));
}

test "all fixtures parse with test/input/expectations structure" {
    const io = testing.io;
    const gpa = testing.allocator;

    var dir = try std.Io.Dir.cwd().openDir(io, "tests/fixtures/xml", .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".xml")) continue;
        const source = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(16 * 1024 * 1024));
        defer gpa.free(source);

        var doc = parse(gpa, source) catch |err| {
            std.debug.print("failed to parse {s}: {s}\n", .{ entry.path, @errorName(err) });
            return err;
        };
        defer doc.deinit();

        try testing.expectEqualStrings("test", doc.root.tag);
        try testing.expect(doc.root.firstChild("input") != null);
        try testing.expect(doc.root.firstChild("expectations") != null);
        count += 1;
    }
    try testing.expect(count > 0);
}
