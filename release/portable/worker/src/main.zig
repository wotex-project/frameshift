const std = @import("std");
const c = @cImport({
    // Glibc's inline variadic fortify wrappers cannot be translated by cImport.
    // Calls here use explicit admitted bounds; import the actual libc functions.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cDefine("_FILE_OFFSET_BITS", "64");
    @cDefine("_POSIX_C_SOURCE", "200809L");
    @cDefine("_DARWIN_C_SOURCE", "1");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("time.h");
});

const refusal = error.Refused;
const max_read: u64 = 16 * 1024 * 1024;
const max_hash: u64 = 8 * 1024 * 1024 * 1024;

const Request = struct {
    operation: u8,
    flags: u8,
    minimum: u64,
    maximum: u64,
    milliseconds: u32,
    path: []const u8,

    fn parse(bytes: []const u8) !Request {
        if (bytes.len < 27 or bytes[0] != 1 or bytes[3] != 0 or
            (bytes[1] != 1 and bytes[1] != 2) or bytes[2] > 3) return refusal;
        const minimum = std.mem.readInt(u64, bytes[4..12], .big);
        const maximum = std.mem.readInt(u64, bytes[12..20], .big);
        const milliseconds = std.mem.readInt(u32, bytes[20..24], .big);
        const length = std.mem.readInt(u16, bytes[24..26], .big);
        if (length == 0 or length > 4096 or bytes.len != 26 + @as(usize, length) or
            minimum > maximum or maximum > (if (bytes[1] == 1) max_read else max_hash) or
            milliseconds == 0 or milliseconds > 900_000 or
            std.mem.indexOfScalar(u8, bytes[26..], 0) != null or
            !std.unicode.utf8ValidateSlice(bytes[26..])) return refusal;
        return .{
            .operation = bytes[1],
            .flags = bytes[2],
            .minimum = minimum,
            .maximum = maximum,
            .milliseconds = milliseconds,
            .path = bytes[26..],
        };
    }
};

fn now() !u64 {
    var clock: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &clock) != 0 or clock.tv_sec < 0) return refusal;
    return @as(u64, @intCast(clock.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(clock.tv_nsec));
}

fn budget(deadline: u64) !u64 {
    const time = try now();
    if (time >= deadline) return refusal;
    return deadline - time;
}

fn wait(fd: c_int, events: c_short, deadline: u64) !void {
    while (true) {
        const remaining = try budget(deadline);
        var descriptor = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };
        const result = c.poll(&descriptor, 1, @intCast(@min((remaining + 999_999) / 1_000_000, 900_000)));
        if (result < 0 and std.c.errno(result) == .INTR) continue;
        if (result <= 0 or descriptor.revents & events == 0) return refusal;
        return;
    }
}

fn input(bytes: []u8, deadline: u64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try wait(0, c.POLLIN, deadline);
        const count = c.read(0, bytes[offset..].ptr, bytes.len - offset);
        if (count < 0 and (std.c.errno(count) == .INTR or std.c.errno(count) == .AGAIN)) continue;
        if (count <= 0) return refusal;
        offset += @intCast(count);
    }
}

fn output(bytes: []const u8, deadline: u64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try wait(1, c.POLLOUT, deadline);
        const count = c.write(1, bytes[offset..].ptr, bytes.len - offset);
        if (count < 0 and (std.c.errno(count) == .INTR or std.c.errno(count) == .AGAIN)) continue;
        if (count <= 0) return refusal;
        offset += @intCast(count);
    }
}

fn frame(bytes: []const u8, deadline: u64) !void {
    var prefix: [4]u8 = undefined;
    std.mem.writeInt(u32, &prefix, @intCast(bytes.len), .big);
    try output(&prefix, deadline);
    try output(bytes, deadline);
}

fn protection(stat: c.struct_stat, flags: u8) !void {
    const mode = stat.st_mode & 0o7777;
    if (stat.st_mode & c.S_IFMT != c.S_IFREG) return refusal;
    if (flags & 1 != 0 and (stat.st_uid != c.getuid() or (mode != 0o400 and mode != 0o600))) return refusal;
    if (flags & 2 != 0 and ((stat.st_uid != 0 and stat.st_uid != c.getuid()) or mode & 0o022 != 0)) return refusal;
}

fn same(a: c.struct_stat, b: c.struct_stat) bool {
    const am = if (@hasField(c.struct_stat, "st_mtimespec")) a.st_mtimespec else a.st_mtim;
    const bm = if (@hasField(c.struct_stat, "st_mtimespec")) b.st_mtimespec else b.st_mtim;
    const ac = if (@hasField(c.struct_stat, "st_ctimespec")) a.st_ctimespec else a.st_ctim;
    const bc = if (@hasField(c.struct_stat, "st_ctimespec")) b.st_ctimespec else b.st_ctim;
    return a.st_dev == b.st_dev and a.st_ino == b.st_ino and a.st_size == b.st_size and
        a.st_mode == b.st_mode and a.st_uid == b.st_uid and a.st_gid == b.st_gid and
        a.st_nlink == b.st_nlink and am.tv_sec == bm.tv_sec and am.tv_nsec == bm.tv_nsec and
        ac.tv_sec == bc.tv_sec and ac.tv_nsec == bc.tv_nsec;
}

fn check(fd: c_int, path: [*:0]const u8, original: c.struct_stat, deadline: u64) !void {
    _ = try budget(deadline);
    var opened: c.struct_stat = undefined;
    var named: c.struct_stat = undefined;
    if (c.fstat(fd, &opened) != 0 or c.lstat(path, &named) != 0 or
        !same(original, opened) or !same(opened, named)) return refusal;
    _ = try budget(deadline);
}

fn readBlock(fd: c_int, bytes: []u8, offset: u64, deadline: u64) !usize {
    while (true) {
        _ = try budget(deadline);
        const count = c.pread(fd, bytes.ptr, bytes.len, @intCast(offset));
        if (count < 0 and std.c.errno(count) == .INTR) continue;
        if (count < 0) return refusal;
        _ = try budget(deadline);
        return @intCast(count);
    }
}

fn run(start: u64) !void {
    var prefix: [4]u8 = undefined;
    const initial_deadline = start + 5_000_000_000;
    try input(&prefix, initial_deadline);
    const length = std.mem.readInt(u32, &prefix, .big);
    if (length > 26 + 4096) return refusal;
    var message: [26 + 4096]u8 = undefined;
    try input(message[0..length], initial_deadline);
    const request = try Request.parse(message[0..length]);
    const deadline = start + @as(u64, request.milliseconds) * 1_000_000;
    _ = try budget(deadline);
    var path: [4097]u8 = undefined;
    @memcpy(path[0..request.path.len], request.path);
    path[request.path.len] = 0;
    const name: [*:0]const u8 = @ptrCast(&path);
    var named: c.struct_stat = undefined;
    if (c.lstat(name, &named) != 0) return refusal;
    try protection(named, request.flags);
    const fd = c.open(name, c.O_RDONLY | c.O_NOFOLLOW | c.O_NONBLOCK | c.O_CLOEXEC);
    if (fd < 0) return refusal;
    defer _ = c.close(fd);
    var original: c.struct_stat = undefined;
    if (c.fstat(fd, &original) != 0 or !same(original, named) or original.st_size < 0) return refusal;
    try protection(original, request.flags);
    const size: u64 = @intCast(original.st_size);
    if (size < request.minimum or size > request.maximum) return refusal;
    try check(fd, name, original, deadline);
    var header: [12]u8 = .{ 1, 0, request.operation, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u64, header[4..12], size, .big);
    if (request.operation == 1) {
        std.mem.writeInt(u32, &prefix, @intCast(12 + size), .big);
        try output(&prefix, deadline);
        try output(&header, deadline);
    }
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var block: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const count = try readBlock(fd, block[0..@intCast(@min(block.len, size - offset))], offset, deadline);
        if (count == 0) return refusal;
        if (request.operation == 1) try output(block[0..count], deadline) else digest.update(block[0..count]);
        offset += count;
    }
    if (try readBlock(fd, block[0..1], size, deadline) != 0) return refusal;
    try check(fd, name, original, deadline);
    if (request.operation == 2) {
        var response: [44]u8 = undefined;
        @memcpy(response[0..12], &header);
        digest.final(response[12..44]);
        try frame(&response, deadline);
    }
    try input(&prefix, deadline);
    if (std.mem.readInt(u32, &prefix, .big) != 1) return refusal;
    var finish: [1]u8 = undefined;
    try input(&finish, deadline);
    if (finish[0] != 1) return refusal;
    try check(fd, name, original, deadline);
    // Reject queued second acknowledgements/requests rather than hiding them.
    var pending = c.struct_pollfd{ .fd = 0, .events = c.POLLIN, .revents = 0 };
    if (c.poll(&pending, 1, 0) < 0 or pending.revents != 0) return refusal;
    try frame(&.{ 1, 0, 3, 0 }, deadline);
}

pub fn main(init: std.process.Init) void {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch std.process.exit(65);
    if (args.len != 1) std.process.exit(64);
    for ([_]c_int{ 0, 1 }) |fd| {
        const flags = c.fcntl(fd, c.F_GETFL);
        if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) std.process.exit(65);
    }
    const start = now() catch std.process.exit(65);
    run(start) catch {
        frame(&.{ 1, 1, 0, 0 }, (now() catch start) + 100_000_000) catch {};
        std.process.exit(65);
    };
}

test "bounded request rejects malformed versions lengths flags UTF8 NUL and limits" {
    var bytes: [27]u8 = .{0} ** 27;
    bytes[0] = 1;
    bytes[1] = 1;
    std.mem.writeInt(u64, bytes[12..20], 1, .big);
    std.mem.writeInt(u32, bytes[20..24], 1000, .big);
    std.mem.writeInt(u16, bytes[24..26], 1, .big);
    bytes[26] = 'a';
    _ = try Request.parse(&bytes);
    for ([_]usize{ 0, 1, 2, 3, 24, 26 }) |index| {
        var changed = bytes;
        changed[index] = 0xff;
        try std.testing.expectError(refusal, Request.parse(&changed));
    }
    bytes[26] = 0;
    try std.testing.expectError(refusal, Request.parse(&bytes));
    try std.testing.expectError(refusal, Request.parse(bytes[0..26]));
}
