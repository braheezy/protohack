// ============================================================================
// Generic TCP/UDP Server Framework
// ============================================================================
// This module provides a complete server framework built on libxev supporting
// both TCP and UDP protocols. To use it, implement a Handler and call
// server.run(YourHandler).

const std = @import("std");
const builtin = @import("builtin");
const xev = @import("xev");

// ============================================================================
// Public API
// ============================================================================

/// Connection type for a given handler (TCP only)
pub fn ConnectionType(comptime HandlerType: type) type {
    return TCPServer(HandlerType).Connection;
}

/// Thread-local storage for current server instance
threadlocal var current_server: ?*anyopaque = null;

fn getCurrentServer(comptime HandlerType: type) ?*TCPServer(HandlerType) {
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
    ?*TCPServer(HandlerType).Connection,
    *xev.Loop,
    *xev.Completion,
    xev.TCP,
    xev.WriteBuffer,
    xev.WriteError!usize,
) xev.CallbackAction {
    const Connection = TCPServer(HandlerType).Connection;
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

/// Run a server with the given handler type (dispatches to TCP or UDP based on handler.protocol)
pub fn run(allocator: std.mem.Allocator, comptime HandlerType: type) !void {
    const protocol = Handler(HandlerType).protocol;

    switch (protocol) {
        .tcp => try runTCP(allocator, HandlerType),
        .udp => try runUDP(allocator, HandlerType),
    }
}

/// Run a TCP server with the given handler type
fn runTCP(allocator: std.mem.Allocator, comptime HandlerType: type) !void {
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
    var server = try TCPServer(HandlerType).init(allocator, &loop, args.host, args.port);
    defer server.deinit();

    // Set thread-local server reference for handler access
    current_server = @ptrCast(&server);
    defer current_server = null;

    std.log.info("TCP Server listening on {s}:{d}", .{ args.host, args.port });

    // Start accepting connections
    try server.start();

    // Run the loop until done
    try loop.run(.until_done);
}

/// Run a UDP server with the given handler type
fn runUDP(allocator: std.mem.Allocator, comptime HandlerType: type) !void {
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
    var server = try UDPServer(HandlerType).init(allocator, &loop, args.host, args.port);
    defer server.deinit();

    std.log.info("UDP Server listening on {s}:{d}", .{ args.host, args.port });

    // Start receiving datagrams
    try server.start();

    // Run the loop until done
    try loop.run(.until_done);
}

// ============================================================================
// Handler Interface
// ============================================================================

/// Network protocol type
pub const Protocol = enum {
    tcp,
    udp,
};

/// Protocol mode for message framing (TCP only)
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
    heartbeat_interval_ms: ?u64 = null,
};

/// Handler interface that protocol implementations must provide
pub fn Handler(comptime Self: type) type {
    return struct {
        /// Protocol type - defaults to TCP if not specified
        pub const protocol: Protocol =
            if (@hasDecl(Self, "protocol")) Self.protocol else .tcp;

        /// Protocol mode - defaults to line_based if not specified (TCP only)
        pub const protocol_mode: ProtocolMode =
            if (@hasDecl(Self, "protocol_mode")) Self.protocol_mode else .line_based;

        // ====================================================================
        // TCP Handler Interface
        // ====================================================================

        /// Called when a new connection is established (TCP only)
        /// Return HandlerResponse to accept and optionally send initial data
        /// Return null to reject the connection
        pub const onConnect: fn (self: *Self, allocator: std.mem.Allocator) ?HandlerResponse =
            if (@hasDecl(Self, "onConnect")) Self.onConnect else defaultOnConnect;

        /// Called when data is received (TCP only)
        /// Should return the response to send back
        /// Set close_after_write=true to disconnect after sending the response
        /// Return error to close the connection immediately without sending a response
        pub const onData: fn (self: *Self, allocator: std.mem.Allocator, data: []const u8) anyerror!HandlerResponse =
            if (@hasDecl(Self, "onData")) Self.onData else defaultOnData;

        /// Called when the connection is being closed (TCP only)
        pub const onClose: fn (self: *Self) anyerror!void =
            if (@hasDecl(Self, "onClose")) Self.onClose else defaultOnClose;

        // ====================================================================
        // UDP Handler Interface
        // ====================================================================

        /// Called when a datagram is received (UDP only)
        /// Should return the response to send back to source address, or null for no response
        pub const onDatagram: fn (self: *Self, allocator: std.mem.Allocator, data: []const u8, source: std.net.Address) anyerror!?[]const u8 =
            if (@hasDecl(Self, "onDatagram")) Self.onDatagram else defaultOnDatagram;

        // ====================================================================
        // Default implementations
        // ====================================================================

        fn defaultOnConnect(_: *Self, _: std.mem.Allocator) ?HandlerResponse {
            return .{};
        }

        fn defaultOnData(_: *Self, _: std.mem.Allocator, _: []const u8) !HandlerResponse {
            return .{};
        }

        fn defaultOnClose(_: *Self) !void {}

        fn defaultOnDatagram(_: *Self, _: std.mem.Allocator, _: []const u8, _: std.net.Address) !?[]const u8 {
            return null;
        }
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
fn TCPServer(comptime HandlerType: type) type {
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
            heartbeat_interval_ms: u64 = 0,
            heartbeat_timer: ?xev.Timer = null,
            heartbeat_completion: ?*xev.Completion = null,
            destroy_pending: bool = false,
            destroyed: bool = false,
            active_heartbeat_callbacks: usize = 0,
            heartbeat_pending: bool = false,

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
                conn.heartbeat_interval_ms = 0;
                conn.heartbeat_timer = null;
                conn.heartbeat_completion = null;
                conn.destroy_pending = false;
                conn.destroyed = false;
                conn.active_heartbeat_callbacks = 0;
                conn.heartbeat_pending = false;
                // Register connection
                server.connections.append(server.allocator, conn) catch |err| {
                    allocator.free(line_buf);
                    allocator.destroy(conn);
                    return err;
                };
                return conn;
            }

            fn finishDestroy(self: *Connection) !void {
                if (self.destroyed) return;
                self.destroyed = true;
                self.destroy_pending = false;
                self.heartbeat_pending = false;
                try Handler(HandlerType).onClose(&self.handler);
                self.stopHeartbeat();
                if (self.heartbeat_timer) |*timer| {
                    timer.deinit();
                    self.heartbeat_timer = null;
                }
                if (self.heartbeat_completion) |c| {
                    self.server.allocator.destroy(c);
                    self.heartbeat_completion = null;
                }
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

            fn tryFinishDestroy(self: *Connection) !void {
                if (!self.destroy_pending) return;
                if (self.active_heartbeat_callbacks != 0) return;
                if (self.heartbeat_pending) return;
                try self.finishDestroy();
            }

            fn requestDestroy(self: *Connection) !void {
                if (self.destroyed or self.destroy_pending) return;
                self.destroy_pending = true;
                try self.tryFinishDestroy();
            }

            fn startHeartbeat(self: *Connection, loop: *xev.Loop, interval_ms: u64) !void {
                if (interval_ms == 0) {
                    self.heartbeat_interval_ms = 0;
                    return;
                }

                self.heartbeat_interval_ms = interval_ms;

                if (self.heartbeat_timer == null) {
                    self.heartbeat_timer = try xev.Timer.init();
                }

                if (self.heartbeat_completion == null) {
                    self.heartbeat_completion = try self.server.allocator.create(xev.Completion);
                }

                self.scheduleHeartbeat(loop, self.heartbeat_completion.?);
            }

            fn stopHeartbeat(self: *Connection) void {
                self.heartbeat_interval_ms = 0;
            }

            fn scheduleHeartbeat(self: *Connection, loop: *xev.Loop, c: *xev.Completion) void {
                self.heartbeat_pending = true;
                self.heartbeat_timer.?.run(
                    loop,
                    c,
                    self.heartbeat_interval_ms,
                    Connection,
                    self,
                    heartbeatCallback,
                );
            }

            fn heartbeatCallback(
                conn_: ?*Connection,
                loop: *xev.Loop,
                c: *xev.Completion,
                result: xev.Timer.RunError!void,
            ) xev.CallbackAction {
                const conn = conn_ orelse return .disarm;

                conn.heartbeat_pending = false;

                _ = result catch {
                    return .disarm;
                };

                conn.active_heartbeat_callbacks += 1;
                defer {
                    conn.active_heartbeat_callbacks -= 1;
                    if (conn.destroy_pending) {
                        conn.tryFinishDestroy() catch |err| {
                            std.log.err("Error destroying connection: {}", .{err});
                        };
                    }
                }

                if (conn.destroy_pending) {
                    return .disarm;
                }

                std.log.debug("Heartbeat callback (interval={d})", .{conn.heartbeat_interval_ms});

                if (@hasDecl(HandlerType, "onHeartbeat")) {
                    const heartbeat_data = HandlerType.onHeartbeat(&conn.handler, conn.server.allocator) catch {
                        return .disarm;
                    };
                    if (heartbeat_data.len > 0) {
                        const heartbeat_write = conn.server.allocator.create(xev.Completion) catch |err| {
                            std.log.err("Failed to create heartbeat completion: {}", .{err});
                            return .disarm;
                        };
                        conn.socket.write(loop, heartbeat_write, .{ .slice = heartbeat_data }, Connection, conn, writeCallback);
                    }
                }

                if (conn.heartbeat_interval_ms > 0 and !conn.close_after_write and !conn.destroy_pending) {
                    conn.scheduleHeartbeat(loop, c);
                }

                return .disarm;
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

                if (handler_response.heartbeat_interval_ms) |interval| {
                    std.log.info("Starting heartbeat timer: {}ms", .{interval});
                    self.startHeartbeat(loop, interval) catch |err| {
                        std.log.err("Failed to start heartbeat: {}", .{err});
                    };
                }

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
                conn.requestDestroy() catch |err| {
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
                    conn.requestDestroy() catch |destroy_err| {
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

            std.log.info("Wrote {} bytes", .{bytes_written});

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
                conn.requestDestroy() catch |destroy_err| {
                    std.log.err("Error destroying connection: {}", .{destroy_err});
                };
                return .disarm;
            };

            std.log.info("Connection closed successfully", .{});

            // Clean up the completion and connection
            conn.server.allocator.destroy(c);
            conn.requestDestroy() catch |err| {
                std.log.err("Error destroying connection: {}", .{err});
            };
            return .disarm;
        }
    };
}

// ============================================================================
// UDP Server Implementation
// ============================================================================

/// Generic UDP server that works with any Handler
fn UDPServer(comptime HandlerType: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        loop: *xev.Loop,
        socket: xev.UDP,
        handler: HandlerType,
        state: xev.UDP.State,
        buffer: [65536]u8, // Max UDP packet size

        pub fn init(allocator: std.mem.Allocator, loop: *xev.Loop, host: []const u8, port: u16) !Self {
            // Parse the address - try IPv4 first, then IPv6
            const addr = std.net.Address.parseIp4(host, port) catch
                std.net.Address.parseIp6(host, port) catch {
                std.log.err("Invalid host address: {s}", .{host});
                return error.InvalidAddress;
            };

            // Create a UDP socket
            var socket = try xev.UDP.init(addr);

            // Bind to the address
            try socket.bind(addr);

            var result: Self = undefined;
            result.allocator = allocator;
            result.loop = loop;
            result.socket = socket;
            result.handler = .{};
            result.state = undefined;
            result.buffer = undefined;
            return result;
        }

        pub fn deinit(self: *Self) void {
            _ = self;
            // Cleanup is handled by loop.deinit()
        }

        /// Start receiving datagrams
        pub fn start(self: *Self) !void {
            const c = try self.allocator.create(xev.Completion);
            self.socket.read(self.loop, c, &self.state, .{ .slice = &self.buffer }, Self, self, readCallback);
        }

        /// Called when a datagram is received
        fn readCallback(
            self_: ?*Self,
            loop: *xev.Loop,
            _: *xev.Completion,
            _: *xev.UDP.State,
            source_addr: std.net.Address,
            _: xev.UDP,
            buffer: xev.ReadBuffer,
            result: xev.ReadError!usize,
        ) xev.CallbackAction {
            const self = self_.?;

            const bytes_read = result catch |err| {
                // For UDP, EOF on read might indicate a 0-byte datagram on some platforms
                // Treat it as a successful 0-byte read
                if (err == error.EOF) {
                    std.log.debug("EOF on UDP read - treating as 0-byte datagram", .{});
                    // Process as empty datagram
                    const empty_data: []const u8 = &[_]u8{};
                    const empty_response = Handler(HandlerType).onDatagram(&self.handler, self.allocator, empty_data, source_addr) catch |handler_err| {
                        std.log.err("Handler error on empty datagram: {}", .{handler_err});
                        return .rearm;
                    };

                    if (empty_response) |response_data| {
                        if (response_data.len > 0) {
                            const c_write = self.allocator.create(xev.Completion) catch {
                                return .rearm;
                            };
                            const write_state = self.allocator.create(xev.UDP.State) catch {
                                self.allocator.destroy(c_write);
                                return .rearm;
                            };
                            self.socket.write(loop, c_write, write_state, source_addr, .{ .slice = response_data }, Self, self, writeCallback);
                        }
                    }
                    return .rearm;
                }

                std.log.err("Read error: {}", .{err});
                // UDP is connectionless - continue listening even on errors
                return .rearm;
            };

            // Extract the data (empty datagrams are valid in UDP)
            const data = buffer.slice[0..bytes_read];

            // Process through the handler
            const response = Handler(HandlerType).onDatagram(&self.handler, self.allocator, data, source_addr) catch |err| {
                std.log.err("Handler error: {}", .{err});
                // Continue listening even on error
                return .rearm;
            };

            // If there's a response, send it back
            if (response) |response_data| {
                std.log.info("Handler returned response: len={d}", .{response_data.len});
                if (response_data.len > 0) {
                    const c_write = self.allocator.create(xev.Completion) catch |err| {
                        std.log.err("Failed to create write completion: {}", .{err});
                        return .rearm;
                    };
                    const write_state = self.allocator.create(xev.UDP.State) catch |err| {
                        std.log.err("Failed to create write state: {}", .{err});
                        self.allocator.destroy(c_write);
                        return .rearm;
                    };
                    std.log.info("Queueing write of {} bytes", .{response_data.len});
                    self.socket.write(loop, c_write, write_state, source_addr, .{ .slice = response_data }, Self, self, writeCallback);
                } else {
                    std.log.info("Response is empty, not sending", .{});
                }
            } else {
                std.log.info("Handler returned null (no response)", .{});
            }

            // Continue listening (rearm)
            return .rearm;
        }

        /// Called when a datagram is written
        fn writeCallback(
            self_: ?*Self,
            _: *xev.Loop,
            c: *xev.Completion,
            state: *xev.UDP.State,
            _: xev.UDP,
            _: xev.WriteBuffer,
            result: xev.WriteError!usize,
        ) xev.CallbackAction {
            const self = self_.?;

            const bytes_written = result catch |err| {
                std.log.err("Write error: {}", .{err});
                self.allocator.destroy(state);
                self.allocator.destroy(c);
                return .disarm;
            };

            std.log.info("Wrote {} bytes", .{bytes_written});

            // Clean up
            self.allocator.destroy(state);
            self.allocator.destroy(c);
            return .disarm;
        }
    };
}
