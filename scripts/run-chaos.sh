#!/usr/bin/env bash
#
# Run the cross-SDK chaos harness against sdk-ruby (qfg-47c2.25).
#
# 1. Boots the shared toxiproxy launcher (../integration-test-data/chaos/start-chaos.sh).
# 2. Launches api-delivery in fixture mode on $CHAOS_API_DELIVERY_PORT.
# 3. Reconfigures the seeded toxiproxy SSE/HTTP proxies to forward to that api-delivery.
# 4. Runs `bundle exec ruby -I chaos -I lib chaos/test_chaos.rb`.
# 5. Tears everything down on exit (success or failure).
#
# Mirrors sdk-go/scripts/run-chaos.sh, sdk-node/scripts/run-chaos.sh, and
# sdk-python/scripts/run-chaos.sh so every SDK has identical boot semantics.
#
# Env knobs (override on the command line):
#   CHAOS_API_DELIVERY_PORT  port for the locally-spawned api-delivery (default 6550)
#   CHAOS_ONLY               comma list of scenarios, e.g. "01,02"
#   CHAOS_SKIP               comma list of scenarios to skip
#   CHAOS_POLL_MS            expectation poll interval (default 250)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$SDK_DIR/.." && pwd)"
HARNESS_DIR="$REPO_ROOT/integration-test-data/chaos"

if [[ ! -d "$HARNESS_DIR" ]]; then
  echo "chaos harness not found at $HARNESS_DIR — is integration-test-data checked out as a sibling?" >&2
  exit 1
fi

API_PORT="${CHAOS_API_DELIVERY_PORT:-6550}"

cleanup_done=0
cleanup() {
  if [[ "$cleanup_done" == "1" ]]; then
    return
  fi
  cleanup_done=1
  echo "==> tearing down chaos harness"
  if [[ -n "${API_DELIVERY_PID:-}" ]]; then
    kill "$API_DELIVERY_PID" 2>/dev/null || true
    wait "$API_DELIVERY_PID" 2>/dev/null || true
  fi
  "$HARNESS_DIR/stop-chaos.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "==> building api-delivery binary"
API_BIN="$SDK_DIR/.chaos-api-delivery"
( cd "$REPO_ROOT/api-delivery" && GOWORK=off go build -o "$API_BIN" ./cmd/server )

echo "==> starting api-delivery on :$API_PORT (FIXTURE_DIR=integration-test-data/data/integration-tests)"
PORT="$API_PORT" \
  FIXTURE_DIR="$REPO_ROOT/integration-test-data/data/integration-tests" \
  SDK_KEYS_FILE="$REPO_ROOT/api-delivery/testdata/fixture-sdk-keys.json" \
  QUONFIG_ENVIRONMENT=development \
  "$API_BIN" &
API_DELIVERY_PID=$!

# Wait for api-delivery healthz.
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$API_PORT/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
  if [[ $i -eq 30 ]]; then
    echo "api-delivery did not come up on :$API_PORT within 15s" >&2
    exit 1
  fi
done

echo "==> booting toxiproxy via shared launcher (upstream :$API_PORT)"
CHAOS_UPSTREAM_HOST=host.docker.internal \
  CHAOS_UPSTREAM_SSE="$API_PORT" \
  CHAOS_UPSTREAM_HTTP="$API_PORT" \
  "$HARNESS_DIR/start-chaos.sh"

echo "==> running chaos scenarios"
cd "$SDK_DIR"
CHAOS_API_DELIVERY_URL="http://127.0.0.1:$API_PORT" \
  bundle exec ruby -I chaos -I lib chaos/test_chaos.rb "$@"
