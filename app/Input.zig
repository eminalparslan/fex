/// Input is responsible for converting values read from stdin
/// into AppAction values which are carried out by App.
const std = @import("std");
const tui = @import("../tui.zig");
const utils = @import("../utils.zig");
const Capture = @import("./Capture.zig");
const View = @import("./View.zig");
const TreeView = @import("./TreeView.zig");
const terminal = @import("../tui/terminal.zig");

const fs = std.fs;
const io = std.io;
const mem = std.mem;

const log = std.log.scoped(.input);

const ReadError = error{
    EndOfStream,
    ReceivedCursorPosition,
};

pub const AppAction = enum {
    up,
    down,
    left,
    right,
    enter,
    quit,
    top,
    bottom,
    depth_one,
    depth_two,
    depth_three,
    depth_four,
    depth_five,
    depth_six,
    depth_seven,
    depth_eight,
    depth_nine,
    expand_all,
    collapse_all,
    prev_fold,
    next_fold,
    change_root,
    open_item,
    change_dir,

    toggle_info,
    toggle_icons,
    toggle_size,
    toggle_time,
    toggle_perm,
    toggle_link,
    toggle_group,
    toggle_user,
    time_modified,
    time_changed,
    time_accessed,
    toggle_dotfiles,

    sort_name,
    sort_size,
    sort_time,
    sort_name_desc,
    sort_size_desc,
    sort_time_desc,

    append_absolute,
    prepend_absolute,
    append_relative,
    prepend_relative,

    select,

    search,
    update_search,
    accept_search,
    dismiss_search,

    command,
    exec_command,
    dismiss_command,

    no_action,
};

const ActionSequence = struct {
    seq: []const u8,
    action: AppAction,
};

const capture_list = [_]ActionSequence{
    // UDLR, navigation inputs
    .{ .seq = "k", .action = .up },
    .{ .seq = "\x1b\x5b\x41", .action = .up }, // Up Arrow
    .{ .seq = "\x1b\x4f\x41", .action = .up }, // Up Arrow (zsh-widget)

    .{ .seq = "j", .action = .down },
    .{ .seq = "\x1b\x5b\x42", .action = .down }, // Down Arrow
    .{ .seq = "\x1b\x4f\x42", .action = .down }, // Down Arrow (zsh-widget)

    .{ .seq = "h", .action = .left },
    .{ .seq = "\x1b\x5b\x44", .action = .left }, // Left Arrow
    .{ .seq = "\x1b\x4f\x44", .action = .left }, // Left Arrow (zsh-widget)

    .{ .seq = "l", .action = .right },
    .{ .seq = "\x1b\x5b\x43", .action = .right }, // Right Arrow
    .{ .seq = "\x1b\x4f\x43", .action = .right }, // Right Arrow (zsh-widget)

    // Toggle expansion or open
    .{ .seq = "\x0d", .action = .enter }, // Enter if ~ICRNL else \x0a

    // Quit
    .{ .seq = "q", .action = .quit },
    .{ .seq = "\x03", .action = .quit }, // Ctrl-C
    .{ .seq = "\x04", .action = .quit }, // Ctrl-D

    // Expand to depth
    .{ .seq = "1", .action = .depth_one },
    .{ .seq = "2", .action = .depth_two },
    .{ .seq = "3", .action = .depth_three },
    .{ .seq = "4", .action = .depth_four },
    .{ .seq = "5", .action = .depth_five },
    .{ .seq = "6", .action = .depth_six },
    .{ .seq = "7", .action = .depth_seven },
    .{ .seq = "8", .action = .depth_eight },
    .{ .seq = "9", .action = .depth_nine },

    // Display toggles
    .{ .seq = "ti", .action = .toggle_info },
    .{ .seq = "tI", .action = .toggle_icons },
    .{ .seq = "ts", .action = .toggle_size },
    .{ .seq = "tp", .action = .toggle_perm },
    .{ .seq = "tt", .action = .toggle_time },
    .{ .seq = "tl", .action = .toggle_link },
    .{ .seq = "tu", .action = .toggle_user },
    .{ .seq = "tg", .action = .toggle_group },
    .{ .seq = "tm", .action = .time_modified },
    .{ .seq = "tc", .action = .time_changed },
    .{ .seq = "ta", .action = .time_accessed },
    .{ .seq = ".", .action = .toggle_dotfiles },

    // Sorting
    .{ .seq = "sn", .action = .sort_name },
    .{ .seq = "ss", .action = .sort_size },
    .{ .seq = "st", .action = .sort_time },
    .{ .seq = "sdn", .action = .sort_name_desc },
    .{ .seq = "sds", .action = .sort_size_desc },
    .{ .seq = "sdt", .action = .sort_time_desc },

    .{ .seq = "A", .action = .append_absolute },
    .{ .seq = "I", .action = .prepend_absolute },
    .{ .seq = "a", .action = .append_relative },
    .{ .seq = "i", .action = .prepend_relative },

    // Expansion toggles
    .{ .seq = "E", .action = .expand_all },
    .{ .seq = "C", .action = .collapse_all },

    // Fold jumps
    .{ .seq = "{", .action = .prev_fold },
    .{ .seq = "}", .action = .next_fold },

    // End jumps
    .{ .seq = "gg", .action = .top },
    .{ .seq = "G", .action = .bottom },

    // Misc
    .{ .seq = "R", .action = .change_root },
    .{ .seq = "o", .action = .open_item },
    .{ .seq = "cd", .action = .change_dir },
    .{ .seq = "\t", .action = .select },

    // Capture actions
    .{ .seq = "/", .action = .search },
    .{ .seq = ":", .action = .command },
};

reader: fs.File.Reader,
buf: [128]u8,
allocator: mem.Allocator,

// Capture groups
search: *Capture,
command: *Capture,

const Self = @This();

pub fn init(allocator: mem.Allocator) !Self {
    const reader = io.getStdIn().reader();

    const search = try allocator.create(Capture);
    search.* = try Capture.init(allocator, .search);

    const command = try allocator.create(Capture);
    command.* = try Capture.init(allocator, .command);

    return .{
        .reader = reader,
        .buf = undefined,
        .allocator = allocator,
        .search = search,
        .command = command,
    };
}

pub fn deinit(self: *Self) void {
    self.search.deinit();
    self.allocator.destroy(self.search);

    self.command.deinit();
    self.allocator.destroy(self.command);
}

pub fn read(self: *Self, buf: []u8) ![]u8 {
    const size = try self.reader.read(buf);
    if (size == 0) {
        return ReadError.EndOfStream;
    }

    if (terminal.isCursorPosition(buf[0..size])) {
        return ReadError.ReceivedCursorPosition;
    }

    return buf[0..size];
}

pub fn getAppAction(self: *Self) !AppAction {
    // Capture search
    if (self.search.is_capturing) {
        return try self.captureSearch();
    }

    // Capture command
    else if (self.command.is_capturing) {
        return try self.captureCommand();
    }

    return self.readAppAction();
}

fn captureSearch(self: *Self) !AppAction {
    const slc = self.read(&self.buf) catch |err| switch (err) {
        error.ReceivedCursorPosition => return .no_action,
        error.EndOfStream => return .no_action,
        else => return err,
    };
    log.debug("slc: {any}", .{slc});

    if (slc[0] == 27) {
        self.search.stop(true);
        return .dismiss_search;
    }

    if (slc[0] == 13) {
        self.search.stop(true);
        return .accept_search;
    }

    try self.search.capture(slc);
    log.info("search: \"{s}\"", .{self.search.string()});
    return .update_search;
}

fn captureCommand(self: *Self) !AppAction {
    const slc = self.read(&self.buf) catch |err| switch (err) {
        error.ReceivedCursorPosition => return .no_action,
        error.EndOfStream => return .no_action,
        else => return err,
    };
    log.debug("slc: {any}", .{slc});

    if (slc[0] == 27) {
        self.command.stop(true);
        return .dismiss_command;
    }

    if (slc[0] == 13) {
        self.command.stop(false);
        return .exec_command;
    }

    try self.command.capture(slc);
    log.info("command: \"{s}\"", .{self.command.string()});

    return .no_action;
}

fn readAppAction(self: *Self) !AppAction {
    var len = try self.reader.read(&self.buf);
    var slc = self.buf[0..len];

    if (terminal.isCursorPosition(slc)) {
        return .no_action;
    }

    var ibuf: [128]u8 = undefined;
    while (true) {
        log.debug("slc: {any}", .{slc});
        inline for (capture_list) |ca| {
            if (utils.eql(ca.seq, slc)) {
                return ca.action;
            }

            if (len < ca.seq.len and utils.eql(slc, ca.seq[0..len])) {
                len += try self.reader.read(self.buf[slc.len..]);
                slc = self.buf[0..len];
                break;
            }
        } else if (slc.len > 1) {
            len -= 1;
            @memcpy(ibuf[0..len], self.buf[1..(len + 1)]);
            @memcpy(self.buf[0..len], ibuf[0..len]);
            slc = self.buf[0..len];
        } else {
            return .no_action;
        }
    }
    unreachable;
}
