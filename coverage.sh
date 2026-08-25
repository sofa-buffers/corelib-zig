#!/usr/bin/env bash
#
# Line coverage for the library sources via kcov (DWARF-based, no
# instrumentation flags needed). Runs both test binaries — the in-source unit
# tests and the shared-vector conformance suite — and merges the reports.
#
# Requires: kcov, jq  (apt-get install kcov jq)
#
# Outputs:
#   coverage/merged/kcov-merged/  HTML report + coverage.json
#   stdout                        the line-coverage percentage
#
# Exits non-zero below COVERAGE_MIN (default 90, CORELIB_PLAN §7.3: "Expected
# coverage is >90%"). The number used to be read only to render the badge, so a
# regression below the bar stayed green and the bar was a statement rather than
# a gate.
set -euo pipefail
cd "$(dirname "$0")"

COVERAGE_MIN=${COVERAGE_MIN:-90}

zig build install-tests
rm -rf coverage
# kcov creates its output directory but not the parent.
mkdir -p coverage

kcov --include-path="$PWD/src" coverage/unit zig-out/bin/unit-tests >/dev/null
kcov --include-path="$PWD/src" coverage/conformance zig-out/bin/conformance-tests >/dev/null
kcov --merge coverage/merged coverage/unit coverage/conformance >/dev/null

REPORT=$(find coverage/merged -name coverage.json | head -1)
PCT=$(jq -r '.percent_covered' "$REPORT")
echo "line coverage: ${PCT}%"

# The bar, enforced. The comparison goes through jq — already a prerequisite, and
# the only one of them that does float arithmetic.
if ! jq -e --argjson min "$COVERAGE_MIN" '(.percent_covered | tonumber) >= $min' "$REPORT" >/dev/null; then
  echo "error: line coverage ${PCT}% is below the ${COVERAGE_MIN}% bar (CORELIB_PLAN §7.3)" >&2
  exit 1
fi
