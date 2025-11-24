const std = @import("std");
const claude = @import("claude.zig");
const git_status = @import("git_status.zig");
const theme = @import("theme.zig");
const usage = @import("usage.zig");
const directory = @import("directory.zig");
const assert = std.debug.assert;

// Small buffer for formatting.
var chunk: [32]u8 = undefined;

/// Formats the status line and prints it to the given writer.
/// Example: Terraform/modules/substation main* ⇣⇡ @34,040 (79%) #9 +20 -81 3m1s
pub fn format(writer: anytype, session: claude.Session, repo: ?*const git_status.Repository, snapshot: ?usage.Snapshot) !void {
    // Precondition: session must have a non-empty cwd.
    assert(session.cwd.len > 0);

    try formatCwd(writer, session.cwd);
    try formatGitBranch(writer, repo);
    try formatChanges(writer, session.cost);
    try formatUsage(writer, snapshot);
    try formatCost(writer, session.cost);
    // try formatTime(writer, session.cost);
}

fn formatCwd(writer: anytype, cwd: []const u8) !void {
    const home_env = std.posix.getenv("HOME");
    const simplified = directory.simplify(cwd, home_env);

    try theme.write(theme.active_config, writer, .{ .directory = simplified });
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
fn formatChanges(writer: anytype, cost_opt: ?claude.Cost) !void {
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
fn formatTime(writer: anytype, cost_opt: ?claude.Cost) !void {
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

fn formatCost(writer: anytype, cost_opt: ?claude.Cost) !void {
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
