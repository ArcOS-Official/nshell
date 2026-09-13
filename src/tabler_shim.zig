const dvui = @import("dvui");

// Test-only stand-in for the `tabler` import (used by the headless test
// builds only; the real app build maps `@import("tabler")` to the
// tabler-zig module wired to dvui's `dvui_sdl3` module).
//
// Why: the real tabler module needs dvui's SVG->TVG pipeline
// (`svgToTvg`, per-window data cache, `render_tvg`), which the link-light
// `dvui_shim` deliberately omits. The headless tests never instantiate
// `HubUi.hubFrame` (generic over `anytype`, so its widget surface is
// never analyzed) and never call `Icons.iconPx`, so only the types and
// signatures used by analyzed code must resolve here (`Outline` in the
// icon helpers' signatures, `Raster` in `Crisp`-adjacent signatures).
// If a test ever calls the raster path, this stub returns an error and
// callers fall back to their empty-icon path via `catch`.
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
    music,
    player_play,
    player_pause,
    player_skip_back,
    player_skip_forward,
    // Activity / status indicators (HubUi hubFrame paths; raster still
    // fails headless, callers catch and skip — same as above).
    player_record,
    screen_share,
    camera,
    microphone,
    download,
    alert_small,
    bell,
    bluetooth,
    globe,
    globe_off,
    battery,
    battery_1,
    battery_2,
    battery_3,
    battery_4,
    battery_charging,
    battery_charging_2,
};

pub fn outline(comptime icon: Outline, size: dvui.Size) ![]const u8 {
    _ = icon;
    _ = size;
    return error.NoWindow;
}

/// Raster counterpart (see tabler's raster.zig): tinted RGBA at
/// ceil(size). Headless stub always fails; Icons.iconPx propagates the
/// error, and tests never call it (no window headless).
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
