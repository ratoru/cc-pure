const std = @import("std");
const assert = std.debug.assert;

/// Maximum length for the formatted cwd output.
const max_cwd_length: u32 = 300;
const component_limit: u32 = 3;

/// Formats the current working directory to show up to 3 folders deep.
/// If 3 components exceed 300 chars, shows 2 components instead.
/// For example: /home/user/projects/myapp becomes user/projects/myapp
/// Returns a slice of the original cwd string.
pub fn simplify(cwd: []const u8, home_env: ?[]const u8) []const u8 {
    assert(cwd.len <= std.math.maxInt(u32));
    const sep = std.fs.path.sep;

    var relative_cwd_idx: u32 = 0;

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
    var end_no_slash: u32 = @intCast(cwd.len);
    if (end_no_slash > 1 and cwd[end_no_slash - 1] == sep) {
        end_no_slash -= 1;
    }

    // We track the start indices of the last 3 segments.
    // candidate_starts[0] will hold the start of the 1st-from-last segment (depth 1).
    // candidate_starts[1] will hold the start of the 2nd-from-last segment (depth 2).
    // candidate_starts[2] will hold the start of the 3rd-from-last segment (depth 3).
    var candidate_starts = [_]u32{0} ** component_limit;
    var segments_found: u32 = 0;

    // Scan backwards from the logical end of the string.
    for (relative_cwd_idx..end_no_slash) |step| {
        const i: u32 = end_no_slash - @as(u32, @intCast(step)) - 1 + relative_cwd_idx;
        // If we find a separator, the segment starts at this separator index.
        // (We include the separator in the output, e.g., "/project" rather than "project").
        if (cwd[i] == sep or i == relative_cwd_idx) {
            // Record this position as a candidate start point.
            if (segments_found < component_limit) {
                candidate_starts[segments_found] = i;
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
        // In this case, start_idx might point to the separator '/'.
        // We want to skip this separator to avoid implying the path is at root.
        // If raw_start == 0, we are including the entire string (absolute or relative), so we keep it as is.
        if (start_idx > 0 and cwd[start_idx] == sep) {
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

test "simplify with home" {
    const result = simplify("~/user", null);
    try std.testing.expectEqualStrings("~/user", result);
}

test "simplify with 2 components" {
    const result = simplify("/home/user", null);
    try std.testing.expectEqualStrings("/home/user", result);
}
test "simplify with exactly 3 components" {
    const result = simplify("/home/user/projects", null);
    try std.testing.expectEqualStrings("/home/user/projects", result);
}

test "simplify with 4 components shows last 3" {
    const result = simplify("/home/user/projects/myapp", null);
    try std.testing.expectEqualStrings("user/projects/myapp", result);
}

test "simplify with many components shows last 3" {
    const result = simplify("~/home/user/projects/myapp/src/components/", null);
    try std.testing.expectEqualStrings("myapp/src/components/", result);
}

test "simplify with single component" {
    const result = simplify("/root", null);
    try std.testing.expectEqualStrings("/root", result);
}

test "simplify with trailing slash" {
    const result = simplify("/home/user/projects/myapp/", null);
    try std.testing.expectEqualStrings("user/projects/myapp/", result);
}

test "simplify respects max length with 3 components" {
    // Create a path where 3 components exceed 300 chars but 2 components fit.
    const long_name = "a" ** 200;
    var buffer: [500]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "/short/{s}/{s}", .{ long_name, long_name });

    const result = simplify(path, null);

    // Should fall back to 2 components since 3 would exceed 300 chars.
    try std.testing.expect(result.len <= max_cwd_length);
    // Should not include the first "short" component.
    try std.testing.expect(std.mem.indexOf(u8, result, "short") == null);
}

test "simplify with relative path" {
    const result = simplify("home/user/projects/myapp", null);
    try std.testing.expectEqualStrings("user/projects/myapp", result);
}

test "simplify handles irrelevant HOME variable" {
    const result = simplify("home/user/projects/myapp", "/s/d/f");
    try std.testing.expectEqualStrings("user/projects/myapp", result);
}

test "simplify handles HOME without slash" {
    const result = simplify("/home/user1/projects/myapp", "/home/user1");
    try std.testing.expectEqualStrings("projects/myapp", result);
}

test "simplify handles HOME with slash" {
    const result = simplify("/home/user1/projects/myapp", "/home/user1/");
    try std.testing.expectEqualStrings("projects/myapp", result);
}
