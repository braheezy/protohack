//! Observation storage and lookup
//! Tracks plate observations per road and finds speeding violations

const std = @import("std");
const testing = std.testing;
const ticket = @import("ticket.zig");

// ============================================================================
// Observation Store
// ============================================================================

pub const ObservationStore = struct {
    allocator: std.mem.Allocator,
    // Map: plate+road -> list of observations
    observations: std.StringHashMap(ObservationList),

    const ObservationList = std.ArrayList(ticket.Observation);

    pub fn init(allocator: std.mem.Allocator) ObservationStore {
        return .{
            .allocator = allocator,
            .observations = std.StringHashMap(ObservationList).init(allocator),
        };
    }

    pub fn deinit(self: *ObservationStore) void {
        var it = self.observations.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // Free all stored plate copies
            for (entry.value_ptr.items) |obs| {
                self.allocator.free(obs.plate);
            }
            entry.value_ptr.deinit();
        }
        self.observations.deinit();
    }

    /// Create a key for plate+road combination
    fn makeKey(allocator: std.mem.Allocator, plate: []const u8, road: u16) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}:{d}", .{ plate, road });
    }

    /// Add an observation and return any violations detected
    /// Returns an array of violation pairs (earlier_obs, later_obs, speed)
    pub fn addObservation(
        self: *ObservationStore,
        obs: ticket.Observation,
        limit: u16,
    ) ![]Violation {
        const key = try makeKey(self.allocator, obs.plate, obs.road);
        errdefer self.allocator.free(key);

        // Get or create the observation list for this plate+road
        const result = try self.observations.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = ObservationList.empty;
        } else {
            self.allocator.free(key);
        }

        // Store a copy of the observation with owned plate string
        const plate_copy = try self.allocator.dupe(u8, obs.plate);
        errdefer self.allocator.free(plate_copy);

        const obs_copy = ticket.Observation{
            .road = obs.road,
            .mile = obs.mile,
            .timestamp = obs.timestamp,
            .plate = plate_copy,
        };

        // Check all existing observations for violations BEFORE adding new one
        var violations = std.ArrayList(Violation).empty;
        errdefer violations.deinit(self.allocator);

        for (result.value_ptr.items) |prev_obs| {
            // Skip if same timestamp
            if (prev_obs.timestamp == obs_copy.timestamp) continue;

            const speed = ticket.calculateSpeed(prev_obs, obs_copy) catch continue;

            if (ticket.isSpeedingViolation(speed, limit)) {
                const earlier = if (prev_obs.timestamp < obs_copy.timestamp) prev_obs else obs_copy;
                const later = if (prev_obs.timestamp < obs_copy.timestamp) obs_copy else prev_obs;

                try violations.append(self.allocator, Violation{
                    .obs1 = earlier,
                    .obs2 = later,
                    .speed = speed,
                });
            }
        }

        // Now add the observation to the store
        try result.value_ptr.append(self.allocator, obs_copy);

        return violations.toOwnedSlice(self.allocator);
    }
};

pub const Violation = struct {
    obs1: ticket.Observation, // Earlier observation
    obs2: ticket.Observation, // Later observation
    speed: u16, // 100x mph
};

// ============================================================================
// Tests
// ============================================================================

test "ObservationStore - single observation" {
    var store = ObservationStore.init(testing.allocator);
    defer store.deinit();

    const obs = ticket.Observation{
        .road = 123,
        .mile = 8,
        .timestamp = 0,
        .plate = "UN1X",
    };

    const violations = try store.addObservation(obs, 60);
    defer testing.allocator.free(violations);

    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "ObservationStore - speeding violation detected" {
    var store = ObservationStore.init(testing.allocator);
    defer store.deinit();

    const obs1 = ticket.Observation{
        .road = 123,
        .mile = 8,
        .timestamp = 0,
        .plate = "UN1X",
    };

    const obs2 = ticket.Observation{
        .road = 123,
        .mile = 9,
        .timestamp = 45,
        .plate = "UN1X",
    };

    const violations1 = try store.addObservation(obs1, 60);
    defer testing.allocator.free(violations1);
    try testing.expectEqual(@as(usize, 0), violations1.len);

    const violations2 = try store.addObservation(obs2, 60);
    defer testing.allocator.free(violations2);

    try testing.expectEqual(@as(usize, 1), violations2.len);
    try testing.expectEqual(@as(u16, 8000), violations2[0].speed);
    try testing.expectEqual(@as(u32, 0), violations2[0].obs1.timestamp);
    try testing.expectEqual(@as(u32, 45), violations2[0].obs2.timestamp);
}

test "ObservationStore - no violation when under limit" {
    var store = ObservationStore.init(testing.allocator);
    defer store.deinit();

    const obs1 = ticket.Observation{
        .road = 200,
        .mile = 0,
        .timestamp = 0,
        .plate = "SLOW1",
    };

    const obs2 = ticket.Observation{
        .road = 200,
        .mile = 1,
        .timestamp = 60,
        .plate = "SLOW1",
    };

    _ = try store.addObservation(obs1, 60);
    const violations = try store.addObservation(obs2, 60);
    defer testing.allocator.free(violations);

    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "ObservationStore - out of order observations" {
    var store = ObservationStore.init(testing.allocator);
    defer store.deinit();

    // Add later observation first
    const obs2 = ticket.Observation{
        .road = 400,
        .mile = 20,
        .timestamp = 1000,
        .plate = "OUTOFO",
    };

    const v1 = try store.addObservation(obs2, 50);
    defer testing.allocator.free(v1);
    try testing.expectEqual(@as(usize, 0), v1.len);

    // Add earlier observation
    const obs1 = ticket.Observation{
        .road = 400,
        .mile = 10,
        .timestamp = 500,
        .plate = "OUTOFO",
    };

    const violations = try store.addObservation(obs1, 50);
    defer testing.allocator.free(violations);

    // Should still detect violation
    // 10 miles in 500 seconds = 72 mph (over 50 mph limit)
    try testing.expectEqual(@as(usize, 1), violations.len);
    try testing.expectEqual(@as(u16, 7200), violations[0].speed);
}

test "ObservationStore - different plates on same road" {
    var store = ObservationStore.init(testing.allocator);
    defer store.deinit();

    const obs1 = ticket.Observation{
        .road = 123,
        .mile = 8,
        .timestamp = 0,
        .plate = "CAR1",
    };

    const obs2 = ticket.Observation{
        .road = 123,
        .mile = 9,
        .timestamp = 45,
        .plate = "CAR2",
    };

    _ = try store.addObservation(obs1, 60);
    const violations = try store.addObservation(obs2, 60);
    defer testing.allocator.free(violations);

    // Different plates, no violation should be detected
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "ObservationStore - same plate on different roads" {
    var store = ObservationStore.init(testing.allocator);
    defer store.deinit();

    const obs1 = ticket.Observation{
        .road = 123,
        .mile = 8,
        .timestamp = 0,
        .plate = "UN1X",
    };

    const obs2 = ticket.Observation{
        .road = 456,
        .mile = 9,
        .timestamp = 45,
        .plate = "UN1X",
    };

    _ = try store.addObservation(obs1, 60);
    const violations = try store.addObservation(obs2, 60);
    defer testing.allocator.free(violations);

    // Different roads, no violation should be detected
    try testing.expectEqual(@as(usize, 0), violations.len);
}

test "ObservationStore - multiple violations" {
    var store = ObservationStore.init(testing.allocator);
    defer store.deinit();

    // Camera at mile 0
    const obs1 = ticket.Observation{
        .road = 800,
        .mile = 0,
        .timestamp = 0,
        .plate = "SPEED",
    };

    // Camera at mile 10
    const obs2 = ticket.Observation{
        .road = 800,
        .mile = 10,
        .timestamp = 300,
        .plate = "SPEED",
    };

    // Camera at mile 20
    const obs3 = ticket.Observation{
        .road = 800,
        .mile = 20,
        .timestamp = 600,
        .plate = "SPEED",
    };

    const v1 = try store.addObservation(obs1, 60);
    defer testing.allocator.free(v1);
    const v2 = try store.addObservation(obs2, 60);
    defer testing.allocator.free(v2);
    const violations = try store.addObservation(obs3, 60);
    defer testing.allocator.free(violations);

    // Should detect violations for:
    // - obs1 to obs3 (20 miles in 600 sec = 120 mph)
    // - obs2 to obs3 (10 miles in 300 sec = 120 mph)
    try testing.expectEqual(@as(usize, 2), violations.len);
}
