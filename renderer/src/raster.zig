const std = @import("std");

pub const max_dimension: u32 = 32_768;
pub const max_pixels: usize = 16_777_216;

pub const OutputFormat = enum(u8) {
    rgb24 = 1,
    indexed8 = 2,
    indexed4_msb = 3,
};

pub const ResizeFilter = enum(u8) {
    nearest = 1,
    bilinear = 2,
};

pub const DitherMode = enum(u8) {
    none = 0,
    ordered_2x2 = 1,
    floyd_steinberg = 2,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const Request = struct {
    source_width: u32,
    source_height: u32,
    crop_x: u32,
    crop_y: u32,
    crop_width: u32,
    crop_height: u32,
    target_width: u32,
    target_height: u32,
    background: Color,
    output_format: OutputFormat,
    resize_filter: ResizeFilter,
    dither_mode: DitherMode,
    palette: []const Color,
    wire_codes: []const u8 = &.{},
    rgba: []const u8,
};

pub const Error = error{
    AllocationFailed,
    BoundsExceeded,
    InvalidCrop,
    InvalidPalette,
    InvalidSourceLength,
    UnsupportedDither,
};

pub fn render(allocator: std.mem.Allocator, request: Request) Error![]u8 {
    try validate(request);

    const rgb = try renderRgb(allocator, request);
    if (request.output_format == .rgb24) return rgb;
    defer allocator.free(rgb);

    const indices = try quantize(allocator, rgb, request);
    if (request.output_format == .indexed8) return indices;
    defer allocator.free(indices);

    const wire_bytes = allocator.alloc(u8, indices.len / 2) catch return error.AllocationFailed;
    for (wire_bytes, 0..) |*byte, offset| {
        byte.* = (request.wire_codes[indices[offset * 2]] << 4) |
            request.wire_codes[indices[offset * 2 + 1]];
    }
    return wire_bytes;
}

fn validate(request: Request) Error!void {
    const dimensions = [_]u32{
        request.source_width,
        request.source_height,
        request.crop_width,
        request.crop_height,
        request.target_width,
        request.target_height,
    };
    for (dimensions) |dimension| {
        if (dimension == 0 or dimension > max_dimension) return error.BoundsExceeded;
    }

    const source_pixels = pixelCount(request.source_width, request.source_height) catch
        return error.BoundsExceeded;
    const target_pixels = pixelCount(request.target_width, request.target_height) catch
        return error.BoundsExceeded;
    if (source_pixels > max_pixels or target_pixels > max_pixels) return error.BoundsExceeded;

    const source_bytes = std.math.mul(usize, source_pixels, 4) catch
        return error.BoundsExceeded;
    if (request.rgba.len != source_bytes) return error.InvalidSourceLength;

    const crop_right = std.math.add(u32, request.crop_x, request.crop_width) catch
        return error.InvalidCrop;
    const crop_bottom = std.math.add(u32, request.crop_y, request.crop_height) catch
        return error.InvalidCrop;
    if (crop_right > request.source_width or crop_bottom > request.source_height)
        return error.InvalidCrop;

    switch (request.output_format) {
        .rgb24 => {
            if (request.palette.len != 0 or request.dither_mode != .none)
                return error.UnsupportedDither;
        },
        .indexed8 => {
            if (request.palette.len == 0 or request.palette.len > 256)
                return error.InvalidPalette;
        },
        .indexed4_msb => {
            if (request.target_width % 2 != 0 or request.palette.len < 2 or
                request.palette.len > 16 or request.wire_codes.len != request.palette.len)
                return error.InvalidPalette;
            var seen: u16 = 0;
            for (request.wire_codes) |code| {
                if (code > 15) return error.InvalidPalette;
                const mask = @as(u16, 1) << @as(u4, @intCast(code));
                if (seen & mask != 0) return error.InvalidPalette;
                seen |= mask;
            }
        },
    }
}

fn renderRgb(allocator: std.mem.Allocator, request: Request) Error![]u8 {
    const target_pixels = pixelCount(request.target_width, request.target_height) catch
        return error.BoundsExceeded;
    const output_len = std.math.mul(usize, target_pixels, 3) catch
        return error.BoundsExceeded;
    const output = allocator.alloc(u8, output_len) catch return error.AllocationFailed;
    errdefer allocator.free(output);

    var y: u32 = 0;
    while (y < request.target_height) : (y += 1) {
        var x: u32 = 0;
        while (x < request.target_width) : (x += 1) {
            const color = switch (request.resize_filter) {
                .nearest => sampleNearest(request, x, y),
                .bilinear => sampleBilinear(request, x, y),
            };
            const offset = (@as(usize, y) * request.target_width + x) * 3;
            output[offset] = color.r;
            output[offset + 1] = color.g;
            output[offset + 2] = color.b;
        }
    }
    return output;
}

fn sampleNearest(request: Request, target_x: u32, target_y: u32) Color {
    const doubled_x = @as(u64, target_x) * 2 + 1;
    const doubled_y = @as(u64, target_y) * 2 + 1;
    const source_x = request.crop_x + @as(u32, @intCast(
        (doubled_x * request.crop_width) / (@as(u64, request.target_width) * 2),
    ));
    const source_y = request.crop_y + @as(u32, @intCast(
        (doubled_y * request.crop_height) / (@as(u64, request.target_height) * 2),
    ));
    return sourceColor(request, source_x, source_y);
}

fn sampleBilinear(request: Request, target_x: u32, target_y: u32) Color {
    const x_fixed = scaleCoordinate(target_x, request.target_width, request.crop_width);
    const y_fixed = scaleCoordinate(target_y, request.target_height, request.crop_height);
    const x0 = request.crop_x + @as(u32, @intCast(x_fixed >> 16));
    const y0 = request.crop_y + @as(u32, @intCast(y_fixed >> 16));
    const x1 = @min(x0 + 1, request.crop_x + request.crop_width - 1);
    const y1 = @min(y0 + 1, request.crop_y + request.crop_height - 1);
    const fx: u32 = @intCast(x_fixed & 0xffff);
    const fy: u32 = @intCast(y_fixed & 0xffff);

    const top = interpolate(sourceColor(request, x0, y0), sourceColor(request, x1, y0), fx);
    const bottom = interpolate(sourceColor(request, x0, y1), sourceColor(request, x1, y1), fx);
    return interpolate(top, bottom, fy);
}

fn scaleCoordinate(target: u32, target_size: u32, crop_size: u32) u64 {
    if (target_size == 1) return (@as(u64, crop_size - 1) << 15);
    return (@as(u64, target) * (crop_size - 1) << 16) / (target_size - 1);
}

fn interpolate(left: Color, right: Color, fraction: u32) Color {
    return .{
        .r = interpolateChannel(left.r, right.r, fraction),
        .g = interpolateChannel(left.g, right.g, fraction),
        .b = interpolateChannel(left.b, right.b, fraction),
    };
}

fn interpolateChannel(left: u8, right: u8, fraction: u32) u8 {
    const inverse = 65_536 - fraction;
    const value = @as(u64, left) * inverse + @as(u64, right) * fraction + 32_768;
    return @intCast(value >> 16);
}

fn sourceColor(request: Request, x: u32, y: u32) Color {
    const offset = (@as(usize, y) * request.source_width + x) * 4;
    const alpha = request.rgba[offset + 3];
    return .{
        .r = composite(request.rgba[offset], request.background.r, alpha),
        .g = composite(request.rgba[offset + 1], request.background.g, alpha),
        .b = composite(request.rgba[offset + 2], request.background.b, alpha),
    };
}

fn composite(foreground: u8, background: u8, alpha: u8) u8 {
    const inverse = 255 - @as(u16, alpha);
    const value = @as(u32, foreground) * alpha + @as(u32, background) * inverse + 127;
    return @intCast(value / 255);
}

fn quantize(allocator: std.mem.Allocator, rgb: []const u8, request: Request) Error![]u8 {
    return switch (request.dither_mode) {
        .none => quantizeDirect(allocator, rgb, request.palette),
        .ordered_2x2 => quantizeOrdered(allocator, rgb, request),
        .floyd_steinberg => quantizeErrorDiffusion(allocator, rgb, request),
    };
}

fn quantizeDirect(
    allocator: std.mem.Allocator,
    rgb: []const u8,
    palette: []const Color,
) Error![]u8 {
    const output = allocator.alloc(u8, rgb.len / 3) catch return error.AllocationFailed;
    for (output, 0..) |*index, pixel| {
        index.* = nearestPalette(palette, .{
            .r = rgb[pixel * 3],
            .g = rgb[pixel * 3 + 1],
            .b = rgb[pixel * 3 + 2],
        });
    }
    return output;
}

fn quantizeOrdered(
    allocator: std.mem.Allocator,
    rgb: []const u8,
    request: Request,
) Error![]u8 {
    const output = allocator.alloc(u8, rgb.len / 3) catch return error.AllocationFailed;
    const thresholds = [4]i16{ -24, 8, 24, -8 };

    for (output, 0..) |*index, pixel| {
        const x = pixel % request.target_width;
        const y = pixel / request.target_width;
        const threshold = thresholds[(y % 2) * 2 + (x % 2)];
        index.* = nearestPalette(request.palette, .{
            .r = adjust(rgb[pixel * 3], threshold),
            .g = adjust(rgb[pixel * 3 + 1], threshold),
            .b = adjust(rgb[pixel * 3 + 2], threshold),
        });
    }
    return output;
}

fn quantizeErrorDiffusion(
    allocator: std.mem.Allocator,
    rgb: []const u8,
    request: Request,
) Error![]u8 {
    const output = allocator.alloc(u8, rgb.len / 3) catch return error.AllocationFailed;
    errdefer allocator.free(output);

    const row_values = std.math.mul(usize, request.target_width + 2, 3) catch
        return error.BoundsExceeded;
    var current = allocator.alloc(i32, row_values) catch return error.AllocationFailed;
    defer allocator.free(current);
    var next = allocator.alloc(i32, row_values) catch return error.AllocationFailed;
    defer allocator.free(next);
    @memset(current, 0);
    @memset(next, 0);

    var y: usize = 0;
    while (y < request.target_height) : (y += 1) {
        var x: usize = 0;
        while (x < request.target_width) : (x += 1) {
            const pixel = y * request.target_width + x;
            const error_offset = (x + 1) * 3;
            const adjusted = Color{
                .r = applyError(rgb[pixel * 3], current[error_offset]),
                .g = applyError(rgb[pixel * 3 + 1], current[error_offset + 1]),
                .b = applyError(rgb[pixel * 3 + 2], current[error_offset + 2]),
            };
            const palette_index = nearestPalette(request.palette, adjusted);
            output[pixel] = palette_index;
            const selected = request.palette[palette_index];
            diffuse(current, next, error_offset, adjusted, selected);
        }
        const swap = current;
        current = next;
        next = swap;
        @memset(next, 0);
    }
    return output;
}

fn diffuse(current: []i32, next: []i32, offset: usize, input: Color, selected: Color) void {
    const errors = [3]i32{
        @as(i32, input.r) - selected.r,
        @as(i32, input.g) - selected.g,
        @as(i32, input.b) - selected.b,
    };
    for (errors, 0..) |value, channel| {
        current[offset + 3 + channel] += value * 7;
        next[offset - 3 + channel] += value * 3;
        next[offset + channel] += value * 5;
        next[offset + 3 + channel] += value;
    }
}

fn applyError(channel: u8, error_value: i32) u8 {
    return clamp(@as(i32, channel) + @divTrunc(error_value, 16));
}

fn adjust(channel: u8, amount: i16) u8 {
    return clamp(@as(i32, channel) + amount);
}

fn clamp(value: i32) u8 {
    return @intCast(std.math.clamp(value, 0, 255));
}

fn nearestPalette(palette: []const Color, color: Color) u8 {
    var best_index: u8 = 0;
    var best_distance: u32 = std.math.maxInt(u32);
    for (palette, 0..) |candidate, index| {
        const red = @as(i32, color.r) - candidate.r;
        const green = @as(i32, color.g) - candidate.g;
        const blue = @as(i32, color.b) - candidate.b;
        const distance: u32 = @intCast(red * red + green * green + blue * blue);
        if (distance < best_distance) {
            best_distance = distance;
            best_index = @intCast(index);
        }
    }
    return best_index;
}

fn pixelCount(width: u32, height: u32) !usize {
    return std.math.mul(usize, width, height);
}

test "nearest crop and alpha composition produce exact RGB24 bytes" {
    const source = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 128, 255, 255, 255, 0,
    };
    const request = Request{
        .source_width = 2,
        .source_height = 2,
        .crop_x = 0,
        .crop_y = 1,
        .crop_width = 2,
        .crop_height = 1,
        .target_width = 2,
        .target_height = 1,
        .background = .{ .r = 10, .g = 20, .b = 30 },
        .output_format = .rgb24,
        .resize_filter = .nearest,
        .dither_mode = .none,
        .palette = &.{},
        .rgba = &source,
    };
    const output = try render(std.testing.allocator, request);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, &.{ 5, 10, 143, 10, 20, 30 }, output);
}

test "bilinear resizing is deterministic at channel boundaries" {
    const source = [_]u8{ 0, 0, 0, 255, 255, 255, 255, 255 };
    var request = Request{
        .source_width = 2,
        .source_height = 1,
        .crop_x = 0,
        .crop_y = 0,
        .crop_width = 2,
        .crop_height = 1,
        .target_width = 3,
        .target_height = 1,
        .background = .{ .r = 0, .g = 0, .b = 0 },
        .output_format = .rgb24,
        .resize_filter = .bilinear,
        .dither_mode = .none,
        .palette = &.{},
        .rgba = &source,
    };
    const first = try render(std.testing.allocator, request);
    defer std.testing.allocator.free(first);
    const second = try render(std.testing.allocator, request);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 128, 128, 128, 255, 255, 255 }, first);
    try std.testing.expectEqualSlices(u8, first, second);

    request.crop_width = 3;
    try std.testing.expectError(error.InvalidCrop, render(std.testing.allocator, request));
}

test "indexed profiles use only the caller supplied palette" {
    const source = [_]u8{
        0,   0,   0,   255, 255, 255, 255, 255,
        140, 140, 140, 255, 120, 120, 120, 255,
    };
    const palette = [_]Color{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 255, .b = 255 },
    };
    var request = Request{
        .source_width = 4,
        .source_height = 1,
        .crop_x = 0,
        .crop_y = 0,
        .crop_width = 4,
        .crop_height = 1,
        .target_width = 4,
        .target_height = 1,
        .background = .{ .r = 255, .g = 255, .b = 255 },
        .output_format = .indexed8,
        .resize_filter = .nearest,
        .dither_mode = .none,
        .palette = &palette,
        .rgba = &source,
    };
    const direct = try render(std.testing.allocator, request);
    defer std.testing.allocator.free(direct);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 1, 0 }, direct);

    request.dither_mode = .floyd_steinberg;
    const diffused = try render(std.testing.allocator, request);
    defer std.testing.allocator.free(diffused);
    try std.testing.expectEqual(@as(usize, 4), diffused.len);
    for (diffused) |index| try std.testing.expect(index < palette.len);
}

test "invalid lengths, palettes, and dimensions are rejected before rendering" {
    const request = Request{
        .source_width = 1,
        .source_height = 1,
        .crop_x = 0,
        .crop_y = 0,
        .crop_width = 1,
        .crop_height = 1,
        .target_width = 1,
        .target_height = 1,
        .background = .{ .r = 0, .g = 0, .b = 0 },
        .output_format = .indexed8,
        .resize_filter = .nearest,
        .dither_mode = .none,
        .palette = &.{},
        .rgba = &.{ 0, 0, 0 },
    };
    try std.testing.expectError(error.InvalidSourceLength, render(std.testing.allocator, request));
}

const pigment_fixture = [_]Color{
    .{ .r = 0, .g = 0, .b = 0 },
    .{ .r = 255, .g = 255, .b = 255 },
    .{ .r = 255, .g = 255, .b = 0 },
    .{ .r = 255, .g = 0, .b = 0 },
    .{ .r = 0, .g = 0, .b = 255 },
    .{ .r = 0, .g = 255, .b = 0 },
};
const pigment_codes = [_]u8{ 0, 1, 2, 3, 5, 6 };

fn indexed4Fixture(source: []const u8, width: u32, height: u32) Request {
    return .{
        .source_width = width,
        .source_height = height,
        .crop_x = 0,
        .crop_y = 0,
        .crop_width = width,
        .crop_height = height,
        .target_width = width,
        .target_height = height,
        .background = .{ .r = 255, .g = 255, .b = 255 },
        .output_format = .indexed4_msb,
        .resize_filter = .nearest,
        .dither_mode = .none,
        .palette = &pigment_fixture,
        .wire_codes = &pigment_codes,
        .rgba = source,
    };
}

test "indexed4 uses explicit hardware codes and first palette entry on color ties" {
    const source = [_]u8{ 0, 0, 255, 255, 0, 255, 0, 255 };
    var request = indexed4Fixture(&source, 2, 1);
    const output = try render(std.testing.allocator, request);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualSlices(u8, &.{0x56}, output);
    request.palette = &.{ pigment_fixture[4], pigment_fixture[4] };
    request.wire_codes = &.{ 15, 0 };
    const ties = try render(std.testing.allocator, request);
    defer std.testing.allocator.free(ties);
    try std.testing.expectEqualSlices(u8, &.{0xff}, ties);
}

test "indexed4 refuses ambiguous codes and odd widths before allocating" {
    const source = [_]u8{ 0, 0, 0, 255, 255, 255, 255, 255 };
    var request = indexed4Fixture(&source, 2, 1);
    request.wire_codes = &.{ 0, 1, 2, 3, 4, 16 };
    try std.testing.expectError(error.InvalidPalette, render(std.testing.failing_allocator, request));
    request.wire_codes = &.{ 0, 1, 2, 3, 5, 5 };
    try std.testing.expectError(error.InvalidPalette, render(std.testing.failing_allocator, request));
    request.wire_codes = &.{0};
    try std.testing.expectError(error.InvalidPalette, render(std.testing.failing_allocator, request));
    request.wire_codes = &pigment_codes;
    request.target_width = 3;
    try std.testing.expectError(error.InvalidPalette, render(std.testing.failing_allocator, request));
}

test "all indexed4 dither modes preserve quantized indices through explicit packing" {
    const source = [_]u8{ 128, 128, 128, 255, 220, 220, 220, 255 } ** 8;
    var packed_job = indexed4Fixture(&source, 4, 4);
    for ([_]DitherMode{ .none, .ordered_2x2, .floyd_steinberg }) |mode| {
        packed_job.dither_mode = mode;
        var index_job = packed_job;
        index_job.output_format = .indexed8;
        const indices = try render(std.testing.allocator, index_job);
        defer std.testing.allocator.free(indices);
        const wire_bytes = try render(std.testing.allocator, packed_job);
        defer std.testing.allocator.free(wire_bytes);
        for (wire_bytes, 0..) |byte, offset| {
            try std.testing.expectEqual(pigment_codes[indices[offset * 2]], byte >> 4);
            try std.testing.expectEqual(pigment_codes[indices[offset * 2 + 1]], byte & 15);
        }
    }
}

test "native 1200 by 1600 indexed4 raster matches independently enumerated controller rows" {
    const allocator = std.testing.allocator;
    const source = try allocator.alloc(u8, 1200 * 1600 * 4);
    defer allocator.free(source);
    for (0..1600) |y| {
        for (0..1200) |x| {
            const color = pigment_fixture[(x / 100 + y) % 6];
            const offset = (y * 1200 + x) * 4;
            @memcpy(source[offset..][0..4], &[_]u8{ color.r, color.g, color.b, 255 });
        }
    }
    const wire_bytes = try render(allocator, indexed4Fixture(source, 1200, 1600));
    defer allocator.free(wire_bytes);
    try std.testing.expectEqual(@as(usize, 960_000), wire_bytes.len);
    // Independently enumerate the sample driver's M/S row-strided stream.
    // Check every byte, including row seams and both controller edges.
    for (0..2) |controller| {
        for (0..1600) |row| {
            for (0..300) |column| {
                const x = controller * 600 + column * 2;
                const high = pigment_codes[(x / 100 + row) % 6];
                const low = pigment_codes[((x + 1) / 100 + row) % 6];
                try std.testing.expectEqual(high * 16 + low, wire_bytes[row * 600 + controller * 300 + column]);
            }
        }
    }
    try std.testing.expect(wire_bytes[300] != wire_bytes[480_000]);
}
