{
  description = "async-matrix-bridge development environment";

  inputs.mine.url = "github:n-at-han-k/flake.nix";
  inputs.mine.inputs.nixpkgs.follows = "nixpkgs";
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { mine, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        # matrix-commander pulls in libolm, which nixpkgs marks insecure
        # (CVE-2024-45191/2/3, deprecated upstream). It is a dev-shell CLI for
        # poking at a homeserver by hand, not something this gem links against,
        # so allow it by name — a version-pinned permittedInsecurePackages
        # entry would break on the next olm bump. Done in the nixpkgs import
        # rather than via NIXPKGS_ALLOW_INSECURE so `nix develop` stays pure.
        pkgs = import nixpkgs {
          inherit system;
          config.allowInsecurePredicate = pkg: nixpkgs.lib.getName pkg == "olm";
        };

        # Our Gemfile says `gemspec`, and async-matrix-bridge.gemspec opens
        # lib/async/matrix/bridge/version.rb for the version. bundlerEnv
        # assembles a store directory holding ONLY the Gemfile and the lockfile
        # and points BUNDLE_GEMFILE at it, so `gemspec` finds no .gemspec there
        # and every wrapped binary (bundle, rubocop, scampi) dies in
        # Bundler.setup.
        #
        # extraConfigPaths is the escape hatch: those paths are copied in
        # alongside the Gemfile. Only version.rb is needed, not all of lib/ —
        # pulling lib/ in wholesale would rebuild the gem set on every source
        # edit.
        gemspecVersion = pkgs.runCommand "async-matrix-bridge-gemspec-version" { } ''
          mkdir -p $out/lib/async/matrix/bridge
          cp ${./lib/async/matrix/bridge/version.rb} $out/lib/async/matrix/bridge/version.rb
        '';

        # async-matrix carries a Rust (vodozemac) extension. bundix records the
        # generic "ruby" platform gem, which is the source gem, so bundlerEnv
        # runs its extconf and the build dies on `cargo: not found` — and even
        # with cargo added it would die fetching crates, since the gem ships no
        # vendored registry and the sandbox has no network.
        #
        # So point this one gem at the precompiled platform gem instead, which
        # already contains the built .so and skips extconf entirely.
        # buildRubyGem takes a `platform` argument and bundlerEnv passes any
        # attribute it does not recognise straight through to it.
        #
        # REFRESH ON EVERY async-matrix BUMP:
        #   nix-prefetch-url https://rubygems.org/gems/async-matrix-<version>-<platform>.gem
        asyncMatrixGems = {
          "x86_64-linux" = { platform = "x86_64-linux"; sha256 = "1mkh53si27a03q7h2fk4x2gknbp1lz8d2l5pc6b16c3h1wxz8fdr"; };
          "aarch64-linux" = { platform = "aarch64-linux"; sha256 = "11176kcy4diypz7p3fl5hhlj7kni2bqlihh7qmz4vdw07khr74py"; };
          "x86_64-darwin" = { platform = "x86_64-darwin"; sha256 = "05pxc85rrzri5vwp4cgz20lx7cab7flpykmv4ddi7gb1x3py5sk1"; };
          "aarch64-darwin" = { platform = "arm64-darwin"; sha256 = "1rz40bsswi1nw33asb3270icgll8kv34jzb6x4iw182shj54fdbb"; };
        };

        asyncMatrixGem = asyncMatrixGems.${system} or null;

        gemsetAttrs = import ./gemset.nix;

        gemset =
          if asyncMatrixGem == null then
            gemsetAttrs
          else
            gemsetAttrs // {
              async-matrix = gemsetAttrs.async-matrix // {
                platform = asyncMatrixGem.platform;
                source = gemsetAttrs.async-matrix.source // {
                  sha256 = asyncMatrixGem.sha256;
                };
              };
            };

        # mine.lib.buildGemset would be the one-liner here, but it has no way
        # to pass extraConfigPaths through to bundlerEnv.
        gems = pkgs.bundlerEnv {
          name = "async-matrix-bridge";
          ruby = pkgs.ruby_3_4;
          gemfile = ./Gemfile;
          lockfile = ./Gemfile.lock;
          inherit gemset;
          extraConfigPaths = [
            ./async-matrix-bridge.gemspec
            "${gemspecVersion}/lib"
          ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            gems
            gems.wrappedRuby

            # scampi discovers co-located `__END__` specs with ripgrep.
            pkgs.ripgrep
            pkgs.matrix-commander
          ];

          shellHook = /* bash */ ''
            export BUNDLE_GEMFILE="$PWD/Gemfile"
            export BUNDLE_FROZEN=false
          '';
        };
      }
    );
}
