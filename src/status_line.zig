const std = @import("std");
const Session = @import("Session.zig");
const git_status = @import("git_status.zig");
const theme = @import("theme.zig");
const usage = @import("usage.zig");
const assert = std.debug.assert;

/// Maximum length for the formatted cwd output.
const max_cwd_length: u32 = 300;
const component_limit: u32 = 3;

// Small buffer for formatting.
var chunk: [32]u8 = undefined;

/// Formats the status line and prints it to the given writer.
/// Example: Terraform/modules/substation main* ⇣⇡ @34,040 (79%) #9 +20 -81 3m1s
pub fn format(writer: anytype, session: Session.Session, repo: ?*const git_status.Repository, snapshot: ?usage.Snapshot) !void {
    // Precondition: session must have a non-empty cwd.
    assert(session.cwd.len > 0);

    try formatCwd(writer, session.cwd);
    try formatGitBranch(writer, repo);
    // try formatContext
    // try formatMessageCount
    try formatChanges(writer, session.cost);
    try formatUsage(writer, snapshot);
    try formatCost(writer, session.cost);
    // try formatTime(writer, session.cost);
}

fn formatCwd(writer: anytype, cwd: []const u8) !void {
    const simplified = simplifyCwd(cwd);

    try theme.write(theme.active_config, writer, .{ .directory = simplified });
}

/// Formats the current working directory to show up to 3 folders deep.
/// If 3 components exceed 300 chars, shows 2 components instead.
/// For example: /home/user/projects/myapp becomes user/projects/myapp
/// Returns a slice of the original cwd string.
fn simplifyCwd(cwd: []const u8) []const u8 {
    assert(cwd.len <= std.math.maxInt(u32));
    const sep = std.fs.path.sep;

    var relative_cwd_idx: u32 = 0;
    const home_env = std.posix.getenv("HOME");

    if (home_env) |home| {
        // We slice OFF the home path AND the separator following it.
        if (std.mem.startsWith(u8, cwd, home) and cwd.len > home.len) {
            assert(home.len <= std.math.maxInt(u32));
            relative_cwd_idx = @intCast(home.len);
            if (cwd[home.len] == sep) {
                relative_cwd_idx += 1;
            }
        }
    }

    // Basic safety checks
    if (cwd.len == 0 or relative_cwd_idx == cwd.len) return cwd;

    // Use the original length for slicing, but a trimmed length for logic
    // (ignoring a single trailing separator so we don't count an empty segment).
    var logical_end: u32 = @intCast(cwd.len);
    if (logical_end > 1 and cwd[logical_end - 1] == sep) {
        logical_end -= 1;
    }

    // We track the start indices of the last 3 segments.
    // candidate_starts[0] will hold the start of the 1st-from-last segment (depth 1).
    // candidate_starts[1] will hold the start of the 2nd-from-last segment (depth 2).
    // candidate_starts[2] will hold the start of the 3rd-from-last segment (depth 3).
    var candidate_starts = [_]u32{0} ** component_limit;
    var segments_found: u32 = 0;

    // Scan backwards from the logical end of the string.
    var i: u32 = logical_end;
    while (i > relative_cwd_idx) : (i -= 1) {
        // If we find a separator, the segment starts at this separator index.
        // (We include the separator in the output, e.g., "/project" rather than "project").
        if (cwd[i - 1] == sep) {
            // Record this position as a candidate start point.
            if (segments_found < component_limit) {
                candidate_starts[segments_found] = i - 1;
                segments_found += 1;
            } else {
                // We found more than 3 segments, so we can stop scanning.
                break;
            }
        }
    }

    // Edge case: If we ran out of string before finding 3 separators,
    // the very start of the string (index 0) is the start of the final candidate
    // (unless we already recorded index 0 via the separator check, e.g. absolute path).
    if (segments_found < component_limit) {
        // Check if index 0 was already added (it would be if cwd[0] == sep).
        // If not, add index 0 as the start of the remaining segment(s).
        if (cwd[0] != sep) {
            candidate_starts[segments_found] = 0;
            segments_found += 1;
        }
    }

    // Now select the optimal candidate.
    // We prefer the most segments (highest index in candidate_starts) that fits max_len.
    // Iterate backwards from the last found candidate (most segments) to the first (fewer segments).
    var check_idx = segments_found;
    while (check_idx > 0) : (check_idx -= 1) {
        var start_idx = candidate_starts[check_idx - 1];

        // If start_idx > 0, it means we are truncating the parent path (e.g. /a/b/c -> /c).
        // In this case, start_idx points to the separator '/'.
        // We want to skip this separator to avoid implying the path is at root.
        // If raw_start == 0, we are including the entire string (absolute or relative), so we keep it as is.
        if (start_idx > 0) {
            start_idx += 1;
        }

        // Calculate length from start to the actual end of the string.
        if (cwd.len - start_idx <= max_cwd_length) {
            return cwd[start_idx..];
        }
    }

    // If we are here, even the single last segment (at candidate_starts[0]) is too long.
    // We must truncate it to 300 characters.
    // "Truncate from the end" means we keep the beginning and discard the end.
    if (segments_found > 0) {
        const start = candidate_starts[0];
        // Ensure we don't go out of bounds (though max_len check above implies we have enough data).
        const safe_len = @min(cwd.len - start, max_cwd_length);
        return cwd[start .. start + safe_len];
    }

    // Fallback for empty/edge cases
    return cwd;
}

/// Formats the git branch status if available.
fn formatGitBranch(writer: anytype, repository: ?*const git_status.Repository) !void {
    const repo = repository orelse return;
    if (repo.branch_name.len == 0) return;

    try writer.writeAll(" ");
    try theme.write(theme.active_config, writer, .{ .git_branch = repo.branch_name });

    if (repo.is_dirty) {
        try theme.write(theme.active_config, writer, .git_dirty);
    }

    if (repo.has_upstream) {
        if (repo.count_behind > 0 or repo.count_ahead > 0) {
            try writer.writeAll(" ");
        }
        if (repo.count_behind > 0) {
            try theme.write(theme.active_config, writer, .git_pull);
        }
        if (repo.count_ahead > 0) {
            try theme.write(theme.active_config, writer, .git_push);
        }
    }
}

/// Formats the changes (lines added/removed) if cost info is available.
fn formatChanges(writer: anytype, cost_opt: ?Session.Cost) !void {
    const c = cost_opt orelse return;

    if (c.total_lines_added > 0) {
        try writer.writeAll(" ");
        const added = try std.fmt.bufPrint(&chunk, "{d}", .{c.total_lines_added});
        try theme.write(theme.active_config, writer, .{ .lines_added = added });
    }

    if (c.total_lines_removed > 0) {
        try writer.writeAll(" ");
        const removed = try std.fmt.bufPrint(&chunk, "{d}", .{c.total_lines_removed});
        try theme.write(theme.active_config, writer, .{ .lines_removed = removed });
    }
}

/// Formats the time taken if cost info is available and exceeds 60 seconds.
fn formatTime(writer: anytype, cost_opt: ?Session.Cost) !void {
    const c = cost_opt orelse return;

    if (c.total_duration_ms <= 60_000) return;

    const total_seconds = @divTrunc(c.total_duration_ms, 1000);
    const minutes = @divTrunc(total_seconds, 60);
    const seconds = @rem(total_seconds, 60);

    // We know that there is at least 1 minute, so we always show minutes and seconds.
    try writer.writeAll(" ");
    const time = try std.fmt.bufPrint(&chunk, "{d}m{d}s", .{ minutes, seconds });
    try theme.write(theme.active_config, writer, .{ .time = time });
}

fn formatCost(writer: anytype, cost_opt: ?Session.Cost) !void {
    const c = cost_opt orelse return;

    try writer.writeAll(" ");
    const usd = try std.fmt.bufPrint(&chunk, "{d:.2}", .{c.total_cost_usd});
    try theme.write(theme.active_config, writer, .{ .cost_usd = usd });
}

fn formatUsage(writer: anytype, snapshot: ?usage.Snapshot) !void {
    const s = snapshot orelse return;

    try writer.writeAll(" ");
    const usage_str = try std.fmt.bufPrint(&chunk, "{d} ({d}%)", .{ s.input, s.usable_percentage });
    const numerator = @as(u16, s.usable_percentage) * theme.context_bar_steps + 50;
    const level = @divFloor(numerator, 100);
    assert(level < theme.context_bar_steps);
    try theme.write(theme.active_config, writer, .{ .context_bar = .{ .idx = @as(u8, @intCast(level)), .text = usage_str } });
}

test "formatCwd with home" {
    const result = simplifyCwd("~/user");
    try std.testing.expectEqualStrings("~/user", result);
}

test "formatCwd with 2 components" {
    const result = simplifyCwd("/home/user");
    try std.testing.expectEqualStrings("/home/user", result);
}
test "formatCwd with exactly 3 components" {
    const result = simplifyCwd("/home/user/projects");
    try std.testing.expectEqualStrings("/home/user/projects", result);
}

test "formatCwd with 4 components shows last 3" {
    const result = simplifyCwd("/home/user/projects/myapp");
    try std.testing.expectEqualStrings("user/projects/myapp", result);
}

test "formatCwd with many components shows last 3" {
    const result = simplifyCwd("~/home/user/projects/myapp/src/components/");
    try std.testing.expectEqualStrings("myapp/src/components/", result);
}

test "formatCwd with single component" {
    const result = simplifyCwd("/root");
    try std.testing.expectEqualStrings("/root", result);
}

test "formatCwd with trailing slash" {
    const result = simplifyCwd("/home/user/projects/myapp/");
    try std.testing.expectEqualStrings("user/projects/myapp/", result);
}

test "formatCwd respects max length with 3 components" {
    // Create a path where 3 components exceed 300 chars but 2 components fit.
    const long_name = "a" ** 200;
    var buffer: [500]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "/short/{s}/{s}", .{ long_name, long_name });

    const result = simplifyCwd(path);

    // Should fall back to 2 components since 3 would exceed 300 chars.
    try std.testing.expect(result.len <= max_cwd_length);
    // Should not include the first "short" component.
    try std.testing.expect(std.mem.indexOf(u8, result, "short") == null);
}

test "formatCwd with relative path" {
    const result = simplifyCwd("home/user/projects/myapp");
    try std.testing.expectEqualStrings("user/projects/myapp", result);
}
