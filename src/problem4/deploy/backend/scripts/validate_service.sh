#!/usr/bin/env bash
# The gate. A non-zero exit fails the deployment, and because this is a
# blue/green group the ALB listener has not been shifted yet -- so a bad release
# never serves a single production request.
set -Eeuo pipefail

PORT="${API_PORT:-3000}"
EXPECTED_VERSION="$(grep '^version=' /opt/api/BUILD_INFO | cut -d= -f2)"

log() { echo "[validate_service] $*"; }

log "validating version ${EXPECTED_VERSION} on :${PORT}"

# 1. Readiness, which the app answers only once its dependencies are reachable.
ready=false
for i in $(seq 1 60); do
  if curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/readyz" >/dev/null 2>&1; then
    log "ready after ${i}s"
    ready=true
    break
  fi
  sleep 2
done

if [[ "$ready" != true ]]; then
  echo "[validate_service] ERROR: /readyz never returned 200" >&2
  journalctl -u api.service --no-pager --lines 200 >&2 || true
  exit 1
fi

# 2. The running build is the build we just shipped. Catches the case where the
#    old process survived and is still serving -- which looks like success to
#    every check that only asks "does it answer".
running_version=$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/healthz" \
                  | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
if [[ "$running_version" != "$EXPECTED_VERSION" ]]; then
  echo "[validate_service] ERROR: serving '${running_version}', expected '${EXPECTED_VERSION}'" >&2
  exit 1
fi
log "version confirmed"

# 3. One real endpoint, not just the health route. A service can be "ready" and
#    still 500 on every actual request -- a wrong schema, a missing migration,
#    a bad IAM permission on a downstream call.
if ! curl -fsS --max-time 10 "http://127.0.0.1:${PORT}/api/v1/status" >/dev/null; then
  echo "[validate_service] ERROR: smoke request to /api/v1/status failed" >&2
  journalctl -u api.service --no-pager --lines 100 >&2 || true
  exit 1
fi

log "validation passed"
