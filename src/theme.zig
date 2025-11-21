const std = @import("std");
const assert = std.debug.assert;
const build_options = @import("config");

// -----------------------------------------------------------------------------
// Introspection & Validation (Comptime)
// -----------------------------------------------------------------------------

/// Validates a hex string at compile time.
fn validate_hex(comptime hex: []const u8) void {
    if (hex.len != 6) @compileError("Hex color must be exactly 6 characters (RRGGBB): " ++ hex);
    inline for (hex) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => @compileError("Hex color contains invalid character: " ++ hex),
        }
    }
}

/// Converts a hex string "RRGGBB" to an ANSI TrueColor foreground sequence.
fn rgb(comptime hex: []const u8) []const u8 {
    validate_hex(hex);
    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch unreachable;
    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch unreachable;
    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch unreachable;
    return std.fmt.comptimePrint("\x1b[38;2;{d};{d};{d}m", .{ r, g, b });
}

// -----------------------------------------------------------------------------
// Types
// -----------------------------------------------------------------------------

/// How many steps are in the context usage bar
pub const context_bar_steps = 8;

pub const Symbols = struct {
    git_push: []const u8,
    git_pull: []const u8,
    git_dirty: []const u8,
    lines_added: []const u8,
    lines_removed: []const u8,
    cost_usd: []const u8,
    /// 8 steps: 0 (empty) to 7 (full)
    context_bar: [context_bar_steps][]const u8,
};

pub const Palette = struct {
    directory_fg: []const u8,
    git_branch_fg: []const u8,
    git_dirty_fg: []const u8,
    git_push_pull_fg: []const u8,
    context_window_fg: []const u8,
    cost_usd_fg: []const u8,
    lines_added_fg: []const u8,
    lines_removed_fg: []const u8,
    time_fg: []const u8,
    reset: []const u8 = "\x1b[0m",
};

pub const Config = struct {
    symbols: Symbols,
    palette: Palette,
};

/// This groups the data with the intent, removing ambiguity about
/// which elements require text overrides vs which use static symbols.
pub const UiElement = union(enum) {
    directory: []const u8,
    git_branch: []const u8,
    cost_usd: []const u8,
    time: []const u8,
    lines_added: []const u8,
    lines_removed: []const u8,

    // These use static symbols defined in config
    git_dirty,
    git_push,
    git_pull,

    /// Uses a numeric index to select the glyph
    context_bar: struct {
        idx: u8,
        text: []const u8,
    },
};

// -----------------------------------------------------------------------------
// Symbol Sets
// -----------------------------------------------------------------------------

pub const symbols_nerd = Symbols{
    .git_push = "⇡",
    .git_pull = "⇣",
    .git_dirty = "*",
    .lines_added = "+",
    .lines_removed = "-",
    .cost_usd = "$",
    .context_bar = .{ "󰪞", "󰪟", "󰪠", "󰪡", "󰪢", "󰪣", "󰪤", "󰪥" },
};

pub const symbols_plain = Symbols{
    .git_push = "^",
    .git_pull = "v",
    .git_dirty = "*",
    .lines_added = "+",
    .lines_removed = "-",
    .cost_usd = "$",
    .context_bar = .{ "_", ".", ".", "=", "=", "/", "|", "@" },
};

// -----------------------------------------------------------------------------
// Palettes
// -----------------------------------------------------------------------------

pub const palette_vague = Palette{
    .directory_fg = rgb("6e94b2"),
    .git_branch_fg = rgb("606079"),
    .git_dirty_fg = rgb("bb9dbd"),
    .git_push_pull_fg = rgb("e08398"),
    .context_window_fg = rgb("f3be7c"),
    .cost_usd_fg = rgb("606079"),
    .lines_added_fg = rgb("7fa563"),
    .lines_removed_fg = rgb("d8647e"),
    .time_fg = rgb("606079"),
};

pub const palette_tokyo_night = Palette{
    .directory_fg = rgb("7aa2f7"),
    .git_branch_fg = rgb("bb9af7"),
    .git_dirty_fg = rgb("f7768e"),
    .git_push_pull_fg = rgb("7dcfff"),
    .context_window_fg = rgb("e0af68"),
    .cost_usd_fg = rgb("c0caf5"),
    .lines_added_fg = rgb("9ece6a"),
    .lines_removed_fg = rgb("f7768e"),
    .time_fg = rgb("565f89"),
};

// -----------------------------------------------------------------------------
// Logic
// -----------------------------------------------------------------------------

/// The final configuration chosen by the user via `zig build -Dtheme=...`
pub const active_config = Config{
    .symbols = if (build_options.nerd) symbols_nerd else symbols_plain,
    .palette = switch (build_options.theme) {
        .vague => palette_vague,
        .tokyo_night => palette_tokyo_night,
    },
};

/// Writes a specific symbol using the semantic color defined in the config.
/// Centralizes control flow and state access.
pub fn write(
    comptime config: Config,
    writer: anytype,
    element: UiElement,
) !void {
    const Style = struct {
        color: []const u8,
        symbol: []const u8 = "",
        text: []const u8 = "",
    };

    const style: Style = switch (element) {
        .directory => |text| .{
            .color = config.palette.directory_fg,
            .symbol = "",
            .text = text,
        },
        .git_branch => |text| .{ .color = config.palette.git_branch_fg, .symbol = "", .text = text },
        .cost_usd => |text| .{ .color = config.palette.cost_usd_fg, .symbol = config.symbols.cost_usd, .text = text },
        .time => |text| .{ .color = config.palette.time_fg, .symbol = "", .text = text },
        .lines_added => |text| .{ .color = config.palette.lines_added_fg, .symbol = config.symbols.lines_added, .text = text },
        .lines_removed => |text| .{ .color = config.palette.lines_removed_fg, .symbol = config.symbols.lines_removed, .text = text },

        .git_dirty => .{ .color = config.palette.git_dirty_fg, .symbol = config.symbols.git_dirty, .text = "" },
        .git_push => .{
            .color = config.palette.git_push_pull_fg,
            .symbol = config.symbols.git_push,
            .text = "",
        },
        .git_pull => .{
            .color = config.palette.git_push_pull_fg,
            .symbol = config.symbols.git_pull,
            .text = "",
        },

        .context_bar => |data| bar: {
            assert(data.idx < config.symbols.context_bar.len);
            break :bar .{ .color = config.palette.context_window_fg, .symbol = config.symbols.context_bar[data.idx], .text = data.text };
        },
    };

    // We expect something to be written.
    assert(style.color.len > 0);
    assert(style.symbol.len > 0 or style.text.len > 0);

    try writer.writeAll(style.color);
    if (style.symbol.len > 0) try writer.writeAll(style.symbol);
    if (style.text.len > 0) try writer.writeAll(style.text);
    try writer.writeAll(config.palette.reset);
}

test "write function with directory element" {
    const config = Config{ .symbols = symbols_nerd, .palette = palette_tokyo_night };
    var allocating_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer allocating_writer.deinit();

    try write(config, &allocating_writer.writer, .{ .directory = "/home/zig" });

    // Verify the output contains the directory path
    const output = allocating_writer.written();
    try std.testing.expect(output.len > 0);

    // Should contain ANSI color codes and the directory text
    const expected_text = "/home/zig";
    try std.testing.expect(std.mem.indexOf(u8, output, expected_text) != null);

    // Should start with color code and end with reset
    try std.testing.expect(std.mem.startsWith(u8, output, "\x1b[38;2;"));
    try std.testing.expect(std.mem.endsWith(u8, output, "\x1b[0m"));
}
