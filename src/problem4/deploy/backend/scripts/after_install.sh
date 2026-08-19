#!/usr/bin/env bash
# Files are in place. Register the unit but do not start it yet.
set -Eeuo pipefail

log() { echo "[after_install] $*"; }

chown -R api:api /opt/api
install -d -o api -g api -m 750 /opt/api/tmp

if [[ ! -f /opt/api/BUILD_INFO ]]; then
  echo "[after_install] ERROR: BUILD_INFO missing -- bundle is malformed" >&2
  exit 1
fi
log "deploying $(grep '^version=' /opt/api/BUILD_INFO | cut -d= -f2)"

systemctl daemon-reload
systemctl enable api.service
log "unit registered"
