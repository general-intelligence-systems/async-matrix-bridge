#!/usr/bin/env bash
#
# run_test.sh — build every example against the LOCAL async-matrix-bridge
# working tree and smoke-test its Matrix Application Service wire protocol,
# inside a Nix dev shell. No live homeserver is required: each example's
# config.ru is loaded as a Rack app in-process and probed directly.
#
# For each example it:
#   1. writes a temporary Gemfile that overrides `async-matrix-bridge` to this
#      repo (so we test the working tree, not the published gem),
#   2. `bundle install`s it inside a Nix dev shell,
#   3. loads config.ru via Rack::Builder and asserts:
#        POST /_matrix/app/v1/ping            -> 200  (healthcheck, no auth)
#        PUT  /_matrix/app/v1/transactions/t  -> 403  (rejected without token)
#
# Notes:
#   * We use the repo-root flake for every example, so every example bundles
#     against one Ruby.
#   * A single shared bundle path is used so gems are installed once and reused
#     across examples. async-matrix (a dependency) ships a native Rust
#     (vodozemac) extension, so it must resolve from RubyGems, where a
#     precompiled platform gem is served. Forcing the source gem (e.g.
#     BUNDLE_FORCE_RUBY_PLATFORM) makes bundler compile vodozemac and needs a
#     Rust toolchain in the shell.
#   * Set EXAMPLES="echo_bot brute" to run a subset.
#
# Usage:
#   examples/run_test.sh
#   EXAMPLES="echo_bot" examples/run_test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FLAKE="$REPO_ROOT"

# Shared, writable gem/bundle home so gems are installed once and reused (the
# Nix store is read-only).
BUNDLE_HOME="$REPO_ROOT/.example-test-bundle"

DEFAULT_EXAMPLES="echo_bot brute brute-steering lindsey_and_dave inbound_webhook_bot"
read -r -a EXAMPLE_LIST <<<"${EXAMPLES:-$DEFAULT_EXAMPLES}"

command -v nix >/dev/null 2>&1 || { echo "error: nix not found on PATH" >&2; exit 127; }

# The in-shell test body, parameterised by the example directory and temp Gemfile.
# $1 = example dir, $2 = temp Gemfile path
run_in_shell() {
  local dir="$1" gemfile="$2"
  nix develop "$FLAKE" --command bash -eo pipefail -c '
    set -euo pipefail
    dir="$1"; gemfile="$2"; bundle_home="$3"
    cd "$dir"

    export GEM_HOME="$bundle_home"
    export BUNDLE_PATH="$bundle_home"
    export PATH="$bundle_home/bin:$PATH"
    export BUNDLE_GEMFILE="$gemfile"
    # Let brute/agent examples load without real credentials.
    export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-dummy-key-for-load}"

    echo "  bundling..."
    bundle install --quiet

    echo "  booting config.ru + probing..."
    bundle exec ruby -e '\''
      require "rack"
      require "rack/mock"

      app = Rack::Builder.parse_file("config.ru")
      app = app.first if app.is_a?(Array)   # rack < 3 returned [app, opts]

      mr = Rack::MockRequest.new(app)

      ping = mr.post("/_matrix/app/v1/ping")
      raise "POST /ping expected 200, got #{ping.status}" unless ping.status == 200

      txn = mr.put("/_matrix/app/v1/transactions/t1",
                   "CONTENT_TYPE" => "application/json", :input => "{}")
      raise "unauthenticated PUT /transactions expected 403, got #{txn.status}" unless txn.status == 403

      puts "  OK — ping 200, unauthenticated transaction 403"
    '\''
  ' _ "$dir" "$gemfile" "$BUNDLE_HOME"
}

declare -a RESULTS
pass=0
fail=0

for ex in "${EXAMPLE_LIST[@]}"; do
  dir="$SCRIPT_DIR/$ex"
  echo "==================== $ex ===================="

  if [ ! -f "$dir/config.ru" ] || [ ! -f "$dir/Gemfile" ]; then
    echo "  skipped (missing config.ru or Gemfile)"
    RESULTS+=("SKIP  $ex")
    continue
  fi

  # Temp Gemfile: override async-matrix-bridge -> local working tree, keep other
  # gems (async-matrix included) resolving from RubyGems.
  tmp_gemfile="$dir/.Gemfile.run_test"
  sed 's|^gem "async-matrix-bridge".*|gem "async-matrix-bridge", path: "'"$REPO_ROOT"'"|' \
    "$dir/Gemfile" >"$tmp_gemfile"

  if run_in_shell "$dir" "$tmp_gemfile"; then
    RESULTS+=("PASS  $ex")
    pass=$((pass + 1))
  else
    RESULTS+=("FAIL  $ex")
    fail=$((fail + 1))
  fi

  rm -f "$tmp_gemfile" "$tmp_gemfile.lock"
  echo
done

echo "==================== summary ===================="
printf '  %s\n' "${RESULTS[@]}"
echo "  ${pass} passed, ${fail} failed"

[ "$fail" -eq 0 ]
