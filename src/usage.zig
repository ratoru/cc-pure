const std = @import("std");
const assert = std.debug.assert;
const fs = std.fs;
const mem = std.mem;
const math = std.math;
const testing = std.testing;

const logger = std.log.scoped(.usage);

/// Configuration dependencies.
pub const Config = struct {
    context_limits: ModelLimits = .{},

    pub const ModelLimits = struct {
        default: u32 = 200_000,
        sonnet: ?u32 = null,
        opus: ?u32 = null,
    };
};

pub const Snapshot = struct {
    /// Total tokens currently consumed in the context window.
    /// Sum of: input_tokens + cache_read_tokens + cache_creation_tokens.
    input: u32,

    /// Usage percentage relative to the absolute hard limit (max).
    /// Formula: (input / max) * 100
    percentage: u8,

    /// Usage percentage relative to the "Safe Limit" (75% of max).
    /// If this is 100%, you have hit the safety threshold.
    /// Formula: (input / usable) * 100
    usable_percentage: u8,

    /// Remaining percentage of the "Safe Limit".
    /// Formula: 100 - usable_percentage (saturates at 0).
    left_percentage: u8,

    /// The absolute hard limit for the specific model (e.g., 200,000).
    /// Derived from Config via `get_limit`.
    max: u32,

    /// The "Safe Limit" ceiling.
    /// Formula: max * 0.75
    usable: u32,
};

/// JSON mapping struct.
const ParsedEntry = struct {
    timestamp: []const u8,

    message: ?struct {
        id: ?[]const u8 = null,
        usage: ?struct {
            input_tokens: ?u32 = null,
            output_tokens: ?u32 = null,
            cache_creation_input_tokens: ?u32 = null,
            cache_read_input_tokens: ?u32 = null,
        } = null,
        model: ?[]const u8 = null,
    } = null,

    costUSD: ?f64 = null,

    isSidechain: ?bool = null,
};

pub const Tracker = struct {
    config: Config,

    pub fn init(config: Config) Tracker {
        return .{ .config = config };
    }

    pub fn calculate(
        self: Tracker,
        allocator: mem.Allocator,
        transcript_path: []const u8,
        model_id: ?[]const u8,
    ) !?Snapshot {
        // Open the file
        var file = fs.cwd().openFile(transcript_path, .{ .mode = .read_only }) catch |err| {
            logger.warn("failed to open transcript file: {s}", .{@errorName(err)});
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        const tail_size: u64 = 256 * 1024; // 256KB

        const read_start = if (stat.size > tail_size) stat.size - tail_size else 0;
        const read_len = @min(tail_size, stat.size);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const buffer_size = read_len + 1;
        const buf = try allocator.alloc(u8, buffer_size);
        defer allocator.free(buf);

        var file_reader = file.reader(buf);
        try file_reader.seekTo(read_start);
        const reader = &file_reader.interface;

        const content = reader.allocRemaining(arena_alloc, @enumFromInt(buffer_size)) catch |err| {
            logger.warn("failed to read transcript file: {s}", .{@errorName(err)});
            return err;
        };
        defer arena_alloc.free(content);

        if (content.len == 0) {
            logger.debug("transcript file is empty", .{});
            return null;
        }

        // Parse backwards to find the latest usage
        var entry: ?ParsedEntry = null;
        var line_iter = mem.splitBackwardsScalar(u8, content, '\n');

        while (line_iter.next()) |line| {
            if (line.len == 0) continue;

            // Parse line-by-line. Ignore fields not defined in ParsedEntry.
            const e = std.json.parseFromSliceLeaky(
                ParsedEntry,
                arena_alloc,
                line,
                .{ .ignore_unknown_fields = true },
            ) catch continue;

            // Skip sidechains
            if (e.isSidechain orelse false) continue;

            // Check deep optional chain for usage
            const msg = e.message orelse continue;
            const usage = msg.usage orelse continue;

            if (usage.input_tokens != null) {
                entry = e;
                logger.debug("found most recent entry at {s}", .{e.timestamp});
                break;
            }
        }

        // Calculate Snapshot
        if (entry) |valid_entry| {
            // Safety: We verified these exist in the loop above.
            const usage = valid_entry.message.?.usage.?;

            const context_len: u32 = (usage.input_tokens orelse 0) +
                (usage.cache_read_input_tokens orelse 0) +
                (usage.cache_creation_input_tokens orelse 0);

            const limit = self.get_limit(model_id);

            logger.debug("context: {d} tokens (limit: {d})", .{ context_len, limit });

            const f_len = @as(f64, @floatFromInt(context_len));
            const f_limit = @as(f64, @floatFromInt(limit));

            const pct = calc_percentage(f_len, f_limit);
            const usable_limit = @as(u32, @intFromFloat(@round(f_limit * 0.75)));
            const usable_pct = calc_percentage(f_len, @as(f64, @floatFromInt(usable_limit)));

            // Saturating subtraction to ensure safety if we exceed 100%
            const left_pct = 100 -| usable_pct;

            assert(pct <= 100);

            return Snapshot{
                .input = context_len,
                .percentage = pct,
                .usable_percentage = usable_pct,
                .left_percentage = left_pct,
                .max = limit,
                .usable = usable_limit,
            };
        }

        logger.debug("no main chain entries with usage data found", .{});
        return null;
    }

    fn get_limit(self: Tracker, model_id: ?[]const u8) u32 {
        const limits = self.config.context_limits;
        const default = limits.default;

        const id = model_id orelse return default;

        // Use std lib for case-insensitive search
        if (std.ascii.indexOfIgnoreCase(id, "sonnet") != null) {
            return limits.sonnet orelse default;
        }
        if (std.ascii.indexOfIgnoreCase(id, "opus") != null) {
            return limits.opus orelse default;
        }

        return default;
    }
};

// --- Internal Helpers ---

fn calc_percentage(numerator: f64, denominator: f64) u8 {
    if (denominator <= math.floatEps(f64)) return 100;

    const val = (numerator / denominator) * 100.0;
    const clamped = math.clamp(val, 0.0, 100.0);

    return @as(u8, @intFromFloat(@round(clamped)));
}

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

test "calc_percentage: standard calculations" {
    try testing.expectEqual(@as(u8, 50), calc_percentage(50.0, 100.0));
    try testing.expectEqual(@as(u8, 25), calc_percentage(1.0, 4.0));
    try testing.expectEqual(@as(u8, 100), calc_percentage(100.0, 100.0));
    try testing.expectEqual(@as(u8, 0), calc_percentage(0.0, 100.0));
}

test "calc_percentage: rounding logic" {
    // 1/3 is 33.333... -> rounds down to 33
    try testing.expectEqual(@as(u8, 33), calc_percentage(1.0, 3.0));

    // 2/3 is 66.666... -> rounds up to 67
    try testing.expectEqual(@as(u8, 67), calc_percentage(2.0, 3.0));

    // 0.5 rounds away from zero (usually up in this context) -> 1
    try testing.expectEqual(@as(u8, 1), calc_percentage(1.0, 200.0)); // 0.5%
}

test "calc_percentage: clamping and edge cases" {
    // Denominator is zero
    try testing.expectEqual(@as(u8, 100), calc_percentage(50.0, 0.0));

    // Result > 100 (should clamp to 100)
    try testing.expectEqual(@as(u8, 100), calc_percentage(200.0, 100.0));

    // Negative numerator (clamped to 0 via math.clamp logic on result)
    try testing.expectEqual(@as(u8, 0), calc_percentage(-10.0, 100.0));
}

test "Tracker: get_limit resolution" {
    const config = Config{
        .context_limits = .{
            .default = 100,
            .sonnet = 200,
            .opus = 300,
        },
    };
    const tracker = Tracker.init(config);

    try testing.expectEqual(@as(u32, 100), tracker.get_limit(null));
    try testing.expectEqual(@as(u32, 100), tracker.get_limit("unknown-model"));
    try testing.expectEqual(@as(u32, 200), tracker.get_limit("claude-3-sonnet"));
    try testing.expectEqual(@as(u32, 200), tracker.get_limit("Sonnet-Pro"));
    try testing.expectEqual(@as(u32, 300), tracker.get_limit("claude-3-opus"));
}
