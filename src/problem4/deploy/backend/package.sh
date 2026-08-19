#!/usr/bin/env bash
#
# Assembles the CodeDeploy bundle. Kept out of the workflow YAML so it can be
# run and debugged locally: ./deploy/backend/package.sh "$(git rev-parse --short=12 HEAD)"
set -Eeuo pipefail

VERSION="${1:?usage: package.sh <version>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="${ROOT}/apps/api"
STAGE="$(mktemp -d)"
OUT_DIR="${APP_DIR}/dist-bundle"

trap 'rm -rf "$STAGE"' EXIT

echo "Packaging api ${VERSION}"

# Production dependencies only. Installing into the bundle rather than on the
# instance means a deploy does not depend on the npm registry being up, and the
# instance needs no build toolchain.
mkdir -p "${STAGE}/app"
cp -R "${APP_DIR}/dist"           "${STAGE}/app/dist"
cp    "${APP_DIR}/package.json"    "${STAGE}/app/"
cp    "${APP_DIR}/package-lock.json" "${STAGE}/app/"
( cd "${STAGE}/app" && npm ci --omit=dev --ignore-scripts && npm cache clean --force )

# CodeDeploy needs appspec.yml at the bundle root.
cp    "${ROOT}/deploy/backend/appspec.yml"  "${STAGE}/"
cp -R "${ROOT}/deploy/backend/scripts"      "${STAGE}/scripts"
cp    "${ROOT}/deploy/backend/api.service"  "${STAGE}/"
chmod +x "${STAGE}"/scripts/*.sh

# The instance reads this to report which build it is running, which is what the
# pipeline's post-deploy check verifies against.
cat > "${STAGE}/app/BUILD_INFO" <<INFO
version=${VERSION}
commit=${GITHUB_SHA:-$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)}
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
built_by=${GITHUB_RUN_ID:-local}
INFO

mkdir -p "${OUT_DIR}"
tar -czf "${OUT_DIR}/api-${VERSION}.tar.gz" -C "${STAGE}" .

echo "Wrote ${OUT_DIR}/api-${VERSION}.tar.gz ($(du -h "${OUT_DIR}/api-${VERSION}.tar.gz" | cut -f1))"
