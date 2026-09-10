const std = @import("std");
const Launcher = @import("Launcher.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var launcher: Launcher = .{};
    launcher.init(alloc, io);
    defer launcher.deinit();

    {
        const t0 = std.Io.Clock.boot.now(io);
        try launcher.loadList(init);
        const t1 = std.Io.Clock.boot.now(io);
        const ns = t0.durationTo(t1).toNanoseconds();
        const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
        std.debug.print("loadList: {d:.2} ms, apps={d}\n", .{ ms, launcher.data.items.len });
    }

    const terms = [_][]const u8{ "", "fire", "code", "term", "a", "settings", "browser", "x", "zzznonmatch" };
    for (terms) |term| _ = launcher.search(term);
    {
        const t0 = std.Io.Clock.boot.now(io);
        try launcher.tick();
        const t1 = std.Io.Clock.boot.now(io);
        const ns = t0.durationTo(t1).toNanoseconds();
        const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
        std.debug.print("search tick (batch {d}): {d:.2} ms\n", .{ terms.len, ms });
    }
    for (terms) |term| {
        const res = launcher.search(term);
        std.debug.print("  search '{s}': {s} len={d}\n", .{ term, if (res == null) "pending" else "ready", if (res) |r| r.len else 0 });
    }

    _ = launcher.search("");
    try launcher.tick();
    const all = launcher.search("") orelse &[_]*Launcher.App{};
    std.debug.print("empty term all apps: {d}\n", .{all.len});

    const to_bench = @min(50, launcher.data.items.len);
    std.debug.print("\n--- icon loading bench (first {d} apps) ---\n", .{to_bench});
    var iconic: usize = 0;
    for (launcher.data.items[0..to_bench]) |*app| {
        _ = launcher.requestIcon(app.icon);
        iconic += 1;
    }
    std.debug.print("queued {d} icons\n", .{iconic});

    var total_icons: usize = 0;
    var ticks: usize = 0;
    var max_tick_ms: f64 = 0;
    const bench_start = std.Io.Clock.boot.now(io);
    while (true) {
        launcher.mu.lockUncancelable(io);
        const pending = launcher.icon_pending.items.len;
        launcher.mu.unlock(io);
        if (pending == 0) break;
        const tick0 = std.Io.Clock.boot.now(io);
        try launcher.tickIcons(8);
        const tick1 = std.Io.Clock.boot.now(io);
        const ns = tick0.durationTo(tick1).toNanoseconds();
        const dt = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
        if (dt > max_tick_ms) max_tick_ms = dt;
        ticks += 1;
        var cached: usize = 0;
        var it = launcher.icon_cache.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.*) |d| {
                if (d.bytes.len > 0) cached += 1;
            }
        }
        if (ticks <= 3 or ticks % 50 == 0)
            std.debug.print(" tick {d}: {d:.2} ms, cache {d}/{d}\n", .{ ticks, dt, cached, iconic });
        total_icons = cached;
        if (ticks > 400) break;
    }
    const bench_end = std.Io.Clock.boot.now(io);
    const total_ns = bench_start.durationTo(bench_end).toNanoseconds();
    const total_ms = @as(f64, @floatFromInt(total_ns)) / 1_000_000.0;
    const avg = if (ticks > 0) total_ms / @as(f64, @floatFromInt(ticks)) else 0;
    std.debug.print("total icon ticks: {d}, cached {d}/{d}, total {d:.2} ms (avg {d:.2} ms/tick, max {d:.2} ms)\n", .{ ticks, total_icons, iconic, total_ms, avg, max_tick_ms });
    launcher.mu.lockUncancelable(io);
    const theme_count = launcher.icon_theme_dirs.items.len;
    const themes_built = launcher.icon_themes_built;
    launcher.mu.unlock(io);
    std.debug.print("themes: {d} dirs, built={s}\n", .{ theme_count, if (themes_built) "yes" else "no" });

    std.debug.print("\n--- search interruption test ---\n", .{});
    // Use apps beyond the first batch to ensure not already cached.
    const start_idx = @min(50, launcher.data.items.len);
    const end_idx = @min(start_idx +| 20, launcher.data.items.len);
    for (launcher.data.items[start_idx..end_idx]) |*app| {
        launcher.mu.lockUncancelable(io);
        const known = launcher.icon_cache.get(app.icon) != null;
        launcher.mu.unlock(io);
        if (known) continue;
        _ = launcher.requestIcon(app.icon);
    }
    _ = launcher.search("interrupt-test");
    const it0 = std.Io.Clock.boot.now(io);
    try launcher.tick();
    try launcher.tickIcons(8);
    const it1 = std.Io.Clock.boot.now(io);
    const it_ns = it0.durationTo(it1).toNanoseconds();
    const it_ms = @as(f64, @floatFromInt(it_ns)) / 1_000_000.0;
    launcher.mu.lockUncancelable(io);
    const rem_icons = launcher.icon_pending.items.len;
    const rem_search = launcher.pending.items.len;
    launcher.mu.unlock(io);
    std.debug.print(" tick with pending search: {d:.2} ms, remaining icons {d}, remaining searches {d}\n", .{ it_ms, rem_icons, rem_search });
    const res2 = launcher.search("interrupt-test");
    std.debug.print("  search 'interrupt-test' after tick: {s}\n", .{if (res2 == null) "still pending (icon priority?)" else "ready (search prioritized)"});

    std.debug.print("\nbench done\n", .{});
}
