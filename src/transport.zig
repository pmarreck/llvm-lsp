const std = @import("std");

pub const max_message_bytes = 10 * 1024 * 1024;

pub fn parseNextFrame(input: []const u8, index: *usize) !?[]const u8 {
	while (index.* < input.len and (input[index.*] == '\n' or input[index.*] == '\r')) {
		index.* += 1;
	}

	if (index.* >= input.len) {
		return null;
	}

	const header_end = std.mem.indexOfPos(u8, input, index.*, "\r\n\r\n") orelse return error.IncompleteFrame;
	const header = input[index.*..header_end];

	var content_length: ?usize = null;
	var lines = std.mem.splitSequence(u8, header, "\r\n");
	while (lines.next()) |line| {
		if (!std.mem.startsWith(u8, line, "Content-Length:")) {
			continue;
		}
		const len_text = std.mem.trim(u8, line["Content-Length:".len..], " \t");
		content_length = try std.fmt.parseInt(usize, len_text, 10);
	}

	const body_len = content_length orelse return error.MissingContentLength;
	if (body_len > max_message_bytes) {
		return error.MessageTooLarge;
	}
	const body_start = header_end + 4;
	const body_end = body_start + body_len;
	if (body_end > input.len) {
		return error.IncompleteFrame;
	}

	index.* = body_end;
	return input[body_start..body_end];
}

pub fn writeFramed(stdout: *std.Io.Writer, body: []const u8) !void {
	try stdout.print("Content-Length: {d}\r\n\r\n", .{body.len});
	try stdout.writeAll(body);
	try stdout.flush();
}

pub fn writeJsonRpcResult(allocator: std.mem.Allocator, stdout: *std.Io.Writer, id: i64, result_json: []const u8) !void {
	const body = try std.fmt.allocPrint(
		allocator,
		"{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}",
		.{ id, result_json },
	);
	defer allocator.free(body);
	try writeFramed(stdout, body);
}

pub fn writeJsonRpcNotification(allocator: std.mem.Allocator, stdout: *std.Io.Writer, method: []const u8, params_json: []const u8) !void {
	const body = try std.fmt.allocPrint(
		allocator,
		"{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
		.{ method, params_json },
	);
	defer allocator.free(body);
	try writeFramed(stdout, body);
}

pub fn writeJsonRpcError(stdout: *std.Io.Writer, id: ?i64, code: i64, message: []const u8) !void {
	if (id) |value| {
		var buffer: [256]u8 = undefined;
		const body = try std.fmt.bufPrint(
			&buffer,
			"{{\"jsonrpc\":\"2.0\",\"id\":{d},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}",
			.{ value, code, message },
		);
		try writeFramed(stdout, body);
		return;
	}

	var buffer: [256]u8 = undefined;
	const body = try std.fmt.bufPrint(
		&buffer,
		"{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}",
		.{ code, message },
	);
	try writeFramed(stdout, body);
}
