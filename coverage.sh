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
set -euo pipefail
cd "$(dirname "$0")"

zig build install-tests
rm -rf coverage

kcov --include-path="$PWD/src" coverage/unit zig-out/bin/unit-tests >/dev/null
kcov --include-path="$PWD/src" coverage/conformance zig-out/bin/conformance-tests >/dev/null
kcov --merge coverage/merged coverage/unit coverage/conformance >/dev/null

PCT=$(jq -r '.percent_covered' coverage/merged/kcov-merged/coverage.json)
echo "line coverage: ${PCT}%"
