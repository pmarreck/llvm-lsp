{
  description = "LSP server for LLVM IR (.ll files), written in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zigPkg = zig-overlay.packages.${system}."0.16.0";
        linuxTarget = {
          x86_64-linux = "x86_64-linux-musl";
          aarch64-linux = "aarch64-linux-musl";
        }.${system} or null;
        zigTargetFlag = pkgs.lib.optionalString (linuxTarget != null) "-Dtarget=${linuxTarget}";
        failureInjection = builtins.getEnv "LLVM_LSP_CI_FAILURE_INJECTION" == "1";
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zigPkg
            zls
            coreutils  # GNU timeout, etc. — ensures cross-platform CLI test compat
          ];
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "llvm-lsp";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ zigPkg ];
          dontConfigure = true;
          dontInstall = true;
          buildPhase = ''
            mkdir -p .cache
            zig build -Doptimize=ReleaseFast -Dcpu=baseline ${zigTargetFlag} --cache-dir $(pwd)/.cache --global-cache-dir $(pwd)/.cache -p $out
          '';
        };

        checks.test = pkgs.stdenv.mkDerivation {
          pname = "llvm-lsp-test";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ zigPkg pkgs.bash pkgs.coreutils pkgs.findutils pkgs.gnugrep ];
          dontConfigure = true;
          LLVM_LSP_IN_NIX_CHECK = "1";
          LLVM_LSP_CI_FAILURE_INJECTION = if failureInjection then "1" else "0";
          LLVM_LSP_ZIG_CPU = "baseline";
          LLVM_LSP_ZIG_TARGET = if linuxTarget == null then "" else linuxTarget;
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global-cache
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
            patchShebangs .
            ./test
          '';
          installPhase = ''
            mkdir -p $out
            printf 'complete test suite passed\n' > $out/result
          '';
        };
      });
}
