// ============================================================================
// Budget Chat Proxy - Protohackers Challenge #3
// ============================================================================
// This implementation skips the libxev framework and uses the standard
// library's TCP server plus poll() to proxy each connection directly.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const upstream_host = "chat.protohackers.com";
const upstream_port: u16 = 16963;
const tony_address = "7YWHMfk9JZe0LM0g1ZauHuiSxhI";

const Args = struct {
    host: []u8,
    port: u16,
};

pub fn main() !void {
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

    const args = try parseArgs(allocator);
    defer allocator.free(args.host);

    const listen_addr = std.net.Address.parseIp4(args.host, args.port) catch
        std.net.Address.parseIp6(args.host, args.port) catch {
        std.log.err("Invalid listen address: {s}", .{args.host});
        return error.InvalidAddress;
    };

    var server = try listen_addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info("Proxy listening on {s}:{d}", .{ args.host, args.port });

    while (true) {
        const conn = server.accept() catch |err| {
            std.log.err("accept failed: {}", .{err});
            continue;
        };

        const thread = std.Thread.spawn(.{}, clientThread, .{ allocator, conn }) catch |err| {
            std.log.err("failed to spawn client thread: {}", .{err});
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn clientThread(allocator: std.mem.Allocator, connection: std.net.Server.Connection) void {
    handleClient(allocator, connection) catch |err| {
        std.log.err("connection handler error: {}", .{err});
    };
}

fn handleClient(allocator: std.mem.Allocator, connection: std.net.Server.Connection) !void {
    const peer_addr = connection.address;
    var client_stream = connection.stream;
    defer client_stream.close();

    var upstream_stream = std.net.tcpConnectToHost(allocator, upstream_host, upstream_port) catch |err| {
        std.log.err("failed to connect upstream for {any}: {}", .{ peer_addr, err });
        return err;
    };
    defer upstream_stream.close();

    std.log.info("proxying {any} <-> {s}:{d}", .{ peer_addr, upstream_host, upstream_port });
    try shuttle(allocator, &client_stream, &upstream_stream);
}

fn shuttle(allocator: std.mem.Allocator, client: *std.net.Stream, upstream: *std.net.Stream) !void {
    var poll_fds = [_]posix.pollfd{
        .{ .fd = client.handle, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = upstream.handle, .events = posix.POLL.IN, .revents = 0 },
    };

    var client_open = true;
    var upstream_open = true;
    var buffer: [4096]u8 = undefined;
    var client_accum = std.ArrayList(u8).empty;
    defer client_accum.deinit(allocator);
    var upstream_accum = std.ArrayList(u8).empty;
    defer upstream_accum.deinit(allocator);

    while (client_open or upstream_open) {
        poll_fds[0].events = if (client_open) posix.POLL.IN else 0;
        poll_fds[1].events = if (upstream_open) posix.POLL.IN else 0;
        for (poll_fds, 0..) |_, i| {
            poll_fds[i].revents = 0;
        }

        if (!client_open and !upstream_open) break;

        _ = try posix.poll(&poll_fds, -1);

        if (client_open and hasReadableEvent(poll_fds[0].revents)) {
            switch (try forward(allocator, client, upstream, &buffer, &client_accum)) {
                .open => {},
                .closed => {
                    if (client_open) {
                        client.close();
                        client_open = false;
                    }
                    if (upstream_open) {
                        upstream.close();
                        upstream_open = false;
                    }
                },
            }
        }

        if (upstream_open and hasReadableEvent(poll_fds[1].revents)) {
            switch (try forward(allocator, upstream, client, &buffer, &upstream_accum)) {
                .open => {},
                .closed => {
                    if (upstream_open) {
                        upstream.close();
                        upstream_open = false;
                    }
                    if (client_open) {
                        client.close();
                        client_open = false;
                    }
                },
            }
        }
    }
}

const RelayState = enum { open, closed };

fn forward(
    allocator: std.mem.Allocator,
    src: *std.net.Stream,
    dst: *std.net.Stream,
    buffer: *[4096]u8,
    accum: *std.ArrayList(u8),
) !RelayState {
    const bytes_read = src.read(buffer) catch |err| switch (err) {
        error.ConnectionResetByPeer,
        error.NotOpenForReading,
        => return .closed,
        else => return err,
    };

    if (bytes_read == 0) {
        const delivered = try flushAccumulated(allocator, dst, accum);
        if (!delivered) return .closed;
        return .closed;
    }

    try accum.appendSlice(allocator, buffer[0..bytes_read]);

    while (std.mem.indexOfScalar(u8, accum.items, '\n')) |newline_idx| {
        const line = accum.items[0 .. newline_idx + 1];
        const delivered = try deliverMessage(allocator, dst, line);
        if (!delivered) return .closed;
        removeProcessed(accum, newline_idx + 1);
    }

    return .open;
}

fn hasReadableEvent(revents: i16) bool {
    const mask: i16 = @intCast(posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR);
    return (revents & mask) != 0;
}

fn flushAccumulated(allocator: std.mem.Allocator, dst: *std.net.Stream, accum: *std.ArrayList(u8)) !bool {
    if (accum.items.len == 0) return true;
    const delivered = try deliverMessage(allocator, dst, accum.items);
    if (delivered) {
        accum.items = accum.items.ptr[0..0];
    }
    return delivered;
}

fn removeProcessed(accum: *std.ArrayList(u8), consumed: usize) void {
    const total_len = accum.items.len;
    const remaining_len = total_len - consumed;
    if (remaining_len > 0) {
        std.mem.copyForwards(u8, accum.items[0..remaining_len], accum.items[consumed..total_len]);
    }
    accum.items = accum.items.ptr[0..remaining_len];
}

fn writeAll(dst: *std.net.Stream, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const amt = dst.write(data[written..]) catch |err| switch (err) {
            error.ConnectionResetByPeer,
            error.BrokenPipe,
            => return err,
            else => return err,
        };
        if (amt == 0) return error.UnexpectedWriteZero;
        written += amt;
    }
}

fn deliverMessage(allocator: std.mem.Allocator, dst: *std.net.Stream, message: []const u8) !bool {
    const rewritten = try rewriteMessage(allocator, message);
    defer allocator.free(rewritten);
    writeAll(dst, rewritten) catch |err| switch (err) {
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        => return false,
        else => return err,
    };
    return true;
}

fn rewriteMessage(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < message.len) {
        const c = message[i];
        if (c == '7' and isStartBoundary(message, i)) {
            var j = i;
            while (j < message.len and std.ascii.isAlphanumeric(message[j])) : (j += 1) {}
            const length = j - i;
            if (length >= 26 and length <= 35 and isEndBoundary(message, j)) {
                try result.appendSlice(allocator, tony_address);
                i = j;
                continue;
            }
        }

        try result.append(allocator, c);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

fn isStartBoundary(message: []const u8, index: usize) bool {
    if (index == 0) return true;
    return message[index - 1] == ' ' or message[index - 1] == '\n' or message[index - 1] == '\r';
}

fn isEndBoundary(message: []const u8, index: usize) bool {
    if (index >= message.len) return true;
    const c = message[index];
    return c == ' ' or c == '\n' or c == '\r';
}

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    _ = args_iter.next(); // program name

    var host: ?[]u8 = null;
    var port: u16 = 3000;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host") or std.mem.eql(u8, arg, "-h")) {
            const value = args_iter.next() orelse {
                std.log.err("Missing value for --host", .{});
                std.process.exit(1);
            };
            host = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            const value = args_iter.next() orelse {
                std.log.err("Missing value for --port", .{});
                std.process.exit(1);
            };
            port = std.fmt.parseInt(u16, value, 10) catch {
                std.log.err("Invalid port: {s}", .{value});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print(
                \\Usage: bogus [options]\n
                \\  -h, --host <address>  Listen address (default: 0.0.0.0)\n
                \\  -p, --port <port>     Listen port (default: 3000)\n
                \\  --help                Show this help message\n
            , .{});
            std.process.exit(0);
        }
    }

    return Args{
        .host = host orelse try allocator.dupe(u8, "0.0.0.0"),
        .port = port,
    };
}
