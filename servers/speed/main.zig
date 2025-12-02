// ============================================================================
// Speed Daemon Server - Protohackers Challenge #6
// ============================================================================

const std = @import("std");
const builtin = @import("builtin");
const server = @import("server");

const protocol = @import("protocol.zig");
const ticket = @import("ticket.zig");
const observation = @import("observation.zig");
const dispatcher = @import("dispatcher.zig");
const client = @import("client.zig");

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

    try server.run(allocator, SpeedHandler);
}

// ============================================================================
// Global State (shared across all connections)
// ============================================================================

var global_state_mutex: std.Thread.Mutex = .{};
var global_observations: ?observation.ObservationStore = null;
var global_dispatchers: ?dispatcher.DispatcherManager = null;
var global_tickets: ?ticket.TicketManager = null;
var global_next_id: usize = 1;
var global_allocator: ?std.mem.Allocator = null;

fn initGlobalState(allocator: std.mem.Allocator) void {
    global_state_mutex.lock();
    defer global_state_mutex.unlock();

    if (global_observations == null) {
        global_allocator = allocator;
        global_observations = observation.ObservationStore.init(allocator);
        global_dispatchers = dispatcher.DispatcherManager.init(allocator);
        global_tickets = ticket.TicketManager.init(allocator);
    }
}

// Helper function to send ticket to a specific dispatcher
fn sendTicketToDispatcher(allocator: std.mem.Allocator, dispatcher_id: usize, ticket_data: protocol.Ticket) !bool {
    const connections = server.getAllConnections(SpeedHandler);

    for (connections) |conn| {
        if (conn.handler.client_id == dispatcher_id) {
            // Found the dispatcher connection - encode and send ticket
            var ticket_buf = std.ArrayList(u8).empty;
            errdefer ticket_buf.deinit(allocator);

            try protocol.encodeTicket(ticket_buf.writer(allocator), ticket_data);
            const ticket_bytes = try ticket_buf.toOwnedSlice(allocator);
            // NOTE: ticket_bytes memory is now owned by the write operation
            // The server framework will handle cleanup after the write completes

            try server.writeToConnection(SpeedHandler, conn, ticket_bytes);
            return true;
        }
    }

    return false;
}

// ============================================================================
// Handler Implementation
// ============================================================================

const SpeedHandler = struct {
    client_id: usize = 0,
    client_state: client.ClientState = client.ClientState.init(),
    message_buffer: std.ArrayList(u8) = undefined,
    buffer_initialized: bool = false,
    heartbeat_interval_ms: ?u64 = null, // Set when WantHeartbeat is received
    allocator: std.mem.Allocator = undefined,

    // For binary protocol, we read one byte at a time to handle variable-length messages
    pub const protocol_mode = server.ProtocolMode{ .binary_fixed = 1 };

    pub fn onConnect(self: *SpeedHandler, allocator: std.mem.Allocator) ?server.HandlerResponse {
        initGlobalState(allocator);

        global_state_mutex.lock();
        const id = global_next_id;
        global_next_id += 1;
        global_state_mutex.unlock();

        self.client_id = id;
        self.client_state = client.ClientState.init();
        self.message_buffer = std.ArrayList(u8).empty;
        self.buffer_initialized = true;
        self.allocator = allocator;

        std.log.info("Client {} connected", .{self.client_id});

        return .{};
    }

    pub fn onData(self: *SpeedHandler, allocator: std.mem.Allocator, data: []const u8) !server.HandlerResponse {
        // Accumulate bytes in our buffer
        try self.message_buffer.append(allocator, data[0]);

        // Try to parse and handle complete messages
        var response_buf = std.ArrayList(u8).empty;
        errdefer response_buf.deinit(allocator);

        var should_close = false;

        while (true) {
            const result = try self.tryParseMessage(allocator, &response_buf);
            if (result.parsed) {
                should_close = result.should_close;
                if (should_close) break;
            } else {
                break; // Need more data
            }
        }

        const owned_response = try response_buf.toOwnedSlice(allocator);
        if (owned_response.len > 0) {
            std.log.debug("Returning response with {} bytes: type=0x{x} full={x}", .{ owned_response.len, owned_response[0], owned_response });
        }

        // Get heartbeat interval if it was set, then clear it
        const hb_interval = self.heartbeat_interval_ms;
        self.heartbeat_interval_ms = null;
        if (hb_interval) |interval| {
            std.log.info("Client {} will request heartbeat interval {} ms", .{ self.client_id, interval });
        }

        return .{
            .data = owned_response,
            .close_after_write = should_close,
            .heartbeat_interval_ms = hb_interval,
        };
    }

    const ParseResult = struct {
        parsed: bool,
        should_close: bool,
    };

    fn tryParseMessage(self: *SpeedHandler, allocator: std.mem.Allocator, response_buf: *std.ArrayList(u8)) !ParseResult {
        const buf = self.message_buffer.items;

        if (buf.len == 0) return .{ .parsed = false, .should_close = false };

        const msg_type = buf[0];

        // Determine how many bytes we need for this message type
        const needed_bytes: ?usize = switch (msg_type) {
            protocol.MSG_I_AM_CAMERA => 1 + 6, // type + 3*u16
            protocol.MSG_WANT_HEARTBEAT => 1 + 4, // type + u32
            protocol.MSG_I_AM_DISPATCHER => blk: {
                if (buf.len < 2) break :blk null; // Need at least type + numroads
                const numroads = buf[1];
                break :blk 1 + 1 + (@as(usize, numroads) * 2); // type + numroads + roads
            },
            protocol.MSG_PLATE => blk: {
                if (buf.len < 2) break :blk null; // Need at least type + length
                const plate_len = buf[1];
                break :blk 1 + 1 + plate_len + 4; // type + len + plate + timestamp
            },
            else => 1, // Unknown message, will error immediately
        };

        if (needed_bytes) |needed| {
            if (buf.len < needed) {
                return .{ .parsed = false, .should_close = false }; // Need more data
            }

            // We have a complete message
            const message = buf[0..needed];
            const msg_type_byte = message[0];
            const msg_data = message[1..];

            // Handle the message
            const should_close = switch (msg_type_byte) {
                protocol.MSG_I_AM_CAMERA => try self.handleIAmCamera(allocator, msg_data, response_buf),
                protocol.MSG_I_AM_DISPATCHER => try self.handleIAmDispatcher(allocator, msg_data, response_buf),
                protocol.MSG_PLATE => try self.handlePlate(allocator, msg_data, response_buf),
                protocol.MSG_WANT_HEARTBEAT => try self.handleWantHeartbeat(allocator, msg_data, response_buf),
                else => blk: {
                    std.log.warn("Client {}: Unknown message type: 0x{x}", .{ self.client_id, msg_type_byte });
                    try protocol.encodeError(response_buf.writer(allocator), "illegal msg");
                    break :blk true;
                },
            };

            // Remove processed message from buffer
            std.mem.copyForwards(u8, self.message_buffer.items[0 .. buf.len - needed], buf[needed..]);
            self.message_buffer.shrinkRetainingCapacity(buf.len - needed);

            return .{ .parsed = true, .should_close = should_close };
        }

        // Need more data to determine message length
        return .{ .parsed = false, .should_close = false };
    }

    pub fn onClose(self: *SpeedHandler) !void {
        std.log.info("Client {} disconnected", .{self.client_id});

        // If this was a dispatcher, unregister it
        if (self.client_state.isDispatcher()) {
            global_state_mutex.lock();
            defer global_state_mutex.unlock();
            if (global_dispatchers) |*disp| {
                disp.unregisterDispatcher(self.client_id);
            }
        }

        if (self.buffer_initialized) {
            self.message_buffer.deinit(self.allocator);
        }
    }

    pub fn onHeartbeat(self: *SpeedHandler, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;
        // Heartbeat message is just a single byte: 0x41
        const data = try allocator.alloc(u8, 1);
        data[0] = protocol.MSG_HEARTBEAT;
        return data;
    }

    // ========================================================================
    // Message Handlers
    // ========================================================================

    fn handleIAmCamera(self: *SpeedHandler, allocator: std.mem.Allocator, data: []const u8, response_buf: *std.ArrayList(u8)) !bool {
        var stream = std.io.fixedBufferStream(data);
        const camera = protocol.decodeIAmCamera(stream.reader()) catch {
            try protocol.encodeError(response_buf.writer(allocator), "bad camera msg");
            return true;
        };

        self.client_state.identifyAsCamera(camera.road, camera.mile, camera.limit) catch {
            try protocol.encodeError(response_buf.writer(allocator), "already identified");
            return true;
        };

        std.log.info("Client {} is camera: road={}, mile={}, limit={}", .{
            self.client_id,
            camera.road,
            camera.mile,
            camera.limit,
        });

        return false;
    }

    fn handleIAmDispatcher(self: *SpeedHandler, allocator: std.mem.Allocator, data: []const u8, response_buf: *std.ArrayList(u8)) !bool {
        var stream = std.io.fixedBufferStream(data);
        const disp = protocol.decodeIAmDispatcher(allocator, stream.reader()) catch {
            try protocol.encodeError(response_buf.writer(allocator), "bad dispatcher msg");
            return true;
        };

        self.client_state.identifyAsDispatcher(disp.roads) catch {
            allocator.free(disp.roads);
            try protocol.encodeError(response_buf.writer(allocator), "already identified");
            return true;
        };

        std.log.info("Client {} is dispatcher for {} roads", .{ self.client_id, disp.roads.len });

        // Register with global dispatcher manager and get any queued tickets
        global_state_mutex.lock();
        defer global_state_mutex.unlock();

        const queued = try global_dispatchers.?.registerDispatcher(self.client_id, disp.roads);
        defer {
            for (queued) |q| {
                allocator.free(q.ticket.plate);
            }
            allocator.free(queued);
        }

        // Send all queued tickets immediately
        for (queued) |q| {
            if (q.dispatcher_id == self.client_id) {
                const before_len = response_buf.items.len;
                try protocol.encodeTicket(response_buf.writer(allocator), q.ticket);
                const after_len = response_buf.items.len;
                std.log.info("Encoded queued ticket for {s} on road {} ({} bytes)", .{
                    q.ticket.plate,
                    q.ticket.road,
                    after_len - before_len,
                });
            }
        }

        return false;
    }

    fn handlePlate(self: *SpeedHandler, allocator: std.mem.Allocator, data: []const u8, response_buf: *std.ArrayList(u8)) !bool {
        // Check if allowed to send plate
        if (!self.client_state.canSendPlate()) {
            std.log.err("Client {} sent plate without being a camera", .{self.client_id});
            try protocol.encodeError(response_buf.writer(allocator), "not a camera");
            return true;
        }

        var stream = std.io.fixedBufferStream(data);
        const plate = protocol.decodePlate(allocator, stream.reader()) catch {
            std.log.err("Client {} sent bad plate message", .{self.client_id});
            return true;
        };
        defer allocator.free(plate.plate);

        const camera_info = self.client_state.camera_info.?;

        const obs = ticket.Observation{
            .road = camera_info.road,
            .mile = camera_info.mile,
            .timestamp = plate.timestamp,
            .plate = plate.plate,
        };

        std.log.debug("Client {}: Plate {s} at timestamp {}", .{ self.client_id, plate.plate, plate.timestamp });

        // Add observation and check for violations
        global_state_mutex.lock();
        defer global_state_mutex.unlock();

        const violations = try global_observations.?.addObservation(obs, camera_info.limit);
        defer allocator.free(violations);

        // Process each violation
        for (violations) |v| {
            // Check if we can issue a ticket (one per day rule)
            const can_issue = try global_tickets.?.canIssueTicket(
                v.obs1.plate,
                v.obs1.road,
                v.obs1.timestamp,
                v.obs2.timestamp,
            );

            if (!can_issue) {
                std.log.info("Skipping ticket for {s} (already ticketed today)", .{v.obs1.plate});
                continue;
            }

            // Record that we're issuing this ticket
            try global_tickets.?.recordTicket(
                v.obs1.plate,
                v.obs1.road,
                v.obs1.timestamp,
                v.obs2.timestamp,
            );

            // Create ticket
            const plate_copy = try allocator.dupe(u8, v.obs1.plate);
            errdefer allocator.free(plate_copy);

            const ticket_data = protocol.Ticket{
                .plate = plate_copy,
                .road = v.obs1.road,
                .mile1 = v.obs1.mile,
                .timestamp1 = v.obs1.timestamp,
                .mile2 = v.obs2.mile,
                .timestamp2 = v.obs2.timestamp,
                .speed = v.speed,
            };

            // Queue or dispatch the ticket
            const dispatcher_id = try global_dispatchers.?.queueOrDispatchTicket(ticket_data);

            if (dispatcher_id) |disp_id| {
                // Ticket was dispatched - send it to the dispatcher connection
                const sent = try sendTicketToDispatcher(allocator, disp_id, ticket_data);
                if (sent) {
                    std.log.info("Dispatched ticket: {s} on road {} at {} mph", .{
                        ticket_data.plate,
                        ticket_data.road,
                        ticket_data.speed / 100,
                    });
                } else {
                    std.log.warn("Dispatcher {} not found, ticket will be lost", .{disp_id});
                }
            } else {
                // Ticket was queued - ownership transferred to queue
                std.log.info("Queued ticket: {s} on road {} (no dispatcher available)", .{
                    ticket_data.plate,
                    ticket_data.road,
                });
            }
        }

        return false;
    }

    fn handleWantHeartbeat(self: *SpeedHandler, allocator: std.mem.Allocator, data: []const u8, response_buf: *std.ArrayList(u8)) !bool {
        var stream = std.io.fixedBufferStream(data);
        const hb = protocol.decodeWantHeartbeat(stream.reader()) catch {
            std.log.err("Client {} sent bad heartbeat message", .{self.client_id});
            try protocol.encodeError(response_buf.writer(allocator), "bad heartbeat msg");
            return true;
        };

        self.client_state.requestHeartbeat(hb.interval) catch {
            std.log.err("Client {} requested heartbeat twice", .{self.client_id});
            try protocol.encodeError(response_buf.writer(allocator), "duplicate heartbeat");
            return true;
        };

        std.log.info("Client {} wants heartbeat every {} deciseconds", .{ self.client_id, hb.interval });

        // Convert deciseconds (1/10 second) to milliseconds and store it
        const interval_ms = @as(u64, hb.interval) * 100;
        self.heartbeat_interval_ms = interval_ms;
        std.log.info("Client {} internal heartbeat interval {} ms", .{ self.client_id, interval_ms });

        return false;
    }
};
