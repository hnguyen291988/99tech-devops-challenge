# syntax=docker/dockerfile:1
ARG NODE_VERSION=20-alpine

# --- dependencies -----------------------------------------------------------
# Separate stage so the final image carries no npm cache and no build tooling.
FROM node:${NODE_VERSION} AS deps
WORKDIR /app
COPY package.json package-lock.json ./
# npm ci, not npm install: it installs exactly the lockfile and fails if
# package.json and the lock disagree. The original Dockerfile ran npm install
# with no lockfile present, so "the same build" resolved different dependency
# versions on different days.
RUN npm ci --omit=dev && npm cache clean --force

# --- runtime ----------------------------------------------------------------
FROM node:${NODE_VERSION} AS runtime
ENV NODE_ENV=production
WORKDIR /app

# The node image already ships an unprivileged 'node' user (uid 1000).
COPY --chown=node:node --from=deps /app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src

# Was running as root, which it has no need to do.
USER node

EXPOSE 3000

# Image-level health so the container is self-describing even outside compose.
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null "http://127.0.0.1:${PORT:-3000}/readyz" || exit 1

# Exec form, so node is PID 1 and receives SIGTERM directly. Combined with the
# SIGTERM handler in the app and init: true in compose, shutdown is graceful.
CMD ["node", "src/index.js"]
