//! Dispatcher management and ticket routing
//! Handles registering dispatchers and queuing tickets

const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol.zig");

// ============================================================================
// Dispatcher Manager
// ============================================================================

pub const DispatcherManager = struct {
    allocator: std.mem.Allocator,
    // Map: road -> list of dispatcher IDs
    road_dispatchers: std.AutoHashMap(u16, DispatcherList),
    // Queued tickets per road (for when no dispatcher is available)
    queued_tickets: std.AutoHashMap(u16, TicketQueue),

    const DispatcherList = std.ArrayList(usize);
    const TicketQueue = std.ArrayList(protocol.Ticket);

    pub fn init(allocator: std.mem.Allocator) DispatcherManager {
        return .{
            .allocator = allocator,
            .road_dispatchers = std.AutoHashMap(u16, DispatcherList).init(allocator),
            .queued_tickets = std.AutoHashMap(u16, TicketQueue).init(allocator),
        };
    }

    pub fn deinit(self: *DispatcherManager) void {
        // Clean up road dispatchers
        var it = self.road_dispatchers.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.road_dispatchers.deinit();

        // Clean up queued tickets
        var it2 = self.queued_tickets.iterator();
        while (it2.next()) |entry| {
            for (entry.value_ptr.items) |t| {
                self.allocator.free(t.plate);
            }
            entry.value_ptr.deinit();
        }
        self.queued_tickets.deinit();
    }

    /// Register a dispatcher for a set of roads
    /// Returns any queued tickets for those roads
    pub fn registerDispatcher(
        self: *DispatcherManager,
        dispatcher_id: usize,
        roads: []const u16,
    ) ![]QueuedTicket {
        var all_queued = std.ArrayList(QueuedTicket).empty;
        errdefer all_queued.deinit(self.allocator);

        for (roads) |road| {
            // Add dispatcher to road
            const result = try self.road_dispatchers.getOrPut(road);
            if (!result.found_existing) {
                result.value_ptr.* = DispatcherList.empty;
            }
            try result.value_ptr.append(self.allocator, dispatcher_id);

            // Get any queued tickets for this road
            if (self.queued_tickets.getPtr(road)) |queue| {
                for (queue.items) |t| {
                    try all_queued.append(self.allocator, .{
                        .dispatcher_id = dispatcher_id,
                        .ticket = t,
                    });
                }
                // Clear the queue (ownership transferred to all_queued)
                queue.clearRetainingCapacity();
            }
        }

        return all_queued.toOwnedSlice(self.allocator);
    }

    /// Unregister a dispatcher (when they disconnect)
    pub fn unregisterDispatcher(self: *DispatcherManager, dispatcher_id: usize) void {
        var it = self.road_dispatchers.iterator();
        while (it.next()) |entry| {
            const list = entry.value_ptr;
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == dispatcher_id) {
                    _ = list.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }

    /// Queue a ticket for a road, or dispatch it immediately if a dispatcher is available
    /// Returns the dispatcher ID to send to, or null if queued
    pub fn queueOrDispatchTicket(
        self: *DispatcherManager,
        ticket_data: protocol.Ticket,
    ) !?usize {
        // Check if there's a dispatcher for this road
        if (self.road_dispatchers.get(ticket_data.road)) |dispatchers| {
            if (dispatchers.items.len > 0) {
                // Pick the first dispatcher (could be round-robin in future)
                return dispatchers.items[0];
            }
        }

        // No dispatcher available, queue the ticket
        const result = try self.queued_tickets.getOrPut(ticket_data.road);
        if (!result.found_existing) {
            result.value_ptr.* = TicketQueue.empty;
        }

        // Make a copy of the ticket with owned plate string
        const plate_copy = try self.allocator.dupe(u8, ticket_data.plate);
        const ticket_copy = protocol.Ticket{
            .plate = plate_copy,
            .road = ticket_data.road,
            .mile1 = ticket_data.mile1,
            .timestamp1 = ticket_data.timestamp1,
            .mile2 = ticket_data.mile2,
            .timestamp2 = ticket_data.timestamp2,
            .speed = ticket_data.speed,
        };

        try result.value_ptr.append(self.allocator, ticket_copy);
        return null;
    }
};

pub const QueuedTicket = struct {
    dispatcher_id: usize,
    ticket: protocol.Ticket,
};

// ============================================================================
// Tests
// ============================================================================

test "DispatcherManager - register dispatcher" {
    var manager = DispatcherManager.init(testing.allocator);
    defer manager.deinit();

    const roads = [_]u16{ 123, 456 };
    const queued = try manager.registerDispatcher(1, &roads);
    defer testing.allocator.free(queued);

    try testing.expectEqual(@as(usize, 0), queued.len);
}

test "DispatcherManager - dispatch ticket to available dispatcher" {
    var manager = DispatcherManager.init(testing.allocator);
    defer manager.deinit();

    const roads = [_]u16{123};
    _ = try manager.registerDispatcher(1, &roads);

    const ticket_data = protocol.Ticket{
        .plate = "UN1X",
        .road = 123,
        .mile1 = 8,
        .timestamp1 = 0,
        .mile2 = 9,
        .timestamp2 = 45,
        .speed = 8000,
    };

    const dispatcher_id = try manager.queueOrDispatchTicket(ticket_data);
    try testing.expectEqual(@as(?usize, 1), dispatcher_id);
}

test "DispatcherManager - queue ticket when no dispatcher" {
    var manager = DispatcherManager.init(testing.allocator);
    defer manager.deinit();

    const ticket_data = protocol.Ticket{
        .plate = "UN1X",
        .road = 123,
        .mile1 = 8,
        .timestamp1 = 0,
        .mile2 = 9,
        .timestamp2 = 45,
        .speed = 8000,
    };

    const dispatcher_id = try manager.queueOrDispatchTicket(ticket_data);
    try testing.expectEqual(@as(?usize, null), dispatcher_id);
}

test "DispatcherManager - delayed dispatcher receives queued tickets" {
    var manager = DispatcherManager.init(testing.allocator);
    defer manager.deinit();

    // Queue a ticket
    const ticket_data = protocol.Ticket{
        .plate = "DELAY",
        .road = 600,
        .mile1 = 0,
        .timestamp1 = 0,
        .mile2 = 1,
        .timestamp2 = 30,
        .speed = 12000,
    };

    const dispatcher_id = try manager.queueOrDispatchTicket(ticket_data);
    try testing.expectEqual(@as(?usize, null), dispatcher_id);

    // Register dispatcher
    const roads = [_]u16{600};
    const queued = try manager.registerDispatcher(1, &roads);
    defer {
        for (queued) |q| {
            testing.allocator.free(q.ticket.plate);
        }
        testing.allocator.free(queued);
    }

    try testing.expectEqual(@as(usize, 1), queued.len);
    try testing.expectEqual(@as(usize, 1), queued[0].dispatcher_id);
    try testing.expectEqualStrings("DELAY", queued[0].ticket.plate);
}

test "DispatcherManager - multiple dispatchers for same road" {
    var manager = DispatcherManager.init(testing.allocator);
    defer manager.deinit();

    const roads = [_]u16{500};
    _ = try manager.registerDispatcher(1, &roads);
    _ = try manager.registerDispatcher(2, &roads);

    const ticket_data = protocol.Ticket{
        .plate = "MULTI",
        .road = 500,
        .mile1 = 0,
        .timestamp1 = 0,
        .mile2 = 1,
        .timestamp2 = 30,
        .speed = 12000,
    };

    // Should dispatch to one of them (currently picks first)
    const dispatcher_id = try manager.queueOrDispatchTicket(ticket_data);
    try testing.expect(dispatcher_id != null);
    try testing.expect(dispatcher_id.? == 1 or dispatcher_id.? == 2);
}

test "DispatcherManager - unregister dispatcher" {
    var manager = DispatcherManager.init(testing.allocator);
    defer manager.deinit();

    const roads = [_]u16{123};
    _ = try manager.registerDispatcher(1, &roads);

    // Should dispatch successfully
    const ticket1 = protocol.Ticket{
        .plate = "TEST",
        .road = 123,
        .mile1 = 0,
        .timestamp1 = 0,
        .mile2 = 1,
        .timestamp2 = 30,
        .speed = 12000,
    };

    const disp1 = try manager.queueOrDispatchTicket(ticket1);
    try testing.expectEqual(@as(?usize, 1), disp1);

    // Unregister
    manager.unregisterDispatcher(1);

    // Should now queue
    const ticket2 = protocol.Ticket{
        .plate = "TEST2",
        .road = 123,
        .mile1 = 0,
        .timestamp1 = 0,
        .mile2 = 1,
        .timestamp2 = 30,
        .speed = 12000,
    };

    const disp2 = try manager.queueOrDispatchTicket(ticket2);
    try testing.expectEqual(@as(?usize, null), disp2);
}

test "DispatcherManager - dispatcher for multiple roads" {
    var manager = DispatcherManager.init(testing.allocator);
    defer manager.deinit();

    const roads = [_]u16{ 100, 200, 300 };
    _ = try manager.registerDispatcher(1, &roads);

    const ticket1 = protocol.Ticket{
        .plate = "T1",
        .road = 100,
        .mile1 = 0,
        .timestamp1 = 0,
        .mile2 = 1,
        .timestamp2 = 30,
        .speed = 12000,
    };

    const ticket2 = protocol.Ticket{
        .plate = "T2",
        .road = 200,
        .mile1 = 0,
        .timestamp1 = 0,
        .mile2 = 1,
        .timestamp2 = 30,
        .speed = 12000,
    };

    const ticket3 = protocol.Ticket{
        .plate = "T3",
        .road = 300,
        .mile1 = 0,
        .timestamp1 = 0,
        .mile2 = 1,
        .timestamp2 = 30,
        .speed = 12000,
    };

    // All should go to dispatcher 1
    try testing.expectEqual(@as(?usize, 1), try manager.queueOrDispatchTicket(ticket1));
    try testing.expectEqual(@as(?usize, 1), try manager.queueOrDispatchTicket(ticket2));
    try testing.expectEqual(@as(?usize, 1), try manager.queueOrDispatchTicket(ticket3));
}
