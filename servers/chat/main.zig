// ============================================================================
// Chat Server - Protohackers Challenge #3
// ============================================================================

const std = @import("std");
const builtin = @import("builtin");
const server = @import("server");

const greeting = "State your name, mortal.\n";

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

    try server.run(allocator, ChatHandler);
}

// ============================================================================
// Handler Implementation
// ============================================================================

const ChatHandler = struct {
    allocator: std.mem.Allocator = undefined,
    joined: bool = false,
    name: []const u8 = undefined,

    pub fn onConnect(self: *ChatHandler, allocator: std.mem.Allocator) ?server.HandlerResponse {
        self.allocator = allocator;
        return .{ .data = greeting, .close_after_write = false };
    }

    pub fn onData(self: *ChatHandler, allocator: std.mem.Allocator, data: []const u8) !server.HandlerResponse {
        if (!self.joined) {
            const name = trimWhitespace(data);
            if (!isNameValid(name)) {
                return .{ .data = "* invalid name\n", .close_after_write = true };
            }
            self.name = try allocator.dupe(u8, name);
            self.joined = true;
            std.log.info("User {s} joined", .{self.name});

            try self.broadcast(try std.fmt.allocPrint(allocator, "* {s} is here.\n", .{self.name}));

            const other_clients = try self.getOtherClients(allocator);
            return .{ .data = try std.fmt.allocPrint(allocator, "* Users online: {s}\n", .{try std.mem.join(allocator, ", ", other_clients)}), .close_after_write = false };
        }
        const message = trimWhitespace(data);
        try self.broadcast(try std.fmt.allocPrint(allocator, "[{s}] {s}\n", .{ self.name, message }));
        return .{};
    }

    pub fn onClose(self: *ChatHandler) !void {
        if (self.joined) {
            try self.broadcast(try std.fmt.allocPrint(self.allocator, "* {s} has left.\n", .{self.name}));
            self.allocator.free(self.name);
        }
    }

    fn broadcast(self: *ChatHandler, message: []const u8) !void {
        const connections = server.getAllConnections(ChatHandler);
        for (connections) |conn| {
            if (conn.handler.joined and !std.mem.eql(u8, conn.handler.name, self.name)) {
                // Verify connection is still in the list before writing
                // (defensive check against race conditions)
                const current_connections = server.getAllConnections(ChatHandler);
                const still_valid = for (current_connections) |c| {
                    if (c == conn) break true;
                } else false;

                if (!still_valid) continue;

                // Ignore write errors - connection might be closing
                server.writeToConnection(ChatHandler, conn, message) catch |err| {
                    std.log.debug("Failed to write to connection: {}", .{err});
                    continue;
                };
            }
        }
    }

    fn getOtherClients(self: *ChatHandler, allocator: std.mem.Allocator) ![]const []const u8 {
        var other_clients = std.ArrayList([]const u8).empty;
        for (server.getAllConnections(ChatHandler)) |conn| {
            if (conn.handler.joined and !std.mem.eql(u8, conn.handler.name, self.name)) {
                try other_clients.append(allocator, conn.handler.name);
            }
        }
        return other_clients.toOwnedSlice(allocator);
    }
};

fn isNameValid(name: []const u8) bool {
    if (name.len > 32) return false;

    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            std.log.info("Invalid character: {c}", .{c});
            std.log.info("isWhitespace: {any}", .{std.ascii.isWhitespace(c)});
            return false;
        }
    }
    return true;
}

fn trimWhitespace(name: []const u8) []const u8 {
    return std.mem.trimEnd(u8, name, " \t\n\r");
}
