#!/usr/bin/env bash
# scripts/smoke_check.sh
#
# Verify a built quonfig-X.Y.Z.gem actually loads in a clean environment
# before we publish it to RubyGems. Prevention measure for qfg-e588 (0.0.9
# was published with a stale gemspec manifest missing
# lib/quonfig/evaluation_details.rb, so `require 'quonfig'` raised
# LoadError on install).
#
# Usage:
#   ./scripts/smoke_check.sh path/to/quonfig-X.Y.Z.gem
#
# What it does:
#   1. Extracts the expected version from the gem filename.
#   2. Creates a throw-away GEM_HOME so we are not polluted by whatever
#      is on the developer's machine (or the CI runner's bundler).
#   3. `gem install`s the local .gem file into that throw-away home.
#   4. Shells out to a fresh ruby process with `-rquonfig` and prints the
#      loaded VERSION constant. If require fails or the version mismatches
#      the filename, we exit non-zero and the caller MUST abort the publish.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 path/to/quonfig-X.Y.Z.gem" >&2
  exit 2
fi

gem_file="$1"

if [ ! -f "$gem_file" ]; then
  echo "smoke_check: gem file not found: $gem_file" >&2
  exit 1
fi

# Extract version from filename: quonfig-X.Y.Z.gem -> X.Y.Z
filename="$(basename "$gem_file")"
version="${filename#quonfig-}"
version="${version%.gem}"

if [ -z "$version" ] || [ "$version" = "$filename" ]; then
  echo "smoke_check: could not parse version from filename: $filename" >&2
  exit 1
fi

echo "smoke_check: testing $gem_file (expected version $version)"

sandbox="$(mktemp -d -t quonfig-smoke.XXXXXX)"
trap 'rm -rf "$sandbox"' EXIT

GEM_HOME="$sandbox" GEM_PATH="$sandbox" \
  gem install --no-document --install-dir "$sandbox" "$gem_file" >/dev/null

# Run in a clean ruby env (unset BUNDLE_*) so a Gemfile in the cwd cannot
# hijack the require path. We want to exercise the gem-as-installed.
loaded_version="$(env -u BUNDLE_GEMFILE -u BUNDLE_PATH -u BUNDLE_BIN_PATH \
  GEM_HOME="$sandbox" GEM_PATH="$sandbox" \
  ruby --disable-gems -e '
    require "rubygems"
    Gem.paths = { "GEM_HOME" => ENV["GEM_HOME"], "GEM_PATH" => ENV["GEM_PATH"] }
    require "quonfig"
    puts Quonfig::VERSION
  ')"

if [ "$loaded_version" != "$version" ]; then
  echo "smoke_check: FAIL — gem filename says $version, Quonfig::VERSION=$loaded_version" >&2
  exit 1
fi

echo "smoke_check: OK — Quonfig::VERSION=$loaded_version loaded cleanly"
