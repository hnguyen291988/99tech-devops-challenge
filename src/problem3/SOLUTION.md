# Problem 3 — Debugging issues within system

> The brief is in [README.md](./README.md) (it's headed "Problem 4" upstream — same task).
> Everything below was reproduced locally on Docker 24.0.2 / Compose v2.18.1. Every command
> output quoted here is real, copied from the terminal, not reconstructed.

## Short version

The report was "the API is unreliable and sometimes inaccessible". Those are two different faults
and they have two different causes:

**Inaccessible** — `nginx` proxies to `api:3001`. The app listens on `3000`. Every request to
`/api/*` has always returned `502`, and always will. Nothing intermittent about it.

**Unreliable** — three separate defects, each of which turns a transient blip into a lasting
failure:

- the `/api/users` handler leaks a pooled Postgres connection on every failed query, so ten
  failures permanently hang the API until someone restarts it;
- there are no timeouts anywhere in the stack, so a slow dependency means a request that never
  returns;
- the handler awaits a Redis cache write on a read path, with `ioredis`' default of 20 retries, so
  a cache outage turns a 20ms read into a 10-second failure.

Fourteen findings in total. The first seven are live faults, the rest are the ones that were
going to cause the next incident. All fixed in this directory, and there's a
[`smoke-test.sh`](./smoke-test.sh) that asserts each fix so they can't quietly come back.

---

## How I diagnosed it

I started the stack as given and looked, rather than reading the code first. Reading first biases
you toward the bug you expect.

```console
$ docker compose up --build -d
$ docker compose ps -a
NAME                  IMAGE          SERVICE    STATUS
problem3-api-1        problem3-api   api        Up 8 seconds
problem3-nginx-1      nginx:1.25     nginx      Up 8 seconds
problem3-postgres-1   postgres:15    postgres   Up 9 seconds
problem3-redis-1      redis:7        redis      Up 9 seconds
```

All four containers up, nothing crash-looping. So this is not a startup failure — it's a
request-path failure, which narrows things considerably.

```console
$ curl -si http://localhost:8080/ | head -1
HTTP/1.1 200 OK

$ curl -si http://localhost:8080/api/users | head -1
HTTP/1.1 502 Bad Gateway

$ curl -so /dev/null -w '%{http_code}\n' http://localhost:8080/status
404
```

`/` works, so nginx is alive and serving. `/api/` is a 502, which is nginx telling me it couldn't
reach the thing behind it. That's a proxy-to-upstream problem, and nginx will have said why:

```console
$ docker compose logs nginx | grep -i error
[error] 29#29: *2 connect() failed (111: Connection refused) while connecting to upstream,
  client: 172.18.0.1, request: "GET /api/users HTTP/1.1",
  upstream: "http://172.18.0.4:3001/api/users", host: "localhost:8080"
[error] 31#31: *4 open() "/etc/nginx/html/status" failed (2: No such file or directory),
  request: "GET /status HTTP/1.1"
```

There it is, in the first line I read. `Connection refused` on port **3001**. And the app says:

```console
$ docker compose logs api
API running on 3000
```

Confirmed from inside the nginx container, which is the only vantage point that actually matters:

```console
$ docker compose exec nginx sh -c 'curl -s http://api:3000/api/users; curl -s http://api:3001/api/users'
{"ok":true,"time":{"now":"2026-08-19T13:43:39.879Z"}}
curl: (7) Failed to connect to api port 3001 after 1 ms: Couldn't connect to server
```

The app is healthy. nginx is knocking on the wrong door.

The second error line is the `/status` 404 explaining itself too: nginx has no `location /status`,
so it fell through to serving files from its own document root and didn't find one.

That's the outage. But "sometimes" was still unexplained, so I kept going — a stack that produces a
502 on every single request wouldn't be described as *sometimes* inaccessible. Something else is
making it intermittent.

### Finding the intermittent half

I fired requests straight at `api:3000` immediately after `up`, bypassing the broken proxy:

```console
t+1 http=500 time=0.027s {"ok":false,"error":"connect ECONNREFUSED 172.19.0.3:5432"}
t+2 http=500 time=0.003s {"ok":false,"error":"connect ECONNREFUSED 172.19.0.3:5432"}
t+3 http=500 time=0.005s {"ok":false,"error":"connect ECONNREFUSED 172.19.0.3:5432"}
t+4 http=200 time=0.020s {"ok":true,"time":{"now":"2026-08-19T13:46:14.179Z"}}
t+5 http=200 time=0.004s {"ok":true,...}
```

A window of 500s after every start, then healthy. That's the `depends_on` race.

Then I broke each dependency in turn, which is where the interesting results were:

```console
# Redis stopped
$ docker compose stop redis && curl -w 'http=%{http_code} time=%{time_total}s\n' ...
http=500 time=10.680635s
{"ok":false,"error":"Reached the max retries per request limit (which is 20).
  Refer to \"maxRetriesPerRequest\" option for details."}

# Postgres frozen (docker pause — simulates an unresponsive DB, not a dead one)
$ docker compose pause postgres && curl -m 15 ...
curl: (28) Operation timed out after 15001 milliseconds with 0 bytes received
http=000 time=15.001483s
```

Both of those are worse than they look. A **cache** being down should not fail a read at all, let
alone hold the connection for ten and a half seconds. And a frozen database produces a request that
simply never ends — there's no timeout anywhere between the client and Postgres.

That last one made me look at how the handler acquires its connection:

```js
const db = await pool.connect();
const result = await db.query("SELECT NOW()");
db.release();                      // <-- unreachable when query() throws
```

If `query()` throws, `release()` never runs and the client is never returned to the pool. `pg`'s
default pool size is 10, so the tenth failed query is the last request that API instance will ever
serve. I wanted to be sure rather than reason about it, so I wrote
[`evidence/pool-leak-repro.js`](./evidence/pool-leak-repro.js) — the same
connect/query/release sequence with `max: 2` — and ran it inside the container:

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

`total=2, idle=0, waiting=1`, permanently. Two clients checked out and never returned, and a third
request queued behind them for as long as anyone cares to wait. **This is the "unreliable".** It's
also unrecoverable without a restart, and there's no restart policy on any container, so nothing
brings it back on its own.

### Sweeping for the rest

```console
$ docker compose exec postgres ls -la /docker-entrypoint-initdb.d/
total 8            # empty — postgres/init.sql was never mounted
$ docker compose exec postgres psql -U postgres -tAc 'SHOW max_connections;'
100                # so its ALTER SYSTEM never applied

$ docker compose exec api id
uid=0(root) gid=0(root)

$ docker compose exec api node -p "require('express/package.json').version"
4.22.2             # package.json says ^4.18.2, and there is no lockfile
$ docker compose exec api node -p "require('pg/package.json').version"
8.23.0             # package.json says ^8.11.3

$ docker inspect --format '{{.Name}} healthcheck={{if .Config.Healthcheck}}yes{{else}}NONE{{end}} restart={{.HostConfig.RestartPolicy.Name}} mem={{.HostConfig.Memory}}' $(docker compose ps -q)
/problem3-api-1      healthcheck=NONE restart= mem=0
/problem3-nginx-1    healthcheck=NONE restart= mem=0
/problem3-postgres-1 healthcheck=NONE restart= mem=0
/problem3-redis-1    healthcheck=NONE restart= mem=0

$ docker inspect --format '{{.HostConfig.LogConfig.Type}} {{.HostConfig.LogConfig.Config}}' $(docker compose ps -q)
json-file map[]     # x4 — no max-size, no max-file
```

---

## The findings

| # | Finding | Severity | Symptom it produced |
|---|---|---|---|
| 1 | nginx proxies to `:3001`, the app listens on `:3000` | **Critical** | Every `/api/*` request is a 502 |
| 2 | Pooled connection leaked on the query error path | **Critical** | API hangs permanently after 10 DB errors |
| 3 | No timeouts: pg connect, pg statement, nginx proxy read | **Critical** | Requests that never return |
| 4 | Cache write awaited on the read path, 20 retries | High | 10.7s + HTTP 500 when Redis is down |
| 5 | `depends_on` with no healthcheck condition | High | A window of 500s after every start |
| 6 | No restart policy on any service | High | Nothing self-heals, including #2 |
| 7 | `/status` is a fake health check, and unroutable | High | 404 via the LB; would report "ok" while broken |
| 8 | `postgres/init.sql` never mounted; its `ALTER SYSTEM` is dead config | Medium | Schema/limits silently absent |
| 9 | Empty `nginx/nginx.conf` committed but not mounted | Medium | Latent landmine |
| 10 | No lockfile, `npm install` in the Dockerfile | Medium | Builds aren't reproducible |
| 11 | Container runs as root | Medium | Unnecessary blast radius |
| 12 | Unbounded `json-file` container logs | Medium | Fills the host disk |
| 13 | No CPU/memory limits | Medium | One container can OOM the host |
| 14 | Credentials hardcoded in source; `.env` empty and unused | Medium | Can't rotate, can't vary by environment |

Plus two smaller things: no graceful shutdown (SIGTERM kills in-flight requests on every deploy),
and no volume on Postgres (`docker compose down` wipes the database). Both fixed.

---

### 1. The wrong upstream port

`nginx/conf.d/default.conf` said `proxy_pass http://api:3001;`, the app called
`app.listen(3000)`. Two places holding one number, and they disagreed.

Changing `3001` to `3000` fixes today's outage and leaves the actual defect in place — the number is
still written twice, so it can still drift. So the port now comes from the environment, once, and is
consumed by both sides. nginx's official image runs `envsubst` over
`/etc/nginx/templates/*.template` at startup, which makes this straightforward:

```nginx
upstream api_backend {
    server ${API_HOST}:${API_PORT} max_fails=3 fail_timeout=10s;
    keepalive 32;
}
```

```yaml
nginx:
  environment:
    API_HOST: ${API_HOST:-api}
    API_PORT: ${API_PORT:-3000}
api:
  environment:
    PORT: ${API_PORT:-3000}
```

Verified rendered inside the container:

```console
$ docker compose exec nginx grep -A1 '^upstream' /etc/nginx/conf.d/default.conf
upstream api_backend {
    server api:3000 max_fails=3 fail_timeout=10s;
```

I also added `keepalive 32` with `proxy_http_version 1.1` and `proxy_set_header Connection ""`.
Without those three together, nginx opens and closes a TCP connection per proxied request, which is
wasted CPU at low volume and ephemeral-port exhaustion at high volume. All three are required — the
usual mistake is setting `keepalive` and leaving HTTP/1.0, where it silently does nothing.

### 2. The connection leak

This is the one I'd want to be judged on, because it's the one that isn't visible from the outside
until it's too late.

```js
// before
const db = await pool.connect();
const result = await db.query("SELECT NOW()");
db.release();                       // skipped on throw
```

```js
// after
const { rows } = await pool.query("SELECT id, email, created_at FROM app.users ORDER BY id LIMIT 100");
```

`pool.query()` checks a client out and returns it in an internal `finally`, so the leak is
structurally impossible rather than merely handled. `try/finally` around the original shape would
also have worked, but the correct fix for "the code does manual resource management and got it
wrong" is to stop doing manual resource management. The only reason to hold a client explicitly is a
transaction or a session-scoped setting, and this handler has neither.

I've seen this exact bug three times in production Node services. It always presents the same way:
fine for weeks, then a brief database hiccup, and afterwards the service is dead in a way that
looks nothing like the hiccup that caused it — which is why the connection between the two gets
missed. Pool gauges on a dashboard are what catch it; see the monitoring section.

### 3. No timeouts

Every layer had an unbounded wait. All of them are now bounded, and the numbers are chosen so that
the inner timeout always fires before the outer one — otherwise the outer timeout hides the inner
one's error and you lose the diagnosis.

| Layer | Before | After |
|---|---|---|
| pg: acquire a client from the pool | unbounded | `connectionTimeoutMillis: 3000` |
| pg: server-side statement execution | unbounded | `statement_timeout: 5000` |
| pg: client-side query wait | unbounded | `query_timeout: 5000` |
| redis: connect | 10s default | `connectTimeout: 2000` |
| redis: command | unbounded | `commandTimeout: 1000` |
| nginx → upstream connect | 60s default | `proxy_connect_timeout 2s` |
| nginx → upstream read | 60s default | `proxy_read_timeout 10s` |
| client → nginx body/header | 60s default | `client_body_timeout 10s` |

The failure mode also changed: a dependency failure now returns **503**, not 500. A 500 means "I'm
broken", a 503 means "try again shortly" — and that distinction is what lets a load balancer and a
client library each do the right thing without guessing.

### 4. The cache on the critical path

```js
// before — a cache write, awaited, blocking the response
await redis.set("last_call", Date.now());
res.json({ ok: true, time: result.rows[0] });
```

Two problems stacked. The write is awaited before responding, and `ioredis` defaults to
`maxRetriesPerRequest: 20` with escalating backoff — which is where the measured 10.68 seconds came
from. So a cache being unavailable didn't degrade the service, it took it down, slowly.

Now: the response is sent first, the cache write is fire-and-forget with a `.catch()`, retries are
capped at 1, and `enableOfflineQueue: false` makes commands fail immediately while Redis is
unreachable instead of queueing in memory (which is its own slow-motion outage — an unbounded
in-memory queue during a long Redis outage is a heap exhaustion waiting to happen).

Measured after the fix:

```console
3. Losing the cache degrades the service, it does not break it
  PASS  redis down: still 200, 37ms
  PASS  /readyz reports degraded rather than lying
```

10,680ms and a 500 → 37ms and a 200. A cache is by definition optional; if losing it takes your
service down, it isn't a cache, it's an undeclared hard dependency.

### 5, 6, 7. Startup ordering, self-healing, and honest health checks

`depends_on` without a condition waits for the container to *start*, which says nothing about
whether the process inside is ready. Every service now has a real healthcheck and every dependency
edge waits for it:

```yaml
api:
  depends_on:
    postgres: { condition: service_healthy }
    redis:    { condition: service_healthy }
```

```console
 Container problem3-postgres-1  Healthy
 Container problem3-redis-1     Healthy
 Container problem3-api-1       Starting
 Container problem3-api-1       Healthy
 Container problem3-nginx-1     Started
```

That ordering is the fix for the boot window of 500s. `restart: unless-stopped` everywhere is the
fix for nothing self-healing.

On health checks, the original `/status` was the more interesting problem:

```js
app.get("/status", (req, res) => res.json({ status: "ok" }));
```

It returns `ok` unconditionally. It would have reported healthy with the database on fire — and it
wasn't routed in nginx, so nothing could reach it anyway. Replaced with two endpoints that answer
two genuinely different questions:

- **`/healthz`** — liveness. Is this process alive? No dependency checks, deliberately. A liveness
  probe that fails when the database blips gets the container killed during an outage it could have
  ridden out, which converts a dependency incident into a crash loop.
- **`/readyz`** — readiness. Should this instance get traffic? Checks Postgres, and reports Redis
  without being disqualified by it, because the service is *degraded* without its cache, not broken:

```console
$ curl -s localhost:8080/readyz
{"ready":true,"degraded":false,"checks":{"postgres":"up","redis":"up"}}

# with redis stopped
{"ready":true,"degraded":true,"checks":{"postgres":"up","redis":"down: Stream isn't writeable..."}}
```

Getting liveness and readiness the wrong way round is one of the most common ways to make an outage
worse, so it's worth being explicit about which is which.

### 8, 9. Config that was never loaded

`postgres/init.sql` wasn't mounted, so it never ran:

```console
$ docker compose exec postgres ls /docker-entrypoint-initdb.d/
total 8            # empty
```

And its content wouldn't have worked anyway. `ALTER SYSTEM SET max_connections = 20` needs a server
restart to take effect, and the initdb phase doesn't give it one. So the setting was doubly
inoperative — a file that never ran containing a statement that wouldn't have worked. `20` is also
too low: it's below `DB_POOL_MAX` × replicas plus the superuser reservation, so had it somehow
applied, it would have caused its own outage.

Connection limits now live in `docker-compose.yml` as server flags, right next to the pool size
they have to agree with:

```yaml
command: [postgres, -c, max_connections=60, -c, log_min_duration_statement=250ms]
```

with the arithmetic written down in `.env.example`: `replicas × DB_POOL_MAX < 60`. That constraint
is invisible until it bites, so it belongs in a comment next to both numbers.

`init.sql` now creates the schema the app actually reads. Which is the other thing worth mentioning:
the endpoint is called `/api/users` and ran `SELECT NOW()`. That query passes against a completely
empty database, so the handler could return `200` with no application schema present at all. A
health-relevant endpoint should touch the thing it claims to serve — it now selects from
`app.users`, so a missing or broken schema shows up as a failure instead of a cheerful timestamp.

The empty `nginx/nginx.conf` is the smallest finding and the one I'd still fix. It's committed,
zero bytes, and not mounted — so it does nothing today. The day someone adds it to the volume list
by pattern-matching on the `conf.d` line above it, nginx starts with an empty configuration and
serves nothing. I deleted it. A zero-byte config file in a repo is a trap with a long fuse.

### 10-14. The rest

**Dockerfile** — `npm install` with no lockfile meant the image resolved different dependency
versions on different days. `^4.18.2` had quietly become `4.22.2`; `^8.11.3` had become `8.23.0`.
That's four minor versions of drift in a service nobody had rebuilt on purpose, and it means the
image you tested is not the image you shipped. Added `package-lock.json`, switched to
`npm ci --omit=dev`, split into a deps stage and a runtime stage so no npm cache ships, set
`NODE_ENV=production`, added a `HEALTHCHECK`, and switched to the `node` user (uid 1000) instead of
root. Final image is 139MB.

I kept the caret ranges in `package.json` rather than pinning exact versions. The lockfile is the
reproducibility mechanism and `npm ci` is what enforces it; pinning in both places just means
Dependabot has two files to edit.

**Logging** — `json-file` with no `max-size` grows until the host disk is full. Which is exactly the
incident in [Problem 2](../problem2/SOLUTION.md), and it's the reason a container platform fills
disks so reliably. Now capped at 10MB × 3 per service via a YAML anchor, so it's one place to change.

**Resource limits** — every service has a CPU and memory ceiling. Without them, one runaway
container takes the host, and the OOM killer picks its victim by memory footprint, which usually
means Postgres — possibly mid-write.

**Credentials** — were hardcoded in `index.js` (`user: "postgres", password: "postgres"`) while
`.env` sat empty and unreferenced. Now every value comes from the environment, the app exits at boot
with a clear message if one is missing rather than failing on the first request, compose supplies
dev defaults so the stack still comes up with no `.env` at all, and `.env` is gitignored with a
committed `.env.example`. In a deployed environment these come from Secrets Manager or SSM and are
injected as container secrets.

**Graceful shutdown** — SIGTERM previously killed the process with requests in flight, so every
deploy dropped connections. Now it stops accepting, drains, closes the pool and Redis, and has a
hard deadline so a stuck drain still exits cleanly:

```console
{"level":"info","time":"2026-08-19T14:03:58.296Z","msg":"SIGTERM received, draining"}
{"level":"info","time":"2026-08-19T14:03:58.301Z","msg":"drained cleanly"}
```

One detail there that causes genuinely baffling bugs: `server.keepAliveTimeout` is set to 65s,
which must exceed nginx's upstream `keepalive_timeout` of 60s. If Node closes a pooled connection at
the moment nginx reuses it, you get sporadic 502s that don't correlate with anything and can't be
reproduced on demand.

---

## What changed

```
 src/problem3/.env                          -> .env.example  (+ .gitignore)
 src/problem3/docker-compose.yml            rewritten
 src/problem3/nginx/nginx.conf              deleted (empty, unmounted, a landmine)
 src/problem3/nginx/conf.d/default.conf     -> nginx/templates/default.conf.template
 src/problem3/api/Dockerfile                multi-stage, npm ci, non-root, healthcheck
 src/problem3/api/package.json              + engines, private, start script
 src/problem3/api/package-lock.json         new — reproducible builds
 src/problem3/api/src/index.js              rewritten
 src/problem3/postgres/init.sql             now mounted; real schema; ALTER SYSTEM removed
 src/problem3/smoke-test.sh                 new — asserts every fix
 src/problem3/evidence/pool-leak-repro.js   new — standalone proof of finding #2
```

The `git log` for this directory is deliberately two commits — the skeleton imported verbatim, then
the fix — so `git diff` between them is a readable before/after.

## Verification

```console
$ ./smoke-test.sh

1. The API is reachable through nginx
  PASS  GET /api/users -> 200 in 0.024085s
  PASS  response body has ok:true
{"ok":true,"count":3,"users":[{"id":"1","email":"ada@example.com",...

2. Health endpoints answer through the load balancer
  PASS  GET /healthz -> 200 in 0.001778s
  PASS  GET /readyz -> 200 in 0.003538s
{"ready":true,"degraded":false,"checks":{"postgres":"up","redis":"up"}}

3. Losing the cache degrades the service, it does not break it
  PASS  redis down: still 200, 37ms
  PASS  /readyz reports degraded rather than lying

4. An unresponsive database fails fast instead of hanging
  PASS  GET /api/users, postgres frozen -> 503 in 5.006007s

5. Repeated database failures do not exhaust the connection pool
  PASS  GET /api/users after 15 failures -> 200 in 0.025157s

6. Every container declares a healthcheck and a restart policy
  PASS  problem3-api-1: healthcheck=yes restart=unless-stopped log-max-size=10m
  PASS  problem3-nginx-1: healthcheck=yes restart=unless-stopped log-max-size=10m
  PASS  problem3-postgres-1: healthcheck=yes restart=unless-stopped log-max-size=10m
  PASS  problem3-redis-1: healthcheck=yes restart=unless-stopped log-max-size=10m

7. The API container does not run as root
  PASS  api runs as uid 1000

8. The API is not reachable except through nginx
  PASS  api has no host port binding; only nginx is exposed

Result
  14 passed, 0 failed
```

Step 5 is the one I care about most. Fifteen requests against a frozen database, unfreeze, and the
next request succeeds in 25ms. Before the fix, request eleven onwards would have hung forever and
the only cure was a restart.

Step 4 returns in 5.0s rather than ~3s, and that's correct: the pool already held an established
connection, so it's `query_timeout` that fires, not `connectionTimeoutMillis`. Bounded and
explainable, which is the whole point — the previous behaviour was "never".

---

## Monitoring and alerts I'd add

The findings above were all invisible to the operator. Someone had to complain before anyone knew.
That's the real defect, and these are the specific signals that would have caught each one — I've
tied them back deliberately, because a monitoring list that isn't derived from actual incidents is
just a list of metrics.

**Would have caught the outage in minutes**

| Signal | Alert on | Catches |
|---|---|---|
| nginx `upstream_status` by code | any sustained 502/504 | #1, immediately and unambiguously |
| HTTP 5xx rate as a share of requests | > 1% for 5 min | #1, #2, #4 |
| Synthetic probe of `/api/users` through the LB | 2 consecutive failures | #1 — the only check that exercises the whole path end to end |
| `readyz` failures per instance | any instance unready > 1 min | #5, #7 |

**Would have caught the leak before it became an outage**

| Signal | Alert on | Catches |
|---|---|---|
| **pg pool `totalCount` / `idleCount` / `waitingCount`** | `waitingCount > 0` for 1 min | #2. `idleCount` trending to zero while `totalCount` sits at max is the leak's signature, and it's visible hours before the first user notices |
| Postgres `pg_stat_activity` count vs `max_connections` | > 70% | #2, #8 |
| Request duration p99 by route | > 1s | #3, #4 |
| Redis command error rate + connection state | any sustained | #4, and it should be *degraded*, not an outage |

**Would have caught the rest**

Container restart count (> 3 in 5 min), OOM-kill events (any — #13), host disk and inode usage
(> 80% — #12), image age and drift between the running digest and the latest built (#10),
Postgres slow queries via `log_min_duration_statement`, which is now on at 250ms.

Two things I'd insist on beyond the metrics themselves. **Structured logs** — the app now emits
JSON with a `request_id` that nginx generates and passes through, so a single request can be traced
across both logs; grepping unstructured text across four containers during an incident is how
15-minute diagnoses become 2-hour ones. And **the pool gauges specifically**, because
`waitingCount` is the one number that makes finding #2 obvious, and almost nobody exports it.

---

## How I'd prevent this in production

Ordered by how much each would actually have helped, which is not the order these lists usually
come in.

**1. Run the smoke test in CI on every pull request.** `smoke-test.sh` boots the stack and asserts
that `/api/users` returns 200 through nginx. That single assertion catches finding #1 — a total
outage caused by a one-character mismatch — before it can merge. Everything else on this list is
secondary to having one test that exercises the real request path. I'd add contract tests per
service too, but the integration smoke test is what would have caught this.

**2. Make the failure modes part of the test suite, not just the happy path.** Steps 3, 4 and 5
above stop a dependency, freeze one, and hammer a broken one. Those are the tests that found the
interesting bugs, and they're the ones nobody writes. This is fault injection at the cheapest
possible scale — three lines of bash each — and it's the difference between "the tests pass" and
"we know what happens when Redis dies".

**3. Don't hand-write the topology twice.** Finding #1 exists because a port number was typed in two
files. In production this is ECS or Kubernetes, where the service address comes from service
discovery and there's no second place to get it wrong. The templating fix here is the same idea
scaled down.

**4. Use managed data stores.** Containerised Postgres and Redis in production means you own
backups, failover, patching and version upgrades. RDS/Aurora and ElastiCache means you own a
Terraform file. Finding #8's `max_connections` problem largely evaporates when it's a parameter
group under version control.

**5. Add the platform-level guardrails.** Container image scanning (Trivy) and a Dockerfile linter
(Hadolint) in CI would have flagged root-user and the missing lockfile automatically — findings #10
and #11 needed a human to notice, and that's the kind of thing humans stop noticing. Digest-pinned
base images with Renovate raising the bumps. A non-root and resource-limits policy enforced at
admission rather than reviewed by eye.

**6. Ship logs and metrics off the host.** With the app already emitting structured JSON, this is
mostly a collector config. It also removes the disk-fill failure mode in #12 entirely rather than
merely capping it.

**7. Rehearse it.** Everything above is theory until someone stops Redis in staging on a Tuesday
afternoon and watches what the dashboards say. The tests in `smoke-test.sh` are that rehearsal,
automated — but a quarterly manual one with the on-call rotation is what tells you whether the
*alerts* work, which is a different question from whether the code works.

---

## What I deliberately didn't do

- **No retry-with-backoff inside the app.** With bounded timeouts and a 503, retries belong in the
  client or the LB. Adding app-level retries on top of nginx's `proxy_next_upstream` gives you
  multiplied load exactly when the system is already struggling.
- **No circuit breaker.** It's the right pattern at scale and it's premature here. The
  fail-fast timeouts get most of the benefit; I'd add one when there are enough downstreams for
  cascading failure to be a real risk.
- **No connection pooler (pgBouncer).** At this size the app-side pool is sufficient. It becomes
  necessary when replica count × pool size approaches `max_connections`, which is the arithmetic now
  written down in `.env.example`.
- **I didn't restructure the app.** No router modules, no DI, no ORM. The brief is to stabilise the
  system, and a large refactor would bury the fourteen actual fixes in noise and make this diff
  unreviewable.
- **I changed the `/api/users` query** from `SELECT NOW()` to a real read of `app.users`, which is
  the one place I went slightly beyond "fix what's broken". I think it's justified — it's what
  proves `init.sql` is now mounted, and an endpoint that can return 200 against an empty database
  is a health signal that lies. But it is a judgement call and I'd rather flag it than have it
  found.
- **Image tags are pinned to a minor, not a digest.** Digest pinning is correct for production and
  needs an automated bump process (Renovate) to not become a security liability. Noting it rather
  than half-doing it.
