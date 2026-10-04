{
  description = "trek terminal file explorer and Git browser";

  nixConfig = {
    extra-substituters = [ "https://termworks.cachix.org" ];
    extra-trusted-public-keys = [ "termworks.cachix.org-1:Ty7sSVALfD5ajbcWBIdaNHcaEx3fEmVrOo+rSzy0mvE=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?rev=4c1018dae018162ec878d42fec712642d214fdfa";
    flake-utils.url = "github:numtide/flake-utils";
    nixgl.url = "github:nix-community/nixGL";
  };

  outputs =
    { nixpkgs, flake-utils, nixgl, ... }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        overlays = [
          (final: prev: {
            xorg = prev.xorg // {
              libX11 = final.libx11;
              libxcb = final.libxcb;
              libxshmfence = final.libxshmfence;
            };
          })
        ];

        pkgs = import nixpkgs {
          inherit system overlays;
          config = {
            allowUnfree = true;
            nvidia.acceptLicense = true;
          };
        };

        nvidiaVersion = builtins.getEnv "NVIDIA_VERSION";
        hasNvidia = nvidiaVersion != "";

        nixglPkgs = import "${nixgl}/default.nix" ({
          inherit pkgs;
        } // pkgs.lib.optionalAttrs hasNvidia {
          inherit nvidiaVersion;
          nvidiaHash = null;
        });

        nixGLTarget =
          if hasNvidia
          then "${nixglPkgs.nixGLNvidia}/bin/nixGLNvidia-${nvidiaVersion}"
          else "${nixglPkgs.nixGLIntel}/bin/nixGLIntel";
        nixVulkanTarget =
          if hasNvidia
          then "${nixglPkgs.nixVulkanNvidia}/bin/nixVulkanNvidia-${nvidiaVersion}"
          else "${nixglPkgs.nixVulkanIntel}/bin/nixVulkanIntel";

        nixGLAlias = pkgs.runCommand "nixGL" { } ''
          mkdir -p $out/bin
          ln -s ${nixGLTarget} $out/bin/nixGL
        '';
        nixVulkanAlias = pkgs.runCommand "nixVulkan" { } ''
          mkdir -p $out/bin
          ln -s ${nixVulkanTarget} $out/bin/nixVulkan
        '';

        guiLibs = with pkgs; [
          alsa-lib
          udev
          vulkan-loader
          libxkbcommon
          wayland
          libx11
          libxcursor
          libxi
          libxrandr
        ];

        trek = pkgs.stdenv.mkDerivation (finalAttrs: {
          pname = "trek";
          version = builtins.head (builtins.match ".*VERSION :: \"([^\"]+)\".*" (builtins.readFile ./src/main.odin));
          src = pkgs.lib.cleanSource ./.;
          nativeBuildInputs = [ pkgs.odin pkgs.clang ];
          buildPhase = ''
            runHook preBuild
            export HOME=$TMPDIR
            mkdir -p target
            mkdir -p "$TMPDIR/odin-libs/nix/store"
            ln -s ${pkgs.odin} "$TMPDIR/odin-libs${pkgs.odin}"
            odin build src -out:target/trek -o:speed \
              -extra-linker-flags:"-static -L$TMPDIR/odin-libs -L${pkgs.glibc.static}/lib"
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -Dm755 target/trek $out/bin/trek
            mkdir -p $out/share/trek
            cp -r config share $out/share/trek/
            runHook postInstall
          '';
          doInstallCheck = true;
          installCheckPhase = ''
            runHook preInstallCheck
            test "$($out/bin/trek --version)" = '${finalAttrs.version}'
            $out/bin/trek --help
            if readelf -l $out/bin/trek | grep -q INTERP; then exit 1; fi
            if readelf -d $out/bin/trek | grep -q NEEDED; then exit 1; fi
            runHook postInstallCheck
          '';
          meta = {
            description = "Terminal file explorer and Git browser";
            homepage = "https://github.com/termworks/trek";
            license = pkgs.lib.licenses.mit;
            mainProgram = "trek";
            platforms = pkgs.lib.platforms.linux;
          };
        });
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.odin
            pkgs.git-cliff
            pkgs.clang
            pkgs.mold
            pkgs.pkg-config

            nixGLAlias
            nixVulkanAlias
            nixglPkgs.nixGLIntel
            nixglPkgs.nixVulkanIntel
          ] ++ pkgs.lib.optionals hasNvidia [
            nixglPkgs.nixGLNvidia
            nixglPkgs.nixVulkanNvidia
          ] ++ guiLibs;

          # A musl toolchain for the static build, handed over as a path rather than a package.
          # As a package its headers land on the default search path, and an ordinary build then
          # compiles against musl while linking against glibc -- which succeeds without a word and
          # crashes at startup. Only the static build is given it: .make.lua reads MUSL_CC.
          # gcc targeting musl, which is the only one of the two that has a C++ standard library.
          MUSL_CC = pkgs.pkgsMusl.stdenv.cc;
          # musl-clang: the host clang, pointed at musl's headers and libs. C only -- it has no
          # libstdc++, so a C++ build against it fails on the first #include <string>.
          MUSL_CLANG = pkgs.musl.dev;

          LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath guiLibs;
          WGPU_VALIDATION = "0";
          WGPU_DEBUG = "0";
        };
      } // (if builtins.elem system [ "x86_64-linux" "aarch64-linux" ] then {
        packages = { default = trek; inherit trek; };
        apps.default = { type = "app"; program = "${trek}/bin/trek"; };
        apps.trek = { type = "app"; program = "${trek}/bin/trek"; };
        checks.trek = trek;
      } else {})
    );
}
