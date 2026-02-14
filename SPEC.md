# llvm-lsp: Language Server for LLVM IR

An LSP server for LLVM IR `.ll` text files, written in Zig. Single static binary, no LLVM dependency.

## Why This Exists

LLVM IR is the lingua franca of modern compilers, but navigating `.ll` files is miserable:
- `%42` is used 300 lines below its definition — good luck finding it
- `@__ZN3foo3barEv` is a mangled C++ name — hover should tell you what it means
- A function has 47 basic blocks — which ones branch to `%cleanup`?
- You're debugging a miscompile and need to trace a value through 12 SSA definitions

Every other serious language has an LSP. LLVM IR doesn't. We're fixing that.

## Architecture

```
LSP clients (editors, codescan) ──► stdin/stdout JSON-RPC ──► Zig LSP server
                                                                    │
                                                              ┌─────┴─────┐
                                                              │  Zig core │
                                                              │ (no I/O)  │
                                                              └───────────┘
                                                              • Lexer
                                                              • Parser
                                                              • Symbol table
                                                              • Query engine
```

**Zig core** is a pure library: parse `.ll` text, build symbol tables, answer queries. No I/O, no allocations it doesn't own. This is the unit-testable heart.

**LSP server** is a thin wrapper: reads JSON-RPC from stdin, dispatches to core, writes responses to stdout. Stateful (open documents, incremental updates).

**C FFI** (later, optional): expose the core for embedding in other tools. Not needed for the LSP server itself, but follows the standard architecture pattern.

## Scope

### In scope (`.ll` text files)
- Go-to-definition
- Find all references
- Hover (types, metadata, demangled names)
- Diagnostics (undefined variables, type mismatches, malformed syntax)
- Completion (instructions, types, in-scope variables)
- Document symbols (functions, globals, types)
- Signature help (instruction operand types)

### Out of scope (for now)
- `.bc` bitcode (binary format, would need LLVM linkage or `llvm-dis` shelling)
- Cross-module analysis (each `.ll` file is self-contained)
- Semantic transforms / refactoring (rename is the exception — SSA names are mechanical)
- Debug info reconstruction (just show raw metadata, don't interpret DWARF)

### Stretch goals
- Basic block control flow graph (custom LSP extension or code lens)
- C++ name demangling (Itanium ABI, no external dependency)
- Auto-convert `.bc` → `.ll` via `llvm-dis` if available on PATH
- Rename (`%old` → `%new` within a function — trivial for SSA)

## LLVM IR Grammar Overview

Reference: https://llvm.org/docs/LangRef.html

### Top-level entities
```llvm
; Comments
source_filename = "test.c"
target datalayout = "e-m:e-p270:32:32-..."
target triple = "x86_64-unknown-linux-gnu"

%struct.Foo = type { i32, ptr }           ; Named struct type

@global_var = global i32 42               ; Global variable
@.str = private constant [6 x i8] c"hello\00"  ; String constant

declare i32 @printf(ptr, ...)             ; External declaration

define i32 @main(i32 %argc, ptr %argv) {  ; Function definition
entry:                                     ; Basic block label
  %0 = alloca i32                         ; Local variable (numbered)
  %retval = alloca i32                    ; Local variable (named)
  store i32 0, ptr %retval
  ret i32 0
}

!0 = !{!"metadata"}                       ; Metadata node
```

### Symbol kinds
| Prefix | Scope | Examples |
|--------|-------|---------|
| `@` | Global (module-wide) | `@main`, `@global_var`, `@.str` |
| `%` | Local (function-scoped) | `%0`, `%retval`, `%struct.Foo` |
| `!` | Metadata | `!0`, `!dbg`, `!DILocation(...)` |
| (none) | Basic block labels | `entry:`, `if.then:`, `cleanup:` |

### Key parsing characteristics
- Line-oriented (no multi-line strings except metadata)
- `;` starts a comment to end of line
- Strongly typed: every value has an explicit type
- SSA form: each `%name` is defined exactly once (within a function)
- Basic blocks are sequences of instructions terminated by a terminator (ret, br, switch, etc.)

## Nix Flake

```nix
# Provides: zig, zls, and test dependencies
# User has zig/zls globally but flake ensures reproducibility
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system}; in {
        devShells.default = pkgs.mkShell {
          buildInputs = [ pkgs.zig pkgs.zls ];
        };
        packages.default = pkgs.stdenv.mkDerivation {
          name = "llvm-lsp";
          src = ./.;
          nativeBuildInputs = [ pkgs.zig ];
          buildPhase = "zig build -Doptimize=ReleaseFast";
          installPhase = "mkdir -p $out/bin && cp zig-out/bin/llvm-lsp $out/bin/";
        };
      });
}
```

## Implementation Phases

Each phase is a TDD cycle: write failing tests first, then implement until green, then refactor.
Each phase produces a working (if limited) binary that doesn't hang your computer.

Resource safety rules that apply to ALL phases:
- **Bounded memory**: arena allocator per document, freed on close. No unbounded growth.
- **Bounded time**: parsing timeout of 5 seconds per file. Files >10MB are rejected.
- **No threads initially**: single-threaded event loop. Add threading only if profiling demands it.
- **Graceful shutdown**: handle `shutdown`/`exit` LSP lifecycle properly.

---

### Phase 0: Project Scaffolding
**Goal:** Empty project that builds, tests, and runs.

- `build.zig` with lib + exe + test targets
- `flake.nix` for Nix users
- `src/main.zig` — LSP entry point (just reads stdin, writes `{"error": "not implemented"}`)
- `src/core/` — library root (empty module)
- Verify: `zig build`, `zig build test`, `echo '...' | zig-out/bin/llvm-lsp` doesn't hang

**Tests:** Build compiles, binary starts and exits cleanly on EOF.

---

### Phase 1: Lexer
**Goal:** Tokenize `.ll` text into a stream of typed tokens.

Tokens:
- `Comment` (`;` to EOL)
- `GlobalIdent` (`@name`, `@"quoted name"`, `@42`)
- `LocalIdent` (`%name`, `%"quoted name"`, `%42`)
- `MetadataId` (`!0`, `!name`)
- `Label` (`name:` at start of line in function context)
- `StringLiteral` (`"..."`, `c"..."`)
- `IntegerLiteral` (`42`, `-1`, `0x1F`)
- `FloatLiteral` (`1.0`, `0x3FF0000000000000`)
- `Keyword` (`define`, `declare`, `global`, `ret`, `br`, `i32`, `ptr`, `void`, etc.)
- `Punctuation` (`=`, `,`, `(`, `)`, `{`, `}`, `[`, `]`, `*`, `...`)
- `Newline`, `Whitespace`
- `Unknown` (error recovery)

The lexer is:
- Allocation-free (returns slices into source text)
- Lazy (iterator pattern, not full array)
- Fuzz-safe (never panics on any input, always produces tokens)

**Tests (write these FIRST):**
1. Empty input → no tokens
2. Comment → single Comment token
3. `@main` → GlobalIdent
4. `%0` → LocalIdent with numeric name
5. `%struct.Foo` → LocalIdent
6. `define i32 @main(i32 %argc)` → sequence of Keyword, Keyword, GlobalIdent, Punctuation, Keyword, LocalIdent, Punctuation
7. String literals with escapes
8. Integer and float literals
9. Garbage input → Unknown tokens (no panic)
10. 1MB of repeated valid tokens → completes in <100ms

---

### Phase 2: Parser + Symbol Table
**Goal:** Parse top-level structure and build a symbol table.

Parse into a lightweight AST:
```
Module
  ├── SourceFilename
  ├── TargetDatalayout
  ├── TargetTriple
  ├── TypeDef        (%struct.Foo = type { ... })
  ├── GlobalDecl     (@var = global/constant ...)
  ├── FunctionDecl   (declare ...)
  ├── FunctionDef    (define ...)
  │   ├── Param      (%name with type)
  │   └── BasicBlock
  │       ├── Label
  │       └── Instruction[]
  │           ├── ResultName (%name =)
  │           ├── Opcode
  │           └── Operands (typed values)
  └── MetadataNode   (!0 = !{...})
```

Symbol table:
- Global symbols: `@name` → {kind, type, location, definition_range}
- Per-function local symbols: `%name` → {type, location, definition_range}
- Type aliases: `%name` → {underlying_type, location}
- Metadata nodes: `!N` → {value, location}
- Basic block labels: `name` → {location, parent_function}

The parser is:
- Error-recovering (skips to next top-level entity on parse error)
- Records source locations (line:col) for every symbol definition and use
- Uses an arena allocator (one arena per parse, freed together)

**Tests (write these FIRST):**
1. Empty module → empty symbol table
2. Single global `@x = global i32 0` → one global symbol with correct type and location
3. Single function with params → function symbol + param symbols
4. Function with basic blocks and locals → BB labels + local symbols
5. Type definition → type alias symbol
6. Metadata node → metadata symbol
7. Multiple definitions → all symbols present, correct locations
8. Parse error recovery: malformed line doesn't prevent parsing rest of file
9. Duplicate symbol detection (error diagnostic)
10. 10,000-line file → parses in <500ms, memory <50MB

---

### Phase 3: LSP Transport Layer
**Goal:** Handle JSON-RPC 2.0 over stdin/stdout with Content-Length framing.

Implement:
- `readMessage()` — read Content-Length header + body from stdin
- `writeMessage()` — write Content-Length header + body to stdout
- `parseJsonRpc()` — extract method, id, params from JSON body
- `formatResponse()` — build JSON-RPC response/notification
- Handle `initialize` → respond with server capabilities
- Handle `initialized` → no-op notification
- Handle `shutdown` → acknowledge
- Handle `exit` → clean exit (code 0 if shutdown received, 1 otherwise)

The transport is:
- Non-blocking reads with timeout (don't hang if client disappears)
- Bounded message size (reject messages >10MB)
- Logs to stderr (never to stdout — that's the LSP channel)

**Tests (write these FIRST):**
1. `readMessage` parses valid Content-Length framing
2. `readMessage` handles split reads (partial header)
3. `writeMessage` produces valid Content-Length framing
4. Round-trip: write then read produces identical content
5. `initialize` request → response with correct capabilities
6. `shutdown` then `exit` → clean exit code 0
7. `exit` without `shutdown` → exit code 1
8. Oversized message → error response
9. Malformed JSON → error response with parse error code (-32700)
10. Unknown method → method not found error (-32601)

**Integration test:** pipe a recorded LSP session through the binary, verify responses.

---

### Phase 4: Document Sync + Document Symbols
**Goal:** Track open documents, respond to `textDocument/documentSymbol`.

Implement:
- `textDocument/didOpen` — parse document, store in document map
- `textDocument/didChange` — re-parse on change (full sync initially; incremental later)
- `textDocument/didClose` — free document from map
- `textDocument/documentSymbol` — return function/global/type symbols with ranges

Document map:
- Key: URI string
- Value: {source text, parsed module, symbol table, diagnostics}
- Arena-allocated per document (freed on close or re-parse)

**Tests (write these FIRST):**
1. didOpen → document appears in map
2. didClose → document removed, memory freed
3. didChange → document re-parsed with new content
4. documentSymbol for empty file → empty list
5. documentSymbol for file with functions → SymbolKind.Function entries with correct ranges
6. documentSymbol for file with globals → SymbolKind.Variable entries
7. documentSymbol for file with types → SymbolKind.Struct entries
8. Open same URI twice → replaces (no leak)
9. Change document 100 times rapidly → no crash, no leak, last state correct

---

### Phase 5: Go-to-Definition
**Goal:** `textDocument/definition` — click a symbol use, jump to its definition.

Implement:
- Given a position, identify the symbol token at that position
- Look up the symbol in the symbol table:
  - `%local` → definition within the current function
  - `@global` → definition at module level
  - `%struct.Name` → type definition
  - `!N` → metadata node definition
  - `label` (in `br` instruction) → basic block label in current function
- Return the definition location

**Tests (write these FIRST):**
1. Cursor on `%0` in `store i32 1, ptr %0` → jumps to `%0 = alloca i32`
2. Cursor on `@func` in `call void @func()` → jumps to `define void @func`
3. Cursor on `@extern` in `call void @extern()` → jumps to `declare void @extern`
4. Cursor on `%struct.Foo` in type position → jumps to `%struct.Foo = type { ... }`
5. Cursor on `!dbg !5` → jumps to `!5 = ...`
6. Cursor on `label` in `br label %loop` → jumps to `loop:` label
7. Cursor on definition itself → returns same location (identity)
8. Cursor on unknown symbol → null response (no crash)
9. Cursor on keyword/literal → null response
10. Works across 10,000-line file in <50ms

---

### Phase 6: Find References
**Goal:** `textDocument/references` — find all uses of a symbol.

Implement:
- Given a position, identify the symbol
- Scan all recorded uses of that symbol in the symbol table
- Return list of locations (optionally including the definition)

Requires the parser to record **use sites** in addition to definition sites. Each instruction's operands should record the source location of every symbol reference.

**Tests (write these FIRST):**
1. `%x` defined once, used 3 times → 3 references (or 4 with definition)
2. `@func` declared, defined, called twice → 3 or 4 references
3. Basic block label used in multiple `br` instructions → all found
4. `%struct.Foo` used in multiple type positions → all found
5. Symbol with zero uses → only definition (if includeDeclaration)
6. Numbered local (`%0`) → all references within function
7. Same name in different functions → only references in same function scope
8. Same-named global and local → correctly distinguished by prefix

---

### Phase 7: Hover
**Goal:** `textDocument/hover` — show type info and context on hover.

Implement:
- Local variable → show its type and the instruction that defines it
- Global variable → show its type, linkage, initializer summary
- Function → show full signature (return type, params with types)
- Type alias → show the underlying type definition
- Instruction keyword → show brief description from LLVM LangRef
- Basic block label → show predecessor/successor blocks
- Metadata → show the metadata value

Format as Markdown for rich display in editors.

**Tests (write these FIRST):**
1. Hover on `%x` where `%x = add i32 %a, %b` → shows "i32 (from add)"
2. Hover on `@main` → shows `define i32 @main(i32 %argc, ptr %argv)`
3. Hover on `ptr` keyword → shows type description
4. Hover on `ret` → shows "Return from function"
5. Hover on basic block label → shows predecessors/successors
6. Hover on metadata node → shows metadata content
7. Hover on nothing → null

---

### Phase 8: Diagnostics
**Goal:** `textDocument/publishDiagnostics` — report errors on parse/type issues.

Implement (publish after each didOpen/didChange):
- **Parse errors**: malformed syntax, unexpected tokens
- **Undefined symbols**: use of `%x` before definition in a function
- **Type mismatches**: `add i32 %x, %y` where `%y` is `ptr` not `i32`
- **Unreachable basic blocks**: no predecessor and not the entry block
- **Missing terminator**: basic block without ret/br/switch/etc.

Severity levels:
- Error: parse errors, undefined symbols
- Warning: type mismatches (could be parser limitation)
- Information: unreachable blocks

**Tests (write these FIRST):**
1. Valid file → zero diagnostics
2. Syntax error → error diagnostic with correct line/col
3. Undefined local → error diagnostic pointing at use site
4. Type mismatch in add → warning diagnostic
5. Missing terminator → error diagnostic on last instruction of block
6. Multiple errors → all reported (don't stop at first)
7. Error recovery: diagnostics for line 5 don't prevent diagnostics for line 50

---

### Phase 9: Completion
**Goal:** `textDocument/completion` — suggest completions as user types.

Implement:
- After `%` → suggest in-scope local variables and type aliases
- After `@` → suggest global variables and functions
- After `!` → suggest metadata node IDs
- After instruction result (`%x = `) → suggest instruction opcodes
- After opcode → suggest type keywords (`i32`, `i64`, `ptr`, `void`, etc.)
- After `br label %` → suggest basic block labels in current function

**Tests (write these FIRST):**
1. `%` in function body → lists local variables
2. `@` anywhere → lists globals and functions
3. `%x = ` → lists instruction opcodes (add, sub, alloca, load, store, ...)
4. After `add ` → suggests type keywords
5. `br label %` → suggests basic block labels
6. Completion in empty file → minimal suggestions (define, declare, @, %)
7. Completion is fast (<100ms on 10,000-line file)

---

### Phase 10: Codescan Integration
**Goal:** Verify llvm-lsp works with codescan's LSP client.

Add to codescan's `lsp.zig`:
```
.extensions = &.{ ".ll" },
.binary = "llvm-lsp",
.args = &empty_args,
.install_hint = "nix build github:pmarreck/llvm-lsp",
.install_url = "https://github.com/pmarreck/llvm-lsp",
```

**Integration tests (manual initially):**
1. `codescan references "main" --file test.ll` → finds all references to `@main`
2. `codescan rename "old_name" --file test.ll --to "new_name" --dry-run` → shows edits
3. `codescan find-symbol "main" --file test.ll` → finds `@main` with line range

---

## Test Data

Create `test/` directory with:
- `empty.ll` — empty module
- `minimal.ll` — source_filename + target triple only
- `hello.ll` — simple main() that calls printf
- `types.ll` — various type definitions
- `large.ll` — auto-generated 10,000+ line file for performance tests
- `malformed.ll` — intentionally broken syntax for error recovery tests
- `ssa.ll` — complex SSA with many locals for reference testing

Generate `large.ll` in the test setup, not checked in.

## Performance Targets

| Operation | Target | Max file size |
|-----------|--------|--------------|
| Full parse | <500ms | 10,000 lines |
| Go-to-definition | <50ms | any |
| Find references | <100ms | any |
| Completion | <100ms | any |
| Memory per document | <50MB | 10,000 lines |
| Startup to ready | <100ms | - |

## File Structure

```
llvm-lsp/
  SPEC.md              ← this file
  LICENSE
  build.zig
  build.zig.zon
  flake.nix
  flake.lock
  src/
    main.zig           ← LSP server entry point (stdin/stdout JSON-RPC)
    transport.zig      ← JSON-RPC framing (read/write Content-Length messages)
    server.zig         ← LSP method dispatch + document state
    core/
      lexer.zig        ← Tokenizer (allocation-free, iterator)
      parser.zig       ← Parse .ll into AST + symbol table
      symbols.zig      ← Symbol table data structures + queries
      types.zig        ← LLVM IR type representation
      ast.zig          ← AST node types
      diagnostics.zig  ← Error/warning collection
  test/
    empty.ll
    minimal.ll
    hello.ll
    types.ll
    malformed.ll
    ssa.ll
```

## Naming Conventions

Per project standards:
- **Binary name**: `llvm-lsp` (hyphenated CLI tool)
- **Source files/modules**: `snake_case` (underscores)
- **Functions**: `camelCase` (Zig convention)
- **Types**: `PascalCase` (Zig convention)

## Dependencies

**Zero runtime dependencies.** The binary is fully self-contained.

Build-time only:
- Zig 0.15+ (via flake or global install)
- No LLVM linkage, no C libraries, no network access

## Git

- Main branch: `yolo`
- Commit messages: imperative, concise, no AI attribution (pre-commit hook rejects it)
