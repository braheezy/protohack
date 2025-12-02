//! Ticket generation logic
//! Handles speed calculation, violation detection, and one-ticket-per-day rule

const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol.zig");

// ============================================================================
// Core Types
// ============================================================================

pub const Observation = struct {
    road: u16,
    mile: u16,
    timestamp: u32,
    plate: []const u8,
};

pub const TicketRecord = struct {
    plate: []const u8,
    road: u16,
    day: u32, // floor(timestamp / 86400)
};

// ============================================================================
// Speed Calculation
// ============================================================================

/// Calculate average speed between two observations
/// Returns speed in 100x mph (e.g., 8000 = 80 mph)
pub fn calculateSpeed(obs1: Observation, obs2: Observation) !u16 {
    if (obs1.road != obs2.road) return error.DifferentRoads;
    if (obs1.timestamp == obs2.timestamp) return error.SameTimestamp;

    // Ensure obs1 is the earlier observation
    const earlier = if (obs1.timestamp < obs2.timestamp) obs1 else obs2;
    const later = if (obs1.timestamp < obs2.timestamp) obs2 else obs1;

    // Calculate distance in miles
    const distance: u32 = if (later.mile > earlier.mile)
        later.mile - earlier.mile
    else
        earlier.mile - later.mile;

    // Calculate time in seconds
    const time_seconds: u32 = later.timestamp - earlier.timestamp;

    // Speed = distance / time
    // mph = (miles) / (seconds / 3600)
    // mph = miles * 3600 / seconds
    // speed (100x mph) = miles * 360000 / seconds

    const speed_x100 = (distance * 360000) / time_seconds;

    // Check for overflow (shouldn't happen per spec)
    if (speed_x100 > 65535) return error.SpeedOverflow;

    return @intCast(speed_x100);
}

/// Check if speed exceeds limit
/// Must exceed by 0.5 mph or more to ticket
pub fn isSpeedingViolation(speed_x100: u16, limit: u16) bool {
    const limit_x100 = limit * 100;
    // Must exceed limit by at least 50 (0.5 mph)
    return speed_x100 >= limit_x100 + 50;
}

/// Calculate day from timestamp
/// Days are defined as floor(timestamp / 86400)
pub fn getDay(timestamp: u32) u32 {
    return timestamp / 86400;
}

/// Check if a ticket would span multiple days
pub fn getTicketDays(timestamp1: u32, timestamp2: u32) struct { start: u32, end: u32 } {
    const day1 = getDay(timestamp1);
    const day2 = getDay(timestamp2);
    return .{
        .start = @min(day1, day2),
        .end = @max(day1, day2),
    };
}

// ============================================================================
// Ticket Manager
// ============================================================================

pub const TicketManager = struct {
    allocator: std.mem.Allocator,
    // Map: plate+road+day -> bool (tracks issued tickets)
    issued_tickets: std.AutoHashMap(TicketKey, void),

    const TicketKey = struct {
        plate_hash: u64,
        road: u16,
        day: u32,

        pub fn init(plate: []const u8, road: u16, day: u32) TicketKey {
            return .{
                .plate_hash = std.hash.Wyhash.hash(0, plate),
                .road = road,
                .day = day,
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator) TicketManager {
        return .{
            .allocator = allocator,
            .issued_tickets = std.AutoHashMap(TicketKey, void).init(allocator),
        };
    }

    pub fn deinit(self: *TicketManager) void {
        self.issued_tickets.deinit();
    }

    /// Check if we can issue a ticket for this violation
    /// Returns true if no ticket has been issued for any day spanned by this violation
    pub fn canIssueTicket(self: *TicketManager, plate: []const u8, road: u16, timestamp1: u32, timestamp2: u32) !bool {
        const days = getTicketDays(timestamp1, timestamp2);

        // Check if any day in the range already has a ticket
        var day = days.start;
        while (day <= days.end) : (day += 1) {
            const key = TicketKey.init(plate, road, day);
            if (self.issued_tickets.contains(key)) {
                return false;
            }
        }

        return true;
    }

    /// Record that a ticket has been issued
    /// Marks all days spanned by the ticket as used
    pub fn recordTicket(self: *TicketManager, plate: []const u8, road: u16, timestamp1: u32, timestamp2: u32) !void {
        const days = getTicketDays(timestamp1, timestamp2);

        var day = days.start;
        while (day <= days.end) : (day += 1) {
            const key = TicketKey.init(plate, road, day);
            try self.issued_tickets.put(key, {});
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "calculateSpeed - basic case" {
    const obs1 = Observation{
        .road = 123,
        .mile = 8,
        .timestamp = 0,
        .plate = "UN1X",
    };

    const obs2 = Observation{
        .road = 123,
        .mile = 9,
        .timestamp = 45,
        .plate = "UN1X",
    };

    const speed = try calculateSpeed(obs1, obs2);
    // 1 mile in 45 seconds = 1 / (45/3600) = 80 mph
    // 80 * 100 = 8000
    try testing.expectEqual(@as(u16, 8000), speed);
}

test "calculateSpeed - reverse order" {
    const obs1 = Observation{
        .road = 123,
        .mile = 9,
        .timestamp = 45,
        .plate = "UN1X",
    };

    const obs2 = Observation{
        .road = 123,
        .mile = 8,
        .timestamp = 0,
        .plate = "UN1X",
    };

    const speed = try calculateSpeed(obs1, obs2);
    try testing.expectEqual(@as(u16, 8000), speed);
}

test "calculateSpeed - longer distance" {
    const obs1 = Observation{
        .road = 368,
        .mile = 1234,
        .timestamp = 1000000,
        .plate = "RE05BKG",
    };

    const obs2 = Observation{
        .road = 368,
        .mile = 1235,
        .timestamp = 1000060,
        .plate = "RE05BKG",
    };

    const speed = try calculateSpeed(obs1, obs2);
    // 1 mile in 60 seconds = 1 / (60/3600) = 60 mph
    // 60 * 100 = 6000
    try testing.expectEqual(@as(u16, 6000), speed);
}

test "isSpeedingViolation - clear violation" {
    // 80 mph in 60 mph zone
    try testing.expect(isSpeedingViolation(8000, 60));
}

test "isSpeedingViolation - at limit" {
    // 60 mph in 60 mph zone - not a violation
    try testing.expect(!isSpeedingViolation(6000, 60));
}

test "isSpeedingViolation - just under threshold" {
    // 60.4 mph in 60 mph zone - not a violation (under 0.5 mph)
    try testing.expect(!isSpeedingViolation(6040, 60));
}

test "isSpeedingViolation - at threshold" {
    // 60.5 mph in 60 mph zone - violation
    try testing.expect(isSpeedingViolation(6050, 60));
}

test "getDay - basic cases" {
    try testing.expectEqual(@as(u32, 0), getDay(0));
    try testing.expectEqual(@as(u32, 0), getDay(86399));
    try testing.expectEqual(@as(u32, 1), getDay(86400));
    try testing.expectEqual(@as(u32, 1), getDay(86401));
    try testing.expectEqual(@as(u32, 2), getDay(172800));
}

test "getTicketDays - same day" {
    const days = getTicketDays(0, 1000);
    try testing.expectEqual(@as(u32, 0), days.start);
    try testing.expectEqual(@as(u32, 0), days.end);
}

test "getTicketDays - spans two days" {
    const days = getTicketDays(86000, 87000);
    try testing.expectEqual(@as(u32, 0), days.start);
    try testing.expectEqual(@as(u32, 1), days.end);
}

test "getTicketDays - reverse order" {
    const days = getTicketDays(87000, 86000);
    try testing.expectEqual(@as(u32, 0), days.start);
    try testing.expectEqual(@as(u32, 1), days.end);
}

test "TicketManager - can issue first ticket" {
    var manager = TicketManager.init(testing.allocator);
    defer manager.deinit();

    const can_issue = try manager.canIssueTicket("UN1X", 123, 0, 1000);
    try testing.expect(can_issue);
}

test "TicketManager - cannot issue duplicate on same day" {
    var manager = TicketManager.init(testing.allocator);
    defer manager.deinit();

    try manager.recordTicket("UN1X", 123, 0, 1000);

    const can_issue = try manager.canIssueTicket("UN1X", 123, 2000, 3000);
    try testing.expect(!can_issue);
}

test "TicketManager - can issue on different day" {
    var manager = TicketManager.init(testing.allocator);
    defer manager.deinit();

    // Day 0
    try manager.recordTicket("UN1X", 123, 0, 1000);

    // Day 1
    const can_issue = try manager.canIssueTicket("UN1X", 123, 86400, 87000);
    try testing.expect(can_issue);
}

test "TicketManager - can issue for different car" {
    var manager = TicketManager.init(testing.allocator);
    defer manager.deinit();

    try manager.recordTicket("UN1X", 123, 0, 1000);

    const can_issue = try manager.canIssueTicket("CAR2", 123, 0, 1000);
    try testing.expect(can_issue);
}

test "TicketManager - can issue on different road" {
    var manager = TicketManager.init(testing.allocator);
    defer manager.deinit();

    try manager.recordTicket("UN1X", 123, 0, 1000);

    const can_issue = try manager.canIssueTicket("UN1X", 456, 0, 1000);
    try testing.expect(can_issue);
}

test "TicketManager - spanning ticket blocks all days" {
    var manager = TicketManager.init(testing.allocator);
    defer manager.deinit();

    // Ticket spanning days 0, 1, 2
    try manager.recordTicket("UN1X", 123, 0, 172800 + 1000);

    // Cannot issue on day 0
    try testing.expect(!try manager.canIssueTicket("UN1X", 123, 1000, 2000));

    // Cannot issue on day 1
    try testing.expect(!try manager.canIssueTicket("UN1X", 123, 86400, 87000));

    // Cannot issue on day 2
    try testing.expect(!try manager.canIssueTicket("UN1X", 123, 172800, 173000));

    // Can issue on day 3
    try testing.expect(try manager.canIssueTicket("UN1X", 123, 259200, 260000));
}
