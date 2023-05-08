const std = @import("std");

const Mem = struct {
    fn fmtSize(buf: []u8, size: usize) []u8 {
        return std.fmt.bufPrint(buf, "\x1b[33m{:>4}\x1b[36m{s:>3}\x1b[0m", .{
            if (size >= 1024 * 1024) size / (1024 * 1024) else if (size >= 1024) size / 1024 else size,
            if (size >= 1024 * 1024) "MiB" else if (size >= 1024) "KiB" else "B",
        }) catch unreachable;
    }
    fn usedMem(usages: anytype) void {
        inline for (@typeInfo(@TypeOf(usages)).Struct.fields, 0..) |field, i| {
            const usage = @field(usages, field.name);
            const used = usage[0];
            var used_buf: [32]u8 = undefined;
            const used_str = fmtSize(&used_buf, usage[0]);
            const max = usage[1];
            var max_buf: [32]u8 = undefined;
            const max_str = fmtSize(&max_buf, usage[1]);

            std.debug.print("{s}\x1b[34m{s}\x1b[0m:{s}/{s} (\x1b[33m{:>3}\x1b[0m%)", .{
                if (i == 0) "" else ", ",
                field.name,
                used_str,
                max_str,
                @floatToInt(
                    usize,
                    (@intToFloat(f64, used) / @intToFloat(f64, max)) * 100,
                ),
            });
        }
        std.debug.print("\n", .{});
    }
    fn initGPA(memory_limit: usize) std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }) {
        var gpa = std.heap.GeneralPurposeAllocator(.{
            .enable_memory_limit = true,
        }){};
        gpa.requested_memory_limit = memory_limit;
        return gpa;
    }
};

const HTTP = struct {
    fn initClient(allocator: std.mem.Allocator) !std.http.Client {
        var client = std.http.Client{ .allocator = allocator };

        try client.ca_bundle.rescan(allocator);
        client.next_https_rescan_certs = false;
        return client;
    }
};

const Zig = struct {
    const JSON = struct {
        master: struct {
            version: []const u8,
        },
    };
    const url = std.Uri.parse("https://ziglang.org/download/index.json") catch unreachable;

    fn fetchZigVersion(client: *std.http.Client, arena: std.mem.Allocator) ![]const u8 {
        var req = try client.request(url, .{}, .{
            .header_strategy = .{ .static = try arena.alloc(u8, 16 * 1024) },
        });
        defer req.deinit();
        var buf: [64 * 1024]u8 = undefined;
        var end = try req.readAll(&buf);
        const body = buf[0..end];
        var tokens = std.json.TokenStream.init(body);
        const parsed = try std.json.parse(JSON, &tokens, .{
            .allocator = arena,
            .duplicate_field_behavior = .UseFirst,
            .ignore_unknown_fields = true,
        });
        return parsed.master.version;
    }
    fn buildMarkdownString(arena: std.mem.Allocator, zig_version: []const u8) ![]const u8 {
        var it = std.mem.split(u8, zig_version, "+");
        const version = it.next() orelse return error.NoVersionFound;
        const commit = it.next() orelse return error.NoCommitFound;
        const versionEscaped = try std.mem.replaceOwned(u8, arena, version, ".", "\\.");
        const versionEscaped2 = try std.mem.replaceOwned(u8, arena, versionEscaped, "-", "\\-");
        const formatted = try std.fmt.allocPrint(
            arena,
            "[{s}](https://ziglang.org/download/)\\+[{s}](https://github.com/ziglang/zig/commits/{s})",
            .{ versionEscaped2, commit, commit },
        );
        const escaped = try std.fmt.allocPrint(arena, "New+Zig+version:+{s}", .{try std.Uri.escapeString(arena, formatted)});
        return escaped;
    }
};

const Telegram = struct {
    fn sendMessage(client: *std.http.Client, arena: std.mem.Allocator, token: []const u8, chat_id: []const u8, encoded_markdown_text: []const u8) ![]const u8 {
        var conn = try client.connect("api.telegram.org", 443, .tls);
        const r = conn.data.reader();
        const w = conn.data.writer();
        try w.writeAll("GET /bot");
        try w.writeAll(token);
        try w.writeAll("/sendMessage?chat_id=");
        try w.writeAll(chat_id);
        try w.writeAll("&text=");
        try w.writeAll(encoded_markdown_text);
        try w.writeAll(
            \\&parse_mode=MarkdownV2&disable_web_page_preview=1 HTTP/1.1
            \\Host: api.telegram.org
            \\Connection: close
            \\
            \\
        );
        var buf = try arena.alloc(u8, 4 * 1024);
        var total_bytes_read: usize = 0;
        var bytes_read = try r.read(buf[total_bytes_read..]);
        while (bytes_read > 0) : (bytes_read = try r.read(buf[total_bytes_read..])) {
            total_bytes_read += bytes_read;
        }
        const response = buf[0..total_bytes_read];
        const split = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.ResponseBodyNotFound;
        const body = response[split + 4 ..];
        return body;
    }
};

pub fn main() !void {
    var gpa = Mem.initGPA(10 * 1024 * 1024);
    defer std.debug.assert(!gpa.deinit());
    const permanent = gpa.allocator();

    var tmpMem = try permanent.alloc(u8, 1 * 1024 * 1024);
    defer permanent.free(tmpMem);
    var tmpFba = std.heap.FixedBufferAllocator.init(tmpMem);
    const arena = tmpFba.allocator();

    const chats_file = try std.fs.cwd().readFileAlloc(permanent, "chats.txt", 5 * 1024 * 1024);
    defer permanent.free(chats_file);

    var chats = std.ArrayList([]const u8).init(permanent);
    defer chats.deinit();

    var it = std.mem.split(u8, chats_file, "\n");
    while (it.next()) |chat| {
        if (chat.len == 0) continue;
        try chats.append(chat);
    }

    const args = try std.process.argsAlloc(permanent);
    defer std.process.argsFree(permanent, args);

    var client = try HTTP.initClient(permanent);
    client.allocator = arena;
    defer {
        client.allocator = permanent;
        client.deinit();
    }

    var current_version = try std.fs.cwd().readFileAlloc(permanent, "zig_version.txt", 1024);
    defer permanent.free(current_version);

    if (args.len >= 3 and std.mem.eql(u8, args[1], "bot")) {
        while (true) : (tmpFba.reset()) {
            defer std.time.sleep(std.time.ns_per_s * 300);

            Mem.usedMem(.{
                .permanent = .{ gpa.total_requested_bytes, gpa.requested_memory_limit },
                .arena = .{ tmpFba.end_index, tmpFba.buffer.len },
            });
            defer Mem.usedMem(.{
                .permanent = .{ gpa.total_requested_bytes, gpa.requested_memory_limit },
                .arena = .{ tmpFba.end_index, tmpFba.buffer.len },
            });

            const fetched_version = try Zig.fetchZigVersion(&client, arena);

            if (!std.mem.eql(u8, fetched_version, current_version)) {
                permanent.free(current_version);
                current_version = try permanent.dupe(u8, fetched_version);
                const escaped = try Zig.buildMarkdownString(arena, fetched_version);
                const token = args[2];
                const restorePoint = tmpFba.end_index;
                for (chats.items) |chat_id| {
                    defer tmpFba.end_index = restorePoint;
                    const body = Telegram.sendMessage(&client, arena, token, chat_id, escaped) catch |err| {
                        std.debug.print("Error while sending to {s}: {}\n", .{ chat_id, err });
                        continue;
                    };
                    std.debug.print("{s}\n", .{body});
                }
                try std.fs.cwd().writeFile("zig_version.txt", current_version);
            }
        }
    }
}
