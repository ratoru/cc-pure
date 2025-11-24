//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

pub const claude = @import("claude.zig");
pub const status_line = @import("status_line.zig");
pub const git_status = @import("git_status.zig");
pub const theme = @import("theme.zig");
pub const usage = @import("usage.zig");
pub const directory = @import("directory.zig");

test {
    _ = @import("status_line.zig");
    _ = @import("claude.zig");
    _ = @import("git_status.zig");
    _ = @import("theme.zig");
    _ = @import("usage.zig");
    _ = @import("directory.zig");
}
