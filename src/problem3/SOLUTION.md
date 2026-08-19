# Problem 3 — Debugging issues within system

> Brief is in [README.md](./README.md) (upstream it is headed "Problem 4" — same task).
> Everything below was reproduced on Docker 24.0.2 / Compose v2.18.1. Every console output here is
> copied from my terminal, not written from memory.

## Short answer

The report was "the API is unreliable and sometimes inaccessible". Those are two faults, not one.

**Inaccessible:** nginx proxies to `api:3001`. The app listens on `3000`. Every `/api/*` request has
always returned 502. Nothing intermittent about it.

**Unreliable:** three separate bugs, each turning a small problem into a lasting one.

- `/api/users` leaks a pooled Postgres connection on every failed query, so 10 failures hang the API
  permanently until someone restarts it.
- No timeouts anywhere, so a slow dependency means a request that never returns.
- The handler awaits a Redis cache write on a read path, with ioredis' default 20 retries. So a cache
  outage turns a 20ms read into a 10-second failure.

14 findings in total. First 7 are live faults, the rest were going to cause the next incident. All fixed
here, and [`smoke-test.sh`](./smoke-test.sh) asserts each one so they cannot come back quietly.

## How I found it

I started the stack and looked, before reading the code. Reading first makes you look for the bug you
expect.

```console
$ docker compose up --build -d && docker compose ps -a
problem3-api-1        Up 8 seconds
problem3-nginx-1      Up 8 seconds
problem3-postgres-1   Up 9 seconds
problem3-redis-1      Up 9 seconds
```

All four up, nothing crash-looping. So this is a request-path problem, not a startup problem.

```console
$ curl -si http://localhost:8080/ | head -1
HTTP/1.1 200 OK
$ curl -si http://localhost:8080/api/users | head -1
HTTP/1.1 502 Bad Gateway
$ curl -so /dev/null -w '%{http_code}\n' http://localhost:8080/status
404
```

`/` works, so nginx is alive. `/api/` is 502, which is nginx saying it could not reach the upstream. It will
have logged why:

```console
$ docker compose logs nginx | grep -i error
[error] connect() failed (111: Connection refused) while connecting to upstream,
  request: "GET /api/users HTTP/1.1", upstream: "http://172.18.0.4:3001/api/users"
[error] open() "/etc/nginx/html/status" failed (2: No such file or directory),
  request: "GET /status HTTP/1.1"
```

Port **3001**, connection refused. And the app says:

```console
$ docker compose logs api
API running on 3000
```

Checked from inside the nginx container, which is the view that matters:

```console
$ docker compose exec nginx sh -c 'curl -s http://api:3000/api/users; curl -s http://api:3001/api/users'
{"ok":true,"time":{"now":"2026-08-19T13:43:39.879Z"}}
curl: (7) Failed to connect to api port 3001 after 1 ms
```

The app is healthy. nginx is knocking on the wrong door. The second error line also explains the 404:
there is no `location /status`, so nginx looked for a file in its own document root.

That is the outage. But "sometimes" was still unexplained — a stack that 502s on every request would not be
called *sometimes* inaccessible. So I kept going.

### Finding the intermittent part

Requests straight to `api:3000` right after `up`, skipping the broken proxy:

```console
t+1 http=500 time=0.027s {"ok":false,"error":"connect ECONNREFUSED 172.19.0.3:5432"}
t+2 http=500 time=0.003s {"ok":false,"error":"connect ECONNREFUSED 172.19.0.3:5432"}
t+3 http=500 time=0.005s {"ok":false,"error":"connect ECONNREFUSED 172.19.0.3:5432"}
t+4 http=200 time=0.020s {"ok":true,"time":{"now":"2026-08-19T13:46:14.179Z"}}
```

A window of 500s after every start, then healthy. That is the `depends_on` race.

Then I broke each dependency:

```console
# Redis stopped
$ docker compose stop redis && curl -w 'http=%{http_code} time=%{time_total}s\n' ...
http=500 time=10.680635s
{"ok":false,"error":"Reached the max retries per request limit (which is 20)."}

# Postgres frozen (docker pause = unresponsive, not dead)
$ docker compose pause postgres && curl -m 15 ...
curl: (28) Operation timed out after 15001 milliseconds
http=000 time=15.001483s
```

Both are worse than they look. A **cache** being down should not fail a read at all, and definitely not
hold the connection for 10.7 seconds. A frozen database gives a request that never ends, because there is
no timeout anywhere between client and Postgres.

That made me look at how the handler gets its connection:

```js
const db = await pool.connect();
const result = await db.query("SELECT NOW()");
db.release();                      // never reached when query() throws
```

If `query()` throws, `release()` never runs and the client never goes back to the pool. `pg` defaults to a
pool of 10, so the tenth failed query is the last request that instance will serve. I wanted proof, not
reasoning, so I wrote [`evidence/pool-leak-repro.js`](./evidence/pool-leak-repro.js) — the same sequence
with `max: 2` — and ran it in the container:

```console
$ docker exec -e DB_HOST=postgres problem3-api-1 node /app/repro.js
req 1: 500 division by zero
   pool: total=1 idle=0 waiting=0
req 2: 500 division by zero
   pool: total=2 idle=0 waiting=0
req 3: calling pool.connect() ...
req 3: STILL WAITING after 5s -- pool exhausted, no timeout configured.
   pool: total=2 idle=0 waiting=1
```

`total=2 idle=0 waiting=1`, forever. **This is the "unreliable".** It also cannot recover on its own,
because no container has a restart policy.

### Checking everything else

```console
$ docker compose exec postgres ls /docker-entrypoint-initdb.d/
total 8                     # empty — postgres/init.sql was never mounted
$ docker compose exec postgres psql -U postgres -tAc 'SHOW max_connections;'
100                         # so its ALTER SYSTEM never applied
$ docker compose exec api id
uid=0(root) gid=0(root)     # running as root
$ docker compose exec api node -p "require('express/package.json').version"
4.22.2                      # package.json says ^4.18.2, and there is no lockfile
$ docker compose exec api node -p "require('pg/package.json').version"
8.23.0                      # package.json says ^8.11.3

$ docker inspect --format '{{.Name}} health={{if .Config.Healthcheck}}yes{{else}}NONE{{end}} restart={{.HostConfig.RestartPolicy.Name}} mem={{.HostConfig.Memory}} log={{.HostConfig.LogConfig.Config}}' $(docker compose ps -q)
/problem3-api-1      health=NONE restart= mem=0 log=map[]
/problem3-nginx-1    health=NONE restart= mem=0 log=map[]
/problem3-postgres-1 health=NONE restart= mem=0 log=map[]
/problem3-redis-1    health=NONE restart= mem=0 log=map[]
```

No healthchecks, no restart policies, no memory limits, and unbounded `json-file` logs on all four.

---

## The 14 findings

| # | Finding | Severity | Symptom |
|---|---|---|---|
| 1 | nginx → `:3001`, app listens on `:3000` | **Critical** | Every `/api/*` is a 502 |
| 2 | Pooled connection leaked on the query error path | **Critical** | API hangs forever after 10 DB errors |
| 3 | No timeouts: pg connect, pg statement, nginx read | **Critical** | Requests that never return |
| 4 | Cache write awaited on the read path, 20 retries | High | 10.7s + HTTP 500 when Redis is down |
| 5 | `depends_on` with no healthcheck condition | High | Window of 500s after every start |
| 6 | No restart policy anywhere | High | Nothing self-heals, including #2 |
| 7 | `/status` is a fake health check, and not routed | High | 404 via the LB, and would say "ok" while broken |
| 8 | `postgres/init.sql` never mounted; its `ALTER SYSTEM` is dead config | Medium | Schema and limits silently absent |
| 9 | Empty `nginx/nginx.conf` committed but not mounted | Medium | Landmine |
| 10 | No lockfile, `npm install` in the Dockerfile | Medium | Builds not reproducible |
| 11 | Container runs as root | Medium | Unnecessary blast radius |
| 12 | Unbounded `json-file` logs | Medium | Fills the host disk |
| 13 | No CPU/memory limits | Medium | One container can OOM the host |
| 14 | Credentials hardcoded in source, `.env` empty and unused | Medium | Cannot rotate, cannot vary by environment |

Plus two smaller ones, also fixed: no graceful shutdown (SIGTERM killed in-flight requests on every
deploy), and no volume on Postgres (`docker compose down` wiped the database).

### 1. Wrong upstream port

`proxy_pass http://api:3001;` versus `app.listen(3000)`. One number written in two places, and they
disagreed.

Changing 3001 to 3000 fixes today's outage and leaves the real defect: the number is still in two places,
so it can drift again. So the port now comes from the environment once, and both sides read it. nginx's
official image runs `envsubst` over `/etc/nginx/templates/*.template` at startup:

```nginx
upstream api_backend {
    server ${API_HOST}:${API_PORT} max_fails=3 fail_timeout=10s;
    keepalive 32;
}
```

```yaml
nginx:  { environment: { API_HOST: ${API_HOST:-api}, API_PORT: ${API_PORT:-3000} } }
api:    { environment: { PORT: ${API_PORT:-3000} } }
```

Verified inside the container:

```console
$ docker compose exec nginx grep -A1 '^upstream' /etc/nginx/conf.d/default.conf
upstream api_backend {
    server api:3000 max_fails=3 fail_timeout=10s;
```

I also added `keepalive 32` with `proxy_http_version 1.1` and `proxy_set_header Connection ""`. All three are
needed together, or nginx opens and closes a TCP connection per request. The usual mistake is setting
`keepalive` and leaving HTTP/1.0, where it silently does nothing.

### 2. The connection leak

This is the one I would want to be judged on, because you cannot see it from outside until it is too late.

```js
// before
const db = await pool.connect();
const result = await db.query("SELECT NOW()");
db.release();                       // skipped on throw

// after
const { rows } = await pool.query("SELECT id, email, created_at FROM app.users ORDER BY id LIMIT 100");
```

`pool.query()` checks a client out and returns it in an internal `finally`, so the leak becomes impossible
instead of merely handled. `try/finally` also works, but when code does manual resource management and gets
it wrong, the right fix is to stop doing manual resource management. You only need an explicit client for a
transaction or a session setting, and this handler has neither.

I have seen this bug three times in production Node services. It always looks the same: fine for weeks, then
a short database hiccup, and after that the service is dead in a way that looks nothing like the hiccup that
caused it. Pool gauges are what catch it.

### 3. No timeouts

Every layer waited forever. All bounded now, with inner timeouts firing before outer ones — otherwise the
outer timeout hides the real error and you lose the diagnosis.

| Layer | Before | After |
|---|---|---|
| pg: get a client from the pool | unbounded | `connectionTimeoutMillis: 3000` |
| pg: server-side execution | unbounded | `statement_timeout: 5000` |
| pg: client-side wait | unbounded | `query_timeout: 5000` |
| redis: connect / command | 10s / unbounded | `connectTimeout: 2000` / `commandTimeout: 1000` |
| nginx → upstream connect / read | 60s / 60s | `2s` / `10s` |
| client → nginx body / header | 60s | `10s` / `10s` |

The failure code changed too: a dependency failure now returns **503**, not 500. 500 means "I am broken",
503 means "try again shortly". That difference is what lets a load balancer and a client library each do the
right thing without guessing.

### 4. The cache on the critical path

```js
// before: a cache write, awaited, blocking the response
await redis.set("last_call", Date.now());
res.json({ ok: true, time: result.rows[0] });
```

Two problems stacked. The write is awaited before responding, and ioredis defaults to
`maxRetriesPerRequest: 20` with growing backoff — that is the measured 10.68 seconds. So the cache being down
did not degrade the service, it took it down slowly.

Now: respond first, cache write is fire-and-forget with `.catch()`, retries capped at 1, and
`enableOfflineQueue: false` so commands fail fast instead of queueing in memory (an unbounded in-memory queue
during a long Redis outage is its own outage waiting to happen). Result: **10,680ms and a 500 → 37ms and a
200.**

A cache is optional by definition. If losing it takes your service down, it is not a cache, it is an
undeclared hard dependency.

### 5, 6, 7. Startup order, self-healing, honest health checks

`depends_on` without a condition waits for the container to *start*, which says nothing about the process
inside. Now every service has a real healthcheck and every edge waits for it, and everything has
`restart: unless-stopped`:

```console
 Container problem3-postgres-1  Healthy
 Container problem3-redis-1     Healthy
 Container problem3-api-1       Healthy
 Container problem3-nginx-1     Started
```

The old `/status` was the more interesting problem: `res.json({ status: "ok" })`, unconditionally. It would
report healthy with the database on fire, and nginx had no route to it anyway. Replaced with two endpoints
that answer two different questions:

- **`/healthz`** — liveness. Is this process alive? No dependency checks, on purpose. A liveness probe that
  fails when the database blips gets the container killed during an outage it could have survived, turning a
  dependency incident into a crash loop.
- **`/readyz`** — readiness. Should this instance get traffic? Checks Postgres, and reports Redis without
  being disqualified by it, because without its cache the service is *degraded*, not broken.

```console
$ curl -s localhost:8080/readyz
{"ready":true,"degraded":false,"checks":{"postgres":"up","redis":"up"}}
# with redis stopped
{"ready":true,"degraded":true,"checks":{"postgres":"up","redis":"down: Stream isn't writeable..."}}
```

Getting liveness and readiness the wrong way round is one of the most common ways to make an outage worse.

### 8, 9. Config that never loaded

`postgres/init.sql` was not mounted, so it never ran. And its content would not have worked anyway:
`ALTER SYSTEM SET max_connections = 20` needs a server restart, which initdb does not give it. A file that
never ran, containing a statement that would not have worked. `20` is also too low — below `DB_POOL_MAX` ×
replicas plus the superuser reservation — so if it had applied, it would have caused its own outage.

Limits now live in compose as server flags, next to the pool size they must agree with:

```yaml
command: [postgres, -c, max_connections=60, -c, log_min_duration_statement=250ms]
```

with the rule written in `.env.example`: `replicas × DB_POOL_MAX < 60`. That constraint is invisible until
it bites, so it belongs next to both numbers.

`init.sql` now creates the schema the app reads. Which is the other point: the endpoint is called
`/api/users` and ran `SELECT NOW()`. That passes against a completely empty database, so it could return 200
with no application schema at all.

The empty `nginx/nginx.conf` is the smallest finding and I still fixed it. Zero bytes, committed, not
mounted, harmless today. The day someone adds it to the volume list by copying the line above it, nginx
starts with an empty config and serves nothing. A zero-byte config file in a repo is a trap with a long fuse.

### 10-14. The rest

| Finding | Fix |
|---|---|
| No lockfile, `npm install` | Added `package-lock.json`, `npm ci --omit=dev`, deps + runtime stages so no npm cache ships, `NODE_ENV=production`, `HEALTHCHECK`. Image 139MB |
| Runs as root | `USER node` (uid 1000) |
| Unbounded logs | `max-size: 10m`, `max-file: 3` via a YAML anchor, so it is one place to change |
| No resource limits | CPU and memory ceiling on every service |
| Hardcoded credentials | All from environment, app exits at boot with a clear message if one is missing, dev defaults in compose, `.env` gitignored with a committed `.env.example` |
| No graceful shutdown | SIGTERM drains, then closes pool and Redis, with a hard deadline |

Three notes on those:

- The drift was real: `^4.18.2` had become `4.22.2` and `^8.11.3` had become `8.23.0`. Four minor versions in
  a service nobody rebuilt on purpose, which means the image you tested is not the image you shipped. I kept
  caret ranges in `package.json` — the lockfile is the reproducibility mechanism and `npm ci` enforces it.
- Unbounded `json-file` logs fill the host disk, which is exactly [Problem 2](../problem2/SOLUTION.md), and
  the reason container platforms fill disks so reliably.
- `server.keepAliveTimeout` is 65s and must be **larger** than nginx's upstream `keepalive_timeout` of 60s.
  If Node closes a pooled connection at the moment nginx reuses it, you get random 502s that match nothing
  and cannot be reproduced on demand.

---

## Files changed

```
 .env                          -> .env.example (+ .gitignore)
 docker-compose.yml            rewritten
 nginx/nginx.conf              deleted (empty, unmounted, a landmine)
 nginx/conf.d/default.conf     -> nginx/templates/default.conf.template
 api/Dockerfile                multi-stage, npm ci, non-root, healthcheck
 api/package-lock.json         new
 api/src/index.js              rewritten
 postgres/init.sql             now mounted; real schema; ALTER SYSTEM removed
 smoke-test.sh                 new — asserts every fix
 evidence/pool-leak-repro.js   new — proof of finding #2
```

Git history for this directory is two commits on purpose — skeleton imported verbatim, then the fix — so the
diff between them is a readable before/after.

## Verification

```console
$ ./smoke-test.sh
1. The API is reachable through nginx
  PASS  GET /api/users -> 200 in 0.024085s
  PASS  response body has ok:true
2. Health endpoints answer through the load balancer
  PASS  GET /healthz -> 200 in 0.001778s
  PASS  GET /readyz -> 200 in 0.003538s
3. Losing the cache degrades the service, it does not break it
  PASS  redis down: still 200, 37ms
  PASS  /readyz reports degraded rather than lying
4. An unresponsive database fails fast instead of hanging
  PASS  GET /api/users, postgres frozen -> 503 in 5.006007s
5. Repeated database failures do not exhaust the connection pool
  PASS  GET /api/users after 15 failures -> 200 in 0.025157s
6. Every container declares a healthcheck and a restart policy
  PASS  problem3-api-1: healthcheck=yes restart=unless-stopped log-max-size=10m
  PASS  ... same for nginx, postgres, redis
7. The API container does not run as root
  PASS  api runs as uid 1000
8. The API is not reachable except through nginx
  PASS  api has no host port binding; only nginx is exposed

Result
  14 passed, 0 failed
```

Step 5 matters most: 15 requests against a frozen database, unfreeze, next request succeeds in 25ms. Before
the fix, request 11 onwards hung forever and only a restart helped.

Step 4 returns in 5.0s, not ~3s, and that is correct — the pool already had an open connection, so
`query_timeout` fires rather than `connectionTimeoutMillis`. Bounded and explainable. The old behaviour was
"never".

---

## Monitoring I would add

All 14 findings were invisible to the operator. Someone had to complain before anyone knew. That is the real
defect. Each signal below maps to a finding, because a monitoring list not derived from real incidents is
just a list of metrics.

| Signal | Alert on | Catches |
|---|---|---|
| nginx `upstream_status` by code | any sustained 502/504 | #1, immediately |
| HTTP 5xx rate | > 1% for 5 min | #1, #2, #4 |
| Synthetic probe of `/api/users` through the LB | 2 failures in a row | #1 — the only check that tests the whole path |
| **pg pool `total` / `idle` / `waiting`** | `waiting > 0` for 1 min | **#2.** `idle` going to zero while `total` sits at max is the leak's signature, visible hours before users notice |
| `pg_stat_activity` vs `max_connections` | > 70% | #2, #8 |
| Request duration p99 by route | > 1s | #3, #4 |
| Redis error rate | any sustained | #4, and it should be *degraded*, not an outage |
| `readyz` failures per instance | unready > 1 min | #5, #7 |
| Container restarts / OOM kills | >3 in 5 min / any | #6, #13 |
| Host disk and inode usage | > 80% | #12 |

Two things beyond metrics. **Structured logs** — the app now emits JSON with a `request_id` that nginx
generates and passes through, so one request can be traced across both logs. Grepping unstructured text
across four containers during an incident is how a 15-minute diagnosis becomes two hours. And **the pool
gauges specifically**, because `waiting` is the one number that makes finding #2 obvious, and almost nobody
exports it.

## How I would prevent this in production

Ordered by how much each would actually have helped.

1. **Run the smoke test in CI on every PR.** One assertion that `/api/users` returns 200 through nginx catches
   finding #1 — a total outage from a one-character mismatch — before it can merge. Everything else is
   secondary to having one test that exercises the real request path.
2. **Test the failure modes, not just the happy path.** Steps 3, 4 and 5 stop a dependency, freeze one, and
   hammer a broken one. Those are the tests that found the interesting bugs, and the ones nobody writes. Three
   lines of bash each.
3. **Do not write the topology twice.** Finding #1 exists because a port was typed in two files. In production
   this is ECS or Kubernetes, where the address comes from service discovery and there is no second place to
   get it wrong.
4. **Use managed data stores.** Containerised Postgres and Redis in production means you own backups, failover,
   patching and upgrades. RDS and ElastiCache means you own a Terraform file.
5. **Add platform guardrails.** Trivy and Hadolint in CI would have flagged root user and the missing lockfile
   automatically. #10 and #11 needed a human to notice, and humans stop noticing.
6. **Practise it.** All of this is theory until someone stops Redis in staging on a Tuesday and watches the
   dashboards. A quarterly manual run tells you whether the *alerts* work, which `smoke-test.sh` does not.

## What I deliberately did not do

- **No retries inside the app.** With bounded timeouts and a 503, retries belong in the client or the LB.
  App-level retries on top of nginx's `proxy_next_upstream` multiply load exactly when the system is already
  struggling.
- **No circuit breaker, no pgBouncer.** Right patterns at scale, premature here. pgBouncer becomes necessary
  when replicas × pool size approaches `max_connections`, the arithmetic now in `.env.example`.
- **No app restructuring.** No router modules, no DI, no ORM. The brief is to stabilise the system; a big
  refactor would bury 14 real fixes in noise.
- **I did change the `/api/users` query** to a real read — the one place I went past "fix what is broken". I
  think it is justified, but it is a judgement call and I would rather flag it than have it found.
- **Image tags pinned to a minor, not a digest.** Digest pinning is correct for production but needs Renovate to
  not become a liability. Noting it rather than half-doing it.
