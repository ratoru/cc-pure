const std = @import("std");
const cc_pure = @import("cc_pure");

const GitContext = struct {
    arena: std.heap.ArenaAllocator,
    repo: ?cc_pure.git_status.Repository = null,

    pub fn init(child_allocator: std.mem.Allocator) GitContext {
        return .{ .arena = std.heap.ArenaAllocator.init(child_allocator) };
    }

    pub fn deinit(self: *GitContext) void {
        self.arena.deinit();
    }
};

const UsageContext = struct {
    arena: std.heap.ArenaAllocator,
    snapshot: ?cc_pure.usage.Snapshot = null,

    pub fn init(child_allocator: std.mem.Allocator) UsageContext {
        return .{ .arena = std.heap.ArenaAllocator.init(child_allocator) };
    }

    pub fn deinit(self: *UsageContext) void {
        self.arena.deinit();
    }
};

pub fn main() !void {
    // Setup Allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stdin_buf: [2048]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    var input_arena = std.heap.ArenaAllocator.init(allocator);
    defer input_arena.deinit();

    // We spawn this *before* parsing so it runs in the background immediately
    var git_ctx = GitContext.init(allocator);
    defer git_ctx.deinit();

    const git_thread = try std.Thread.spawn(.{}, fetchGit, .{&git_ctx});

    // Get claude info from stdin
    const raw_bytes = try stdin.takeDelimiterExclusive('\n');
    const bytes = try input_arena.allocator().dupe(u8, raw_bytes);

    const parsed = try cc_pure.claude.parse(input_arena.allocator(), bytes);
    const session = parsed.value;

    // Now that we have 'session', we can spawn the usage calculator
    var usage_ctx = UsageContext.init(allocator);
    defer usage_ctx.deinit();

    const usage_thread = try std.Thread.spawn(.{}, calcUsage, .{ &usage_ctx, session });

    // Join and Print
    git_thread.join();
    usage_thread.join();

    const repo = if (git_ctx.repo) |*r| r else null;
    try cc_pure.status_line.format(stdout, session, repo, usage_ctx.snapshot);

    try stdout.writeAll("\n");
    try stdout.flush();
}

// --- Worker Functions ---

fn fetchGit(ctx: *GitContext) void {
    const alloc = ctx.arena.allocator();
    ctx.repo = cc_pure.git_status.fetch_repository(alloc);
}

fn calcUsage(ctx: *UsageContext, session: cc_pure.claude.Session) void {
    const alloc = ctx.arena.allocator();
    const usage_tracker = cc_pure.usage.Tracker.init(.{});

    ctx.snapshot = usage_tracker.calculate(alloc, session.transcript_path, session.model.id) catch null;
}
