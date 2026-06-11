#!/usr/bin/env bash
# Privacy gate: telemetry call sites must not interpolate library/user
# names. Breadcrumbs and tracing events carry bookkeeping only — the
# allowlist scrub in CrashReporting.swift enforces it at runtime for
# Sentry; this grep keeps new call sites from smuggling names into either
# transport at review time. Heuristic and single-line by design: cheap,
# zero-dependency, and good enough to catch the realistic accident.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

# Rust: tracing macros interpolating name/title fields of library or user
# records on the macro line.
if grep -rnE 'tracing::(trace|debug|info|warn|error)!\([^)]*\b(track|album|artist|user)\.(name|title)' core/src --include='*.rs'; then
  fail=1
fi

# Swift: breadcrumb payload lines carrying the same fields. Tests are in
# scope too — a fixture that interpolates a real name field would
# normalize the pattern the gate exists to keep out.
if grep -rnE '(Breadcrumb\(|addBreadcrumb|crumb\.data)[^"]*\b(track|album|artist|user)\.name' macos/Sources macos/Tests --include='*.swift'; then
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo 'privacy-grep: telemetry call site interpolates a library/user name — route it through the allowlisted breadcrumb keys instead' >&2
  exit 1
fi
echo "privacy-grep: clean"
