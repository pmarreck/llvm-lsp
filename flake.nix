{
  description = "LSP server for LLVM IR (.ll files), written in Zig";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            zls
          ];
        };

        packages.default = pkgs.stdenv.mkDerivation {
          pname = "llvm-lsp";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.zig ];
          dontConfigure = true;
          dontInstall = true;
          buildPhase = ''
            mkdir -p .cache
            zig build -Doptimize=ReleaseFast --cache-dir $(pwd)/.cache --global-cache-dir $(pwd)/.cache -p $out
          '';
        };
      });
}
