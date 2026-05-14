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
            zig build -Doptimize=ReleaseFast --cache-dir $(pwd)/.cache --global-cache-dir $(pwd)/.cache -p $out
          '';
        };
      });
}
