const std = @import("std");

// ============================================================================
// Protohackers Multi-Server Build Configuration
// ============================================================================
// To add a new server, just call addServer() with the server name and port.
// This will create all the build steps automatically:
//   zig build {name}        - Build and run locally
//   zig build {name}-linux  - Cross-compile for Linux
//   zig build {name}-deploy - Deploy to server
//   zig build {name}-run    - Deploy and run
//   zig build {name}-stop   - Stop the server
//   zig build {name}-status - Check server status
//   zig build {name}-logs   - View server logs

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add servers here - each call creates all build steps
    addServer(b, "smoke", 3000, target, optimize, true);
    addServer(b, "prime", 3001, target, optimize, true);
    addServer(b, "prices", 3002, target, optimize, true);
    addServer(b, "chat", 3003, target, optimize, true);
    addServer(b, "wdb", 3004, target, optimize, true);
    addServer(b, "bogus", 3005, target, optimize, false);
}

// ============================================================================
// Server Build Configuration
// ============================================================================

const ServerConfig = struct {
    name: []const u8,
    port: u16,
    use_framework: bool,
};

/// Add all build steps for a server
fn addServer(
    b: *std.Build,
    name: []const u8,
    port: u16,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_framework: bool,
) void {
    const config = ServerConfig{ .name = name, .port = port, .use_framework = use_framework };

    // Allocate stable strings for step names
    const step_linux = std.fmt.allocPrint(b.allocator, "{s}-linux", .{name}) catch @panic("OOM");
    const step_deploy = std.fmt.allocPrint(b.allocator, "{s}-deploy", .{name}) catch @panic("OOM");
    const step_run = std.fmt.allocPrint(b.allocator, "{s}-run", .{name}) catch @panic("OOM");
    const step_stop = std.fmt.allocPrint(b.allocator, "{s}-stop", .{name}) catch @panic("OOM");
    const step_status = std.fmt.allocPrint(b.allocator, "{s}-status", .{name}) catch @panic("OOM");
    const step_logs = std.fmt.allocPrint(b.allocator, "{s}-logs", .{name}) catch @panic("OOM");

    // Create the server framework module (shared by all servers)
    const server_module = if (config.use_framework)
        b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        })
    else
        null;

    if (config.use_framework) {
        const xev_dep = b.dependency("libxev", .{
            .target = target,
            .optimize = optimize,
        });
        server_module.?.addImport("xev", xev_dep.module("xev"));
    }

    // ========================================================================
    // Local build and run
    // ========================================================================
    const exe = b.addExecutable(.{
        .name = config.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("servers/{s}/main.zig", .{config.name})),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (config.use_framework) {
        exe.root_module.addImport("server", server_module.?);
    }

    b.installArtifact(exe);

    const run_step = b.step(config.name, b.fmt("Build and run {s} server locally", .{config.name}));
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&exe.step);
    // Add default port argument
    run_cmd.addArgs(&[_][]const u8{ "-p", b.fmt("{d}", .{config.port}) });
    // Add any additional user-provided arguments
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    // ========================================================================
    // Linux cross-compilation
    // ========================================================================
    const linux_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .gnu,
    });

    const server_module_linux = if (config.use_framework)
        b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = linux_target,
            .optimize = .ReleaseFast,
        })
    else
        null;

    if (config.use_framework) {
        const xev_linux = b.dependency("libxev", .{
            .target = linux_target,
            .optimize = .ReleaseFast,
        });
        server_module_linux.?.addImport("xev", xev_linux.module("xev"));
    }

    const linux_exe = b.addExecutable(.{
        .name = config.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("servers/{s}/main.zig", .{config.name})),
            .target = linux_target,
            .optimize = .ReleaseFast,
        }),
    });
    if (config.use_framework) {
        linux_exe.root_module.addImport("server", server_module_linux.?);
    }

    const install_linux = b.addInstallArtifact(linux_exe, .{
        .dest_dir = .{ .override = .{ .custom = b.fmt("linux/{s}", .{config.name}) } },
    });

    const linux_step = b.step(
        step_linux,
        b.fmt("Build {s} for Linux x86_64", .{config.name}),
    );
    linux_step.dependOn(&install_linux.step);

    // ========================================================================
    // Deploy to server
    // ========================================================================
    const deploy_step = b.step(
        step_deploy,
        b.fmt("Deploy {s} to server", .{config.name}),
    );
    deploy_step.dependOn(&install_linux.step);

    // Create deploy directory
    const mkdir_cmd = b.addSystemCommand(&[_][]const u8{
        "ssh",
        "proto",
        "mkdir -p deploy",
    });
    mkdir_cmd.step.dependOn(&install_linux.step);

    // SCP binary to server
    const scp_cmd = b.addSystemCommand(&[_][]const u8{
        "scp",
        b.fmt("zig-out/linux/{s}/{s}", .{ config.name, config.name }),
        b.fmt("proto:~/deploy/{s}", .{config.name}),
    });
    scp_cmd.step.dependOn(&mkdir_cmd.step);
    deploy_step.dependOn(&scp_cmd.step);

    // ========================================================================
    // Deploy and run
    // ========================================================================
    const run_remote_step = b.step(
        step_run,
        b.fmt("Deploy and run {s} on server", .{config.name}),
    );
    run_remote_step.dependOn(&scp_cmd.step);

    const ssh_run = b.addSystemCommand(&[_][]const u8{
        "ssh",
        "-f",
        "proto",
        b.fmt(
            "cd deploy && nohup ./{s} -p {d} > {s}.log 2>&1 &",
            .{ config.name, config.port, config.name },
        ),
    });
    ssh_run.step.dependOn(&scp_cmd.step);
    run_remote_step.dependOn(&ssh_run.step);

    // ========================================================================
    // Stop server
    // ========================================================================
    const stop_step = b.step(
        step_stop,
        b.fmt("Stop {s} server", .{config.name}),
    );
    const ssh_stop = b.addSystemCommand(&[_][]const u8{
        "ssh",
        "proto",
        b.fmt("pkill {s} && echo 'Server stopped' || echo 'No server running'", .{config.name}),
    });
    stop_step.dependOn(&ssh_stop.step);
    scp_cmd.step.dependOn(&ssh_stop.step);

    // ========================================================================
    // Check status
    // ========================================================================
    const status_step = b.step(
        step_status,
        b.fmt("Check {s} server status", .{config.name}),
    );
    const ssh_status = b.addSystemCommand(&[_][]const u8{
        "ssh",
        "proto",
        b.fmt("pgrep -a {s} || echo 'No server running'", .{config.name}),
    });
    status_step.dependOn(&ssh_status.step);

    // ========================================================================
    // View logs
    // ========================================================================
    const logs_step = b.step(
        step_logs,
        b.fmt("View {s} server logs", .{config.name}),
    );
    const ssh_logs = b.addSystemCommand(&[_][]const u8{
        "ssh",
        "proto",
        b.fmt("tail -n 50 deploy/{s}.log || echo 'No log file found'", .{config.name}),
    });
    logs_step.dependOn(&ssh_logs.step);
}
