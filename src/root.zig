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
pub fn run(allocator: std.mem.Allocator, comptime HandlerType: type) !void {
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

/// Response from a handler
pub const HandlerResponse = struct {
    data: []const u8,
    close_after_write: bool = true,
};

/// Handler interface that protocol implementations must provide
pub fn Handler(comptime Self: type) type {
    return struct {
        /// Called when a new connection is established
        /// Return true to accept the connection, false to reject it
        pub const onConnect: fn (self: *Self) bool =
            if (@hasDecl(Self, "onConnect")) Self.onConnect else defaultOnConnect;

        /// Called when data is received
        /// Should return the response to send back
        /// Set close_after_write=true to disconnect after sending the response
        /// Return error to close the connection immediately without sending a response
        pub const onData: fn (self: *Self, allocator: std.mem.Allocator, data: []const u8) anyerror!HandlerResponse = Self.onData;

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
            line_buffer: []u8,
            line_buffer_len: usize,
            server: *Self,
            handler: HandlerType,
            close_after_write: bool = false,

            fn create(allocator: std.mem.Allocator, socket: xev.TCP, server: *Self) !*Connection {
                const conn = try allocator.create(Connection);
                const line_buf = try allocator.alloc(u8, 1024 * 1024);
                conn.socket = socket;
                conn.buffer = undefined;
                conn.line_buffer = line_buf;
                conn.line_buffer_len = 0;
                conn.server = server;
                conn.handler = .{};
                conn.close_after_write = false;
                return conn;
            }

            fn destroy(self: *Connection) void {
                Handler(HandlerType).onClose(&self.handler);
                self.server.allocator.free(self.line_buffer);
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

            // Append new data to line buffer
            if (conn.line_buffer_len + bytes_read > conn.line_buffer.len) {
                std.log.err("Line buffer overflow", .{});
                socket.close(loop, c, Connection, conn, closeCallback);
                return .disarm;
            }
            @memcpy(conn.line_buffer[conn.line_buffer_len..][0..bytes_read], buffer.slice[0..bytes_read]);
            conn.line_buffer_len += bytes_read;

            // Process all complete lines
            var processed_until: usize = 0;
            while (std.mem.indexOfScalarPos(u8, conn.line_buffer[0..conn.line_buffer_len], processed_until, '\n')) |newline_pos| {
                // Extract the line (including the newline)
                const line = conn.line_buffer[processed_until .. newline_pos + 1];
                std.log.info("Processing line: {s}", .{std.mem.trimRight(u8, line, "\n\r")});

                // Process the line through the handler
                const handler_response = Handler(HandlerType).onData(&conn.handler, conn.server.allocator, line) catch |err| {
                    std.log.err("Handler error: {}", .{err});
                    socket.close(loop, c, Connection, conn, closeCallback);
                    return .disarm;
                };

                processed_until = newline_pos + 1;

                // Store whether to close after write
                conn.close_after_write = handler_response.close_after_write;

                // If there's a response, write it back
                if (handler_response.data.len > 0) {
                    const c_write = conn.server.allocator.create(xev.Completion) catch |err| {
                        std.log.err("Failed to create write completion: {}", .{err});
                        socket.close(loop, c, Connection, conn, closeCallback);
                        return .disarm;
                    };
                    socket.write(loop, c_write, .{ .slice = handler_response.data }, Connection, conn, writeCallback);

                    // If closing after write, disarm now - writeCallback will handle the close
                    if (conn.close_after_write) {
                        return .disarm;
                    }
                } else if (conn.close_after_write) {
                    // No response but should close
                    socket.close(loop, c, Connection, conn, closeCallback);
                    return .disarm;
                }
            }

            // Remove processed data from buffer
            if (processed_until > 0) {
                const remaining = conn.line_buffer_len - processed_until;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, conn.line_buffer[0..remaining], conn.line_buffer[processed_until..conn.line_buffer_len]);
                }
                conn.line_buffer_len = remaining;
            }

            // Continue reading (rearm)
            return .rearm;
        }

        /// Called when data is written to a connection
        fn writeCallback(
            conn_: ?*Connection,
            loop: *xev.Loop,
            c: *xev.Completion,
            socket: xev.TCP,
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

            // Check if we should close after writing
            if (conn.close_after_write) {
                std.log.info("Closing connection after write", .{});
                socket.close(loop, c, Connection, conn, closeCallback);
                return .disarm;
            }

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
