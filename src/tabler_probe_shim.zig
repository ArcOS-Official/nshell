const dvui = @import("dvui");

// Layout-probe stand-in for the `tabler` import: identical surface to
// src/tabler_shim.zig, but bound to the real dvui module (backend =
// .custom + testing backend) instead of the dvui_shim, so the probe
// compiles the real widget code. The raster path still fails (no window
// rendering in the probe — Icons.iconPx callers catch and skip), which
// is fine for geometry measurement: icon boxes still lay out, only the
// pixels are absent.
pub const Outline = enum {
    photo,
    network,
    network_off,
    wifi,
    wifi_0,
    wifi_1,
    wifi_2,
    wifi_off,
    lock,
    lock_cancel,
    bluetooth,
    chevron_right,
    chevron_left,
    power,
};

pub const Filled = enum {
    lock,
};

pub fn outline(comptime icon: Outline, size: dvui.Size) ![]const u8 {
    _ = icon;
    _ = size;
    return error.NoWindow;
}

pub fn filled(comptime icon: Filled, size: dvui.Size) ![]const u8 {
    _ = icon;
    _ = size;
    return error.NoWindow;
}

pub const Raster = struct {
    rgba: []const u8,
    w: u32,
    h: u32,
};

pub fn outlineRaster(comptime icon: Outline, size: dvui.Size, tint: dvui.Color) !Raster {
    _ = icon;
    _ = size;
    _ = tint;
    return error.NoWindow;
}

pub fn filledRaster(comptime icon: Filled, size: dvui.Size, tint: dvui.Color) !Raster {
    _ = icon;
    _ = size;
    _ = tint;
    return error.NoWindow;
}
