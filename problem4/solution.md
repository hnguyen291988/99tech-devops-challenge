# Problem 4 — Debugging Issues Within System

## Setup

```bash
docker compose up --build
# App available at http://localhost:8080
```

---

## Problems Found

### Bug 1 — depends_on Does Not Wait for Readiness

**Severity: Critical**

Docker Compose depends_on only waits for the container to start, not for the service inside it to be ready. PostgreSQL and Redis take several seconds to initialise. The API starts immediately, attempts to connect, and crashes.

**How diagnosed:**
```bash
docker compose up --build
docker compose logs api
# connection refused errors to postgres/redis on startup
# container exiting with code 1 immediately
```

---

### Bug 2 — No Restart Policy

**Severity: High**

No restart policy is set. If the API crashes, Docker leaves it stopped with no self-healing.

**How diagnosed:**
```bash
docker compose ps
# STATUS shows "Exited" for api container
```

---

### Bug 3 — Postgres Data Is Not Persisted

**Severity: High**

No named volume is configured. All data lives inside the container writable layer. Every docker compose down wipes the database completely.

**How diagnosed:**
```bash
docker compose down && docker compose up -d
# All data gone on every restart
```

---

### Bug 4 — No Database Name or User Configured

**Severity: High**

postgres only sets POSTGRES_PASSWORD. The API env only sets DB_HOST — no DB_NAME, DB_USER, or DB_PASSWORD. The API fails to authenticate.

---

### Bug 5 — No Resource Limits

**Severity: Medium**

No memory or CPU limits. A runaway query can consume all host memory, triggering the OOM killer on all containers including postgres mid-write (data corruption risk).

---

### Bug 6 — No Health Checks on Postgres or Redis

**Severity: Medium**

Without health checks, Docker cannot know when postgres/redis are actually ready to accept connections, compounding Bug 1.

---

## Fixed docker-compose.yml

See the fixed file at [docker-compose.yml](./docker-compose.yml)

Key changes:
- Added healthcheck to postgres and redis
- Changed depends_on to use condition: service_healthy
- Added restart: unless-stopped to all services
- Added postgres_data named volume
- Added POSTGRES_USER, POSTGRES_DB, and matching API env vars
- Added deploy.resources.limits on the API container

---

## Summary of Changes

| Bug | Fix |
|---|---|
| API starts before DB is ready | healthcheck on postgres + redis; depends_on with service_healthy condition |
| No self-healing on crash | restart: unless-stopped on all services |
| Data wiped on restart | postgres_data named volume |
| No DB credentials or name | POSTGRES_USER, POSTGRES_DB, DB_USER, DB_PASSWORD, DB_NAME env vars |
| No resource limits | deploy.resources.limits (512MB RAM, 0.5 CPU) on API |

---

## Monitoring & Alerting to Add

| What | Tool | Threshold |
|---|---|---|
| API error rate (5xx) | Prometheus + Grafana | > 1% of requests |
| API response time | Prometheus histogram | p99 > 500ms |
| Container restart count | Prometheus + Docker exporter | > 3 restarts in 5 min |
| Postgres connections | pg_exporter | > 80% of max_connections |
| Redis memory | Redis INFO exporter | > 80% of maxmemory |
| Host disk | Node exporter | > 80% |

---

## How to Prevent This in Production

1. Use Kubernetes with proper readinessProbe and livenessProbe instead of Docker Compose
2. Use managed databases (RDS, ElastiCache) instead of containerised postgres/redis
3. Store secrets in AWS Secrets Manager or HashiCorp Vault — not plaintext env vars
4. Add CI/CD pipeline with integration tests that boot the compose stack and verify the API before merging
5. Centralised logging — ship container logs to Datadog, Loki, or CloudWatch
6. Immutable infrastructure — build and tag Docker images in CI, never build in production
