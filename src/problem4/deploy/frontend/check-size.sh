#!/usr/bin/env bash
#
# Fails the build if the shipped bundle exceeds a gzipped size budget. A
# performance regression is a bug that no unit test catches, and the only way it
# stays fixed is for the number to be enforced rather than watched.
#
#   ./check-size.sh <dist-dir> <budget-kb>
#
set -Eeuo pipefail

DIST="${1:?usage: check-size.sh <dist-dir> <budget-kb>}"
BUDGET_KB="${2:-600}"

[[ -d "$DIST" ]] || { echo "ERROR: ${DIST} not found" >&2; exit 1; }

total=0
echo "Gzipped sizes of shipped JS and CSS:"
while IFS= read -r -d '' file; do
  size=$(gzip -c "$file" | wc -c | tr -d ' ')
  total=$((total + size))
  printf '  %8s KB  %s\n' "$((size / 1024))" "${file#"$DIST"/}"
done < <(find "$DIST" -type f \( -name '*.js' -o -name '*.css' \) -print0)

total_kb=$((total / 1024))
echo "-----"
printf 'Total: %s KB (budget %s KB)\n' "$total_kb" "$BUDGET_KB"

# Also surfaced on the pull request, so the number is reviewed rather than
# buried in a log.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '**Bundle size:** %s KB gzipped (budget %s KB)\n' "$total_kb" "$BUDGET_KB" \
    >> "$GITHUB_STEP_SUMMARY"
fi

if (( total_kb > BUDGET_KB )); then
  echo "::error::Bundle is ${total_kb} KB gzipped, over the ${BUDGET_KB} KB budget."
  echo "Either optimise it, or raise the budget deliberately in the workflow."
  exit 1
fi

echo "Within budget."
