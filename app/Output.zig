/// Output is responsible for writing out values in View.buffer
/// to stdout. It uses TreeView—which handles formatting—to do so.
const std = @import("std");
const args = @import("./args.zig");
const tui = @import("../tui.zig");
const string = @import("../utils/string.zig");
const icons_ = @import("./icons.zig");

const App = @import("./App.zig");
const View = @import("./View.zig");
const Capture = @import("./Capture.zig");
const Viewport = @import("./Viewport.zig");
const TreeView = @import("./TreeView.zig");
const Item = @import("../fs/Item.zig");

const Config = App.Config;
const SearchQuery = string.SearchQuery;

const fs = std.fs;
const io = std.io;
const mem = std.mem;
const icons = icons_.icons;

allocator: mem.Allocator,
draw: *tui.Draw,
writer: *tui.BufferedStdOut,

treeview: *TreeView,
obuf: [2048]u8, // Content Buffer
sbuf: [2048]u8, // Style Buffer

const Self = @This();

pub fn init(allocator: mem.Allocator, config: *Config) !Self {
    const treeview = try allocator.create(TreeView);
    const writer = try allocator.create(tui.BufferedStdOut);
    var draw = try allocator.create(tui.Draw);

    writer.* = tui.BufferedStdOut.init();

    // writer.use_csi_sync = try tui.terminal.canSynchornizeOutput(); // breaks on macOS Terminal
    // writer.use_dcs_sync = true; // garbage output on macOS Terminal
    writer.use_csi_sync = true; // fails silently if does not work

    draw.* = tui.Draw{ .writer = writer };
    treeview.* = try TreeView.init(allocator, config);

    try draw.hideCursor();
    try draw.disableAutowrap();
    return .{
        .allocator = allocator,
        .writer = writer,
        .draw = draw,
        .treeview = treeview,
        .obuf = undefined,
        .sbuf = undefined,
    };
}

pub fn deinit(self: *Self) void {
    self.draw.showCursor() catch {};
    self.draw.enableAutowrap() catch {};
    self.treeview.deinit();
    self.allocator.destroy(self.draw);
    self.allocator.destroy(self.treeview);
    self.allocator.destroy(self.writer);
}

pub fn printContents(
    self: *Self,
    viewport: *Viewport,
    view: *View,
    search_query: ?*const SearchQuery,
    is_capturing_command: bool,
    root_path: []const u8,
) !void {
    self.writer.buffered();
    defer {
        self.writer.flush() catch {};
        self.writer.unbuffered();
    }

    try self.draw.moveCursor(viewport.start_row, 0);
    try self.treeview.printLines(
        view,
        self.draw,
        viewport,
        search_query,
        is_capturing_command,
        root_path,
    );

    const rendered_rows: u16 = @intCast(view.last - view.first);
    try self.draw.clearLinesBelow(viewport.start_row + rendered_rows + 1);
}

pub fn printCaptureString(self: *Self, view: *View, viewport: *Viewport, capture: *Capture) !void {
    self.writer.buffered();
    defer {
        self.writer.flush() catch {};
        self.writer.unbuffered();
    }

    const captured = capture.string();
    const row = viewport.start_row + view.last - view.first;
    const col = viewport.size.cols - captured.len - 1;
    try self.draw.moveCursor(row, col);

    const sigil = if (capture.ctype == .search) "/" else ":";
    try self.draw.print(sigil, .{ .fg = .black, .bg = .cyan });
    try self.draw.print(captured, .{ .fg = .black, .bg = .yellow });
}
