#!/usr/bin/env bash
#
# Run the failover + canonical-ordering chaos rigs against sdk-ruby (qfg-7h5d.1.9).
#
# Unlike run-chaos.sh (single upstream), these two rigs spawn their own
# api-delivery fixture upstream(s) from inside chaos/failover_chaos.rb:
#   - failover suite (f01-f05): ONE upstream behind the primary ('http') +
#     'secondary' proxies; faults hit the primary leg, the SDK must resolve off
#     the secondary, fast.
#   - ordering suite (o01-o04): TWO upstreams pinned to divergent
#     Meta.generations (one pair per scenario via FIXTURE_GENERATION).
#
# So this wrapper:
#   1. Builds the api-delivery binary once (GOWORK=off so the pinned sdk-go
#      module resolves, not the local sibling).
#   2. Boots toxiproxy via the shared launcher (no upstream — the runner spawns
#      its own and repoints the seeded 'http'/'secondary'/'sse' proxies).
#   3. Runs the Ruby runner, which builds/repoints per scenario.
#
# Env knobs:
#   CHAOS_RUN    only-run regex on scenario file basename (default empty)
#   CHAOS_SKIP   skip regex on scenario file basename. The CI default skips
#                o01-secondary-newer — it needs cross-leg max-wins (qfg-7h5d.1.14),
#                out of the §5f reject-older scope and not yet built.
#   CHAOS_POLL_MS expectation poll interval (default 200)
#
# Examples:
#   ./scripts/run-failover-chaos.sh
#   CHAOS_RUN='^f0' ./scripts/run-failover-chaos.sh                 # failover suite only
#   CHAOS_RUN='^o0' ./scripts/run-failover-chaos.sh                 # ordering suite only
#   CHAOS_SKIP='o01-secondary-newer' ./scripts/run-failover-chaos.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$SDK_DIR/.." && pwd)"
HARNESS_DIR="$REPO_ROOT/integration-test-data/chaos"

if [[ ! -d "$HARNESS_DIR" ]]; then
  echo "chaos harness not found at $HARNESS_DIR — is integration-test-data checked out as a sibling?" >&2
  exit 1
fi

# Identify ourselves to the shared chaos lock (qfg-47c2.32). Owner PID is THIS
# wrapper's pid so the lock survives the whole run, not just the short-lived
# start-chaos.sh subprocess.
export QUONFIG_CHAOS_SESSION="${QUONFIG_CHAOS_SESSION:-sdk-ruby-failover-$$-$(date +%s)}"
export QUONFIG_CHAOS_OWNER_PID=$$

cleanup_done=0
cleanup() {
  if [[ "$cleanup_done" == "1" ]]; then
    return
  fi
  cleanup_done=1
  echo "==> tearing down chaos harness"
  "$HARNESS_DIR/stop-chaos.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "==> building api-delivery binary (GOWORK=off)"
API_BIN="$SDK_DIR/.chaos-api-delivery"
( cd "$REPO_ROOT/api-delivery" && GOWORK=off go build -o "$API_BIN" ./cmd/server )

echo "==> booting toxiproxy via shared launcher (no upstream — the runner spawns its own)"
"$HARNESS_DIR/start-chaos.sh"

echo "==> running failover + ordering scenarios"
cd "$SDK_DIR"
CHAOS_API_DELIVERY_BIN="$API_BIN" \
  CHAOS_FIXTURE_DIR="$REPO_ROOT/integration-test-data/data/integration-tests" \
  CHAOS_SDK_KEYS_FILE="$REPO_ROOT/api-delivery/testdata/fixture-sdk-keys.json" \
  CHAOS_UPSTREAM_HOST="${CHAOS_UPSTREAM_HOST:-host.docker.internal}" \
  bundle exec ruby -I chaos -I lib chaos/failover_chaos.rb "$@"
