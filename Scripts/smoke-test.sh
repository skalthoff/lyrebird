#!/usr/bin/env bash
# Real-server smoke test — backs the POLISH_TARGETS gate for: login, library
# page 1, search, queue add, playback start/stop.
#
# Thin wrapper over the live e2e suite (core/tests/e2e_live.rs) so the gate
# exercises the actual core library — auth header handling, response
# deserialization, queue state — rather than re-implementing REST calls in
# shell. Defaults to the shared read-only test account authorized in
# CLAUDE.md; point LYREBIRD_E2E_URL / _USER / _PASS elsewhere to smoke another
# server.
set -euo pipefail

: "${LYREBIRD_E2E_URL:=https://music.skalthoff.com}"
: "${LYREBIRD_E2E_USER:=test}"
: "${LYREBIRD_E2E_PASS:=test}"
export LYREBIRD_E2E_URL LYREBIRD_E2E_USER LYREBIRD_E2E_PASS

cd "$(dirname "$0")/.."

# Fail fast with a readable message when the server is down, instead of
# letting every test time out individually.
curl -fsS --max-time 20 "$LYREBIRD_E2E_URL/System/Info/Public" > /dev/null \
  || { echo "smoke-test: server $LYREBIRD_E2E_URL unreachable" >&2; exit 1; }

# Serial (--test-threads=1) to keep load on the shared test server polite,
# matching the e2e workflow.
cargo test --package lyrebird_core --test e2e_live -- --nocapture --test-threads=1

echo "smoke-test: PASS — login, library page 1, search, queue add, playback start/stop (+ downloads)"
