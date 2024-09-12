const std = @import("std");
const fs = std.fs;
const Signal = u8;
const SIG = std.c.SIG;
const Allocator = std.mem.Allocator;

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
    const parsed_value: u64 = std.fmt.parseInt(u64, value, 10) catch {
        std.debug.print("Failed to parse duration.\n", .{});
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

pub fn main() !void {
    const args = std.process.args;
    const allocator = std.heap.page_allocator;

    var arg_count: usize = 0;
    var arg_iter1 = args();
    while (arg_iter1.next()) |_| {
        arg_count += 1;
    }

    if (arg_count < 3) {
        std.debug.print("Usage: timeout [-fp] [-k time] [-s signal_name] duration utility [argument...]\n", .{});
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
                    '-' => break,
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
                        // ignore
                    },
                }
            },
            else => {
                current_arg = arg;
                std.debug.print("breaking_arg dur: {?s}\n", .{current_arg});
                break;
            },
        }
    }

    const duration = parse_duration(current_arg.?);
    std.debug.print("current_arg dur: {?s} {any}\n", .{ current_arg, duration });

    current_arg = arg_iter2.next();
    const utility = current_arg.?;
    var mut_args = std.ArrayList([]const u8).init(allocator);
    try mut_args.append(utility);
    while (arg_iter2.next()) |arg| {
        try mut_args.append(arg);
    }
    defer mut_args.deinit();

    var child = std.process.Child.init(
        try mut_args.toOwnedSlice(),
        allocator,
    );
    child.cwd_dir = fs.cwd();

    // const s = 1_000_000_000; // 1s in nanos
    const ms = 1_000_000; // 1ms in nanos
    //
    var timed_out = false;
    const start_time = std.time.milliTimestamp();
    const check_delay = 100 * ms; // TODO thread and join instead of poll?
    child.spawn() catch {
        std.debug.print("Failed to start utility: {s}\n", .{utility});
        return;
    };

    var pid = -child.id;
    if (signal_child_only) {
        pid = child.id;
    }

    const wait_timeout = duration * 1000;
    while (true) {
        std.time.sleep(check_delay);

        const status = std.posix.kill(child.id, 0) catch |e| {
            std.debug.print("timeout check error: {any} {any}\n", .{ child.id, e });
            switch (e) {
                std.posix.KillError.ProcessNotFound => {
                    break;
                },
                else => {},
            }
        };
        std.debug.print("timeout check result: {any} {any}\n", .{ child.id, status });

        const now = std.time.milliTimestamp();
        const delta = now - start_time;
        if (delta < wait_timeout) {
            continue;
        }

        timed_out = true;
        std.posix.kill(pid, signal) catch |e| {
            switch (e) {
                std.posix.KillError.ProcessNotFound => {
                    break;
                },
                else => {
                    std.debug.print("error killing child process: {any}\n", .{e});
                    std.process.exit(125);
                },
            }
        };
    }

    if (kill_after) |kill_after_s| {
        const wait_kill = kill_after_s * 1000;
        const start_kill = std.time.milliTimestamp();
        while (true) {
            std.time.sleep(check_delay);

            const status = std.posix.kill(child.id, 0) catch |e| {
                std.debug.print("kill check error: {any}\n", .{e});
                switch (e) {
                    std.posix.KillError.ProcessNotFound => {
                        break;
                    },
                    else => {},
                }
            };
            std.debug.print("kill check result: {any}\n", .{status});

            const now = std.time.milliTimestamp();
            const delta = now - start_kill;
            if (delta >= wait_kill) {
                std.posix.kill(pid, SIG.KILL) catch |e| {
                    switch (e) {
                        std.posix.KillError.ProcessNotFound => {
                            break;
                        },
                        else => {},
                    }
                };
                break;
            }
        }
    }

    const exit_status = child.wait() catch |e| {
        std.debug.print("error while waiting for child process: {any}\n", .{e});
        std.process.exit(125);
    };

    if (!preserve_status) {
        const code: u8 = if (timed_out) 124 else 0;
        std.process.exit(code);
        return;
    }

    switch (exit_status) {
        std.process.Child.Term.Exited => |status| {
            std.process.exit(status);
        },
        else => {
            std.process.exit(125);
        },
    }

    std.debug.print("Timeout finished.\n", .{});
}
