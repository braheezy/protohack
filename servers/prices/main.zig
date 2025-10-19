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

    try server.run(allocator, PricesHandler);
}

// ============================================================================
// Handler Implementation
// ============================================================================

const PricesHandler = struct {
    asset: std.AutoHashMap(i32, i32) = undefined,

    // Specify binary protocol with 9-byte fixed messages
    pub const protocol_mode: server.ProtocolMode = .{ .binary_fixed = 9 };

    pub fn onConnect(self: *PricesHandler, allocator: std.mem.Allocator) bool {
        self.asset = std.AutoHashMap(i32, i32).init(allocator);
        return true;
    }

    pub fn onClose(self: *PricesHandler) void {
        self.asset.deinit();
    }

    pub fn onData(self: *PricesHandler, allocator: std.mem.Allocator, data: []const u8) !server.HandlerResponse {
        // Ensure we have exactly 9 bytes
        if (data.len != 9) {
            std.log.err("Invalid message length: {d}", .{data.len});
            return error.InvalidMessage;
        }

        // Parse message type
        switch (data[0]) {
            'I' => {
                // Insert: timestamp (4 bytes) + price (4 bytes)
                const timestamp = std.mem.readInt(i32, data[1..5], .big);
                const price = std.mem.readInt(i32, data[5..9], .big);

                try self.asset.put(timestamp, price);

                std.log.info("Insert: timestamp={d}, price={d}", .{ timestamp, price });

                // Insert has no response - keep connection open
                return .{ .data = "", .close_after_write = false };
            },
            'Q' => {
                // query
                const mintime = std.mem.readInt(i32, data[1..5], .big);
                const maxtime = std.mem.readInt(i32, data[5..9], .big);
                std.log.info("Query: mintime={d}, maxtime={d}", .{ mintime, maxtime });
                const mean = try allocator.alloc(u8, 4);
                std.mem.writeInt(i32, mean[0..4], self.calculateMean(mintime, maxtime), .big);
                return .{ .data = mean, .close_after_write = false };
            },
            else => {
                // undefined behavior
                std.log.info("Undefined behavior: {s}", .{data});
                return .{ .data = "undefined\n" };
            },
        }
        return .{ .data = "malformed\n" };
    }

    fn calculateMean(self: *PricesHandler, mintime: i32, maxtime: i32) i32 {
        if (mintime > maxtime) return 0;
        var sum: i64 = 0;
        var count: i64 = 0;

        var it = self.asset.iterator();
        while (it.next()) |entry| {
            const timestamp = entry.key_ptr.*;
            const price = entry.value_ptr.*;
            if (timestamp >= mintime and timestamp <= maxtime) {
                std.log.info("Calculating mean: timestamp={d}, price={d}", .{ timestamp, price });
                sum += price;
                count += 1;
            }
        }
        if (count == 0) return 0;
        std.log.info("Mean: sum={d}, count={d}", .{ sum, count });
        return @intCast(@divTrunc(sum, count));
    }
};
