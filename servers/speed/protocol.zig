//! Binary protocol encoding/decoding for Speed Daemon
//! Handles all message types and primitive types (u8, u16, u32, str)

const std = @import("std");
const testing = std.testing;

// ============================================================================
// Message Type Constants
// ============================================================================

pub const MSG_ERROR: u8 = 0x10;
pub const MSG_PLATE: u8 = 0x20;
pub const MSG_TICKET: u8 = 0x21;
pub const MSG_WANT_HEARTBEAT: u8 = 0x40;
pub const MSG_HEARTBEAT: u8 = 0x41;
pub const MSG_I_AM_CAMERA: u8 = 0x80;
pub const MSG_I_AM_DISPATCHER: u8 = 0x81;

// ============================================================================
// Message Types
// ============================================================================

pub const IAmCamera = struct {
    road: u16,
    mile: u16,
    limit: u16, // miles per hour
};

pub const IAmDispatcher = struct {
    roads: []const u16,
};

pub const Plate = struct {
    plate: []const u8,
    timestamp: u32,
};

pub const Ticket = struct {
    plate: []const u8,
    road: u16,
    mile1: u16,
    timestamp1: u32,
    mile2: u16,
    timestamp2: u32,
    speed: u16, // 100x miles per hour
};

pub const WantHeartbeat = struct {
    interval: u32, // deciseconds
};

pub const Error = struct {
    msg: []const u8,
};

// ============================================================================
// Encoding Functions
// ============================================================================

/// Encode a string in protocol format (length-prefixed)
pub fn encodeStr(writer: anytype, s: []const u8) !void {
    if (s.len > 255) return error.StringTooLong;
    try writer.writeByte(@intCast(s.len));
    try writer.writeAll(s);
}

/// Encode Error message
pub fn encodeError(writer: anytype, msg: []const u8) !void {
    try writer.writeByte(MSG_ERROR);
    try encodeStr(writer, msg);
}

/// Encode Ticket message
pub fn encodeTicket(writer: anytype, ticket: Ticket) !void {
    try writer.writeByte(MSG_TICKET);
    try encodeStr(writer, ticket.plate);
    try writer.writeInt(u16, ticket.road, .big);
    try writer.writeInt(u16, ticket.mile1, .big);
    try writer.writeInt(u32, ticket.timestamp1, .big);
    try writer.writeInt(u16, ticket.mile2, .big);
    try writer.writeInt(u32, ticket.timestamp2, .big);
    try writer.writeInt(u16, ticket.speed, .big);
}

/// Encode Heartbeat message
pub fn encodeHeartbeat(writer: anytype) !void {
    try writer.writeByte(MSG_HEARTBEAT);
}

// ============================================================================
// Decoding Functions
// ============================================================================

pub const DecodeError = error{
    EndOfStream,
    InvalidMessageType,
    StringTooLong,
    InvalidUtf8,
};

/// Decode a string from protocol format
/// Returns the string and advances the reader
pub fn decodeStr(allocator: std.mem.Allocator, reader: anytype) ![]u8 {
    const len = try reader.readByte();
    const buffer = try allocator.alloc(u8, len);
    errdefer allocator.free(buffer);

    const bytes_read = try reader.readAll(buffer);
    if (bytes_read != len) return error.EndOfStream;

    return buffer;
}

/// Decode IAmCamera message (without message type byte)
pub fn decodeIAmCamera(reader: anytype) !IAmCamera {
    return IAmCamera{
        .road = try reader.readInt(u16, .big),
        .mile = try reader.readInt(u16, .big),
        .limit = try reader.readInt(u16, .big),
    };
}

/// Decode IAmDispatcher message (without message type byte)
pub fn decodeIAmDispatcher(allocator: std.mem.Allocator, reader: anytype) !IAmDispatcher {
    const numroads = try reader.readByte();
    const roads = try allocator.alloc(u16, numroads);
    errdefer allocator.free(roads);

    for (roads) |*road| {
        road.* = try reader.readInt(u16, .big);
    }

    return IAmDispatcher{ .roads = roads };
}

/// Decode Plate message (without message type byte)
pub fn decodePlate(allocator: std.mem.Allocator, reader: anytype) !Plate {
    const plate = try decodeStr(allocator, reader);
    errdefer allocator.free(plate);

    const timestamp = try reader.readInt(u32, .big);

    return Plate{
        .plate = plate,
        .timestamp = timestamp,
    };
}

/// Decode WantHeartbeat message (without message type byte)
pub fn decodeWantHeartbeat(reader: anytype) !WantHeartbeat {
    return WantHeartbeat{
        .interval = try reader.readInt(u32, .big),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "encode/decode string" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    // Test empty string
    try encodeStr(buffer.writer(), "");
    try testing.expectEqualSlices(u8, &[_]u8{0x00}, buffer.items);

    // Test "foo"
    buffer.clearRetainingCapacity();
    try encodeStr(buffer.writer(), "foo");
    try testing.expectEqualSlices(u8, &[_]u8{ 0x03, 'f', 'o', 'o' }, buffer.items);

    // Test "Elbereth"
    buffer.clearRetainingCapacity();
    try encodeStr(buffer.writer(), "Elbereth");
    const expected = [_]u8{ 0x08, 'E', 'l', 'b', 'e', 'r', 'e', 't', 'h' };
    try testing.expectEqualSlices(u8, &expected, buffer.items);
}

test "decode string" {
    // Test "foo"
    const data = [_]u8{ 0x03, 'f', 'o', 'o' };
    var stream = std.io.fixedBufferStream(&data);
    const result = try decodeStr(testing.allocator, stream.reader());
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("foo", result);
}

test "encode Error message" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try encodeError(buffer.writer(), "bad");
    const expected = [_]u8{ 0x10, 0x03, 'b', 'a', 'd' };
    try testing.expectEqualSlices(u8, &expected, buffer.items);
}

test "encode Heartbeat message" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    try encodeHeartbeat(buffer.writer());
    try testing.expectEqualSlices(u8, &[_]u8{0x41}, buffer.items);
}

test "encode Ticket message" {
    var buffer = std.ArrayList(u8).init(testing.allocator);
    defer buffer.deinit();

    const ticket = Ticket{
        .plate = "UN1X",
        .road = 66,
        .mile1 = 100,
        .timestamp1 = 123456,
        .mile2 = 110,
        .timestamp2 = 123816,
        .speed = 10000,
    };

    try encodeTicket(buffer.writer(), ticket);

    const expected = [_]u8{
        0x21, // Message type
        0x04, 'U', 'N', '1', 'X', // plate
        0x00, 0x42, // road: 66
        0x00, 0x64, // mile1: 100
        0x00, 0x01, 0xe2, 0x40, // timestamp1: 123456
        0x00, 0x6e, // mile2: 110
        0x00, 0x01, 0xe3, 0xa8, // timestamp2: 123816
        0x27, 0x10, // speed: 10000
    };

    try testing.expectEqualSlices(u8, &expected, buffer.items);
}

test "decode IAmCamera message" {
    const data = [_]u8{
        0x00, 0x42, // road: 66
        0x00, 0x64, // mile: 100
        0x00, 0x3c, // limit: 60
    };

    var stream = std.io.fixedBufferStream(&data);
    const result = try decodeIAmCamera(stream.reader());

    try testing.expectEqual(@as(u16, 66), result.road);
    try testing.expectEqual(@as(u16, 100), result.mile);
    try testing.expectEqual(@as(u16, 60), result.limit);
}

test "decode IAmDispatcher message" {
    const data = [_]u8{
        0x03, // numroads: 3
        0x00, 0x42, // road 66
        0x01, 0x70, // road 368
        0x13, 0x88, // road 5000
    };

    var stream = std.io.fixedBufferStream(&data);
    const result = try decodeIAmDispatcher(testing.allocator, stream.reader());
    defer testing.allocator.free(result.roads);

    try testing.expectEqual(@as(usize, 3), result.roads.len);
    try testing.expectEqual(@as(u16, 66), result.roads[0]);
    try testing.expectEqual(@as(u16, 368), result.roads[1]);
    try testing.expectEqual(@as(u16, 5000), result.roads[2]);
}

test "decode Plate message" {
    const data = [_]u8{
        0x04, 'U', 'N', '1', 'X', // plate: "UN1X"
        0x00, 0x00, 0x03, 0xe8, // timestamp: 1000
    };

    var stream = std.io.fixedBufferStream(&data);
    const result = try decodePlate(testing.allocator, stream.reader());
    defer testing.allocator.free(result.plate);

    try testing.expectEqualStrings("UN1X", result.plate);
    try testing.expectEqual(@as(u32, 1000), result.timestamp);
}

test "decode WantHeartbeat message" {
    const data = [_]u8{
        0x00, 0x00, 0x00, 0x0a, // interval: 10
    };

    var stream = std.io.fixedBufferStream(&data);
    const result = try decodeWantHeartbeat(stream.reader());

    try testing.expectEqual(@as(u32, 10), result.interval);
}
