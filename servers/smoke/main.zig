// ============================================================================
// Echo Server - Protohackers Challenge #0
// ============================================================================
// This demonstrates the minimal code needed to implement a server using
// the framework. Just implement a Handler with an onData() method!

const std = @import("std");
const server = @import("server");

pub fn main() !void {
    try server.run(EchoHandler);
}

// ============================================================================
// Handler Implementation
// ============================================================================

const EchoHandler = struct {
    // No per-connection state needed for echo server

    /// Echo back whatever we receive
    pub fn onData(_: *EchoHandler, data: []const u8) ![]const u8 {
        std.log.info("Echoing {} bytes: {s}", .{ data.len, data });
        return data;
    }
};
