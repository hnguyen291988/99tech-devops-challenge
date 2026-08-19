#!/usr/bin/env bash
# Runs on the OLD instances once the ALB has stopped sending them new requests,
# so in-flight work is allowed to finish. Must not fail on a first-ever deploy
# where there is nothing to stop.
set -Eeuo pipefail

log() { echo "[application_stop] $*"; }

if ! systemctl list-unit-files api.service >/dev/null 2>&1; then
  log "no api.service present (first deploy) -- nothing to stop"
  exit 0
fi

if ! systemctl is-active --quiet api.service; then
  log "api.service already inactive"
  exit 0
fi

# SIGTERM, then wait. The app drains: stops accepting, finishes in-flight
# requests, closes its connection pools. TimeoutStopSec in the unit caps it.
log "stopping api.service"
systemctl stop api.service || true

for i in $(seq 1 30); do
  systemctl is-active --quiet api.service || { log "stopped after ${i}s"; exit 0; }
  sleep 1
done

log "did not stop within 30s; escalating to SIGKILL"
systemctl kill --signal=SIGKILL api.service || true
exit 0
