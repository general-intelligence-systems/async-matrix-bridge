{
  description = "async-matrix-bridge development environment";

  inputs.mine.url = "github:n-at-han-k/flake.nix";
  inputs.mine.inputs.nixpkgs.follows = "nixpkgs";
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { mine, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

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

        # mine.lib.buildGemset would be the one-liner here, but it has no way
        # to pass extraConfigPaths through to bundlerEnv.
        gems = pkgs.bundlerEnv {
          name = "async-matrix-bridge";
          ruby = pkgs.ruby_3_4;
          gemfile = ./Gemfile;
          lockfile = ./Gemfile.lock;
          gemset = ./gemset.nix;
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
          ];

          shellHook = /* bash */ ''
            export BUNDLE_FORCE_RUBY_PLATFORM=true
            export BUNDLE_GEMFILE="$PWD/Gemfile"
            export BUNDLE_FROZEN=false
          '';
        };
      }
    );
}
