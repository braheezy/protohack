// ============================================================================
// Echo Server - Protohackers Challenge #0
// ============================================================================
// This demonstrates the minimal code needed to implement a server using
// the framework. Just implement a Handler with an onData() method!

const std = @import("std");
const builtin = @import("builtin");
const server = @import("server");

pub fn main() !void {
    // Setup allocator
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

    const allocator, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        if (debug_allocator.deinit() == .leak) {
            std.process.exit(1);
        }
    };

    try server.run(allocator, EchoHandler);
}

// ============================================================================
// Handler Implementation
// ============================================================================

const EchoHandler = struct {
    // No per-connection state needed for echo server

    /// Echo back whatever we receive
    pub fn onData(_: *EchoHandler, _: std.mem.Allocator, data: []const u8) !server.HandlerResponse {
        std.log.info("Echoing {d} bytes: {s}", .{ data.len, data });
        return .{ .data = data };
    }
};
