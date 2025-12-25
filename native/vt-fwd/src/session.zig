const std = @import("std");

pub const SessionInfo = struct {
    id: []const u8,
    name: []const u8,
    command: []const []const u8,
    workingDir: []const u8,
    status: []const u8,
    exitCode: ?i32 = null,
    startedAt: []const u8,
    pid: ?i32 = null,
    initialCols: ?u16 = null,
    initialRows: ?u16 = null,
    lastClearOffset: ?u64 = null,
    version: ?[]const u8 = null,
    gitRepoPath: ?[]const u8 = null,
    gitBranch: ?[]const u8 = null,
    gitAheadCount: ?i32 = null,
    gitBehindCount: ?i32 = null,
    gitHasChanges: ?bool = null,
    gitIsWorktree: ?bool = null,
    gitMainRepoPath: ?[]const u8 = null,
    attachedViaVT: ?bool = null,
};

pub fn writeSessionInfo(path: []const u8, info: SessionInfo, allocator: std.mem.Allocator) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp_path);

    var file = try std.fs.cwd().createFile(temp_path, .{ .truncate = true, .read = false, .mode = 0o644 });
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(&buffer);
    try std.json.Stringify.value(info, .{ .emit_null_optional_fields = false, .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.end();

    try std.fs.cwd().rename(temp_path, path);
}

pub fn readSessionInfo(
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.json.Parsed(SessionInfo) {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    errdefer allocator.free(data);
    return std.json.parseFromSlice(SessionInfo, allocator, data, .{});
}

pub fn readSessionName(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const data = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return null;
    defer allocator.free(data);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const name_value = parsed.value.object.get("name") orelse return null;
    if (name_value != .string) return null;
    const name_copy = allocator.dupe(u8, name_value.string) catch return null;
    return name_copy;
}

pub fn updateSessionName(allocator: std.mem.Allocator, path: []const u8, name: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const data = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(data);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidSessionJson;
    try parsed.value.object.put("name", .{ .string = name });

    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp_path);

    var file = try std.fs.cwd().createFile(temp_path, .{ .truncate = true, .read = false, .mode = 0o644 });
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(&buffer);
    try std.json.Stringify.value(parsed.value, .{ .whitespace = .indent_2 }, &writer.interface);
    try writer.interface.writeAll("\n");
    try writer.end();

    try std.fs.cwd().rename(temp_path, path);
}

test "writeSessionInfo and updateSessionName" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "session.json" });
    defer allocator.free(path);

    const command = [_][]const u8{ "echo", "hi" };
    const info = SessionInfo{
        .id = "test-session",
        .name = "initial name",
        .command = &command,
        .workingDir = "/tmp",
        .status = "running",
        .startedAt = "2025-01-01T00:00:00Z",
    };

    try writeSessionInfo(path, info, allocator);

    const name1 = try readSessionName(allocator, path);
    defer if (name1) |value| allocator.free(value);
    try std.testing.expect(name1 != null);
    try std.testing.expectEqualStrings("initial name", name1.?);

    try updateSessionName(allocator, path, "updated name");
    const name2 = try readSessionName(allocator, path);
    defer if (name2) |value| allocator.free(value);
    try std.testing.expect(name2 != null);
    try std.testing.expectEqualStrings("updated name", name2.?);
}

test "updateSessionName preserves fields and tolerates missing keys" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "session.json" });
    defer allocator.free(path);

    const json =
        \\{
        \\  "id": "test-session",
        \\  "name": "old name",
        \\  "command": ["bash"],
        \\  "workingDir": "/tmp",
        \\  "status": "running",
        \\  "extraField": "keep-me",
        \\  "nestedObject": { "a": 1 }
        \\}
        ;

    try std.fs.cwd().makePath(std.fs.path.dirname(path).?);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .read = false, .mode = 0o644 });
    defer file.close();
    try file.writeAll(json);

    try updateSessionName(allocator, path, "new name");

    const updated = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(updated);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, updated, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("new name", obj.get("name").?.string);
    try std.testing.expectEqualStrings("keep-me", obj.get("extraField").?.string);
    try std.testing.expect(obj.get("nestedObject").? == .object);
}

test "updateSessionName adds name when missing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "session.json" });
    defer allocator.free(path);

    const json =
        \\{
        \\  "id": "test-session",
        \\  "command": ["bash"],
        \\  "workingDir": "/tmp",
        \\  "status": "running"
        \\}
        ;

    try std.fs.cwd().makePath(std.fs.path.dirname(path).?);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .read = false, .mode = 0o644 });
    defer file.close();
    try file.writeAll(json);

    try updateSessionName(allocator, path, "inserted name");

    const updated = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(updated);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, updated, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("inserted name", obj.get("name").?.string);
    try std.testing.expectEqualStrings("test-session", obj.get("id").?.string);
}

test "updateSessionName errors on non-object JSON" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "session.json" });
    defer allocator.free(path);

    try std.fs.cwd().makePath(std.fs.path.dirname(path).?);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .read = false, .mode = 0o644 });
    defer file.close();
    try file.writeAll("[]\n");

    try std.testing.expectError(error.InvalidSessionJson, updateSessionName(allocator, path, "new name"));
}
