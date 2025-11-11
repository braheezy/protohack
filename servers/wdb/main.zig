// ============================================================================
// Weird DB Server - Protohackers Challenge #0
// ============================================================================
// This demonstrates the minimal code needed to implement a server using
// the framework. Just implement a Handler with an onData() method!

const std = @import("std");
const builtin = @import("builtin");
const server = @import("server");

var db: std.StringArrayHashMap([]const u8) = undefined;
var db_allocator: std.mem.Allocator = undefined;

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

    db_allocator = allocator;
    db = std.StringArrayHashMap([]const u8).init(allocator);

    try server.run(allocator, WdbHandler);
}

// ============================================================================
// Handler Implementation
// ============================================================================

const WdbHandler = struct {
    pub const protocol = .udp;

    pub fn onDatagram(_: *WdbHandler, al: std.mem.Allocator, data: []const u8, _: std.net.Address) !?[]const u8 {
        if (data.len > 1000) {
            return null; // ignore too large packets
        }
        std.debug.print("=== Received datagram: len={d} ===\n", .{data.len});

        if (std.mem.containsAtLeastScalar(u8, data, 1, '=')) {
            // insert/update - split first, don't trim (values can have newlines)
            var iter = std.mem.splitScalar(u8, data, '=');
            const first = iter.first();
            const second = iter.rest();
            std.debug.print("first: '{s}', second: '{s}'\n", .{ first, second });
            // Don't allow updating the version key
            if (std.mem.eql(u8, first, "version")) {
                return null; // Ignore attempts to update version
            }

            // Must duplicate strings since they're slices into a reused buffer
            const gop = try db.getOrPut(first);
            if (!gop.found_existing) {
                // New key - duplicate the key that's currently pointing to temp buffer
                gop.key_ptr.* = try db_allocator.dupe(u8, first);
                gop.value_ptr.* = try db_allocator.dupe(u8, second);
            } else {
                // Updating existing key - free old value first
                db_allocator.free(gop.value_ptr.*);
                gop.value_ptr.* = try db_allocator.dupe(u8, second);
            }
            return null;
        } else {
            // query - trim the key for queries
            const key = std.mem.trimEnd(u8, data, " \r\t\n");
            std.debug.print("query: '{s}'\n", .{key});
            const result = if (std.mem.eql(u8, key, "version"))
                "weirddb-0.1.0"
            else
                db.get(key) orelse "";

            const response = try std.fmt.allocPrint(al, "{s}={s}", .{ key, result });
            std.debug.print("sending response: '{s}' (len={d})\n", .{ response, response.len });
            return response;
        }
    }
};
