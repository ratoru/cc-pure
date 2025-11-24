const std = @import("std");
const assert = std.debug.assert;

/// Represents the model information from Claude Code.
/// This includes both the internal model ID and the user-facing display name.
pub const Model = struct {
    id: []const u8,
    display_name: []const u8,
};

/// Represents workspace directory information.
/// Tracks both the current working directory and the project root directory.
pub const Workspace = struct {
    current_dir: []const u8,
    project_dir: []const u8,
};

/// Represents [output style](https://code.claude.com/docs/en/output-styles) configuration.
pub const OutputStyle = struct {
    name: []const u8,
};

/// Represents cost and usage statistics for a Claude Code session.
/// Tracks both financial costs and resource usage metrics.
pub const Cost = struct {
    total_cost_usd: f64,
    total_duration_ms: u64,
    total_api_duration_ms: u64,
    total_lines_added: u64,
    total_lines_removed: u64,
};

/// Main session structure that matches https://code.claude.com/docs/en/statusline.
/// This is passed to status line scripts via stdin as JSON,
/// providing contextual information about the current Claude Code session.
pub const Session = struct {
    session_id: []const u8,
    transcript_path: []const u8,
    cwd: []const u8,
    model: Model,
    workspace: Workspace,
    version: ?[]const u8 = null,
    output_style: ?OutputStyle = null,
    cost: ?Cost = null,
    exceeds_200k_tokens: ?bool = null,
};

/// Parses JSON bytes into a Session struct.
/// The caller owns the returned Parsed(Session) and must call deinit() on it to free memory.
/// Unknown fields are ignored to maintain forward compatibility as the format evolves.
pub fn parse(allocator: std.mem.Allocator, json_bytes: []const u8) !std.json.Parsed(Session) {
    // Precondition: json_bytes must not be empty.
    assert(json_bytes.len > 0);

    const parsed = try std.json.parseFromSlice(
        Session,
        allocator,
        json_bytes,
        .{ .ignore_unknown_fields = true },
    );

    // Postconditions: required fields must be present after successful parsing.
    assert(parsed.value.session_id.len > 0);
    assert(parsed.value.transcript_path.len > 0);
    assert(parsed.value.cwd.len > 0);
    assert(parsed.value.model.id.len > 0);
    assert(parsed.value.model.display_name.len > 0);
    assert(parsed.value.workspace.current_dir.len > 0);
    assert(parsed.value.workspace.project_dir.len > 0);

    return parsed;
}

test "parse full JSON" {
    const allocator = std.testing.allocator;

    const mock_json =
        \\{
        \\  "session_id": "abc123",
        \\  "transcript_path": "/path/to/transcript",
        \\  "cwd": "/current/working/dir",
        \\  "model": {
        \\    "id": "claude-sonnet-4",
        \\    "display_name": "Claude Sonnet 4"
        \\  },
        \\  "workspace": {
        \\    "current_dir": "/workspace/current",
        \\    "project_dir": "/workspace/project"
        \\  },
        \\  "version": "1.0.0",
        \\  "output_style": {
        \\    "name": "default"
        \\  },
        \\  "cost": {
        \\    "total_cost_usd": 0.05,
        \\    "total_duration_ms": 5000,
        \\    "total_api_duration_ms": 3000,
        \\    "total_lines_added": 100,
        \\    "total_lines_removed": 50
        \\  },
        \\ "exceeds_200k_tokens": false
        \\}
    ;

    const parsed = try parse(allocator, mock_json);
    defer parsed.deinit();

    const session = parsed.value;

    try std.testing.expectEqualStrings("abc123", session.session_id);
    try std.testing.expectEqualStrings("claude-sonnet-4", session.model.id);
    try std.testing.expectEqualStrings("Claude Sonnet 4", session.model.display_name);
    try std.testing.expectEqualStrings("/workspace/current", session.workspace.current_dir);

    try std.testing.expectEqualStrings("default", session.output_style.?.name);

    // Assert the positive space: cost should be present in this test.
    try std.testing.expect(session.cost != null);
    if (session.cost) |cost| {
        try std.testing.expectEqual(@as(f64, 0.05), cost.total_cost_usd);
        try std.testing.expectEqual(@as(u64, 100), cost.total_lines_added);
        try std.testing.expectEqual(@as(u64, 50), cost.total_lines_removed);
    }
}

test "parse partial JSON" {
    const allocator = std.testing.allocator;

    const mock_json =
        \\{
        \\  "session_id": "abc123",
        \\  "transcript_path": "/path/to/transcript",
        \\  "cwd": "/current/working/dir",
        \\  "model": {
        \\    "id": "claude-sonnet-4",
        \\    "display_name": "Claude Sonnet 4"
        \\  },
        \\  "workspace": {
        \\    "current_dir": "/workspace/current",
        \\    "project_dir": "/workspace/project"
        \\  },
        \\  "version": "1.0.0",
        \\  "cost": {
        \\    "total_cost_usd": 0.05,
        \\    "total_duration_ms": 5000,
        \\    "total_api_duration_ms": 3000,
        \\    "total_lines_added": 100,
        \\    "total_lines_removed": 50
        \\  }
        \\}
    ;

    const parsed = try parse(allocator, mock_json);
    defer parsed.deinit();

    const session = parsed.value;

    try std.testing.expectEqualStrings("abc123", session.session_id);
    try std.testing.expectEqualStrings("claude-sonnet-4", session.model.id);
    try std.testing.expectEqualStrings("Claude Sonnet 4", session.model.display_name);
    try std.testing.expectEqualStrings("/workspace/current", session.workspace.current_dir);

    // Assert the positive space: cost should be present in this test.
    try std.testing.expect(session.cost != null);
    if (session.cost) |cost| {
        try std.testing.expectEqual(@as(f64, 0.05), cost.total_cost_usd);
        try std.testing.expectEqual(@as(u64, 100), cost.total_lines_added);
        try std.testing.expectEqual(@as(u64, 50), cost.total_lines_removed);
    }
}
