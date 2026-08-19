#!/usr/bin/env bash
#
# The deploy jobs need AWS, so they cannot run here. Everything that does not
# need AWS is checked: workflow schema and expression syntax via actionlint,
# every deploy script via shellcheck, and the embedded run: blocks too --
# actionlint pipes those through shellcheck as well.
#
# actionlint resolves `uses: ./.github/workflows/...` relative to the git
# project root, and in this submission the workflows live under src/problem4/
# rather than at the repository root. So it runs against a throwaway checkout
# laid out the way a real repository would be -- which is also the only layout
# in which the local reusable-workflow references can be verified at all.
#
#   ./validate.sh
#
set -Eeuo pipefail
cd "$(dirname "$0")"

fail=0
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R .github deploy "$STAGE"/
git -C "$STAGE" init -q

echo "==> actionlint (workflow schema, expressions, action inputs, embedded bash)"
docker run --rm -v "$STAGE":/repo -w /repo rhysd/actionlint:latest -color || fail=1

echo
echo "==> shellcheck (deploy scripts)"
docker run --rm -v "$PWD":/mnt -w /mnt koalaman/shellcheck:stable \
  deploy/backend/package.sh \
  deploy/backend/scripts/*.sh \
  deploy/frontend/*.sh || fail=1

echo
if [[ "$fail" -eq 0 ]]; then
  echo "All checks passed."
else
  echo "Checks failed." >&2
fi
exit "$fail"
