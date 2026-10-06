const std = @import("std");
const raster = @import("raster.zig");

pub const request_magic = "FSR1";
pub const response_magic = "FSO1";
pub const request_header_bytes: usize = 52;
pub const response_header_bytes: usize = 20;
pub const max_frame_bytes: usize = 64 * 1024 * 1024;

pub const Status = enum(u8) {
    ok = 0,
    malformed = 1,
    unsupported_version = 2,
    bounds_exceeded = 3,
    invalid_crop = 4,
    invalid_profile = 5,
    allocation_failed = 6,
};

pub const ParseError = error{
    Malformed,
    UnsupportedVersion,
    BoundsExceeded,
    InvalidProfile,
};

const ParsedRequest = struct {
    request_without_palette: raster.Request,
    palette_storage: [256]raster.Color,
    wire_codes: [16]u8,
    palette_count: usize,

    fn rasterRequest(parsed: *const ParsedRequest) raster.Request {
        var request = parsed.request_without_palette;
        request.palette = parsed.palette_storage[0..parsed.palette_count];
        if (request.output_format == .indexed4_msb)
            request.wire_codes = parsed.wire_codes[0..parsed.palette_count];
        return request;
    }
};

pub const Response = struct {
    status: Status,
    minor: u8 = 1,
    output_format: u8 = 0,
    width: u32 = 0,
    height: u32 = 0,
    payload: []const u8 = &.{},
};

fn parseRequest(body: []const u8) ParseError!ParsedRequest {
    if (body.len < request_header_bytes) return error.Malformed;
    if (!std.mem.eql(u8, body[0..4], request_magic)) return error.Malformed;
    if (body[4] != 0 or (body[5] != 1 and body[5] != 2)) return error.UnsupportedVersion;
    if (body[6] != 1 or readU16(body, 10) != 0 or body[47] != 0 or readU16(body, 50) != 0)
        return error.Malformed;

    const output_format: raster.OutputFormat = switch (body[7]) {
        1 => if (body[5] == 1) .rgb24 else return error.InvalidProfile,
        2 => if (body[5] == 1) .indexed8 else return error.InvalidProfile,
        3 => if (body[5] == 2) .indexed4_msb else return error.InvalidProfile,
        else => return error.InvalidProfile,
    };
    const resize_filter: raster.ResizeFilter = switch (body[8]) {
        1 => .nearest,
        2 => .bilinear,
        else => return error.InvalidProfile,
    };
    const dither_mode: raster.DitherMode = switch (body[9]) {
        0 => .none,
        1 => .ordered_2x2,
        2 => .floyd_steinberg,
        else => return error.InvalidProfile,
    };

    const palette_count = readU16(body, 48);
    if (palette_count > 256) return error.InvalidProfile;
    if (output_format == .indexed4_msb and (palette_count < 2 or palette_count > 16))
        return error.InvalidProfile;
    const entry_bytes: usize = if (body[5] == 2) 4 else 3;
    const palette_bytes = std.math.mul(usize, palette_count, entry_bytes) catch
        return error.BoundsExceeded;
    const source_pixels = std.math.mul(usize, readU32(body, 12), readU32(body, 16)) catch
        return error.BoundsExceeded;
    const source_bytes = std.math.mul(usize, source_pixels, 4) catch
        return error.BoundsExceeded;
    const expected = std.math.add(usize, request_header_bytes, palette_bytes) catch
        return error.BoundsExceeded;
    const expected_total = std.math.add(usize, expected, source_bytes) catch
        return error.BoundsExceeded;
    if (expected_total != body.len or expected_total > max_frame_bytes) return error.Malformed;

    var parsed: ParsedRequest = undefined;
    var palette_index: usize = 0;
    while (palette_index < palette_count) : (palette_index += 1) {
        const offset = request_header_bytes + palette_index * entry_bytes;
        parsed.palette_storage[palette_index] = .{
            .r = body[offset],
            .g = body[offset + 1],
            .b = body[offset + 2],
        };
        if (body[5] == 2) parsed.wire_codes[palette_index] = body[offset + 3];
    }
    const pixels_offset = request_header_bytes + palette_bytes;
    parsed.request_without_palette = .{
        .source_width = readU32(body, 12),
        .source_height = readU32(body, 16),
        .crop_x = readU32(body, 20),
        .crop_y = readU32(body, 24),
        .crop_width = readU32(body, 28),
        .crop_height = readU32(body, 32),
        .target_width = readU32(body, 36),
        .target_height = readU32(body, 40),
        .background = .{ .r = body[44], .g = body[45], .b = body[46] },
        .output_format = output_format,
        .resize_filter = resize_filter,
        .dither_mode = dither_mode,
        .palette = &.{},
        .rgba = body[pixels_offset..],
    };
    parsed.palette_count = palette_count;
    return parsed;
}

pub fn processFrame(allocator: std.mem.Allocator, body: []const u8) Response {
    const minor: u8 = if (body.len >= 6 and body[4] == 0 and body[5] == 2) 2 else 1;
    const parsed = parseRequest(body) catch |parse_error| {
        return .{ .status = statusForParseError(parse_error), .minor = minor };
    };
    const request = parsed.rasterRequest();
    const payload = raster.render(allocator, request) catch |render_error| {
        return .{ .status = statusForRenderError(render_error), .minor = minor };
    };
    return .{
        .status = .ok,
        .minor = minor,
        .output_format = @intFromEnum(request.output_format),
        .width = request.target_width,
        .height = request.target_height,
        .payload = payload,
    };
}

fn statusForParseError(parse_error: ParseError) Status {
    return switch (parse_error) {
        error.Malformed => .malformed,
        error.UnsupportedVersion => .unsupported_version,
        error.BoundsExceeded => .bounds_exceeded,
        error.InvalidProfile => .invalid_profile,
    };
}

pub fn writeResponse(writer: *std.Io.Writer, response: Response) std.Io.Writer.Error!void {
    const body_len = std.math.cast(u32, response_header_bytes + response.payload.len) orelse
        unreachable;
    try writer.writeInt(u32, body_len, .big);
    try writer.writeAll(response_magic);
    try writer.writeAll(&.{ 0, response.minor, @intFromEnum(response.status), response.output_format });
    try writer.writeInt(u32, response.width, .big);
    try writer.writeInt(u32, response.height, .big);
    try writer.writeInt(u32, @intCast(response.payload.len), .big);
    try writer.writeAll(response.payload);
}

fn statusForRenderError(render_error: raster.Error) Status {
    return switch (render_error) {
        error.AllocationFailed => .allocation_failed,
        error.BoundsExceeded => .bounds_exceeded,
        error.InvalidCrop => .invalid_crop,
        error.InvalidPalette, error.UnsupportedDither => .invalid_profile,
        error.InvalidSourceLength => .malformed,
    };
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

test "binary request parser and renderer preserve exact wire output" {
    var body: [request_header_bytes + 8]u8 = @splat(0);
    @memcpy(body[0..4], request_magic);
    body[5] = 1;
    body[6] = 1;
    body[7] = 1;
    body[8] = 1;
    writeU32(&body, 12, 2);
    writeU32(&body, 16, 1);
    writeU32(&body, 28, 2);
    writeU32(&body, 32, 1);
    writeU32(&body, 36, 2);
    writeU32(&body, 40, 1);
    const pixels = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255 };
    @memcpy(body[request_header_bytes..], &pixels);

    const response = processFrame(std.testing.allocator, &body);
    defer if (response.status == .ok) std.testing.allocator.free(response.payload);
    try std.testing.expectEqual(Status.ok, response.status);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, response.payload);
}

test "malformed, unsupported, and out of-bounds frames return typed statuses" {
    try std.testing.expectError(error.Malformed, parseRequest("short"));

    var body: [request_header_bytes]u8 = @splat(0);
    @memcpy(body[0..4], request_magic);
    body[4] = 1;
    body[5] = 1;
    try std.testing.expectError(error.UnsupportedVersion, parseRequest(&body));

    body[4] = 0;
    body[6] = 1;
    body[7] = 1;
    body[8] = 1;
    writeU32(&body, 12, std.math.maxInt(u32));
    writeU32(&body, 16, std.math.maxInt(u32));
    try std.testing.expectError(error.BoundsExceeded, parseRequest(&body));

    writeU32(&body, 12, 0);
    writeU32(&body, 16, 0);
    std.mem.writeInt(u16, body[48..50], 257, .big);
    try std.testing.expectError(error.InvalidProfile, parseRequest(&body));
}

test "bounded parser accepts arbitrary bytes without trapping" {
    try std.testing.fuzz({}, fuzzParser, .{});
}

fn fuzzParser(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    var body: [512]u8 = undefined;
    const length = smith.valueRangeAtMost(u16, 0, body.len);
    smith.bytes(body[0..length]);
    _ = parseRequest(body[0..length]) catch return;
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .big);
}

fn indexed4Body() [request_header_bytes + 8 + 8]u8 {
    var body: [request_header_bytes + 8 + 8]u8 = @splat(0);
    @memcpy(body[0..4], request_magic);
    body[5] = 2;
    body[6] = 1;
    body[7] = 3;
    body[8] = 1;
    writeU32(&body, 12, 2);
    writeU32(&body, 16, 1);
    writeU32(&body, 28, 2);
    writeU32(&body, 32, 1);
    writeU32(&body, 36, 2);
    writeU32(&body, 40, 1);
    std.mem.writeInt(u16, body[48..50], 2, .big);
    @memcpy(body[52..60], &[_]u8{ 0, 0, 255, 5, 0, 255, 0, 6 });
    @memcpy(body[60..68], &[_]u8{ 0, 0, 255, 255, 0, 255, 0, 255 });
    return body;
}

test "FSR1 0.2 packs RGB plus hardware-code palette and refuses format version substitution" {
    var body = indexed4Body();
    const response = processFrame(std.testing.allocator, &body);
    defer std.testing.allocator.free(response.payload);
    try std.testing.expectEqual(Status.ok, response.status);
    try std.testing.expectEqual(@as(u8, 2), response.minor);
    try std.testing.expectEqual(@as(u8, 3), response.output_format);
    try std.testing.expectEqualSlices(u8, &.{0x56}, response.payload);
    body[5] = 1;
    try std.testing.expectEqual(Status.invalid_profile, processFrame(std.testing.failing_allocator, &body).status);
    body[5] = 2;
    body[7] = 2;
    try std.testing.expectEqual(Status.invalid_profile, processFrame(std.testing.failing_allocator, &body).status);
}

test "indexed4 wire refusal covers codes, lengths, reserved bytes and geometry" {
    const original = indexed4Body();
    for ([_]usize{ 10, 11, 47, 50, 51 }) |offset| {
        var body = original;
        body[offset] = 1;
        try std.testing.expectEqual(Status.malformed, processFrame(std.testing.failing_allocator, &body).status);
    }
    var body = original;
    body[59] = 5;
    try std.testing.expectEqual(Status.invalid_profile, processFrame(std.testing.failing_allocator, &body).status);
    body[59] = 16;
    try std.testing.expectEqual(Status.invalid_profile, processFrame(std.testing.failing_allocator, &body).status);
    body = original;
    writeU32(&body, 36, 3);
    try std.testing.expectEqual(Status.invalid_profile, processFrame(std.testing.failing_allocator, &body).status);
    body = original;
    std.mem.writeInt(u16, body[48..50], 17, .big);
    try std.testing.expectEqual(Status.invalid_profile, processFrame(std.testing.failing_allocator, &body).status);
    try std.testing.expectEqual(Status.malformed, processFrame(std.testing.failing_allocator, original[0..67]).status);
    var extra = original ++ [_]u8{0};
    try std.testing.expectEqual(Status.malformed, processFrame(std.testing.failing_allocator, &extra).status);
}
