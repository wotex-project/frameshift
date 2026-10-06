const std = @import("std");
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cDefine("_POSIX_C_SOURCE", "200809L");
    @cDefine("_DARWIN_C_SOURCE", "1");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("time.h");
    @cInclude("signal.h");
});

const invalid = error.Refused;
const maximum_request = 288 * 1024;

const Request = struct {
    milliseconds: u32,
    stdout: u32,
    stderr: u32,
    executable: []const u8,
    cwd: []const u8,
    arguments: []const []const u8,

    fn parse(bytes: []const u8, allocator: std.mem.Allocator) !Request {
        if (bytes.len < 20 or bytes.len > maximum_request or bytes[0] != 1 or bytes[1] != 0) return invalid;
        const count = std.mem.readInt(u16, bytes[2..4], .big);
        const milliseconds = std.mem.readInt(u32, bytes[4..8], .big);
        const stdout = std.mem.readInt(u32, bytes[8..12], .big);
        const stderr = std.mem.readInt(u32, bytes[12..16], .big);
        const executable_len = std.mem.readInt(u16, bytes[16..18], .big);
        const cwd_len = std.mem.readInt(u16, bytes[18..20], .big);
        if (count > 256 or milliseconds == 0 or milliseconds > 900_000 or
            stdout == 0 or stdout > 16 * 1024 * 1024 or stderr == 0 or stderr > 16 * 1024 * 1024 or
            executable_len == 0 or cwd_len == 0) return invalid;
        var offset: usize = 20;
        const executable = try take(bytes, &offset, executable_len);
        const cwd = try take(bytes, &offset, cwd_len);
        if (executable[0] != '/' or cwd[0] != '/') return invalid;
        const arguments = try allocator.alloc([]const u8, count);
        var total: usize = 0;
        for (arguments) |*argument| {
            if (offset + 2 > bytes.len) return invalid;
            const length = std.mem.readInt(u16, bytes[offset..][0..2], .big);
            offset += 2;
            argument.* = try take(bytes, &offset, length);
            total += length;
            if (total > 256 * 1024) return invalid;
        }
        if (offset != bytes.len) return invalid;
        return .{ .milliseconds = milliseconds, .stdout = stdout, .stderr = stderr, .executable = executable, .cwd = cwd, .arguments = arguments };
    }

    fn take(bytes: []const u8, offset: *usize, length: usize) ![]const u8 {
        if (length > 8192 or length > bytes.len - offset.*) return invalid;
        const value = bytes[offset.*..][0..length];
        if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return invalid;
        offset.* += length;
        return value;
    }
};

fn now() !u64 {
    var value: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &value) != 0 or value.tv_sec < 0) return invalid;
    return @as(u64, @intCast(value.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(value.tv_nsec));
}

fn transfer(fd: c_int, bytes: []u8, writing: bool, deadline: u64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const current = try now();
        if (current >= deadline) return invalid;
        const events: c_short = if (writing) c.POLLOUT else c.POLLIN;
        var poll = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };
        const result = c.poll(&poll, 1, @intCast(@min((deadline - current + 999_999) / 1_000_000, 900_000)));
        if (result < 0 and std.c.errno(result) == .INTR) continue;
        if (result <= 0 or poll.revents & events == 0) return invalid;
        const count = if (writing) c.write(fd, bytes[offset..].ptr, bytes.len - offset) else c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (count < 0 and (std.c.errno(count) == .INTR or std.c.errno(count) == .AGAIN)) continue;
        if (count <= 0) return invalid;
        offset += @intCast(count);
    }
}

fn output(bytes: []const u8, deadline: u64) !void {
    try transfer(1, @constCast(bytes), true, deadline);
}

fn frame(bytes: []const u8, deadline: u64) !void {
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, @intCast(bytes.len), .big);
    try output(&prefix, deadline);
    try output(bytes, deadline);
}

fn nonblocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return invalid;
}

fn pipe() ![2]c_int {
    var descriptors: [2]c_int = undefined;
    if (c.pipe(&descriptors) != 0) return invalid;
    errdefer for (descriptors) |fd| {
        _ = c.close(fd);
    };
    for (descriptors) |fd| {
        const flags = c.fcntl(fd, c.F_GETFD);
        if (flags < 0 or c.fcntl(fd, c.F_SETFD, flags | c.FD_CLOEXEC) < 0) return invalid;
    }
    try nonblocking(descriptors[0]);
    return descriptors;
}

const Child = struct {
    pid: c.pid_t,
    stdout: c_int,
    stderr: c_int,
    exit: ?c_int = null,
    exit_seen: ?u64 = null,
    failure: u8 = 0,
    term_sent: bool = false,

    fn reap(self: *Child) void {
        if (self.exit != null) return;
        var status: c_int = 0;
        const result = c.waitpid(self.pid, &status, c.WNOHANG);
        if (result == self.pid and status & 0x7f != 0x7f and status != 0xffff) {
            self.exit = status;
            self.exit_seen = now() catch 0;
            if (status != 0) self.refuse(2);
        } else if (result < 0 and std.c.errno(result) != .INTR) {
            // Unknown custody cannot grant an exit or a reused-PID signal.
            self.failure = 7;
            self.term_sent = true;
        }
    }

    fn refuse(self: *Child, category: u8) void {
        if (self.failure == 0) self.failure = category;
        if (!self.term_sent and self.exit == null) {
            self.term_sent = true;
            _ = c.kill(self.pid, c.SIGTERM);
        }
    }

    fn drain(self: *Child, fd: *c_int, bytes: []u8, size: *usize) void {
        if (fd.* < 0) return;
        var block: [16 * 1024]u8 = undefined;
        for (0..4) |_| {
            const count = c.read(fd.*, &block, block.len);
            if (count > 0) {
                const length: usize = @intCast(count);
                if (self.failure == 0) {
                    if (length > bytes.len - size.*) self.refuse(4) else {
                        @memcpy(bytes[size.*..][0..length], block[0..length]);
                        size.* += length;
                    }
                }
            } else if (count == 0) {
                _ = c.close(fd.*);
                fd.* = -1;
                return;
            } else if (std.c.errno(count) == .AGAIN) return else if (std.c.errno(count) != .INTR) {
                self.refuse(6);
                _ = c.close(fd.*);
                fd.* = -1;
                return;
            }
        }
    }

    fn close(self: *Child) void {
        if (self.stdout >= 0) _ = c.close(self.stdout);
        if (self.stderr >= 0) _ = c.close(self.stderr);
        self.stdout = -1;
        self.stderr = -1;
    }
};

fn launch(request: Request, allocator: std.mem.Allocator) !Child {
    const executable = try allocator.dupeZ(u8, request.executable);
    const cwd = try allocator.dupeZ(u8, request.cwd);
    var argv: [258][*c]u8 = .{null} ** 258;
    argv[0] = executable.ptr;
    for (request.arguments, 1..) |argument, index| argv[index] = (try allocator.dupeZ(u8, argument)).ptr;
    const stdout = try pipe();
    errdefer for (stdout) |fd| {
        _ = c.close(fd);
    };
    const stderr = try pipe();
    errdefer for (stderr) |fd| {
        _ = c.close(fd);
    };
    const null_fd = c.open("/dev/null", c.O_RDONLY | c.O_CLOEXEC);
    if (null_fd < 0) return invalid;
    defer _ = c.close(null_fd);
    const pid = c.fork();
    if (pid < 0) return invalid;
    if (pid == 0) {
        // exec preserves blocked signals and ignored dispositions. Establish a
        // caught TERM handler (reset by exec) and an empty mask before exec.
        var signals: c.sigset_t = undefined;
        if (c.sigemptyset(&signals) != 0 or c.sigprocmask(c.SIG_SETMASK, &signals, null) != 0) c._exit(127);
        _ = c.signal(c.SIGTERM, ignoreSignal);
        if (c.dup2(null_fd, 0) < 0 or c.dup2(stdout[1], 1) < 0 or c.dup2(stderr[1], 2) < 0 or c.chdir(cwd.ptr) != 0) c._exit(127);
        for (stdout ++ stderr) |fd| {
            _ = c.close(fd);
        }
        _ = c.close(null_fd);
        _ = c.execv(executable.ptr, &argv);
        c._exit(127);
    }
    _ = c.close(stdout[1]);
    _ = c.close(stderr[1]);
    return .{ .pid = pid, .stdout = stdout[0], .stderr = stderr[0] };
}

fn run(start: u64, allocator: std.mem.Allocator) !u8 {
    var prefix: [4]u8 = undefined;
    try transfer(0, &prefix, false, start + 5_000_000_000);
    const length = std.mem.readInt(u32, &prefix, .big);
    if (length < 20 or length > maximum_request) return invalid;
    const bytes = try allocator.alloc(u8, length);
    try transfer(0, bytes, false, start + 5_000_000_000);
    const request = try Request.parse(bytes, allocator);
    const deadline = start + @as(u64, request.milliseconds) * 1_000_000;
    if (try now() >= deadline) return 3;
    const out = try allocator.alloc(u8, request.stdout);
    const err = try allocator.alloc(u8, request.stderr);
    var out_size: usize = 0;
    var err_size: usize = 0;
    var child = try launch(request, allocator);
    defer child.close();
    var control: [5]u8 = undefined;
    var control_size: usize = 0;
    var control_open = true;
    while (true) {
        child.reap();
        const time = now() catch {
            child.refuse(1);
            continue;
        };
        if (time >= deadline) child.refuse(3);
        child.drain(&child.stdout, out, &out_size);
        child.drain(&child.stderr, err, &err_size);
        if (control_open) {
            const count = c.read(0, control[control_size..].ptr, control.len - control_size);
            if (count > 0) {
                control_size += @intCast(count);
                if (control_size == control.len) {
                    child.refuse(if (std.mem.eql(u8, &control, &.{ 0, 0, 0, 1, 0 })) 5 else 1);
                    control_open = false;
                }
            } else if (count == 0) {
                child.refuse(5);
                control_open = false;
            } else if (std.c.errno(count) != .INTR and std.c.errno(count) != .AGAIN) {
                child.refuse(1);
                control_open = false;
            }
        }
        if (child.exit_seen) |observed| {
            if (child.stdout == -1 and child.stderr == -1) break;
            if (time >= observed + 200_000_000) {
                child.refuse(6);
                child.close();
                break;
            }
        }
        var polls = [_]c.struct_pollfd{
            .{ .fd = if (control_open) 0 else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = child.stdout, .events = c.POLLIN, .revents = 0 },
            .{ .fd = child.stderr, .events = c.POLLIN, .revents = 0 },
        };
        _ = c.poll(&polls, polls.len, 5);
    }
    if (control_size != 0) child.refuse(1);
    if (child.failure != 0) return child.failure;
    if (try now() >= deadline) return 3;
    var header: [16]u8 = .{0} ** 16;
    std.mem.writeInt(u32, header[0..4], @intCast(12 + out_size), .big);
    @memcpy(header[4..8], &[_]u8{ 1, 0, 1, 0 });
    std.mem.writeInt(u64, header[8..16], out_size, .big);
    try output(&header, deadline);
    try output(out[0..out_size], deadline);
    return 0;
}

// Caught handlers reset to default on exec; SIGCHLD stays waitable here.
// Avoid SDK SIG_IGN function-cast macros that Zig cannot translate on Darwin.
fn ignoreSignal(_: c_int) callconv(.c) void {}

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(65);
    if (args.len != 1) std.process.exit(64);
    _ = c.signal(c.SIGPIPE, ignoreSignal);
    _ = c.signal(c.SIGCHLD, ignoreSignal);
    nonblocking(0) catch std.process.exit(65);
    nonblocking(1) catch std.process.exit(65);
    const start = now() catch std.process.exit(65);
    const category = run(start, init.arena.allocator()) catch 1;
    if (category == 0) return;
    frame(&.{ 1, 1, category, 0 }, (now() catch start) + 100_000_000) catch {};
    std.process.exit(65);
}

test "launch description bounds versions strings flags and exact framing" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bytes: [22]u8 = .{0} ** 22;
    bytes[0] = 1;
    std.mem.writeInt(u32, bytes[4..8], 1000, .big);
    std.mem.writeInt(u32, bytes[8..12], 1, .big);
    std.mem.writeInt(u32, bytes[12..16], 1, .big);
    std.mem.writeInt(u16, bytes[16..18], 1, .big);
    std.mem.writeInt(u16, bytes[18..20], 1, .big);
    bytes[20] = '/';
    bytes[21] = '/';
    _ = try Request.parse(&bytes, arena.allocator());
    for ([_]usize{ 0, 1, 2, 16, 18, 20, 21 }) |index| {
        var changed = bytes;
        changed[index] = 255;
        try std.testing.expectError(invalid, Request.parse(&changed, arena.allocator()));
    }
    try std.testing.expectError(invalid, Request.parse(bytes[0..21], arena.allocator()));
}
