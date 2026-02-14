const std = @import("std");

pub const SymbolKind = enum {
	function_decl,
	function_def,
	global,
	type_alias,
	local,
	param,
	label,
	metadata,
};

pub const Symbol = struct {
	kind: SymbolKind,
	name: []const u8,
	line: usize,
	scope_function: ?[]const u8,
};

pub const Reference = struct {
	name: []const u8,
	line: usize,
	scope_function: ?[]const u8,
};

pub const Index = struct {
	allocator: std.mem.Allocator,
	symbols: std.ArrayListUnmanaged(Symbol) = .{},
	references: std.ArrayListUnmanaged(Reference) = .{},

	pub fn init(allocator: std.mem.Allocator) Index {
		return .{ .allocator = allocator };
	}

	pub fn deinit(self: *Index) void {
		self.symbols.deinit(self.allocator);
		self.references.deinit(self.allocator);
	}

	pub fn countByKind(self: *const Index, kind: SymbolKind) usize {
		var count: usize = 0;
		for (self.symbols.items) |sym| {
			if (sym.kind == kind) count += 1;
		}
		return count;
	}

	pub fn addSymbol(self: *Index, kind: SymbolKind, name: []const u8, line: usize, scope_function: ?[]const u8) !void {
		try self.symbols.append(self.allocator, .{
			.kind = kind,
			.name = name,
			.line = line,
			.scope_function = scope_function,
		});
	}

	pub fn addReference(self: *Index, name: []const u8, line: usize, scope_function: ?[]const u8) !void {
		try self.references.append(self.allocator, .{
			.name = name,
			.line = line,
			.scope_function = scope_function,
		});
	}

	pub fn hasDefinition(self: *const Index, kind: SymbolKind, name: []const u8, scope_function: ?[]const u8, line: usize) bool {
		for (self.symbols.items) |sym| {
			if (sym.kind != kind) continue;
			if (!std.mem.eql(u8, sym.name, name)) continue;
			if (!scopeEqual(sym.scope_function, scope_function)) continue;
			if (sym.line != line) continue;
			return true;
		}
		return false;
	}

	pub fn countReferences(self: *const Index, name: []const u8, scope_function: ?[]const u8) usize {
		var count: usize = 0;
		for (self.references.items) |ref| {
			if (!std.mem.eql(u8, ref.name, name)) continue;
			if (!scopeEqual(ref.scope_function, scope_function)) continue;
			count += 1;
		}
		return count;
	}

	fn scopeEqual(a: ?[]const u8, b: ?[]const u8) bool {
		if (a == null and b == null) return true;
		if (a == null or b == null) return false;
		return std.mem.eql(u8, a.?, b.?);
	}
};
