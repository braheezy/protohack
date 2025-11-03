// ============================================================================
// Prime Server - Protohackers Challenge #1
// ============================================================================

const std = @import("std");
const builtin = @import("builtin");
const server = @import("server");

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

    try server.run(allocator, PrimeHandler);
}

// ============================================================================
// Handler Implementation
// ============================================================================

const Message = struct { method: []const u8, number: std.json.Value };
const Response = struct { method: []const u8, prime: bool };

const PrimeHandler = struct {
    pub fn onData(_: *PrimeHandler, allocator: std.mem.Allocator, data: []const u8) !server.HandlerResponse {
        // Trim newline from the line
        const line = std.mem.trimRight(u8, data, "\n\r");

        const parsed = std.json.parseFromSlice(
            Message,
            allocator,
            line,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            return switch (err) {
                else => {
                    std.log.info("malformed JSON error: {any}", .{err});
                    return .{ .data = "malformed\n" };
                },
            };
        };
        std.log.info("Parsed: {any}", .{parsed.value});
        if (!std.mem.eql(u8, parsed.value.method, "isPrime")) {
            const msg = try allocator.dupe(u8, "malformed\n");
            return .{ .data = msg };
        }
        const is_prime = isPrime(parsed.value.number) catch |err| {
            switch (err) {
                error.InvalidNumber => {
                    // Wrong type for number field - return false but keep connection alive
                    return .{ .data = "malformed\n" };
                },
            }
        };

        const result = try createResponse(allocator, is_prime);
        return .{ .data = result, .close_after_write = false };
    }

    fn isPrime(val: std.json.Value) !bool {
        const number: f64 = switch (val) {
            .float => val.float,
            .integer => @floatFromInt(val.integer),
            .number_string => {
                // Numbers too large to fit in standard JSON number type
                // These can't be prime because they're not representable as integers in f64
                std.log.info("Number too large, treating as not prime", .{});
                return false;
            },
            else => {
                // Wrong type (string, bool, array, object, null)
                std.log.info("Wrong type for number field: {any}", .{val});
                return error.InvalidNumber;
            },
        };
        std.log.info("Number: {d}", .{number});
        // Negative numbers and non-integers are not prime
        if (number < 0) return false;

        const n: u64 = @intFromFloat(number);
        // If it's not an integer (has fractional part), it's not prime
        if (@as(f64, @floatFromInt(n)) != number) return false;

        // 0 and 1 are not prime
        if (n <= 1) return false;

        // 2 and 3 are prime
        if (n <= 3) return true;

        // If divisible by 2 or 3, it's NOT prime
        if (n % 2 == 0 or n % 3 == 0) return false;

        // Check all numbers of the form 6k±1 which are ≤ √n
        var i: u64 = 5;
        while (i * i <= n) : (i += 6) {
            if (n % i == 0 or n % (i + 2) == 0) return false;
        }
        return true;
    }

    fn createResponse(allocator: std.mem.Allocator, is_prime: bool) ![]const u8 {
        const response = Response{ .method = "isPrime", .prime = is_prime };
        const json = try std.json.Stringify.valueAlloc(allocator, response, .{});
        const result = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
        allocator.free(json);
        return result;
    }
};
