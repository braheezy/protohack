// ============================================================================
// Generic TCP Server Framework
// ============================================================================
// This module provides a complete TCP server framework built on libxev.
// To use it, just implement a Handler and call server.run(YourHandler).

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");

// ============================================================================
// Public API
// ============================================================================

/// Run a TCP server with the given handler type
pub fn run(comptime HandlerType: type) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

    // Memory allocation setup
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

    // Parse command line arguments
    const args = try parseArgs(allocator);
    defer allocator.free(args.host);

    // Initialize thread pool (required for kqueue on macOS)
    var thread_pool = xev.ThreadPool.init(.{});
    defer thread_pool.deinit();
    defer thread_pool.shutdown();

    // Initialize the event loop with the thread pool
    var loop = try xev.Loop.init(.{
        .thread_pool = &thread_pool,
    });
    defer loop.deinit();

    // Create the server with the handler
    var server = try Server(HandlerType).init(allocator, &loop, args.host, args.port);
    defer server.deinit();

    std.log.info("Server listening on {s}:{d}", .{ args.host, args.port });

    // Start accepting connections
    try server.start();

    // Run the loop until done
    try loop.run(.until_done);
}

// ============================================================================
// Handler Interface
// ============================================================================

/// Handler interface that protocol implementations must provide
pub fn Handler(comptime Self: type) type {
    return struct {
        /// Called when a new connection is established
        /// Return true to accept the connection, false to reject it
        pub const onConnect: fn (self: *Self) bool =
            if (@hasDecl(Self, "onConnect")) Self.onConnect else defaultOnConnect;

        /// Called when data is received
        /// Should return the response to send back (can be empty slice for no response)
        /// Return error to close the connection
        pub const onData: fn (self: *Self, data: []const u8) anyerror![]const u8 = Self.onData;

        /// Called when the connection is being closed
        pub const onClose: fn (self: *Self) void =
            if (@hasDecl(Self, "onClose")) Self.onClose else defaultOnClose;

        fn defaultOnConnect(_: *Self) bool {
            return true;
        }

        fn defaultOnClose(_: *Self) void {}
    };
}

// ============================================================================
// Internal Implementation
// ============================================================================

const Args = struct {
    host: []const u8,
    port: u16,
};

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.skip();

    var host: ?[]const u8 = null;
    var port: u16 = 3000; // default port (for protohackers)

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host") or std.mem.eql(u8, arg, "-h")) {
            if (args.next()) |h| {
                host = try allocator.dupe(u8, h);
            } else {
                std.log.err("Missing value for --host", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (args.next()) |p| {
                port = std.fmt.parseInt(u16, p, 10) catch {
                    std.log.err("Invalid port: {s}", .{p});
                    std.process.exit(1);
                };
            } else {
                std.log.err("Missing value for --port", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\Usage: server [options]
                \\
                \\Options:
                \\  -h, --host <address>  Listen address (default: 0.0.0.0)
                \\  -p, --port <port>     Listen port (default: 3000)
                \\  --help                Show this help message
                \\
            , .{});
            std.process.exit(0);
        }
    }

    return Args{
        .host = host orelse try allocator.dupe(u8, "0.0.0.0"),
        .port = port,
    };
}

/// Generic TCP server that works with any Handler
fn Server(comptime HandlerType: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        loop: *xev.Loop,
        socket: xev.TCP,

        /// Connection represents a single client connection with handler state
        const Connection = struct {
            socket: xev.TCP,
            buffer: [4096]u8,
            server: *Self,
            handler: HandlerType,

            fn create(allocator: std.mem.Allocator, socket: xev.TCP, server: *Self) !*Connection {
                const conn = try allocator.create(Connection);
                conn.* = .{
                    .socket = socket,
                    .buffer = undefined,
                    .server = server,
                    .handler = .{},
                };
                return conn;
            }

            fn destroy(self: *Connection) void {
                Handler(HandlerType).onClose(&self.handler);
                self.server.allocator.destroy(self);
            }
        };

        pub fn init(allocator: std.mem.Allocator, loop: *xev.Loop, host: []const u8, port: u16) !Self {
            // Parse the address - try IPv4 first, then IPv6
            const addr = std.net.Address.parseIp4(host, port) catch
                std.net.Address.parseIp6(host, port) catch {
                std.log.err("Invalid host address: {s}", .{host});
                return error.InvalidAddress;
            };

            // Create a TCP socket
            var socket = try xev.TCP.init(addr);

            // Bind to the address and start listening
            try socket.bind(addr);
            try socket.listen(128); // backlog of 128 connections

            return .{
                .allocator = allocator,
                .loop = loop,
                .socket = socket,
            };
        }

        pub fn deinit(_: *Self) void {
            // Cleanup is handled by loop.deinit()
        }

        /// Start accepting connections
        pub fn start(self: *Self) !void {
            const c = try self.allocator.create(xev.Completion);
            self.socket.accept(self.loop, c, Self, self, acceptCallback);
        }

        /// Called when a new connection is accepted
        fn acceptCallback(
            self_: ?*Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            result: xev.AcceptError!xev.TCP,
        ) xev.CallbackAction {
            const self = self_.?;

            // Get the new socket
            const client_socket = result catch |err| {
                std.log.err("Accept error: {}", .{err});
                self.allocator.destroy(c);
                return .disarm;
            };

            // Create a connection object to track this client
            const conn = Connection.create(self.allocator, client_socket, self) catch |err| {
                std.log.err("Failed to create connection: {}", .{err});
                self.allocator.destroy(c);
                return .disarm;
            };

            // Call the handler's onConnect
            if (!Handler(HandlerType).onConnect(&conn.handler)) {
                std.log.info("Connection rejected by handler", .{});
                conn.destroy();
                self.allocator.destroy(c);
                return .disarm;
            }

            std.log.info("New connection accepted", .{});

            // Start reading from this connection (reuse the completion)
            conn.socket.read(loop, c, .{ .slice = &conn.buffer }, Connection, conn, readCallback);

            // Accept the next connection (need a new completion)
            const c_accept = self.allocator.create(xev.Completion) catch |err| {
                std.log.err("Failed to create completion: {}", .{err});
                return .disarm;
            };
            self.socket.accept(loop, c_accept, Self, self, acceptCallback);

            return .disarm;
        }

        /// Called when data is read from a connection
        fn readCallback(
            conn_: ?*Connection,
            loop: *xev.Loop,
            c: *xev.Completion,
            socket: xev.TCP,
            buffer: xev.ReadBuffer,
            result: xev.ReadError!usize,
        ) xev.CallbackAction {
            const conn = conn_.?;

            const bytes_read = result catch |err| switch (err) {
                error.EOF => {
                    std.log.info("Connection closed by client", .{});
                    socket.close(loop, c, Connection, conn, closeCallback);
                    return .disarm;
                },
                else => {
                    std.log.err("Read error: {}", .{err});
                    conn.server.allocator.destroy(c);
                    conn.destroy();
                    return .disarm;
                },
            };

            if (bytes_read == 0) {
                std.log.info("Connection closed (0 bytes)", .{});
                socket.close(loop, c, Connection, conn, closeCallback);
                return .disarm;
            }

            std.log.debug("Read {} bytes", .{bytes_read});

            // Process the data through the handler
            const response = Handler(HandlerType).onData(&conn.handler, buffer.slice[0..bytes_read]) catch |err| {
                std.log.err("Handler error: {}", .{err});
                socket.close(loop, c, Connection, conn, closeCallback);
                return .disarm;
            };

            // If there's a response, write it back
            if (response.len > 0) {
                const c_write = conn.server.allocator.create(xev.Completion) catch |err| {
                    std.log.err("Failed to create write completion: {}", .{err});
                    socket.close(loop, c, Connection, conn, closeCallback);
                    return .disarm;
                };
                socket.write(loop, c_write, .{ .slice = response }, Connection, conn, writeCallback);
            }

            // Continue reading (rearm)
            return .rearm;
        }

        /// Called when data is written to a connection
        fn writeCallback(
            conn_: ?*Connection,
            _: *xev.Loop,
            c: *xev.Completion,
            _: xev.TCP,
            _: xev.WriteBuffer,
            result: xev.WriteError!usize,
        ) xev.CallbackAction {
            const conn = conn_.?;

            const bytes_written = result catch |err| {
                std.log.err("Write error: {}", .{err});
                conn.server.allocator.destroy(c);
                return .disarm;
            };

            std.log.debug("Wrote {} bytes", .{bytes_written});

            // We're done with this write completion
            conn.server.allocator.destroy(c);
            return .disarm;
        }

        /// Called when a connection is closed
        fn closeCallback(
            conn_: ?*Connection,
            _: *xev.Loop,
            c: *xev.Completion,
            _: xev.TCP,
            result: xev.CloseError!void,
        ) xev.CallbackAction {
            const conn = conn_.?;

            result catch |err| {
                std.log.err("Close error: {}", .{err});
                conn.server.allocator.destroy(c);
                conn.destroy();
                return .disarm;
            };

            std.log.info("Connection closed successfully", .{});

            // Clean up the completion and connection
            conn.server.allocator.destroy(c);
            conn.destroy();
            return .disarm;
        }
    };
}
