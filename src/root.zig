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

/// Connection type for a given handler
pub fn ConnectionType(comptime HandlerType: type) type {
    return Server(HandlerType).Connection;
}

/// Thread-local storage for current server instance
threadlocal var current_server: ?*anyopaque = null;

fn getCurrentServer(comptime HandlerType: type) ?*Server(HandlerType) {
    const ptr = current_server orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Get all active connections
pub fn getAllConnections(comptime HandlerType: type) []*ConnectionType(HandlerType) {
    const server_ptr = getCurrentServer(HandlerType) orelse return &[_]*ConnectionType(HandlerType){};
    return server_ptr.connections.items;
}

/// Write data to a connection
pub fn writeToConnection(comptime HandlerType: type, conn: *ConnectionType(HandlerType), data: []const u8) !void {
    const server = getCurrentServer(HandlerType) orelse return error.NoServer;
    const c_write = server.allocator.create(xev.Completion) catch |err| {
        std.log.err("Failed to create write completion: {}", .{err});
        return err;
    };
    // Use the Server's internal writeCallback through a wrapper
    conn.socket.write(server.loop, c_write, .{ .slice = data }, ConnectionType(HandlerType), conn, writeCompletionWrapper(HandlerType));
}

fn writeCompletionWrapper(comptime HandlerType: type) fn (
    ?*Server(HandlerType).Connection,
    *xev.Loop,
    *xev.Completion,
    xev.TCP,
    xev.WriteBuffer,
    xev.WriteError!usize,
) xev.CallbackAction {
    const Connection = Server(HandlerType).Connection;
    return struct {
        fn callback(
            _: ?*Connection,
            _: *xev.Loop,
            c: *xev.Completion,
            _: xev.TCP,
            _: xev.WriteBuffer,
            result: xev.WriteError!usize,
        ) xev.CallbackAction {
            // Get allocator from global server reference, not through connection
            // (connection might be partially destroyed)
            const server = getCurrentServer(HandlerType);
            const allocator = if (server) |s| s.allocator else {
                // Server is gone, leak completion rather than crash
                return .disarm;
            };

            _ = result catch |err| {
                std.log.err("Write error: {}", .{err});
                allocator.destroy(c);
                return .disarm;
            };
            // Clean up the completion, connection is still active
            allocator.destroy(c);
            return .disarm;
        }
    }.callback;
}

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

    // Set thread-local server reference for handler access
    current_server = @ptrCast(&server);
    defer current_server = null;

    std.log.info("Server listening on {s}:{d}", .{ args.host, args.port });

    // Start accepting connections
    try server.start();

    // Run the loop until done
    try loop.run(.until_done);
}

// ============================================================================
// Handler Interface
// ============================================================================

/// Protocol mode for message framing
pub const ProtocolMode = union(enum) {
    /// Line-based protocol (messages delimited by \n)
    line_based,
    /// Binary protocol with fixed-size messages
    binary_fixed: usize,
};

/// Response from a handler
pub const HandlerResponse = struct {
    data: []const u8 = "",
    close_after_write: bool = false,
};

/// Handler interface that protocol implementations must provide
pub fn Handler(comptime Self: type) type {
    return struct {
        /// Protocol mode - defaults to line_based if not specified
        pub const protocol_mode: ProtocolMode =
            if (@hasDecl(Self, "protocol_mode")) Self.protocol_mode else .line_based;

        /// Called when a new connection is established
        /// Return HandlerResponse to accept and optionally send initial data
        /// Return null to reject the connection
        pub const onConnect: fn (self: *Self, allocator: std.mem.Allocator) ?HandlerResponse =
            if (@hasDecl(Self, "onConnect")) Self.onConnect else defaultOnConnect;

        /// Called when data is received
        /// Should return the response to send back
        /// Set close_after_write=true to disconnect after sending the response
        /// Return error to close the connection immediately without sending a response
        pub const onData: fn (self: *Self, allocator: std.mem.Allocator, data: []const u8) anyerror!HandlerResponse = Self.onData;

        /// Called when the connection is being closed
        pub const onClose: fn (self: *Self) anyerror!void =
            if (@hasDecl(Self, "onClose")) Self.onClose else defaultOnClose;

        fn defaultOnConnect(_: *Self, _: std.mem.Allocator) ?HandlerResponse {
            return .{};
        }

        fn defaultOnClose(_: *Self) !void {}
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

        /// Connection represents a single client connection with handler state
        pub const Connection = struct {
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
                // Register connection
                server.connections.append(server.allocator, conn) catch |err| {
                    allocator.free(line_buf);
                    allocator.destroy(conn);
                    return err;
                };
                return conn;
            }

            fn destroy(self: *Connection) !void {
                try Handler(HandlerType).onClose(&self.handler);
                // Unregister connection
                for (self.server.connections.items, 0..) |conn, i| {
                    if (conn == self) {
                        _ = self.server.connections.swapRemove(i);
                        break;
                    }
                }
                self.server.allocator.free(self.line_buffer);
                self.server.allocator.destroy(self);
            }

            /// Process a single message through the handler
            /// Returns false if the connection should be disarmed
            fn processMessage(
                self: *Connection,
                loop: *xev.Loop,
                c: *xev.Completion,
                socket: xev.TCP,
                message: []const u8,
            ) bool {
                // Process through the handler
                const handler_response = Handler(HandlerType).onData(&self.handler, self.server.allocator, message) catch |err| {
                    std.log.err("Handler error: {}", .{err});
                    socket.close(loop, c, Connection, self, closeCallback);
                    return false;
                };

                // Store whether to close after write
                self.close_after_write = handler_response.close_after_write;

                // If there's a response, write it back
                if (handler_response.data.len > 0) {
                    const c_write = self.server.allocator.create(xev.Completion) catch |err| {
                        std.log.err("Failed to create write completion: {}", .{err});
                        socket.close(loop, c, Connection, self, closeCallback);
                        return false;
                    };
                    socket.write(loop, c_write, .{ .slice = handler_response.data }, Connection, self, writeCallback);

                    // If closing after write, disarm now - writeCallback will handle the close
                    if (self.close_after_write) {
                        return false;
                    }
                } else if (self.close_after_write) {
                    // No response but should close
                    socket.close(loop, c, Connection, self, closeCallback);
                    return false;
                }

                return true;
            }
        };

        const ConnectionsList = std.ArrayListUnmanaged(*Connection);

        allocator: std.mem.Allocator,
        loop: *xev.Loop,
        socket: xev.TCP,
        connections: ConnectionsList,

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

            var result: Self = undefined;
            result.allocator = allocator;
            result.loop = loop;
            result.socket = socket;
            result.connections = .{};
            return result;
        }

        pub fn deinit(self: *Self) void {
            self.connections.deinit(self.allocator);
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
            const connect_response = Handler(HandlerType).onConnect(&conn.handler, self.allocator);
            if (connect_response == null) {
                std.log.info("Connection rejected by handler", .{});
                conn.destroy() catch |err| {
                    std.log.err("Error destroying connection: {}", .{err});
                };
                self.allocator.destroy(c);
                return .disarm;
            }

            std.log.info("New connection accepted", .{});

            // If there's initial data to send, write it
            if (connect_response.?.data.len > 0) {
                conn.close_after_write = connect_response.?.close_after_write;
                const c_write = self.allocator.create(xev.Completion) catch |err| {
                    std.log.err("Failed to create write completion: {}", .{err});
                    conn.socket.close(loop, c, Connection, conn, closeCallback);
                    return .disarm;
                };
                conn.socket.write(loop, c_write, .{ .slice = connect_response.?.data }, Connection, conn, writeCallback);
            }

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
                    conn.destroy() catch |destroy_err| {
                        std.log.err("Error destroying connection: {}", .{destroy_err});
                    };
                    return .disarm;
                },
            };

            if (bytes_read == 0) {
                std.log.info("Connection closed (0 bytes)", .{});
                socket.close(loop, c, Connection, conn, closeCallback);
                return .disarm;
            }

            std.log.debug("Read {} bytes", .{bytes_read});

            // Append new data to buffer
            if (conn.line_buffer_len + bytes_read > conn.line_buffer.len) {
                std.log.err("Buffer overflow", .{});
                socket.close(loop, c, Connection, conn, closeCallback);
                return .disarm;
            }
            @memcpy(conn.line_buffer[conn.line_buffer_len..][0..bytes_read], buffer.slice[0..bytes_read]);
            conn.line_buffer_len += bytes_read;

            // Process messages based on protocol mode
            const protocol_mode = Handler(HandlerType).protocol_mode;
            var processed_until: usize = 0;

            switch (protocol_mode) {
                .line_based => {
                    // Process all complete lines (delimited by \n)
                    while (std.mem.indexOfScalarPos(u8, conn.line_buffer[0..conn.line_buffer_len], processed_until, '\n')) |newline_pos| {
                        // Extract the line (including the newline)
                        const line = conn.line_buffer[processed_until .. newline_pos + 1];
                        std.log.info("Processing line: {s}", .{std.mem.trimRight(u8, line, "\n\r")});

                        // Process through handler
                        if (!conn.processMessage(loop, c, socket, line)) {
                            return .disarm;
                        }

                        processed_until = newline_pos + 1;
                    }
                },
                .binary_fixed => |message_size| {
                    // Process all complete fixed-size messages
                    while (processed_until + message_size <= conn.line_buffer_len) {
                        const message = conn.line_buffer[processed_until .. processed_until + message_size];
                        std.log.debug("Processing binary message of {} bytes", .{message_size});

                        // Process through handler
                        if (!conn.processMessage(loop, c, socket, message)) {
                            return .disarm;
                        }

                        processed_until += message_size;
                    }
                },
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
                conn.destroy() catch |destroy_err| {
                    std.log.err("Error destroying connection: {}", .{destroy_err});
                };
                return .disarm;
            };

            std.log.info("Connection closed successfully", .{});

            // Clean up the completion and connection
            conn.server.allocator.destroy(c);
            conn.destroy() catch |err| {
                std.log.err("Error destroying connection: {}", .{err});
            };
            return .disarm;
        }
    };
}
