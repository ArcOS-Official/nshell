const std = @import("std");
const dvui = @import("dvui");
const tabler = @import("tabler");

// Aliased (unsmoothed) icons over tabler-zig's supersampled raster
// pipeline.
//
// Why this exists: dvui's TVG path (`dvui.icon`) hardcodes its edge
// feather (1px in `renderIcon`, `Path.strokeTriangles`, and the TVG
// round join/cap discs), so vector icons always render smoothed and
// there is no knob to turn that off. Instead we rasterize via
// `tabler.outlineRaster` (true 4x SSAA), posterize the alpha channel
// to 1-bit for hard stair-step edges, and display with `dvui.image`
// under nearest-neighbor sampling (linear would re-soften the edges
// on any fractional placement or scaling).
//
// Two flavors (callers pick per site):
// - crisp: rasterize at the display size, show 1:1 (`iconPx`).
// - chunky: rasterize at half size, show at 2x (`iconChunkyPx`).
// `tint` is baked at raster time (and part of the cache key) because
// `dvui.image` has no tint stage — pass the text/fill color the icon
// sits on, as before with `dvui.icon`'s white defaults.
//
// Only valid between `Window.begin` and `Window.end`. Returned bytes
// live in dvui's per-window data store; do not free them.

pub const Crisp = struct {
    rgba: []const u8,
    w: u32,
    h: u32,
};

// Posterize alpha to 1-bit in place: `a >= cutoff` becomes opaque,
// anything below becomes fully transparent. RGB is untouched (the
// raster is already tinted). Pure; unit-tested headless below.
pub fn thresholdAlpha(rgba: []u8, cutoff: u8) void {
    var i: usize = 3;
    while (i < rgba.len) : (i += 4) {
        rgba[i] = if (rgba[i] >= cutoff) 255 else 0;
    }
}

// Rasterize `icon` at `raster_px`, threshold to hard edges, cache per
// window under `nshell-crisp-outline-<tag>-WxH-<tint>` (same data-store
// pattern `tabler` itself uses: the store copies, so the arena scratch
// below is safe to hand over). Repeat calls are free after the first.
pub fn iconPx(comptime icon: tabler.Outline, raster_px: f32, tint: dvui.Color) !Crisp {
    const r = try tabler.outlineRaster(icon, dvui.Size.all(raster_px), tint);
    if (r.rgba.len == 0) return .{ .rgba = &.{}, .w = r.w, .h = r.h };

    const rgba = tint.toRGBA();
    var key_buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "nshell-crisp-outline-{s}-{d}x{d}-{x}{x}{x}{x}", .{
        @tagName(icon), r.w, r.h, rgba[0], rgba[1], rgba[2], rgba[3],
    }) catch unreachable;
    const id = dvui.Id.zero.update("nshell-crisp");
    if (dvui.dataGetSlice(null, id, key, []u8)) |stored| {
        return .{ .rgba = stored, .w = r.w, .h = r.h };
    }

    // Never mutate the raster store slice in place: dupe, threshold
    // the copy, hand the copy to the store.
    const win = dvui.currentWindow();
    const buf = try win.arena().alloc(u8, r.rgba.len);
    @memcpy(buf, r.rgba);
    thresholdAlpha(buf, 128);
    dvui.dataSetSlice(null, id, key, buf);
    return .{ .rgba = dvui.dataGetSlice(null, id, key, []u8).?, .w = r.w, .h = r.h };
}

// Rasterize `icon` at `raster_px`, threshold to hard edges, cache per
// window under `nshell-crisp-outline-<tag>-WxH-<tint>` (same data-store
// pattern `tabler` itself uses: the store copies, so the arena scratch
// below is safe to hand over). Repeat calls are free after the first.
pub fn iconPxFilled(comptime icon: tabler.Filled, raster_px: f32, tint: dvui.Color) !Crisp {
    const r = try tabler.filledRaster(icon, dvui.Size.all(raster_px), tint);
    if (r.rgba.len == 0) return .{ .rgba = &.{}, .w = r.w, .h = r.h };

    const rgba = tint.toRGBA();
    var key_buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "nshell-crisp-outline-{s}-{d}x{d}-{x}{x}{x}{x}", .{
        @tagName(icon), r.w, r.h, rgba[0], rgba[1], rgba[2], rgba[3],
    }) catch unreachable;
    const id = dvui.Id.zero.update("nshell-crisp");
    if (dvui.dataGetSlice(null, id, key, []u8)) |stored| {
        return .{ .rgba = stored, .w = r.w, .h = r.h };
    }

    // Never mutate the raster store slice in place: dupe, threshold
    // the copy, hand the copy to the store.
    const win = dvui.currentWindow();
    const buf = try win.arena().alloc(u8, r.rgba.len);
    @memcpy(buf, r.rgba);
    thresholdAlpha(buf, 128);
    dvui.dataSetSlice(null, id, key, buf);
    return .{ .rgba = dvui.dataGetSlice(null, id, key, []u8).?, .w = r.w, .h = r.h };
}

// Chunky variant: rasterize at half the display size so showing at
// `display_px` with `pixelImage` (nearest) yields double-size pixels.
pub fn iconChunkyPx(comptime icon: tabler.Outline, display_px: f32, tint: dvui.Color) !Crisp {
    return iconPx(icon, display_px / 2, tint);
}

// `dvui.image` init opts for a Crisp raster. Nearest-neighbor is the
// whole point: it preserves the hard thresholded edges.
pub fn pixelImage(c: Crisp) dvui.ImageInitOptions {
    return .{ .source = .{ .pixels = .{
        .rgba = c.rgba,
        .width = c.w,
        .height = c.h,
        .interpolation = .nearest,
    } } };
}

// No refAllDecls block here on purpose: iconPx/iconChunkyPx need a
// window (mesh building + data store), which the link-light headless
// test builds don't have. Only the pure threshold helper is tested.

test "icons: threshold posterizes alpha to 1-bit, keeps rgb" {
    var px = [_]u8{
        10, 20, 30, 0,
        10, 20, 30, 127,
        10, 20, 30, 128,
        10, 20, 30, 255,
    };
    thresholdAlpha(&px, 128);
    try std.testing.expectEqualSlices(u8, &.{
        10, 20, 30, 0,
        10, 20, 30, 0,
        10, 20, 30, 255,
        10, 20, 30, 255,
    }, &px);
}

test "icons: threshold cutoff 255 keeps only fully opaque" {
    var px = [_]u8{ 1, 2, 3, 254, 4, 5, 6, 255 };
    thresholdAlpha(&px, 255);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 0, 4, 5, 6, 255 }, &px);
}

test "icons: threshold empty slice is a no-op" {
    var px = [_]u8{};
    thresholdAlpha(&px, 128);
    try std.testing.expectEqual(@as(usize, 0), px.len);
}
