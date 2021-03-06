{ system, tree-sitter, nodejs, emscripten, httplz, nixUnstable, gnutar, stdenv
, lib, fetchurl, linkFarm, callPackage, writeTextFile, writeShellScript
, runCommand, fetchFromGitHub, nix-prefetch-github, jq }: rec {
  maintainers = import ./maintainers.nix;

  abiVersion = "13";

  # TODO:
  # - cd into subpath
  # - npm dependencies / submodules
  grammar = grammar: language: owner: lock:
    { format, ... }:
    let
      lockKey = grammar.follows or "${owner}/${language}";
      lockEntry = builtins.getAttr lockKey lock;
      defaultSrc = assert lockEntry.type == "github";
        fetchFromGitHub {
          inherit (lockEntry) owner repo;
          rev = lockEntry.revision;
          sha256 = lockEntry.integrity;
        };
      src = grammar.src or defaultSrc;
    in stdenv.mkDerivation rec {
      inherit system format tree-sitter language src;
      pname = "grammar-${language}-${owner}-${format}";
      version = lockEntry.revision;
      subpath = grammar.subpath or ".";
      copyPaths = grammar.copyPaths or [ ];
      preGenerate = grammar.preGenerate or "true";
      doCheck = grammar.doCheck or true;
      abi = abiVersion;

      languageConfigJson = ./language-config.json;
      buildInputs = [ tree-sitter nodejs emscripten gnutar ];
      builder = ./build-grammar.sh;
    };

  buildAllGrammars = grammars: opts:
    if opts.metadata or false then
      linkFarmWithMetadata "artifacts" grammars opts
    else
      linkFarm "all-grammars" (grammarLinks grammars opts);

  formatGrammars = grammars:
    let lock = builtins.fromJSON (builtins.readFile ../grammar-lock.json);
    in lib.lists.flatten (builtins.map (language:
      builtins.map (owner: {
        inherit language owner;
        builder = grammars.${language}.${owner} language owner lock;
      }) (builtins.attrNames grammars.${language}))
      (builtins.attrNames grammars));

  grammarLinks = grammars: opts:
    builtins.map (grammar: {
      name = "${grammar.language}/${grammar.owner}";
      path = grammar.builder opts;
    }) grammars;

  treeSitterJs = fetchurl {
    url =
      "https://github.com/tree-sitter/tree-sitter/releases/download/v${tree-sitter.version}/tree-sitter.js";
    sha256 = "sha256-M2eDcW3OdYSq9H0ldF8YwL4IAAQzmy+Fif2y0P32mV8=";
  };

  treeSitterWasm = fetchurl {
    url =
      "https://github.com/tree-sitter/tree-sitter/releases/download/v${tree-sitter.version}/tree-sitter.wasm";
    sha256 = "sha256-QBVbxeMq3KdHwApTeYZszBP2Q7de8lL7eT8AviFbcbk=";
  };

  copyFarm = name: entries:
    let
      copyEntry = { name, path }: ''
        mkdir -p "$(dirname ${name})"
        cp -r ${path} ${name}
      '';
      copies = builtins.map copyEntry entries;
    in runCommand name {
      preferLocalBuild = true;
      allowSubstitutes = false;
    } ''
      mkdir -p $out
      cd $out
      ${builtins.concatStringsSep "" copies}
    '';

  linkFarmWithMetadata = name: grammars: opts:
    let
      grammarEntry = grammar:
        let artifact = grammar.builder opts;
        in ''
          hash="$(${nixUnstable}/bin/nix --option experimental-features nix-command hash file --type sha256 --base16 ${artifact} | tr --delete '\n')"
          path="${grammar.language}/${grammar.owner}/${artifact.version}-${tree-sitter.version}-${abiVersion}-$hash-${opts.format}"
          mkdir -p "$(dirname "$path")"
          ln -s ${artifact} "$path"
        '';
      links = builtins.map grammarEntry grammars;
    in runCommand name {
      preferLocalBuild = true;
      allowSubstitutes = false;
    } ''
      mkdir -p $out
      cd $out
      ${builtins.concatStringsSep "" links}
    '';

  buildPlayground = grammars:
    let
      playgroundHtml = writeTextFile {
        name = "tree-sitter-playground-html";
        text = callPackage ./assets/index.html.nix { inherit grammars; };
      };
      wasmGrammars = builtins.filter (g: !(g.skipPlayground or false)) grammars;
      entries = [
        {
          name = "run.sh";
          path = writeShellScript "tree-sitter-playground-run" ''
            ${httplz}/bin/httplz "$(dirname $0)"
          '';
        }
        {
          name = "tree-sitter.js";
          path = treeSitterJs;
        }
        {
          name = "tree-sitter.wasm";
          path = treeSitterWasm;
        }
        {
          name = "playground.js";
          path = ./assets/playground.js;
        }
        {
          name = "index.html";
          path = playgroundHtml;
        }
      ] ++ (grammarLinks wasmGrammars { format = "wasm"; });
    in copyFarm "tree-sitter-playground" entries;

  lockScript = writeShellScript "lock-script" ''
    set -e
    ${nix-prefetch-github}/bin/nix-prefetch-github --json --no-prefetch --no-fetch-submodules "$1" "tree-sitter-$2" > .tmp-lock.json 2>/dev/null
    mv grammar-lock.json grammar-lock.json.bak
    ${jq}/bin/jq \
      --slurpfile lock .tmp-lock.json \
      --arg key "$1/$2" \
      '.[$key] = {type: "github", owner: $lock[0].owner, repo: $lock[0].repo, revision: $lock[0].rev, integrity: $lock[0].sha256}' \
      grammar-lock.json.bak > grammar-lock.json
  '';
}
