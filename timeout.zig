// zig v0.14.0-dev.1511+54b668f8a (2024-09-12)
// (because 'std.process.Child.pgid' was added after v0.13.0)

const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const Signal = u8;
const SIG = std.c.SIG;
const Allocator = std.mem.Allocator;
const AtomicBool = std.atomic.Value(bool);
const native_os = builtin.os.tag;

const timeout_context = struct {
    child: *std.process.Child,
    timeout_reached: *AtomicBool,
    child_exited: *AtomicBool,
    term_delay: u64,
    kill_delay: ?u64,
    pid: std.process.Child.Id,
    signal: Signal,
};
var child_term: ?std.process.Child.Term = null;

const second_ns = 1_000_000_000; // 1s in nanos
// const ms = 1_000_000; // 1ms in nanos

fn parse_signal(signal_name: []const u8) Signal {
    if (std.mem.eql(u8, signal_name, "term")) {
        return SIG.TERM;
    } else if (std.mem.eql(u8, signal_name, "kill")) {
        return SIG.KILL;
    } else if (std.mem.eql(u8, signal_name, "cont")) {
        return SIG.CONT;
    } else if (std.mem.eql(u8, signal_name, "int")) {
        return SIG.INT;
    } else {
        return SIG.TERM; // default is SIGTERM
    }
}

fn parse_duration(duration: []const u8) u64 {
    const value: []const u8 = duration[0 .. duration.len - 1];
    const suffix: u8 = duration[duration.len - 1];
    const parsed_value: u64 = std.fmt.parseInt(u64, value, 10) catch |e| {
        std.debug.print("could not parse duration '{any}': {any}\n", .{ value, e });
        std.process.exit(125);
        return 0;
    };

    return switch (suffix) {
        's' => parsed_value, // seconds
        'm' => parsed_value * 60, // minutes
        'h' => parsed_value * 3600, // hours
        'd' => parsed_value * 86400, // days
        else => parsed_value, // default to seconds if no suffix
    };
}

fn wait_for_child(ctx: *const timeout_context) void {
    child_term = ctx.child.wait() catch |e| {
        ctx.child_exited.store(true, .seq_cst);
        switch (e) {
            error.FileNotFound => {
                std.process.exit(127);
            },
            error.AccessDenied => {
                std.process.exit(126);
            },
            else => {
                std.debug.print("error waiting on child to exit: {any}\n", .{e});
                std.process.exit(125);
            },
        }
        return;
    };
    ctx.child_exited.store(true, .seq_cst);

    if (ctx.timeout_reached.load(.seq_cst)) {
        return;
    }

    if (child_term) |term| {
        switch (term) {
            std.process.Child.Term.Exited => |status| {
                std.process.exit(status);
            },
            else => {
                std.debug.print("unsupported return type: {any}\n", .{term});
                std.process.exit(125); // unknown error
            },
        }
    }
}

fn wait_for_timeout(ctx: *const timeout_context) void {
    std.time.sleep(ctx.term_delay);
    if (ctx.child_exited.load(.seq_cst)) {
        return;
    }

    ctx.timeout_reached.store(true, .seq_cst);
    std.posix.kill(ctx.pid, ctx.signal) catch |e| {
        switch (e) {
            std.posix.KillError.ProcessNotFound => {
                return;
            },
            else => {
                std.debug.print("error signaling child process: {any}\n", .{e});
                std.process.exit(125);
            },
        }
    };

    if (ctx.kill_delay) |kill_delay| {
        std.time.sleep(kill_delay);
        if (ctx.child_exited.load(.seq_cst)) {
            return;
        }

        // ctx.kill_reached.store(true, .seq_cst);
        std.posix.kill(ctx.pid, SIG.KILL) catch |e| {
            switch (e) {
                std.posix.KillError.ProcessNotFound => {
                    return;
                },
                else => {
                    std.debug.print("error killing child process: {any}\n", .{e});
                    std.process.exit(125);
                },
            }
        };
    }
}

pub fn main() !void {
    const args = std.process.args;
    const allocator = std.heap.page_allocator;

    var arg_count: usize = 0;
    var arg_iter1 = args();
    while (arg_iter1.next()) |_| {
        arg_count += 1;
    }

    if (arg_count < 3) {
        std.debug.print("USAGE\n\ttimeout [-f] [-p] [-k duration] [-s signal] <duration> <command> [arguments...]\n\n", .{});
        std.debug.print("EXAMPLE\n\ttimeout -p -k 3s -s TERM 1.5m <command> [arguments...]\n\n", .{});
        return;
    }

    // Restart the argument iterator to parse the arguments
    var arg_iter2 = args();
    var current_arg: ?[]const u8 = undefined;

    var signal: Signal = SIG.TERM;
    var kill_after: ?u64 = null;
    var signal_child_only = false;
    var preserve_status = false;

    _ = arg_iter2.next(); // 0th arg 'timeout'

    while (arg_iter2.next()) |arg| {
        switch (arg[0]) {
            '-' => {
                switch (arg[1]) {
                    'f' => signal_child_only = true,
                    'p' => preserve_status = true,
                    's' => {
                        current_arg = arg_iter2.next();
                        signal = parse_signal(current_arg.?);
                    },
                    'k' => {
                        current_arg = arg_iter2.next();
                        kill_after = parse_duration(current_arg.?);
                    },
                    else => {
                        std.debug.print("unknown option: {s}\n", .{arg});
                        std.process.exit(125);
                    },
                }
            },
            else => {
                current_arg = arg;
                break;
            },
        }
    }
    const kill_delay = if (kill_after) |kill_after_s| kill_after_s * second_ns else null;

    const duration = parse_duration(current_arg.?);
    const term_delay = duration * second_ns;

    current_arg = arg_iter2.next();
    const command = current_arg.?;
    var mut_args = std.ArrayList([]const u8).init(allocator);
    try mut_args.append(command);
    while (arg_iter2.next()) |arg| {
        try mut_args.append(arg);
    }
    defer mut_args.deinit();

    var child = std.process.Child.init(
        try mut_args.toOwnedSlice(),
        allocator,
    );
    child.cwd_dir = fs.cwd();
    if (native_os != .windows and native_os != .wasi) {
        if (!signal_child_only) {
            child.pgid = 0; // not available in v0.13.0
        }
    }

    child.spawn() catch |e| {
        std.debug.print("could not exec command '{s}': {any}\n", .{ command, e });
        std.process.exit(126);
        return;
    };

    const pid = if (native_os != .windows and native_os != .wasi) child.id else if (signal_child_only) child.id else -child.id;

    var timeout_reached = AtomicBool.init(false);
    var child_exited = AtomicBool.init(false);

    const cfg = std.Thread.SpawnConfig{
        .allocator = allocator,
    };
    const ctx = &timeout_context{
        .child = &child,
        .child_exited = &child_exited,
        .timeout_reached = &timeout_reached,
        .term_delay = term_delay,
        .kill_delay = kill_delay,
        .pid = pid,
        .signal = signal,
    };
    var child_thread = try std.Thread.spawn(cfg, wait_for_child, .{ctx});
    _ = try std.Thread.spawn(cfg, wait_for_timeout, .{ctx});

    child_thread.join();
    if (!preserve_status) {
        std.process.exit(124);
        return;
    }

    if (child_term) |e| {
        switch (e) {
            std.process.Child.Term.Exited => |status| {
                std.process.exit(status);
            },
            else => {
                std.process.exit(125);
            },
        }
    }

    std.process.exit(125);
}
