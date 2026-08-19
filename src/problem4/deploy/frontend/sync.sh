#!/usr/bin/env bash
#
# Publishes a built SPA to S3 in the correct order, with the correct cache
# headers. Both of those details matter more than they look.
#
#   ./sync.sh <dist-dir> <bucket>
#
set -Eeuo pipefail

DIST="${1:?usage: sync.sh <dist-dir> <bucket>}"
BUCKET="${2:?usage: sync.sh <dist-dir> <bucket>}"

[[ -f "${DIST}/index.html" ]] || { echo "ERROR: ${DIST}/index.html not found" >&2; exit 1; }

IMMUTABLE='public, max-age=31536000, immutable'
NO_CACHE='no-cache, no-store, must-revalidate'

echo "==> Pass 1: content-hashed assets (immutable, 1 year)"
# Assets FIRST. index.html references them by hashed filename, so if index.html
# went up first there would be a window where the browser asks for a chunk that
# does not exist yet. On a busy site that window is real user-visible errors.
#
# Deliberately NO --delete. Old chunks are kept: a user who loaded the previous
# index.html minutes ago will still request them, and deleting them breaks that
# session mid-navigation. An S3 lifecycle rule expires releases/ and orphaned
# assets after 30 days, which is both safer and cheaper than being tidy now.
aws s3 sync "${DIST}" "s3://${BUCKET}/" \
  --exclude 'index.html' \
  --exclude 'config.json' \
  --exclude 'build-id.txt' \
  --exclude 'releases/*' \
  --cache-control "${IMMUTABLE}" \
  --only-show-errors \
  --no-cli-pager

echo "==> Pass 2: entry points (never cached)"
# index.html must not be cached, at the edge or in the browser. If it is, a
# deploy silently does not take effect until the TTL expires, and a rollback
# appears not to work -- which is when people start invalidating /* in a panic.
for f in index.html config.json build-id.txt; do
  [[ -f "${DIST}/${f}" ]] || continue
  case "$f" in
    *.html) ctype='text/html; charset=utf-8' ;;
    *.json) ctype='application/json' ;;
    *)      ctype='text/plain; charset=utf-8' ;;
  esac
  echo "    ${f} (${ctype})"
  aws s3 cp "${DIST}/${f}" "s3://${BUCKET}/${f}" \
    --cache-control "${NO_CACHE}" \
    --content-type "${ctype}" \
    --only-show-errors \
    --no-cli-pager
done

echo "==> Done. Assets are immutable; entry points are no-cache."
