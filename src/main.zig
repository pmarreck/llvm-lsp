const builtin = @import("builtin");
const std = @import("std");

const Request = struct {
	jsonrpc: ?[]const u8 = null,
	id: ?i64 = null,
	method: ?[]const u8 = null,
};

const max_message_bytes = 10 * 1024 * 1024;
const max_input_bytes = max_message_bytes + (64 * 1024);

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();
	const allocator = gpa.allocator();

	var stdout_buffer: [4096]u8 = undefined;
	var stdout_file_writer = std.fs.File.stdout().writer(&stdout_buffer);
	const stdout = &stdout_file_writer.interface;

	var stderr_buffer: [4096]u8 = undefined;
	var stderr_file_writer = std.fs.File.stderr().writer(&stderr_buffer);
	const stderr = &stderr_file_writer.interface;

	if (comptime builtin.mode == .Debug) {
		try stderr.writeAll("\x1b[33mDEBUG BUILD\x1b[0m\n");
	}

	const exit_code = try run(allocator, stdout, stderr);

	try stdout.flush();
	try stderr.flush();

	if (exit_code != 0) {
		std.process.exit(exit_code);
	}
}

fn run(allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
	_ = stderr;

	const input = try std.fs.File.stdin().readToEndAlloc(allocator, max_input_bytes);
	defer allocator.free(input);

	if (input.len == 0) {
		return 0;
	}

	var saw_shutdown = false;
	var index: usize = 0;
	while (true) {
		const body_opt = parseNextFrame(input, &index) catch |err| {
			const message = switch (err) {
				error.InvalidCharacter, error.Overflow, error.MissingContentLength, error.InvalidFrame, error.TruncatedBody, error.MessageTooLarge => "invalid request framing",
			};
			try writeJsonRpcError(stdout, null, -32600, message);
			return 1;
		};
		if (body_opt == null) {
			break;
		}

		const body = body_opt.?;
		var parsed = std.json.parseFromSlice(Request, allocator, body, .{ .ignore_unknown_fields = true }) catch {
			try writeJsonRpcError(stdout, null, -32700, "parse error");
			continue;
		};
		defer parsed.deinit();

		const method = parsed.value.method orelse continue;
		if (std.mem.eql(u8, method, "initialize")) {
			const id = parsed.value.id orelse continue;
			const response = try std.fmt.allocPrint(
				allocator,
				"{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"capabilities\":{{}}}}}}",
				.{id},
			);
			defer allocator.free(response);
			try writeFramed(stdout, response);
			continue;
		}

		if (std.mem.eql(u8, method, "shutdown")) {
			saw_shutdown = true;
			const id = parsed.value.id orelse continue;
			const response = try std.fmt.allocPrint(
				allocator,
				"{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":null}}",
				.{id},
			);
			defer allocator.free(response);
			try writeFramed(stdout, response);
			continue;
		}

		if (std.mem.eql(u8, method, "exit")) {
			return if (saw_shutdown) 0 else 1;
		}
	}

	return 0;
}

fn parseNextFrame(input: []const u8, index: *usize) !?[]const u8 {
	while (index.* < input.len and (input[index.*] == '\n' or input[index.*] == '\r')) {
		index.* += 1;
	}

	if (index.* >= input.len) {
		return null;
	}

	const header_end = std.mem.indexOfPos(u8, input, index.*, "\r\n\r\n") orelse return error.InvalidFrame;
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
		return error.TruncatedBody;
	}

	index.* = body_end;
	return input[body_start..body_end];
}

fn writeFramed(stdout: *std.Io.Writer, body: []const u8) !void {
	try stdout.print("Content-Length: {d}\r\n\r\n", .{body.len});
	try stdout.writeAll(body);
}

fn writeJsonRpcError(stdout: *std.Io.Writer, id: ?i64, code: i64, message: []const u8) !void {
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
