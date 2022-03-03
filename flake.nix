{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-21.11";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = inputs:
    with inputs;
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        checks = {
          format = pkgs.runCommand "format-check" { } ''
            ${pkgs.nixfmt}/bin/nixfmt --check ${./.}/**.nix
          '';
        };
      });
}
