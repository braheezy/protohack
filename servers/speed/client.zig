//! Client state machine
//! Tracks client type (unidentified, camera, dispatcher) and prevents invalid state transitions

const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol.zig");

// ============================================================================
// Client State
// ============================================================================

pub const ClientType = enum {
    unidentified,
    camera,
    dispatcher,
};

pub const CameraInfo = struct {
    road: u16,
    mile: u16,
    limit: u16,
};

pub const DispatcherInfo = struct {
    roads: []const u16,
};

pub const ClientState = struct {
    client_type: ClientType,
    camera_info: ?CameraInfo,
    dispatcher_info: ?DispatcherInfo,
    heartbeat_interval: u32, // deciseconds, 0 = no heartbeat
    heartbeat_requested: bool,

    pub fn init() ClientState {
        return .{
            .client_type = .unidentified,
            .camera_info = null,
            .dispatcher_info = null,
            .heartbeat_interval = 0,
            .heartbeat_requested = false,
        };
    }

    /// Identify as a camera
    /// Returns error if already identified
    pub fn identifyAsCamera(self: *ClientState, road: u16, mile: u16, limit: u16) !void {
        if (self.client_type != .unidentified) {
            return error.AlreadyIdentified;
        }

        self.client_type = .camera;
        self.camera_info = CameraInfo{
            .road = road,
            .mile = mile,
            .limit = limit,
        };
    }

    /// Identify as a dispatcher
    /// Returns error if already identified
    /// Takes ownership of the roads slice
    pub fn identifyAsDispatcher(self: *ClientState, roads: []const u16) !void {
        if (self.client_type != .unidentified) {
            return error.AlreadyIdentified;
        }

        self.client_type = .dispatcher;
        self.dispatcher_info = DispatcherInfo{
            .roads = roads,
        };
    }

    /// Request heartbeat
    /// Returns error if already requested
    pub fn requestHeartbeat(self: *ClientState, interval: u32) !void {
        if (self.heartbeat_requested) {
            return error.HeartbeatAlreadyRequested;
        }

        self.heartbeat_interval = interval;
        self.heartbeat_requested = true;
    }

    /// Check if this client can send plate observations
    pub fn canSendPlate(self: *ClientState) bool {
        return self.client_type == .camera;
    }

    /// Check if this client is a camera
    pub fn isCamera(self: *ClientState) bool {
        return self.client_type == .camera;
    }

    /// Check if this client is a dispatcher
    pub fn isDispatcher(self: *ClientState) bool {
        return self.client_type == .dispatcher;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "ClientState - initial state" {
    var state = ClientState.init();

    try testing.expectEqual(ClientType.unidentified, state.client_type);
    try testing.expect(!state.canSendPlate());
    try testing.expect(!state.isCamera());
    try testing.expect(!state.isDispatcher());
}

test "ClientState - identify as camera" {
    var state = ClientState.init();

    try state.identifyAsCamera(123, 10, 60);

    try testing.expectEqual(ClientType.camera, state.client_type);
    try testing.expect(state.canSendPlate());
    try testing.expect(state.isCamera());
    try testing.expect(state.camera_info != null);
    try testing.expectEqual(@as(u16, 123), state.camera_info.?.road);
    try testing.expectEqual(@as(u16, 10), state.camera_info.?.mile);
    try testing.expectEqual(@as(u16, 60), state.camera_info.?.limit);
}

test "ClientState - identify as dispatcher" {
    var state = ClientState.init();

    const roads = [_]u16{ 123, 456 };
    try state.identifyAsDispatcher(&roads);

    try testing.expectEqual(ClientType.dispatcher, state.client_type);
    try testing.expect(!state.canSendPlate());
    try testing.expect(state.isDispatcher());
    try testing.expect(state.dispatcher_info != null);
    try testing.expectEqual(@as(usize, 2), state.dispatcher_info.?.roads.len);
}

test "ClientState - cannot identify twice as camera" {
    var state = ClientState.init();

    try state.identifyAsCamera(123, 10, 60);

    const result = state.identifyAsCamera(456, 20, 50);
    try testing.expectError(error.AlreadyIdentified, result);
}

test "ClientState - cannot identify twice as dispatcher" {
    var state = ClientState.init();

    const roads1 = [_]u16{123};
    try state.identifyAsDispatcher(&roads1);

    const roads2 = [_]u16{456};
    const result = state.identifyAsDispatcher(&roads2);
    try testing.expectError(error.AlreadyIdentified, result);
}

test "ClientState - cannot identify as both camera and dispatcher" {
    var state = ClientState.init();

    try state.identifyAsCamera(123, 10, 60);

    const roads = [_]u16{456};
    const result = state.identifyAsDispatcher(&roads);
    try testing.expectError(error.AlreadyIdentified, result);
}

test "ClientState - heartbeat request" {
    var state = ClientState.init();

    try state.requestHeartbeat(100);

    try testing.expect(state.heartbeat_requested);
    try testing.expectEqual(@as(u32, 100), state.heartbeat_interval);
}

test "ClientState - cannot request heartbeat twice" {
    var state = ClientState.init();

    try state.requestHeartbeat(100);

    const result = state.requestHeartbeat(200);
    try testing.expectError(error.HeartbeatAlreadyRequested, result);
}

test "ClientState - can send plate only as camera" {
    var state = ClientState.init();
    try testing.expect(!state.canSendPlate());

    try state.identifyAsCamera(123, 10, 60);
    try testing.expect(state.canSendPlate());
}
