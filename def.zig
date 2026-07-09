const std = @import("std");

const Definition = struct {
    definition: []const u8,
    example: []const u8,
};

const Meaning = struct {
    partOfSpeech: []const u8,
    definitions: []const Definition,
    synonyms: []const []const u8,
    antonyms: []const []const u8,
};

const Entry = struct {
    word: []const u8,
    meanings: []const Meaning,
};

const base_url = "https://api.dictionaryapi.dev/api/v2/entries/en/";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);

    if (args.len == 1) {
        std.debug.print("usage: def word\n", .{});
        return;
    }

    const words = args[1..];

    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    var stdout_buffer: [4 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    for (words) |word| {
        const response = getDefinition(gpa, &client, word) catch |err| switch (err) {
            error.UnknownWord => {
                std.debug.print("unknown word: {s}\n", .{word});
                continue;
            },
            else => return err,
        };
        defer gpa.free(response);

        const parsed = try std.json.parseFromSlice(
            []const Entry,
            gpa,
            response,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        for (parsed.value) |entry| {
            try stdout.print("{s}\n", .{entry.word});

            for (entry.meanings) |meaning| {
                try stdout.print("  {s}\n", .{meaning.partOfSpeech});

                for (meaning.definitions) |definition| {
                    try stdout.print("    {s}\n", .{definition.definition});
                }

                for (meaning.synonyms) |synonym| {
                    try stdout.print("    {s},", .{synonym});
                }
                try stdout.writeByte('\n');

                for (meaning.antonyms) |antonym| {
                    try stdout.print("    {s},", .{antonym});
                }
                try stdout.writeByte('\n');
            }
        }
    }
    try stdout.flush();
}

pub fn getDefinition(allocator: std.mem.Allocator, client: *std.http.Client, word: []const u8) ![]u8 {
    const request_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, word });
    defer allocator.free(request_url);

    var request = try client.request(.GET, try std.Uri.parse(request_url), .{});
    defer request.deinit();

    try request.sendBodiless();

    var redirect_buffer: [1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);

    if (response.head.status == .not_found) {
        return error.UnknownWord;
    }

    if (response.head.status.class() != .success) {
        return error.HttpRequestFailure;
    }

    var decompress: std.http.Decompress = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;

    var transfer_buffer: [4 * 1024]u8 = undefined;
    var reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

    var body: std.Io.Writer.Allocating = .init(allocator);
    errdefer body.deinit();

    _ = try reader.streamRemaining(&body.writer);

    return try body.toOwnedSlice();
}
