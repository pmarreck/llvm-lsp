# CODE_MINIMAP

## Repository Root

`SPEC.md`
- Product and engineering specification for `llvm-lsp`.
- Defines scope, done criteria, functional requirements, architecture, NFRs, test strategy, milestones, and acceptance gates.

`PLAN.md`
- Active work checklist and progress log with EST completion timestamps.
- Includes short curiosity probes for unresolved design decisions.

`build`
- Top-level build script wrapper.
- Invokes `zig build` through `nix develop`, defaults to `ReleaseFast`, supports `--debug` and `--test`.

`test`
- Top-level test runner script with aggregate exit behavior.
- Runs `./build --test` plus executable CLI tests under `tests/cli/`.

`build.zig`
- Zig build graph for `llvm-lsp`.
- Defines executable target and `zig build test` step, with default optimize mode `ReleaseFast`.
- Unit test step now runs `src/tests.zig` so parser/core tests are part of `./test`.

`src/main.zig`
- M0 server implementation.
- Handles stdin/stdout LSP framing, `initialize`, `shutdown`, `exit`, EOF behavior, and debug build banner emission.
- Emits framed JSON-RPC errors for malformed JSON (`-32700`) and invalid request framing (`-32600`), including oversized content-length rejection.

`src/tests.zig`
- Unit test entrypoint imported by `zig build test`.
- Pulls in `src/core/parser.zig` and `src/core/symbols.zig` tests.

`src/core/symbols.zig`
- Core symbol/reference index types.
- Defines `SymbolKind`, `Symbol`, `Reference`, and `Index` with query helpers (`countByKind`, `hasDefinition`, `countReferences`).

`src/core/parser.zig`
- Minimal LLVM IR text parser spike for top-level/module/function-local symbol extraction.
- Parses type aliases, globals, metadata defs, function decl/defs, params, labels, local defs, and operand references with per-function scoping.
- Collects top-level RHS references for global/type/metadata assignment lines.
- Collects top-level parameter-signature references from both `declare` and `define` lines.
- Supports quoted `%/@/!` identifiers including escaped quotes within quoted names.
- Contains unit tests validating extraction, `%0` scope isolation across functions, RHS local reference counting, top-level/metadata reference extraction, escaped quoted identifier handling, and signature-level type alias references.

`tests/cli/m0_lifecycle`
- CLI integration test covering M0 lifecycle behavior.
- Asserts release/debug EOF behavior, initialize response framing/content, shutdown->exit code `0`, and exit-without-shutdown code `1`.

`tests/cli/m0_transport_hardening`
- CLI integration test for malformed/partial/oversized request handling.
- Asserts parse-error and invalid-request error codes, no-hang behavior on partial headers, and non-zero exits for framing failures.

`flake.nix`
- Nix flake defining project development shell and default package build.
- Exposes Zig/ZLS toolchain and `zig build -Doptimize=ReleaseFast` package build behavior.

`flake.lock`
- Nix input lockfile for reproducible dependency resolution.

`AGENTS.md` (symlink)
- Workspace collaboration and engineering process rules.

`ZIG_RECENT_API_CHANGES_2025.md` (symlink)
- Zig API migration notes relevant to 0.14/0.15 behavior changes.

`jj_cheatsheet.md` (symlink)
- Quick-reference guide for `jj` workflow commands.
