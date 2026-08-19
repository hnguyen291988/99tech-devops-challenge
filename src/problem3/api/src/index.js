"use strict";

const http = require("http");
const express = require("express");
const { Pool } = require("pg");
const Redis = require("ioredis");

const PORT = Number(process.env.PORT || 3000);
const SHUTDOWN_GRACE_MS = Number(process.env.SHUTDOWN_GRACE_MS || 10_000);

// Fail loudly at boot rather than quietly at the first request. A container
// that exits immediately with a clear reason is far easier to debug than one
// that starts fine and 500s later.
function required(name) {
  const value = process.env[name];
  if (!value) {
    console.error(JSON.stringify({ level: "fatal", msg: `missing required env var ${name}` }));
    process.exit(1);
  }
  return value;
}

const log = (level, fields) =>
  console.log(JSON.stringify({ level, time: new Date().toISOString(), ...fields }));

// ---------------------------------------------------------------------------
// Postgres
// ---------------------------------------------------------------------------
const pool = new Pool({
  host: required("DB_HOST"),
  port: Number(process.env.DB_PORT || 5432),
  user: required("DB_USER"),
  password: required("DB_PASSWORD"),
  database: required("DB_NAME"),
  max: Number(process.env.DB_POOL_MAX || 10),
  idleTimeoutMillis: 30_000,

  // The three that were missing, and the reason the original API could hang
  // forever. Without connectionTimeoutMillis, waiting for a client from an
  // exhausted pool never gives up; without statement_timeout, a query against
  // a frozen database never returns.
  connectionTimeoutMillis: 3_000,
  statement_timeout: 5_000,
  query_timeout: 5_000,

  application_name: "api",
});

// An idle client whose socket dies (database restart, failover, network blip)
// emits 'error' on the pool. With no listener, Node treats it as an unhandled
// error event and kills the process.
pool.on("error", (err) => log("error", { msg: "idle postgres client error", err: err.message }));

// ---------------------------------------------------------------------------
// Redis — a cache, and therefore optional by definition
// ---------------------------------------------------------------------------
const redis = new Redis({
  host: required("REDIS_HOST"),
  port: Number(process.env.REDIS_PORT || 6379),
  connectTimeout: 2_000,
  commandTimeout: 1_000,

  // Defaults are maxRetriesPerRequest: 20 with an escalating backoff, which is
  // why a stopped Redis made this endpoint take ~10s to fail. One retry, then
  // give up and let the caller carry on without the cache.
  maxRetriesPerRequest: 1,
  enableOfflineQueue: false,
  retryStrategy: (attempt) => Math.min(attempt * 200, 5_000),
});

// ioredis emits 'error' on every failed reconnect. Unhandled, that is fatal.
redis.on("error", (err) => log("warn", { msg: "redis error", err: err.message }));
redis.on("ready", () => log("info", { msg: "redis connected" }));

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------
const app = express();
app.disable("x-powered-by");
app.use(express.json({ limit: "100kb" }));

// Correlate a request across nginx and app logs.
app.use((req, res, next) => {
  req.id = req.header("x-request-id") || `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  res.setHeader("x-request-id", req.id);
  const started = process.hrtime.bigint();
  res.on("finish", () => {
    const ms = Number(process.hrtime.bigint() - started) / 1e6;
    if (req.path !== "/healthz" && req.path !== "/readyz") {
      log("info", { msg: "request", id: req.id, method: req.method, path: req.path, status: res.statusCode, ms: Math.round(ms) });
    }
  });
  next();
});

app.get("/api/users", async (req, res) => {
  try {
    // pool.query() checks a client out and returns it in a finally block
    // internally, so it cannot leak. The original code did
    //   const db = await pool.connect(); await db.query(...); db.release();
    // which leaks the client on every thrown query, permanently shrinking the
    // pool until the API hangs. See evidence/pool-leak-repro.js.
    const { rows } = await pool.query(
      "SELECT id, email, created_at FROM app.users ORDER BY id LIMIT 100"
    );
    res.json({ ok: true, count: rows.length, users: rows });
  } catch (err) {
    log("error", { msg: "GET /api/users failed", id: req.id, err: err.message });
    // 503, not 500: this is a dependency failure, it is retryable, and the
    // distinction is what lets a load balancer and a client behave sensibly.
    return res.status(503).json({ ok: false, error: "database unavailable" });
  }

  // Cache bookkeeping is best-effort and happens after the response is sent.
  // Awaiting it inline is what let a Redis outage turn a healthy read into a
  // 10-second failure.
  redis
    .set("last_call", Date.now(), "EX", 3600)
    .catch((err) => log("warn", { msg: "cache write skipped", id: req.id, err: err.message }));
});

// Liveness: is this process alive and able to answer? No dependencies, because
// a liveness check that fails when the database blips gets the container killed
// during an outage it could have ridden out.
app.get("/healthz", (_req, res) => res.json({ status: "ok", component: "api" }));

// Readiness: should this instance receive traffic? Postgres is required.
// Redis is reported but not disqualifying — the service is degraded without
// its cache, not broken.
app.get("/readyz", async (_req, res) => {
  const checks = { postgres: "down", redis: "down" };

  try {
    await pool.query("SELECT 1");
    checks.postgres = "up";
  } catch (err) {
    checks.postgres = `down: ${err.message}`;
  }

  try {
    await redis.ping();
    checks.redis = "up";
  } catch (err) {
    checks.redis = `down: ${err.message}`;
  }

  const ready = checks.postgres === "up";
  res.status(ready ? 200 : 503).json({
    ready,
    degraded: ready && checks.redis !== "up",
    checks,
  });
});

app.use((_req, res) => res.status(404).json({ ok: false, error: "not found" }));

// Express swallows errors without this and the client sees a hung request.
app.use((err, req, res, _next) => {
  log("error", { msg: "unhandled route error", id: req.id, err: err.message });
  res.status(500).json({ ok: false, error: "internal error" });
});

// ---------------------------------------------------------------------------
// Server + graceful shutdown
// ---------------------------------------------------------------------------
const server = http.createServer(app);

// Must exceed nginx's upstream keepalive_timeout (60s), otherwise Node closes a
// pooled connection at the same moment nginx reuses it and the client gets a
// sporadic, unreproducible 502.
server.keepAliveTimeout = 65_000;
server.headersTimeout = 66_000;

server.listen(PORT, () => log("info", { msg: `api listening on ${PORT}` }));

let shuttingDown = false;
async function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  log("info", { msg: `${signal} received, draining` });

  // Hard deadline: if draining stalls, exit anyway rather than waiting for the
  // orchestrator's SIGKILL, so the exit stays clean and attributable.
  const deadline = setTimeout(() => {
    log("error", { msg: "graceful shutdown timed out, exiting" });
    process.exit(1);
  }, SHUTDOWN_GRACE_MS);
  deadline.unref();

  server.close(async () => {
    try {
      await pool.end();
      redis.disconnect();
      log("info", { msg: "drained cleanly" });
      process.exit(0);
    } catch (err) {
      log("error", { msg: "error during shutdown", err: err.message });
      process.exit(1);
    }
  });
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

// Crash loudly and let the restart policy do its job. A process in an unknown
// state serving traffic is worse than a process that restarted.
process.on("unhandledRejection", (reason) => {
  log("fatal", { msg: "unhandled rejection", err: String(reason) });
  process.exit(1);
});
process.on("uncaughtException", (err) => {
  log("fatal", { msg: "uncaught exception", err: err.message, stack: err.stack });
  process.exit(1);
});
