const builtin = @import("builtin");
const std = @import("std");
const server = @import("server.zig");

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

	const exit_code = try server.run(allocator, stdout, stderr);

	try stdout.flush();
	try stderr.flush();

	if (exit_code != 0) {
		std.process.exit(exit_code);
	}
}
