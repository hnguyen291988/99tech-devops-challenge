#!/usr/bin/env bash
# Runs on the replacement instances before files are copied. No traffic yet.
set -Eeuo pipefail

log() { echo "[before_install] $*"; }

# The service account. Created here rather than baked into the AMI so the
# bundle is self-sufficient on a bare instance.
if ! id api >/dev/null 2>&1; then
  log "creating api service account"
  useradd --system --home-dir /opt/api --shell /usr/sbin/nologin api
fi

install -d -o api -g api -m 750 /opt/api /opt/api/tmp
install -d -o root -g api -m 750 /etc/api

# Fetch configuration at deploy time from Parameter Store. Secrets never enter
# the artifact, never appear in the repository, and rotate without a rebuild.
# The instance profile is scoped to this environment's parameter path only.
: "${APP_ENV:?APP_ENV must be set on the instance (from user-data or the AMI)}"
log "fetching configuration for ${APP_ENV}"

umask 027
aws ssm get-parameters-by-path \
  --path "/api/${APP_ENV}/" \
  --with-decryption \
  --recursive \
  --query 'Parameters[].[Name,Value]' \
  --output text \
  --no-cli-pager \
| while IFS=$'\t' read -r name value; do
    printf '%s=%s\n' "$(basename "$name" | tr '[:lower:]-' '[:upper:]_')" "$value"
  done > /etc/api/env.new

# Fail before touching the live file if the fetch produced nothing: an empty
# EnvironmentFile starts the app with no database credentials, which is a
# harder failure to diagnose than not starting at all.
if [[ ! -s /etc/api/env.new ]]; then
  echo "[before_install] ERROR: no parameters found under /api/${APP_ENV}/" >&2
  exit 1
fi

mv /etc/api/env.new /etc/api/env
chown root:api /etc/api/env
chmod 640 /etc/api/env
log "wrote $(wc -l < /etc/api/env) configuration values"
