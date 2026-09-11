const std = @import("std");

// Test-only stand-in for the `dvui` import (used by the headless test
// builds only; the real app build maps `@import("dvui")` to dvui's
// `dvui_sdl3` module).
//
// Why: importing the real dvui backend module drags SDL3/freetype/stb C
// objects into the link, which the toolchain here cannot link (pre-existing
// `R_X86_64_PC64` / lld-segfault failures, unrelated to nshell code). The
// headless tests must stay link-light, so they compile State/HubUi against
// this faithful mirror of the dvui types actually used instead.
//
// Faithfulness: `ImageSource` below mirrors `dvui/src/Texture.zig`
// field-for-field (names, types, defaults), so struct literals typecheck
// identically in both builds. The animation/Id/Size/Key stubs below only
// cover what HubUi's headless-tested helpers execute (`init/switchMode`
// paths + the harness's direct `animationGet` check); `hubFrame` itself is
// generic and never instantiated by tests, so its widget surface is never
// analyzed here. If HubUi ever needs more, the test build fails fast and
// this shim must be extended (pure-data shapes only — never backend
// handles). The app build always compiles against real dvui, so drift
// surfaces there at compile time.

pub const TextureInterpolation = enum {
    nearest,
    linear,
};

pub const ImageSource = union(enum) {
    /// bytes of a supported image file (png/jpeg/...), decoded by stb in real dvui
    imageFile: struct {
        bytes: []const u8,
        name: []const u8 = "imageFile",
        interpolation: TextureInterpolation = .linear,
        invalidation: InvalidationStrategy = .ptr,
    },
    /// bytes of a non premultiplied rgba u8 array in row major order, will
    /// be converted to premultiplied when making a texture
    pixels: struct {
        rgba: []const u8,
        width: u32,
        height: u32,
        interpolation: TextureInterpolation = .linear,
        invalidation: InvalidationStrategy = .ptr,
    },

    pub const InvalidationStrategy = enum {
        ptr,
        bytes,
        always,
    };
};

/// Opaque widget id. Headless stub: unique per extendId call.
pub const Id = struct {
    n: usize,
    var next: usize = 1;

    pub fn extendId(_: ?*const anyopaque, _: std.builtin.SourceLocation, _: usize) Id {
        defer next += 1;
        return .{ .n = next };
    }
};

pub const Size = struct {
    w: f32 = 0,
    h: f32 = 0,

    pub fn all(v: f32) Size {
        return .{ .w = v, .h = v };
    }
};

/// Minimal color stub: only what icon signatures name (`tint` params
/// and `.white` defaults). Real rendering never runs headless.
pub const Color = struct {
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
    a: u8 = 255,

    pub const white: Color = .{};
};

pub const enums = struct {
    /// Key codes referenced by HubUi helpers + the JSON harness.
    /// (Real dvui has many more; add on demand — stringToEnum maps
    /// unknown names to null, which the harness reports as BadKey.)
    pub const Key = enum {
        tab,
        slash,
        space,
        p,
        escape,
        enter,
    };
};

pub const App = struct {
    pub const Result = enum { ok };
};

/// Minimal event shapes for HubUi.pressed (frame-context key scan).
/// Only the key surface is mirrored; real dvui carries far more.
/// Headless tests never push events, so events() is always empty here.
pub const Event = struct {
    pub const Key = struct {
        code: enums.Key = .escape,
        action: Action = .up,

        pub const Action = enum { down, repeat, up };
    };

    evt: union(enum) {
        key: Key,
    },
};

pub fn events() []const Event {
    return &.{};
}

pub const easing = struct {
    /// Real easing curve (mirrors dvui's outQuart = 1-(1-t)^4) so the
    /// headless-tested row-height helper integrates against it.
    pub fn outQuart(t: f32) f32 {
        const u = 1 - t;
        return 1 - u * u * u * u;
    }
    pub const outExpo: u8 = 0;
};

const AnimState = struct {
    id: Id,
    key: []const u8,
    start_us: i64,
    end_us: i64,
};

var last_anim: ?AnimState = null;

/// Headless animation registry: records the latest animation so
/// animationGet() can answer. Times are pass-through (no clock here).
pub fn animation(id: Id, key: []const u8, opts: anytype) void {
    const O = @TypeOf(opts);
    const end: i64 = if (@hasField(O, "end_time")) opts.end_time else 0;
    last_anim = .{ .id = id, .key = key, .start_us = 0, .end_us = end };
}

pub const AnimHandle = struct {
    state: AnimState,
    pub fn value(self: *const AnimHandle) f32 {
        _ = self;
        return 1.0;
    }
    pub fn done(self: *const AnimHandle) bool {
        _ = self;
        return false;
    }
};

var anim_handle: AnimHandle = .{ .state = .{ .id = .{ .n = 0 }, .key = "", .start_us = 0, .end_us = 0 } };

/// Returns non-null once an animation was recorded (the harness only
/// asserts presence after switchMode, never absence or progress).
pub fn animationGet(id: Id, key: []const u8) ?*const AnimHandle {
    const st = last_anim orelse return null;
    if (st.id.n != id.n) return null;
    if (!std.mem.eql(u8, st.key, key)) return null;
    anim_handle.state = st;
    return &anim_handle;
}

test {
    // Cheap shape guard: constructing `.pixels` the way State does must keep
    // compiling against this mirror.
    const src: ImageSource = .{ .pixels = .{ .rgba = &.{}, .width = 0, .height = 0 } };
    _ = src;
    std.testing.refAllDecls(@This());
}
