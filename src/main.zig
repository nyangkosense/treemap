const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const fmt = std.fmt;

const max_path = 4096;
const max_depth = 64;
const max_pie = 10;

const EntryList = std.ArrayList(Entry);

const Entry = struct {
    name: []u8,
    size: u64,
    is_dir: bool,
    children: EntryList,
};

const Opts = struct {
    path: []const u8,
    html: bool,
};

const colors = [_][]const u8{
    "#e6194b", "#3cb44b", "#ffe119", "#4363d8", "#f58231",
    "#911eb4", "#42d4f4", "#f032e6", "#bfef45", "#fabed4",
    "#469990", "#dcbeff", "#9A6324", "#800000", "#aaffc3",
    "#808000", "#ffd8b1", "#000075", "#a9a9a9",
};

const usage =
    \\usage: treemap [--html] [--help] [path]
    \\
    \\recursively show directory tree with file sizes.
    \\
    \\options:
    \\  --html   generate treemap.html with pie chart
    \\  --help   show this help
    \\
;

fn die(comptime msg: []const u8) noreturn {
    const stderr = fs.File.stderr();
    var buf: [1024]u8 = undefined;
    var writer = stderr.writer(&buf);
    writer.interface.writeAll(msg) catch {};
    writer.interface.flush() catch {};
    std.process.exit(1);
}

fn parse_args(alloc: mem.Allocator) !Opts {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    const stdout = fs.File.stdout();
    var buf: [1024]u8 = undefined;
    var writer = stdout.writer(&buf);

     _ = args.next();

    var opts = Opts{ .path = ".", .html = false };
    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--html")) {
            opts.html = true;
        } else if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
            writer.interface.writeAll(usage) catch {};
            writer.interface.flush() catch {};
            std.process.exit(0);
        } else if (arg[0] == '-') {
            die(usage);
        } else {
            opts.path = arg;
        }
    }

    return opts;
}

fn resolve_path(alloc: mem.Allocator, path: []const u8) ![]u8 {
    if (fs.path.isAbsolute(path)) {
        return alloc.dupe(u8, path);
    }
    var buf: [max_path]u8 = undefined;
    const cwd = try fs.cwd().realpath(".", &buf);
    return fmt.allocPrint(alloc, "{s}/{s}", .{ cwd, path });
}

fn format_size(buf: []u8, size: u64) ![]const u8 {
    const fsize = @as(f64, @floatFromInt(size));
    if (size >= 1024 * 1024 * 1024) {
        return fmt.bufPrint(buf, "{d:.2} GB", .{fsize / (1024.0 * 1024.0 * 1024.0)});
    }
    if (size >= 1024 * 1024) {
        return fmt.bufPrint(buf, "{d:.2} MB", .{fsize / (1024.0 * 1024.0)});
    }
    if (size >= 1024) {
        return fmt.bufPrint(buf, "{d:.2} KB", .{fsize / 1024.0});
    }
    return fmt.bufPrint(buf, "{d} B", .{size});
}

fn get_color(name: []const u8) []const u8 {
    var hash: u32 = 0;
    for (name) |c| {
        hash = hash *% 31 +% c;
    }
    return colors[hash % colors.len];
}

fn open_dir(parent: fs.Dir, name: []const u8) ?fs.Dir {
    return parent.openDir(name, .{ .iterate = true }) catch return null;
}

fn stat_size(dir: fs.Dir, name: []const u8) u64 {
    const stat = dir.statFile(name) catch return 0;
    return stat.size;
}

fn calc_dir_size(parent: fs.Dir, name: []const u8) u64 {
    var dir = open_dir(parent, name) orelse return 0;
    defer dir.close();

    var total: u64 = 0;
    var iter = dir.iterate();
    while (iter.next() catch return total) |item| {
        if (item.kind == .directory) {
            total += calc_dir_size(dir, item.name);
        } else {
            total += stat_size(dir, item.name);
        }
    }
    return total;
}

fn count_entries(dir: fs.Dir) usize {
    var count: usize = 0;
    var iter = dir.iterate();
    while (iter.next() catch return count) |_| {
        count += 1;
    }
    return count;
}

fn print_entry(writer: *std.Io.Writer, name: []const u8, size: u64, is_dir: bool, prefix: []const u8, is_last: bool) !void {
    var size_buf: [64]u8 = undefined;
    const size_str = try format_size(&size_buf, size);
    const connector: []const u8 = if (is_last) "└── " else "├── ";
    const suffix: []const u8 = if (is_dir) "/" else "";
    try writer.print("{s}{s}{s}{s} [{s}]\n", .{ prefix, connector, name, suffix, size_str });
}

fn child_prefix(prefix: []const u8, is_last: bool, buf: []u8) ![]const u8 {
    return fmt.bufPrint(buf, "{s}{s}", .{
        prefix,
        if (is_last) "    " else "│   ",
    });
}

fn stream_tree(writer: *std.Io.Writer, parent: fs.Dir, name: []const u8, prefix: []const u8, is_last: bool) !void {
    var dir = open_dir(parent, name) orelse {
        try print_entry(writer, name, 0, true, prefix, is_last);
        return;
    };
    defer dir.close();

    const total = calc_dir_size(parent, name);
    try print_entry(writer, name, total, true, prefix, is_last);

    const count = count_entries(dir);

    var new_prefix_buf: [max_depth * 4]u8 = undefined;
    const new_prefix = try child_prefix(prefix, is_last, &new_prefix_buf);

    var iter = dir.iterate();
    var i: usize = 0;
    while (try iter.next()) |item| {
        i += 1;
        const child_is_last = i == count;

        if (item.kind == .directory) {
            try stream_tree(writer, dir, item.name, new_prefix, child_is_last);
        } else {
            const size = stat_size(dir, item.name);
            try print_entry(writer, item.name, size, false, new_prefix, child_is_last);
        }
    }
}

fn run_stream(path: []const u8) !void {
    var wbuf: [4096]u8 = undefined;
    var writer = fs.File.stdout().writer(&wbuf);
    const stdout = &writer.interface;

    var path_buf: [max_path]u8 = undefined;
    const abs = try fs.cwd().realpath(path, &path_buf);

    try stdout.print("{s}\n", .{abs});

    var dir = open_dir(fs.cwd(), path) orelse {
        try stdout.flush();
        return;
    };
    defer dir.close();

    const count = count_entries(dir);
    var iter = dir.iterate();
    var i: usize = 0;
    while (try iter.next()) |item| {
        i += 1;
        const child_is_last = i == count;

        if (item.kind == .directory) {
            try stream_tree(stdout, dir, item.name, "", child_is_last);
        } else {
            const size = stat_size(dir, item.name);
            try print_entry(stdout, item.name, size, false, "", child_is_last);
        }
    }
    try stdout.flush();
}

fn free_entry(alloc: mem.Allocator, entry: *const Entry) void {
    alloc.free(entry.name);
    for (entry.children.items) |child| {
        free_entry(alloc, &child);
    }
    var mut_children = entry.children;
    mut_children.deinit(alloc);
}

fn sum_sizes(children: EntryList) u64 {
    var total: u64 = 0;
    for (children.items) |child| {
        total += child.size;
    }
    return total;
}

fn entry_greater(_: void, a: Entry, b: Entry) bool {
    return a.size > b.size;
}

fn sort_entries(children: *EntryList) void {
    mem.sort(Entry, children.items, {}, entry_greater);
}

fn walk_dir(alloc: mem.Allocator, path: []const u8) anyerror!Entry {
    var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        if (err == error.AccessDenied) {
            const name = try alloc.dupe(u8, fs.path.basename(path));
            return Entry{ .name = name, .size = 0, .is_dir = true, .children = .empty };
        }
        return err;
    };
    defer dir.close();

    var children = EntryList.empty;
    errdefer {
        for (children.items) |child| {
            free_entry(alloc, &child);
        }
        children.deinit(alloc);
    }

    const initial_cap = 64;
    try children.ensureTotalCapacity(alloc, initial_cap);

    var iter = dir.iterate();
    while (try iter.next()) |item| {
        const child = if (item.kind == .directory)
            try walk_subdir(alloc, path, item.name)
        else
            try read_file(alloc, dir, item.name);
        try children.append(alloc, child);
    }

    sort_entries(&children);

    const name = try alloc.dupe(u8, fs.path.basename(path));
    errdefer alloc.free(name);

    return Entry{
        .name = name,
        .size = sum_sizes(children),
        .is_dir = true,
        .children = children,
    };
}

fn walk_subdir(alloc: mem.Allocator, parent: []const u8, name: []const u8) anyerror!Entry {
    const child_path = try fmt.allocPrint(alloc, "{s}/{s}", .{ parent, name });
    defer alloc.free(child_path);
    return walk_dir(alloc, child_path);
}

fn read_file(alloc: mem.Allocator, dir: fs.Dir, name: []const u8) anyerror!Entry {
    const stat = dir.statFile(name) catch |err| {
        if (err == error.FileNotFound or err == error.AccessDenied) {
            const entry_name = try alloc.dupe(u8, name);
            return Entry{ .name = entry_name, .size = 0, .is_dir = false, .children = .empty };
        }
        return err;
    };
    const entry_name = try alloc.dupe(u8, name);
    errdefer alloc.free(entry_name);

    return Entry{
        .name = entry_name,
        .size = stat.size,
        .is_dir = false,
        .children = .empty,
    };
}

fn write_html_header(writer: *std.Io.Writer, title: []const u8) !void {
    try writer.writeAll(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\<meta charset="utf-8">
        \\<title>
    );
    try writer.writeAll(title);
    try writer.writeAll(
        \\</title>
        \\<style>
        \\body { font-family: monospace; margin: 20px; background: #1a1a2e; color: #eee; }
        \\h1 { color: #e6194b; }
        \\h2 { color: #4363d8; margin-top: 30px; }
        \\.size { color: #888; }
        \\.dir { color: #4363d8; font-weight: bold; }
        \\.file { color: #ccc; }
        \\ul { list-style: none; padding-left: 20px; }
        \\li { margin: 2px 0; }
        \\.chart-wrap { display: flex; gap: 40px; align-items: flex-start; flex-wrap: wrap; }
        \\.legend { margin-top: 10px; }
        \\.legend-item { display: flex; align-items: center; gap: 8px; margin: 4px 0; }
        \\.dot { width: 12px; height: 12px; border-radius: 50%; display: inline-block; }
        \\svg { filter: drop-shadow(0 0 6px rgba(0,0,0,0.5)); }
        \\</style>
        \\</head>
        \\<body>
        \\
    );
}

fn write_html_footer(writer: *std.Io.Writer) !void {
    try writer.writeAll("</body>\n</html>\n");
}

fn write_slice(writer: *std.Io.Writer, name: []const u8, dash: f64, circ: f64, offset: f64) !void {
    try writer.print(
        \\<circle cx="50" cy="50" r="40" fill="none" stroke="{s}" stroke-width="20" stroke-dasharray="{d:.2} {d:.2}" stroke-dashoffset="{d:.2}" transform="rotate(-90 50 50)"/>
        \\
    , .{ get_color(name), dash, circ, -offset });
}

fn write_pie_chart(writer: *std.Io.Writer, entry: Entry) !void {
    if (entry.children.items.len == 0 or entry.size == 0) return;

    try writer.writeAll(
        \\<svg viewBox="0 0 100 100" width="300" height="300">
        \\
    );

    const circ = 2.0 * std.math.pi * 40.0;
    var offset: f64 = 0;

    const limit = @min(entry.children.items.len, max_pie);
    for (entry.children.items[0..limit]) |child| {
        const pct = @as(f64, @floatFromInt(child.size)) / @as(f64, @floatFromInt(entry.size));
        const dash = pct * circ;
        try write_slice(writer, child.name, dash, circ, offset);
        offset += dash;
    }

    if (entry.children.items.len > max_pie) {
        var other_size: u64 = 0;
        for (entry.children.items[max_pie..]) |child| {
            other_size += child.size;
        }
        const pct = @as(f64, @floatFromInt(other_size)) / @as(f64, @floatFromInt(entry.size));
        const dash = pct * circ;
        try write_slice(writer, "Other", dash, circ, offset);
    }

    try writer.writeAll("</svg>\n");
}

fn write_legend(writer: *std.Io.Writer, entry: Entry) !void {
    var size_buf: [64]u8 = undefined;

    try writer.writeAll("<div class=\"legend\">\n");

    const limit = @min(entry.children.items.len, max_pie);
    for (entry.children.items[0..limit]) |child| {
        const size_str = try format_size(&size_buf, child.size);
        const pct = if (entry.size > 0)
            @as(f64, @floatFromInt(child.size)) / @as(f64, @floatFromInt(entry.size)) * 100.0
        else
            0.0;
        try writer.print(
            \\<div class="legend-item"><span class="dot" style="background:{s}"></span> {s} <span class="size">[{s} ({d:.1}%)]</span></div>
            \\
        , .{ get_color(child.name), child.name, size_str, pct });
    }

    try writer.writeAll("</div>\n");
}

fn write_tree_html(writer: *std.Io.Writer, entry: Entry) !void {
    var size_buf: [64]u8 = undefined;
    const size_str = try format_size(&size_buf, entry.size);
    const cls: []const u8 = if (entry.is_dir) "dir" else "file";

    try writer.print("<li><span class=\"{s}\">{s}</span> <span class=\"size\">[{s}]</span>\n", .{
        cls,
        entry.name,
        size_str,
    });

    if (!entry.is_dir) return;

    try writer.writeAll("<ul>\n");
    for (entry.children.items) |child| {
        try write_tree_html(writer, child);
    }
    try writer.writeAll("</ul>\n</li>\n");
}

fn write_html(alloc: mem.Allocator, entry: Entry) !void {
    const path = "treemap.html";
    const file = try fs.cwd().createFile(path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    const w = &writer.interface;
    try write_html_header(w, entry.name);
    try w.writeAll("<h1>treemap</h1>\n");
    var size_buf: [64]u8 = undefined;
    const size_str = try format_size(&size_buf, entry.size);
    try w.print("<p>{s} - total: {s}</p>\n", .{ entry.name, size_str });

    if (entry.children.items.len > 0) {
        try w.writeAll("<h2>size distribution</h2>\n<div class=\"chart-wrap\">\n<div>\n");
        try write_pie_chart(w, entry);
        try w.writeAll("</div>\n");
        try write_legend(w, entry);
        try w.writeAll("</div>\n");
    }

    try w.writeAll("<h2>tree</h2>\n<ul>\n");
    for (entry.children.items) |child| {
        try write_tree_html(w, child);
    }
    try w.writeAll("</ul>\n");
    try write_html_footer(w);
    try w.flush();

    _ = alloc;

    var owbuf: [4096]u8 = undefined;
    var out_writer = fs.File.stdout().writer(&owbuf);
    try out_writer.interface.print("wrote {s}\n", .{path});
    try out_writer.interface.flush();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const opts = try parse_args(alloc);

    const abs_path = try resolve_path(alloc, opts.path);
    defer alloc.free(abs_path);

    if (opts.html) {
        const entry = try walk_dir(alloc, abs_path);
        defer free_entry(alloc, &entry);
        try write_html(alloc, entry);
    } else {
        try run_stream(abs_path);
    }
}

test "format_size bytes" {
    var buf: [64]u8 = undefined;
    const result = try format_size(&buf, 512);
    try std.testing.expectEqualStrings("512 B", result);
}

test "format_size kb" {
    var buf: [64]u8 = undefined;
    const result = try format_size(&buf, 1536);
    try std.testing.expectEqualStrings("1.50 KB", result);
}

test "format_size mb" {
    var buf: [64]u8 = undefined;
    const result = try format_size(&buf, 1024 * 1024);
    try std.testing.expectEqualStrings("1.00 MB", result);
}

test "format_size gb" {
    var buf: [64]u8 = undefined;
    const result = try format_size(&buf, 1024 * 1024 * 1024);
    try std.testing.expectEqualStrings("1.00 GB", result);
}

test "get_color deterministic" {
    const c1 = get_color("test");
    const c2 = get_color("test");
    try std.testing.expectEqualStrings(c1, c2);
}
