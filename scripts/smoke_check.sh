#!/usr/bin/env bash
# scripts/smoke_check.sh
#
# Verify a built quonfig-X.Y.Z.gem actually loads in a clean environment
# before we publish it to RubyGems. This is the prevention measure for
# qfg-e588 (published 0.0.9 was missing lib/quonfig/evaluation_details.rb
# from the gemspec manifest, so `require 'quonfig'` raised LoadError on
# install).
#
# What it does:
#   1. Resolves the gem file path (defaults to ./quonfig-<VERSION>.gem
#      where VERSION is read from the VERSION file at the repo root).
#   2. Creates a throw-away GEM_HOME under /tmp so we are not polluted by
#      whatever is on the developer's machine.
#   3. `gem install`s the local .gem file into that throw-away home with
#      no docs, no other gems.
#   4. Shells out to a fresh ruby process with `-rquonfig` and prints the
#      loaded VERSION constant. If require fails — for any reason —
#      this script exits non-zero and the caller (Rakefile :release task,
#      CI workflow) MUST abort the publish.
#
# Usage:
#   ./scripts/smoke_check.sh                       # auto-discovers ./quonfig-<VERSION>.gem
#   ./scripts/smoke_check.sh path/to/quonfig.gem   # explicit path
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(cat "$repo_root/VERSION" | tr -d '[:space:]')"

gem_file="${1:-$repo_root/quonfig-${version}.gem}"

if [ ! -f "$gem_file" ]; then
  echo "smoke_check: gem file not found: $gem_file" >&2
  echo "smoke_check: run 'gem build quonfig.gemspec' first." >&2
  exit 1
fi

echo "smoke_check: testing $gem_file (version $version)"

# Throw-away GEM_HOME so we exercise install + require in isolation.
sandbox="$(mktemp -d -t quonfig-smoke.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT

# Install the built gem (and its runtime deps) into the sandbox.
GEM_HOME="$sandbox" GEM_PATH="$sandbox" \
  gem install --no-document --install-dir "$sandbox" "$gem_file" >/dev/null

# Require it from a fresh ruby process and print the VERSION constant.
# This is exactly the failure mode qfg-e588 hit: `require 'quonfig'`
# raised LoadError because lib/quonfig/evaluation_details.rb was missing
# from the gemspec manifest.
loaded_version="$(GEM_HOME="$sandbox" GEM_PATH="$sandbox" \
  ruby -rquonfig -e 'puts Quonfig::VERSION')"

if [ "$loaded_version" != "$version" ]; then
  echo "smoke_check: FAIL — expected Quonfig::VERSION=$version, got '$loaded_version'" >&2
  exit 1
fi

echo "smoke_check: OK — Quonfig::VERSION=$loaded_version loaded cleanly"
