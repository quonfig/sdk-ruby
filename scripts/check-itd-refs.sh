#!/usr/bin/env bash
#
# Fail when the integration-test-data refs pinned across this repo's workflows
# differ (qfg-6vno.7). The unit tests, the release gate and both chaos suites
# must run against the same ITD tag: a chaos pin left behind passed rows the
# unit pin had already rewritten.
#
# Reads every `ref:` inside an actions/checkout step whose `repository:` is
# quonfig/integration-test-data. Usage: scripts/check-itd-refs.sh [workflow-dir]

set -euo pipefail

dir="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/workflows}"

refs="$(
  awk '
    # An ITD checkout with no ref tracks the default branch: report it so it
    # can never match a pinned tag.
    function unpinned() { if (itd) printf "%s:%d (no-ref)\n", file, line; itd = 0 }
    FNR == 1 { unpinned() }
    /^[[:space:]]*-[[:space:]]/ { unpinned() }
    /repository:[[:space:]]*quonfig\/integration-test-data[[:space:]]*$/ { itd = 1; file = FILENAME; line = FNR }
    itd && /^[[:space:]]*ref:[[:space:]]*/ {
      ref = $0
      sub(/^[[:space:]]*ref:[[:space:]]*/, "", ref)
      sub(/[[:space:]]*#.*$/, "", ref)
      printf "%s:%d %s\n", FILENAME, FNR, ref
      itd = 0
    }
    END { unpinned() }
  ' "$dir"/*.yml "$dir"/*.yaml 2>/dev/null
)"

if [[ -z "$refs" ]]; then
  echo "check-itd-refs: no integration-test-data ref found under $dir" >&2
  exit 1
fi

echo "$refs"
distinct="$(echo "$refs" | awk '{ print $2 }' | sort -u)"
if [[ "$(echo "$distinct" | wc -l | tr -d ' ')" != "1" ]]; then
  echo "check-itd-refs: integration-test-data refs differ across workflows:" >&2
  echo "$distinct" | sed 's/^/  /' >&2
  exit 1
fi
echo "check-itd-refs: all integration-test-data refs are ${distinct}"
