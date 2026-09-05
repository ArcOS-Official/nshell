const std = @import("std");

// Test-only stand-in for the `dvui` import (used by `test-state` only; the
// real app build maps `@import("dvui")` to dvui's `dvui_sdl3` module).
//
// Why: importing the real dvui backend module drags SDL3/freetype/stb C
// objects into the link, which the toolchain here cannot link (pre-existing
// `R_X86_64_PC64` / lld-segfault failures, unrelated to nshell code). The
// headless State tests must stay link-light, so they compile State against
// this faithful mirror of the dvui types State actually uses instead.
//
// Faithfulness: `ImageSource.pixels` below mirrors
// `dvui/src/Texture.zig` field-for-field (names, types, defaults), so the
// `windowImage` struct literal typechecks identically in both builds. Only
// the `.pixels` variant exists here on purpose: if State ever needs another
// variant, the test build fails fast and this shim must be extended
// (pure-data shapes only — never backend handles).
// The app build always compiles State against real dvui, so drift surfaces
// there at compile time.

pub const TextureInterpolation = enum {
    nearest,
    linear,
};

pub const ImageSource = union(enum) {
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

test {
    // Cheap shape guard: constructing `.pixels` the way State does must keep
    // compiling against this mirror.
    const src: ImageSource = .{ .pixels = .{ .rgba = &.{}, .width = 0, .height = 0 } };
    _ = src;
    std.testing.refAllDecls(@This());
}
