#!/usr/bin/env bash
#
# Publish a Shields.io endpoint badge for the line-coverage percentage.
#
# The badge JSON lives on an orphan `badges` branch so it never clutters `main`;
# the README points Shields at its raw URL. Force-pushed on every run from main.
#
# Inputs (environment):
#   COVERAGE_PCT       line coverage as a float (e.g. "93.9")
#   GH_TOKEN           token with push access
#   GITHUB_REPOSITORY  "owner/repo" (set automatically by GitHub Actions)
set -euo pipefail

pct_int=$(printf '%.0f' "$COVERAGE_PCT")
if   [ "$pct_int" -ge 90 ]; then color=brightgreen
elif [ "$pct_int" -ge 75 ]; then color=green
elif [ "$pct_int" -ge 60 ]; then color=yellowgreen
elif [ "$pct_int" -ge 40 ]; then color=orange
else                             color=red
fi
msg=$(printf '%.1f%%' "$COVERAGE_PCT")

work=$(mktemp -d)
cd "$work"
printf '{"schemaVersion":1,"label":"coverage","message":"%s","color":"%s"}\n' "$msg" "$color" > coverage.json

git init -q
git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git checkout -q -b badges
git add coverage.json
git commit -q -m "chore: update coverage badge ($msg)"
git push -f "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" badges
