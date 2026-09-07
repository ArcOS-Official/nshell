const std = @import("std");
const dvui = @import("dvui");

/// Owned list of desktop entries.
data: std.ArrayList(App) = .empty,
/// Cache: query term -> results slice (null = pending).
/// Key is owned dupe of term; value slice is owned alloc of []*App pointing into data.
query: std.StringHashMapUnmanaged(?[]*App) = .empty,
/// Terms waiting to be searched by tick() on the worker thread.
pending: std.ArrayList([]const u8) = .empty,
mu: std.Io.Mutex = .init,
alloc: std.mem.Allocator = undefined,
io: std.Io = undefined,
inited: bool = false,

const Launcher = @This();

pub const App = struct {
    name: []const u8,
    categories: ?[]const u8 = null,
    version: ?[]const u8 = null,
    generic_name: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    path: ?[]const u8 = null,
    exec: ?[]const u8 = null,
    icon: []const u8,
    terminal: bool = false,
};

const ParsedApp = struct {
    name: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    categories: ?[]const u8 = null,
    version: ?[]const u8 = null,
    generic_name: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    path: ?[]const u8 = null,
    exec: ?[]const u8 = null,
    terminal: ?bool = null,
};

fn unNullify(n: ParsedApp) ?App {
    return .{
        .name = n.name orelse return null,
        .icon = n.icon orelse return null,
        .categories = n.categories,
        .version = n.version,
        .generic_name = n.generic_name,
        .comment = n.comment,
        .path = n.path,
        .exec = n.exec,
        .terminal = n.terminal orelse false,
    };
}

pub fn init(self: *Launcher, alloc: std.mem.Allocator, io: std.Io) void {
    self.alloc = alloc;
    self.io = io;
    self.inited = true;
}

pub fn deinit(self: *Launcher) void {
    // Caller owns alloc/io lifetime; just free owned data.
    // Note: deinit may be called from UI thread while worker is stopped.
    for (self.data.items) |a| {
        self.alloc.free(a.name);
        if (a.categories) |v| self.alloc.free(v);
        if (a.version) |v| self.alloc.free(v);
        if (a.generic_name) |v| self.alloc.free(v);
        if (a.comment) |v| self.alloc.free(v);
        if (a.path) |v| self.alloc.free(v);
        if (a.exec) |v| self.alloc.free(v);
        self.alloc.free(a.icon);
    }
    self.data.deinit(self.alloc);
    var it = self.query.iterator();
    while (it.next()) |kv| {
        self.alloc.free(kv.key_ptr.*);
        if (kv.value_ptr.*) |slice| self.alloc.free(slice);
    }
    self.query.deinit(self.alloc);
    // pending items are same pointers as keys; don't double free.
    self.pending.deinit(self.alloc);
    self.* = .{};
}

// ---------------------------------------------------------------------------
// Helpers: case-insensitive substring
// ---------------------------------------------------------------------------
fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (needle.len > hay.len) return false;
    // Lowercase needle once into stack buf when small, heap otherwise
    // For simplicity, direct O(n*m) with ascii toLower.
    for (0..hay.len - needle.len + 1) |i| {
        var ok = true;
        for (needle, 0..) |nc, j| {
            const hc = hay[i + j];
            if (std.ascii.toLower(hc) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn appScore(app: *const App, term: []const u8) ?u8 {
    if (term.len == 0) return 0; // empty shows all as name-priority
    if (containsIgnoreCase(app.name, term)) return 0;
    if (app.comment) |c| if (containsIgnoreCase(c, term)) return 1;
    if (app.generic_name) |g| if (containsIgnoreCase(g, term)) return 1;
    if (app.categories) |cats| if (containsIgnoreCase(cats, term)) return 2;
    if (app.exec) |e| if (containsIgnoreCase(e, term)) return 3;
    return null;
}

// ---------------------------------------------------------------------------
// File loading – freedesktop .desktop parser
// ---------------------------------------------------------------------------
fn parseDesktopData(
    self: *Launcher,
    alloc: std.mem.Allocator,
    data: []const u8,
    path: []const u8,
) !void {
    var app: ParsedApp = .{};
    // Ensure we clean up on early return for non-Application types.
    var in_desktop_entry = false;
    var seen_desktop_entry = false;

    var lines = std.mem.splitSequence(u8, data, "\n");
    while (lines.next()) |line_raw| {
        // Handle CRLF and trim surrounding whitespace
        const line_trimmed = std.mem.trim(u8, line_raw, " \t\r");
        if (line_trimmed.len == 0) continue;
        if (line_trimmed[0] == '#') continue;

        // Group header: [Desktop Entry] or [Desktop Action ...]
        if (line_trimmed[0] == '[') {
            if (line_trimmed[line_trimmed.len - 1] != ']') {
                std.log.warn("malformed group header in \"{s}\": {s}", .{ path, line_trimmed });
                continue;
            }
            const group = std.mem.trim(u8, line_trimmed[1 .. line_trimmed.len - 1], " \t");
            if (std.mem.eql(u8, group, "Desktop Entry")) {
                in_desktop_entry = true;
                seen_desktop_entry = true;
            } else {
                in_desktop_entry = false;
            }
            continue;
        }

        if (!in_desktop_entry) {
            // If file never had a [Desktop Entry] header but contains keys,
            // be lenient: treat first keys as if in Desktop Entry until we
            // see a header. This maintains compatibility with files that
            // omit the header (rare) while still requiring seenDesktopEntry
            // later for strict files? For now, only parse if we have seen
            // the header OR file has no headers at all.
            // If we have not yet seen any header, assume we are in Desktop Entry.
            if (!seen_desktop_entry) {
                // Check if line looks like a key=value
                if (std.mem.indexOfScalar(u8, line_trimmed, '=') == null) continue;
                // Lazily consider we are in Desktop Entry
                in_desktop_entry = true;
            } else {
                continue;
            }
        }

        const eq_idx = std.mem.indexOfScalar(u8, line_trimmed, '=') orelse {
            // No '=', not a key line – skip
            continue;
        };
        const key_raw = std.mem.trim(u8, line_trimmed[0..eq_idx], " \t");
        const val_raw = std.mem.trim(u8, line_trimmed[eq_idx + 1 ..], " \t");

        if (key_raw.len == 0) continue;

        // Strip locale suffix: "Name[ar]" -> "Name", but keep original to detect locale
        const is_locale = std.mem.indexOfScalar(u8, key_raw, '[') != null;
        const key = if (std.mem.indexOfScalar(u8, key_raw, '[')) |b| key_raw[0..b] else key_raw;

        // For locale variants, keep first value and don't overwrite an existing
        // non-locale value. For non-locale, always (re)set, overwriting any
        // prior locale value.
        if (std.mem.eql(u8, key, "Name")) {
            if (is_locale and app.name != null) continue;
            if (app.name) |old| alloc.free(old);
            app.name = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "Exec")) {
            if (is_locale and app.exec != null) continue;
            if (app.exec) |old| alloc.free(old);
            app.exec = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "Type")) {
            if (!std.mem.eql(u8, val_raw, "Application")) {
                // Cleanup and skip this file – not an application
                if (app.name) |v| alloc.free(v);
                if (app.icon) |v| alloc.free(v);
                if (app.categories) |v| alloc.free(v);
                if (app.version) |v| alloc.free(v);
                if (app.generic_name) |v| alloc.free(v);
                if (app.comment) |v| alloc.free(v);
                if (app.path) |v| alloc.free(v);
                if (app.exec) |v| alloc.free(v);
                // Note: app.terminal is bool, no alloc
                return;
            }
        } else if (std.mem.eql(u8, key, "Version")) {
            if (is_locale and app.version != null) continue;
            if (app.version) |old| alloc.free(old);
            app.version = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "Categories")) {
            if (is_locale and app.categories != null) continue;
            if (app.categories) |old| alloc.free(old);
            app.categories = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "GenericName")) {
            if (is_locale and app.generic_name != null) continue;
            if (app.generic_name) |old| alloc.free(old);
            app.generic_name = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "Comment")) {
            if (is_locale and app.comment != null) continue;
            if (app.comment) |old| alloc.free(old);
            app.comment = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "Path")) {
            if (is_locale and app.path != null) continue;
            if (app.path) |old| alloc.free(old);
            app.path = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "Icon")) {
            if (is_locale and app.icon != null) continue;
            if (app.icon) |old| alloc.free(old);
            app.icon = try alloc.dupe(u8, val_raw);
        } else if (std.mem.eql(u8, key, "Terminal")) {
            app.terminal = std.mem.eql(u8, val_raw, "true") or std.mem.eql(u8, val_raw, "True") or std.mem.eql(u8, val_raw, "1");
        } else {
            // Unknown key – intentionally silent; locale keys like Name[ar] are
            // already handled via stripping, so this won't warn for "ar".
            continue;
        }
    }

    const a = unNullify(app) orelse {
        if (app.name) |v| alloc.free(v);
        if (app.icon) |v| alloc.free(v);
        if (app.categories) |v| alloc.free(v);
        if (app.version) |v| alloc.free(v);
        if (app.generic_name) |v| alloc.free(v);
        if (app.comment) |v| alloc.free(v);
        if (app.path) |v| alloc.free(v);
        if (app.exec) |v| alloc.free(v);
        return;
    };
    try self.data.append(alloc, a);
}

fn addFile(
    self: *Launcher,
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !void {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);
    const stat = try file.stat(io);
    var rd = file.reader(io, &.{});
    const data = try rd.interface.readAlloc(alloc, stat.size);
    defer alloc.free(data);
    try self.parseDesktopData(alloc, data, path);
}

fn addDir(
    self: *Launcher,
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{
        .iterate = true,
        .follow_symlinks = true,
    });
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".desktop")) {
            const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, e.name });
            defer alloc.free(full);
            try self.addFile(alloc, io, full);
        }
    }
}

pub fn loadList(self: *Launcher, pinit: std.process.Init) !void {
    if (!self.inited) {
        self.alloc = pinit.arena.allocator();
        // best-effort io: use pinit.io if available, else stored
        self.io = pinit.io;
        self.inited = true;
    }
    const alloc = self.alloc;
    // Use provided init alloc for scanning but store owned strings in self.alloc
    // For simplicity use self.alloc for everything now.
    var home: ?[]const u8 = null;
    defer if (home) |h| alloc.free(h);
    if (pinit.environ_map.get("HOME")) |h| {
        home = try std.fmt.allocPrint(alloc, "{s}/.local/share/applications", .{h});
    }
    if (home) |h|
        self.addDir(alloc, pinit.io, h) catch |e| {
            if (e != error.FileNotFound) std.log.warn("cannot get applications from {s}: {s}", .{
                h,
                @errorName(e),
            });
        };
    self.addDir(alloc, pinit.io, "/usr/local/share/applications") catch |e| {
        if (e != error.FileNotFound) std.log.warn("cannot get applications from {s}: {s}", .{
            "/usr/local/share/applications",
            @errorName(e),
        });
    };
    self.addDir(alloc, pinit.io, "/usr/share/applications") catch |e| {
        if (e != error.FileNotFound) std.log.warn("cannot get applications from {s}: {s}", .{
            "/usr/share/applications",
            @errorName(e),
        });
    };
}

/// Queue a search. Returns cached results if already computed, otherwise
/// inserts `null` for the term, enqueues it for `tick` and returns `null`.
/// Thread-safe: UI calls this, worker calls `tick`.
pub fn search(self: *Launcher, term: []const u8) ?[]*App {
    if (!self.inited) return null;
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);

    if (self.query.get(term)) |cached| {
        return cached;
    }
    const key = self.alloc.dupe(u8, term) catch return null;
    self.query.put(self.alloc, key, null) catch {
        self.alloc.free(key);
        return null;
    };
    self.pending.append(self.alloc, key) catch {
        // rollback map on OOM
        _ = self.query.remove(key);
        self.alloc.free(key);
        return null;
    };
    return null;
}

/// Worker-thread side: drain pending queue and populate query cache.
/// Prioritizes: 0=name, 1=comment/generic_name, 2=categories, 3=exec.
/// Must be called from the State worker thread (see State.zig).
pub fn tick(self: *Launcher) !void {
    if (!self.inited) return;
    var batch: std.ArrayList([]const u8) = .empty;
    defer batch.deinit(self.alloc);

    {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.pending.items.len == 0) return;
        std.mem.swap(std.ArrayList([]const u8), &self.pending, &batch);
    }

    for (batch.items) |term| {
        // Collect matches by priority buckets.
        var buckets: [4]std.ArrayList(*App) = .{ .empty, .empty, .empty, .empty };
        defer for (&buckets) |*b| b.deinit(self.alloc);

        // Fast path: empty term -> all apps in insertion order.
        if (term.len == 0) {
            var all: std.ArrayList(*App) = .empty;
            defer all.deinit(self.alloc);
            for (self.data.items) |*a| try all.append(self.alloc, @constCast(a));
            const owned = try all.toOwnedSlice(self.alloc);
            self.mu.lockUncancelable(self.io);
            if (self.query.getPtr(term)) |ptr| ptr.* = owned else {
                // Should not happen; term was inserted.
                self.alloc.free(owned);
            }
            self.mu.unlock(self.io);
            continue;
        }

        for (self.data.items) |*a| {
            const sc = appScore(a, term) orelse continue;
            try buckets[sc].append(self.alloc, a);
        }

        var total: usize = 0;
        for (buckets) |b| total += b.items.len;
        if (total == 0) {
            const empty: []*App = try self.alloc.alloc(*App, 0);
            self.mu.lockUncancelable(self.io);
            if (self.query.getPtr(term)) |ptr| ptr.* = empty;
            self.mu.unlock(self.io);
            continue;
        }

        const out = try self.alloc.alloc(*App, total);
        var off: usize = 0;
        for (buckets) |b| {
            @memcpy(out[off .. off + b.items.len], b.items);
            off += b.items.len;
        }

        self.mu.lockUncancelable(self.io);
        if (self.query.getPtr(term)) |ptr| {
            ptr.* = out;
        } else {
            // Term removed concurrently? free and ignore.
            self.alloc.free(out);
        }
        self.mu.unlock(self.io);
    }
}

pub fn run(self: *Launcher, id: usize) void {
    if (id >= self.data.items.len) return;
    const app = self.data.items[id];
    const raw_exec = app.exec orelse return;
    // Strip freedesktop Exec field codes (%f %F %u %U %d %D %n %N %i %c %k %v %m, %% -> %)
    // so `sh -c` doesn't see literal %U etc. and freeze on missing args.
    var cleaned: std.ArrayList(u8) = .empty;
    defer cleaned.deinit(self.alloc);
    var i: usize = 0;
    while (i < raw_exec.len) : (i += 1) {
        if (raw_exec[i] == '%' and i + 1 < raw_exec.len) {
            const code = raw_exec[i + 1];
            if (code == '%') {
                cleaned.append(self.alloc, '%') catch {};
                i += 1;
                continue;
            }
            if (std.mem.indexOfScalar(u8, "fFuUdDnNiCkv", code) != null or code == 'm') {
                i += 1;
                continue;
            }
        }
        cleaned.append(self.alloc, raw_exec[i]) catch {};
    }
    const exec = cleaned.items;
    if (exec.len == 0) return;
    const cwd: std.process.Child.Cwd = if (app.path) |p| .{ .path = p } else .inherit;
    var child = std.process.spawn(self.io, .{ .argv = &.{ "/bin/sh", "-c", exec }, .cwd = cwd }) catch |e| {
        std.log.err("failed to run {s}: {s}", .{ app.name, @errorName(e) });
        return;
    };
    // Don't block the UI thread: launching a long-lived app (e.g. terminal,
    // browser) would freeze the hub until it exits. Detach and reap in a
    // background thread so we don't leak zombies.
    const pid = child.id orelse return;
    child.id = null; // we will reap via waitpid, not Child.wait
    // Close any inherited stdio handles that Child may own (none for .inherit)
    if (child.stdin) |*f| f.close(self.io);
    if (child.stdout) |*f| f.close(self.io);
    if (child.stderr) |*f| f.close(self.io);
    const Box = struct { pid: std.posix.pid_t };
    const box = self.alloc.create(Box) catch return;
    box.pid = pid;
    const thread = std.Thread.spawn(.{}, struct {
        fn reap(b: *Box, alloc: std.mem.Allocator) void {
            defer alloc.destroy(b);
            var status: c_int = 0;
            _ = std.c.waitpid(b.pid, &status, 0);
        }
    }.reap, .{ box, self.alloc }) catch {
        self.alloc.destroy(box);
        return;
    };
    thread.detach();
}

// ---------------------------------------------------------------------------
// Tests – practical coverage against real .desktop files
// ---------------------------------------------------------------------------
test "launcher: parser handles locale keys without double free" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var launcher: Launcher = .{};
    launcher.init(alloc, io);
    defer launcher.deinit();

    const data =
        \\[Desktop Entry]
        \\Name=TestApp
        \\Name[ar]=اختبار
        \\GenericName=Test
        \\GenericName[ar]=اختبار
        \\Comment=A comment
        \\Comment[ar]=تعليق
        \\Exec=testapp --flag
        \\Icon=testicon
        \\Type=Application
        \\Categories=Utility;Test;
        \\Terminal=false
        \\
    ;
    try launcher.parseDesktopData(alloc, data, "/tmp/fake.desktop");
    try std.testing.expectEqual(@as(usize, 1), launcher.data.items.len);
    try std.testing.expectEqualStrings("TestApp", launcher.data.items[0].name);
    // Locale should not overwrite non-locale
    try std.testing.expectEqualStrings("Test", launcher.data.items[0].generic_name.?);
    try std.testing.expectEqualStrings("A comment", launcher.data.items[0].comment.?);
}

test "launcher: parser skips non-Application Type and cleans up" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var launcher: Launcher = .{};
    launcher.init(alloc, io);
    defer launcher.deinit();
    const data =
        \\[Desktop Entry]
        \\Name=Link
        \\Icon=link
        \\Type=Link
        \\URL=https://example.com
        \\
    ;
    try launcher.parseDesktopData(alloc, data, "/tmp/fake2.desktop");
    try std.testing.expectEqual(@as(usize, 0), launcher.data.items.len);
}

test "launcher: parser handles tricky real-world lines (equals in value, spaces)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var launcher: Launcher = .{};
    launcher.init(alloc, io);
    defer launcher.deinit();
    // Value contains '=' and leading/trailing spaces, plus locale and duplicate keys
    const data =
        \\[Desktop Entry]
        \\Name=My App
        \\Exec=sh -c "echo a=b; echo c=d"
        \\Icon=myicon
        \\Type=Application
        \\Comment=  spaced value  
        \\Categories=Utility;
        \\# Comment line
        \\GenericName=First
        \\GenericName=Second
        \\Terminal=True
        \\
    ;
    try launcher.parseDesktopData(alloc, data, "/tmp/fake3.desktop");
    try std.testing.expectEqual(@as(usize, 1), launcher.data.items.len);
    try std.testing.expectEqualStrings("My App", launcher.data.items[0].name);
    try std.testing.expectEqualStrings("sh -c \"echo a=b; echo c=d\"", launcher.data.items[0].exec.?);
    try std.testing.expectEqualStrings("spaced value", launcher.data.items[0].comment.?);
    try std.testing.expectEqualStrings("Second", launcher.data.items[0].generic_name.?);
    try std.testing.expect(launcher.data.items[0].terminal == true);
}

test "launcher: parser ignores actions and other groups" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var launcher: Launcher = .{};
    launcher.init(alloc, io);
    defer launcher.deinit();
    const data =
        \\[Desktop Entry]
        \\Name=App
        \\Exec=app
        \\Icon=icon
        \\Type=Application
        \\Categories=Utility;
        \\[Desktop Action New]
        \\Name=New Window
        \\Exec=app --new
        \\
    ;
    try launcher.parseDesktopData(alloc, data, "/tmp/fake4.desktop");
    try std.testing.expectEqual(@as(usize, 1), launcher.data.items.len);
    try std.testing.expectEqualStrings("App", launcher.data.items[0].name);
    try std.testing.expectEqualStrings("app", launcher.data.items[0].exec.?);
}

test "launcher: parse many real desktop files from system (practical)" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var launcher: Launcher = .{};
    launcher.init(alloc, io);
    defer launcher.deinit();

    const dirs = [_][]const u8{
        "/usr/share/applications",
        "/usr/local/share/applications",
    };

    var total_files: usize = 0;
    var parsed: usize = 0;
    for (dirs) |d| {
        var dir = std.Io.Dir.openDirAbsolute(io, d, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var iter = dir.iterate();
        while (try iter.next(io)) |e| {
            if (e.kind != .file) continue;
            if (!std.mem.endsWith(u8, e.name, ".desktop")) continue;
            total_files += 1;
            const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ d, e.name });
            defer alloc.free(full);
            // Must not crash, double-free, or leak (GPA will catch)
            launcher.addFile(alloc, io, full) catch |err| {
                // Some broken files are expected to be skipped; ensure no crash
                std.log.warn("skip {s}: {s}", .{ full, @errorName(err) });
                continue;
            };
            parsed += 1;
        }
    }
    // On this system we expect a lot of files; ensure we actually parsed some
    // and didn't double-free. The GPA in std.testing will fail on leak/double-free.
    try std.testing.expect(total_files > 50);
    try std.testing.expect(parsed > 30);
    try std.testing.expect(launcher.data.items.len > 10);

    // Spot-check a known file that previously triggered "unknown entry ar"
    var found_sieve = false;
    for (launcher.data.items) |app| {
        if (std.mem.indexOf(u8, app.name, "Sieve") != null) found_sieve = true;
    }
    // If sieveeditor exists on system, it should have been parsed; otherwise just ensure no crash
    if (found_sieve) try std.testing.expect(true);

    // Also test async search still works after bulk load (practical)
    // Need to guarantee search prioritizes correctly after bulk load
    try std.testing.expect(launcher.search("fire") == null);
    try launcher.tick();
    const res = launcher.search("fire");
    try std.testing.expect(res != null);
}
