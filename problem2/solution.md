# Problem 2 — Building Castle In The Cloud

## Constraints

| Parameter | Value |
|---|---|
| Cloud provider | AWS |
| Throughput | 500 requests/second |
| Latency | p99 < 100ms |

---

## Architecture Diagram

**Architecture Diagram:** [architecture.drawio](./architecture.drawio)

Open with https://app.diagrams.net or the VS Code draw.io extension to view the interactive diagram.

---

## Architecture Overview

```
Users
  |
  v
[Edge Layer]  Route 53 · CloudFront · AWS WAF
  |
  v
[Routing]     Application Load Balancer (Multi-AZ)
  |
  |---> Order Service (ECS Fargate)
  |---> Market Data Service (ECS Fargate)
  |---> Auth Service (ECS Fargate)
  `---> Wallet Service (ECS Fargate)
         |
  +------+-------------+
  v      v             v
Aurora  ElastiCache  MSK/Kafka  DynamoDB
(RDS)   (Redis)      (Events)   (History)
```

---

## Service Choices & Rationale

### Edge Layer

| Service | Role | Why chosen | Alternative considered |
|---|---|---|---|
| Route 53 | DNS + health-check-based failover | Latency-based routing across regions; auto-failover if primary ALB goes unhealthy | Cloudflare DNS |
| CloudFront | CDN + DDoS protection | Caches static assets and market data snapshots at edge; absorbs volumetric DDoS via AWS Shield Standard | Fastly |
| AWS WAF | Rate limiting, bot filtering | Attached to CloudFront; blocks abusive clients before traffic hits origin | Self-hosted ModSecurity |

### Routing

| Service | Role | Why chosen | Alternative |
|---|---|---|---|
| Application Load Balancer | Layer-7 routing, health checks | Supports path-based routing, WebSocket, sticky sessions, native ECS integration; multi-AZ by default | NGINX/HAProxy on EC2 |

### Compute

| Service | Role | Why chosen | Alternative |
|---|---|---|---|
| ECS Fargate | Containerised microservices | Serverless containers — no node management; auto-scales per service; integrates with ALB and CloudWatch natively | EKS — better for very large teams and high traffic |

#### Why ECS Fargate over EKS at this stage

EKS (Kubernetes) is more flexible and scalable at high traffic, but ECS Fargate is the right starting point here.

| Factor | ECS Fargate | EKS |
|---|---|---|
| Operational overhead | Near zero — no nodes, no control plane | High — node groups, cluster upgrades, CNI, add-ons |
| Time to production | Hours | Days to weeks |
| AWS native integration | First-class out of the box | Requires aws-load-balancer-controller, IRSA, Cluster Autoscaler |
| Cost at 500 RPS | Pay per task only — no idle node cost | EC2 node groups run 24/7 |
| Auto-scaling precision | CPU, memory, ALB request count | CPU, memory + custom metrics via KEDA (Kafka lag, etc.) |
| Service mesh | Not natively supported | Istio/Linkerd — mTLS, circuit breaking, traffic splitting |
| Multi-team isolation | Limited | Full RBAC, namespaces, network policies |
| Deployment strategies | Blue/green via CodeDeploy | Argo Rollouts, Flagger — canary %, A/B, auto-rollback |
| Portability | AWS-only | Runs on any cloud or on-prem |

**EKS becomes the better choice when:**
- Traffic grows beyond 5,000–10,000 RPS and per-service auto-scaling on custom metrics is needed
- Engineering team grows to 5+ services owned by multiple squads requiring namespace isolation
- Service mesh needed for mTLS between services or traffic shaping
- Advanced deployment strategies like canary with automatic metric-based rollback required
- Platform expands to multi-cloud or hybrid

The migration path is already planned in the scaling section — ECS Fargate at launch, EKS at 2,000–10,000 RPS.

#### Microservices

| Service | Responsibility |
|---|---|
| Order service | Order validation, matching engine, execution |
| Market data service | Real-time price feeds, order book aggregation, WebSocket push |
| Auth service | User authentication, JWT issuance, session management |
| Wallet service | Balance reads/writes, deposit/withdrawal, transaction locking |

### Data Layer

| Service | Role | Why chosen | Alternative |
|---|---|---|---|
| Aurora PostgreSQL (Multi-AZ) | Transactional data | ACID guarantees; Multi-AZ auto-failover in < 30s; up to 15 read replicas | RDS PostgreSQL, CockroachDB |
| ElastiCache (Redis) | Order book cache, session store | Sub-millisecond reads; native Pub/Sub for price updates | Memcached, Valkey |
| Amazon MSK (Kafka) | Event streaming | Durable, ordered, replayable; exactly-once semantics | SQS/SNS, Kinesis |
| DynamoDB | Trade history, audit logs | Single-digit ms reads; auto-scaling; pay-per-request | MongoDB Atlas, Cassandra |

### Supporting Services

| Service | Purpose |
|---|---|
| AWS Secrets Manager | Rotate and inject DB credentials — never hardcoded |
| CloudWatch + X-Ray | Metrics, logs, distributed tracing |
| AWS Certificate Manager | TLS termination at CloudFront and ALB |
| VPC with private subnets | Services and databases isolated; only ALB is public |

---

## High Availability Design

- All ECS services run across 3 Availability Zones with minimum 2 tasks per service
- ALB health checks remove unhealthy ECS tasks within 10-30 seconds
- Aurora automatic failover to standby replica in < 30 seconds
- ElastiCache Multi-AZ with automatic failover
- MSK brokers span 3 AZs with replication factor 3
- Route 53 health checks detect ALB failure and failover to secondary region

**Target SLO:** 99.95% availability (< 4.4 hours downtime/year)

---

## Meeting the Throughput & Latency SLOs

### Latency budget (p99 path)

```
CloudFront to ALB:       ~5ms
ALB to ECS:              ~2ms
ECS service logic:       ~10ms
Redis cache read:        ~1ms
Aurora read replica:     ~5ms (cache miss)
Total (cache hit):       ~18ms  -- well under 100ms
Total (cache miss):      ~23ms  -- well under 100ms
```

---

## Scaling Plan

| Growth stage | Action |
|---|---|
| 500 to 2,000 RPS | Increase ECS task count; add Aurora read replicas; enable Redis cluster mode |
| 2,000 to 10,000 RPS | Migrate compute to EKS; partition Kafka topics; DynamoDB on-demand scaling |
| 10,000+ RPS / Global | Multi-region active-active; Aurora Global Database; CloudFront regional edge caches |

---

## Cost Optimisation

- Fargate Spot for stateless services — up to 70% cost reduction
- Aurora Serverless v2 for off-peak hours
- Reserved Instances (1-year) for baseline ElastiCache and MSK
- CloudFront reduces origin load by ~70%

---

## Security

- All services run in private VPC subnets
- Secrets Manager rotates DB passwords every 30 days
- WAF rules: block OWASP Top 10, rate-limit login endpoints
- IAM roles per ECS task — least-privilege access
- Encryption at rest: Aurora (AES-256), ElastiCache (TLS), MSK (TLS)
