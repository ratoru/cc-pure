const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const process = std.process;

/// Repository represents the aggregated state of the git repo.
pub const Repository = struct {
    branch_name: []const u8,
    count_ahead: u64,
    count_behind: u64,
    is_dirty: bool,
    has_upstream: bool,

    /// Initialize with defaults (empty/zero).
    pub fn init(target: *Repository) void {
        target.* = .{
            .branch_name = &[_]u8{},
            .count_ahead = 0,
            .count_behind = 0,
            .is_dirty = false,
            .has_upstream = false,
        };
    }

    /// Caller must call this to free the branch_name string.
    pub fn deinit(self: *Repository, allocator: mem.Allocator) void {
        if (self.branch_name.len > 0) {
            allocator.free(self.branch_name);
            self.branch_name = &[_]u8{};
        }
    }
};

/// Fetches git status using a single subprocess.
///
/// - Runs: `git status --porcelain=v2 --branch`
/// - Logic: Synchronous (Blocking). The caller should run this in a thread.
/// - Memory: Owner must deinit the returned Repository to free branch_name.
pub fn fetch_repository(allocator: mem.Allocator) Repository {
    // 1. Setup Default State
    var repo: Repository = undefined;
    repo.init();

    // 2. Setup Environment
    // We catch errors here and return the empty repo (fail safe).
    var env_map = process.getEnvMap(allocator) catch return repo;
    defer env_map.deinit();

    env_map.put("GIT_OPTIONAL_LOCKS", "0") catch return repo;

    // 3. Run Command
    // --porcelain=v2: Easy to parse format
    // --branch: Adds headers for branch name and ahead/behind counts
    const argv = &[_][]const u8{ "git", "status", "--porcelain=v2", "--branch" };

    const result = process.Child.run(.{
        .argv = argv,
        .allocator = allocator,
        .env_map = &env_map,
    }) catch return repo;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    // 4. Parse Output
    parse_v2_output(allocator, &repo, result.stdout);

    return repo;
}

fn parse_v2_output(allocator: mem.Allocator, repo: *Repository, output: []const u8) void {
    var lines = mem.tokenizeScalar(u8, output, '\n');

    while (lines.next()) |line| {
        if (line.len < 2) continue;

        if (line[0] == '#') {
            // --- Header Parsing ---
            if (mem.startsWith(u8, line, "# branch.head ")) {
                const name = line["# branch.head ".len..];
                if (!mem.eql(u8, name, "(detached)")) {
                    repo.branch_name = allocator.dupe(u8, name) catch &[_]u8{};
                } else {
                    // Optional: Handle detached head explicitly if desired
                    repo.branch_name = allocator.dupe(u8, "DETACHED") catch &[_]u8{};
                }
            } else if (mem.startsWith(u8, line, "# branch.upstream ")) {
                repo.has_upstream = true;
            } else if (mem.startsWith(u8, line, "# branch.ab ")) {
                // Format: # branch.ab +5 -0
                var parts = mem.tokenizeScalar(u8, line["# branch.ab ".len..], ' ');
                const ahead_part = parts.next() orelse "+0";
                const behind_part = parts.next() orelse "-0";

                // Skip the '+' and '-' signs (index 1..)
                if (ahead_part.len > 1) {
                    repo.count_ahead = std.fmt.parseInt(u64, ahead_part[1..], 10) catch 0;
                }
                if (behind_part.len > 1) {
                    repo.count_behind = std.fmt.parseInt(u64, behind_part[1..], 10) catch 0;
                }
            }
        } else {
            // --- File Parsing ---
            // In V2, any line NOT starting with '#' is a file change (1, 2, ?, u).
            // If we see even ONE file line, the repo is dirty.
            repo.is_dirty = true;
            break;
        }
    }
}

// ============================================================================
// TESTS
// ============================================================================

const testing = std.testing;

test "parse clean repository aligned with upstream" {
    const allocator = testing.allocator;

    var repo: Repository = undefined;
    repo.init();
    defer repo.deinit(allocator);

    // Mock output from: git status --porcelain=v2 --branch
    const input =
        \\# branch.oid 9a99c7...
        \\# branch.head main
        \\# branch.upstream origin/main
        \\# branch.ab +0 -0
        \\
    ;

    parse_v2_output(allocator, &repo, input);

    try testing.expectEqualStrings("main", repo.branch_name);
    try testing.expectEqual(true, repo.has_upstream);
    try testing.expectEqual(0, repo.count_ahead);
    try testing.expectEqual(0, repo.count_behind);
    try testing.expectEqual(false, repo.is_dirty);
}

test "parse dirty repository (modified files)" {
    const allocator = testing.allocator;

    var repo: Repository = undefined;
    repo.init();
    defer repo.deinit(allocator);

    // '1 .M' indicates a modified file
    const input =
        \\# branch.head feature/login
        \\# branch.upstream origin/feature/login
        \\# branch.ab +0 -0
        \\1 .M N... 100644 100644 100644 ... src/main.zig
    ;

    parse_v2_output(allocator, &repo, input);

    try testing.expectEqualStrings("feature/login", repo.branch_name);
    try testing.expectEqual(true, repo.is_dirty);
}

test "parse dirty repository (untracked files)" {
    const allocator = testing.allocator;

    var repo: Repository = undefined;
    repo.init();
    defer repo.deinit(allocator);

    // '?' indicates untracked
    const input =
        \\# branch.head master
        \\? new_file.txt
    ;

    parse_v2_output(allocator, &repo, input);

    try testing.expectEqual(true, repo.is_dirty);
}

test "parse ahead and behind counts" {
    const allocator = testing.allocator;

    var repo: Repository = undefined;
    repo.init();
    defer repo.deinit(allocator);

    const input =
        \\# branch.head master
        \\# branch.upstream origin/master
        \\# branch.ab +5 -12
    ;

    parse_v2_output(allocator, &repo, input);

    try testing.expectEqual(5, repo.count_ahead);
    try testing.expectEqual(12, repo.count_behind);
}

test "parse no upstream (local branch)" {
    const allocator = testing.allocator;

    var repo: Repository = undefined;
    repo.init();
    defer repo.deinit(allocator);

    // No branch.upstream or branch.ab lines appear for local-only branches
    const input =
        \\# branch.head local-experiment
        \\# branch.oid 12345...
    ;

    parse_v2_output(allocator, &repo, input);

    try testing.expectEqualStrings("local-experiment", repo.branch_name);
    try testing.expectEqual(false, repo.has_upstream);
    try testing.expectEqual(0, repo.count_ahead);
}

test "parse detached head" {
    const allocator = testing.allocator;

    var repo: Repository = undefined;
    repo.init();
    defer repo.deinit(allocator);

    const input =
        \\# branch.oid deadbeef...
        \\# branch.head (detached)
        \\1 .M ...
    ;

    parse_v2_output(allocator, &repo, input);

    // Based on the logic: if "(detached)", set to "DETACHED"
    try testing.expectEqualStrings("DETACHED", repo.branch_name);
    try testing.expectEqual(true, repo.is_dirty);
}

test "parse empty output (not a git repo handling)" {
    const allocator = testing.allocator;

    var repo: Repository = undefined;
    repo.init();
    defer repo.deinit(allocator);

    const input = "";

    parse_v2_output(allocator, &repo, input);

    try testing.expectEqualStrings("", repo.branch_name);
    try testing.expectEqual(false, repo.is_dirty);
}
