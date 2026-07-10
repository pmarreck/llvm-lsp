# llvm-lsp

`llvm-lsp` is a language server for LLVM IR (`.ll`) files, written in Zig. It
provides navigation, symbols, completion, hover, rename, and diagnostics over
the Language Server Protocol.

## Build and test

```sh
./build
./test
```

`./build` produces `zig-out/bin/llvm-lsp`. `./test` runs the Zig unit tests and
every executable CLI test under `tests/cli/`.

The Nix flake exposes the same complete suite as `checks.<system>.test`; for the
Mechatron Prime Linux worker, run:

```sh
nix build .#checks.x86_64-linux.test
```

Linux CI binaries use the baseline CPU and static musl target so sandbox-built
executables remain runnable on the worker rather than inheriting host CPU
features or dynamic-library assumptions.
