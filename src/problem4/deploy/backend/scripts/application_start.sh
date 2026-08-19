#!/usr/bin/env bash
# Start the service and confirm systemd is satisfied. Traffic still has not
# been shifted to these instances.
set -Eeuo pipefail

log() { echo "[application_start] $*"; }

systemctl restart api.service

# systemctl restart returns as soon as the unit is activating, so poll rather
# than assume. Without this, a process that starts and immediately exits looks
# like a successful start.
for i in $(seq 1 30); do
  if systemctl is-active --quiet api.service; then
    log "active after ${i}s"
    exit 0
  fi
  sleep 1
done

echo "[application_start] ERROR: api.service did not become active" >&2
systemctl status api.service --no-pager --lines 50 >&2 || true
journalctl -u api.service --no-pager --lines 100 >&2 || true
exit 1
