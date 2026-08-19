# Problem 4 — Ship It Twice

Two applications, one repository, two pipelines. Backend HTTP API to EC2, static SPA to S3.

```
src/problem4/
├── .github/workflows/
│   ├── backend-ci.yml              PR gate: lint, typecheck, test, build, scan
│   ├── backend-deploy.yml          main → build once → staging → production
│   ├── _backend-deploy-env.yml     reusable: deploy one bundle to one environment
│   ├── frontend-ci.yml             PR gate: lint, test, build, size budget, scan
│   ├── frontend-deploy.yml         main → build once → staging → production
│   ├── _frontend-deploy-env.yml    reusable: publish one build to one environment
│   └── rollback.yml                manual, first-class, uses the same deploy code
├── deploy/backend/
│   ├── package.sh                  assembles the CodeDeploy bundle
│   ├── appspec.yml                 blue/green lifecycle hooks
│   ├── api.service                 systemd unit, hardened, graceful stop
│   └── scripts/*.sh                the five lifecycle hooks
├── deploy/frontend/
│   ├── sync.sh                     two-pass S3 upload with correct cache headers
│   └── check-size.sh               gzipped bundle-size budget
├── validate.sh                     actionlint + shellcheck, runs locally
└── SOLUTION.md
```

**Note on placement:** the skeleton puts these under `src/problem4/.github/workflows/`, so GitHub
won't execute them from here — Actions only reads the repository root. In a real repo they sit at
`.github/workflows/` and `deploy/`, and the `uses: ./.github/workflows/_*.yml` references assume
that. I kept the skeleton's layout rather than quietly moving things to the root, and
[`validate.sh`](./validate.sh) works around it by linting against a throwaway checkout laid out the
way a real repository would be.

---

## What I'm assuming, and why

The brief leaves plenty open. These are the calls I made; each one would take about a minute to
change if the real setup differs.

| Assumption | Why |
|---|---|
| **Monorepo**: `apps/api` and `apps/web` | The problem describes one team shipping one product made of two apps. Path filters keep a frontend change from redeploying the API. If they're separate repos, delete the `paths:` filters and the `working-directory` lines — nothing else changes |
| **Node 20 + npm, with lockfiles** | Most common for this shape of product. `npm ci` throughout, so the lockfile is authoritative |
| Standard scripts exist: `lint`, `typecheck`, `test`, `build` | I'd rather assume the conventional names and be corrected than invent a bespoke interface |
| **Trunk-based**: PRs into `main`, `main` is deployable | Fits "released manually today" — they want a path from merge to production, not a release-branch ceremony |
| **Two environments**: `staging`, `production` | The minimum that lets "build once, promote the artifact" mean anything. A third is a copy of the environment config |
| **Backend**: EC2 in an ASG behind an ALB | The brief says EC2. An ASG is the only version of "EC2" where zero-downtime deploys and rollback are possible, and any production EC2 service should be in one anyway |
| **Frontend**: S3 behind CloudFront | S3 alone can host a site, but with no TLS on a custom domain and no compression. CloudFront isn't optional in practice, and it's what makes the cache-header work matter |
| **Deploy mechanism**: AWS CodeDeploy, blue/green | Reasoning below — this is the main design decision |
| **Auth**: GitHub OIDC → per-environment IAM roles | No long-lived AWS keys in the repository, at all, ever |
| The API exposes `/healthz` returning its build version, plus `/readyz` | The pipeline verifies *which build* is live, not merely that something answers 200. Without a version in the health response, half the verification in these pipelines is impossible — if the app doesn't do this, that's the first change I'd ask for |
| The SPA reads `/config.json` at boot instead of baked-in `VITE_*` values | Also below, and it's the thing that makes "build once" true rather than aspirational |
| Approval on production is configured on the GitHub Environment | It's a repository setting, not something a workflow can grant itself. That's the point of it |

**Assumptions I'd want to check before shipping this for real:** whether there are database
migrations (that changes the deploy order and the rollback story materially — see *left out*),
whether staging shares any data or downstreams with production, what the ASG size and instance type
are, and whether anyone is depending on the current manual process in a way I haven't seen.

---

## What "production ready" means here

The brief asks me to decide. This is my list, and every row is implemented rather than aspirational:

| Property | How | Where |
|---|---|---|
| **No standing credentials** | GitHub OIDC → IAM role assumed per job, scoped by repo *and* environment in the trust policy. Zero AWS secrets in the repo | both `_*-deploy-env.yml` |
| **Build once, deploy that** | One `build` job produces the artifact; staging and production consume the same one. The bytes tested in staging are the bytes in production | `*-deploy.yml` |
| **Immutable, addressable artifacts** | Keyed by 12-char commit SHA, retained 30 days, in S3 and in Actions artifacts | `package.sh`, `releases/<sha>/` |
| **Zero-downtime** | CodeDeploy blue/green with ALB traffic shifting for the API; ordered two-pass upload for the SPA | `appspec.yml`, `sync.sh` |
| **Verified, not fire-and-forget** | On-instance `ValidateService` gate, then an independent check through the public URL confirming the *version* | `validate_service.sh`, verify steps |
| **Automatic rollback** | CodeDeploy auto-rollback on failed hooks or alarms; plus an explicit workflow rollback for the case CodeDeploy can't see (deploy succeeded, live check disagrees) | `_backend-deploy-env.yml` |
| **Fast, tested manual rollback** | `rollback.yml` redeploys a known artifact through the same code path as a normal deploy | `rollback.yml` |
| **Human gate where it matters** | GitHub Environment approval on production; staging is automatic | `environment:` |
| **No racing deploys** | `concurrency` per environment, `cancel-in-progress: false` | all deploy workflows |
| **Least privilege in CI itself** | Default `permissions: contents: read`; `id-token` only on jobs that need it. CI jobs have no AWS access at all | every workflow |
| **Supply chain** | Actions pinned to commit SHAs, `npm ci`, `npm audit`, Trivy → SARIF, gitleaks, signed build provenance | `*-ci.yml`, `*-deploy.yml` |
| **Config outside the artifact** | API config from SSM at deploy time; SPA config written as `config.json` at deploy time | `before_install.sh`, `_frontend-deploy-env.yml` |
| **Fast, honest feedback** | Dependency caching, `timeout-minutes` on every job, PR runs cancel superseded ones, deploys never do | all |
| **Observable** | Job summaries with version/artifact/deployment ids, GitHub deployment history via Environments, Slack on failure | all |
| **Correctness is checkable** | actionlint + shellcheck over every workflow and script | `validate.sh` |

Two things I'd push back on if someone called them "production ready" without them: **a rollback
path that has actually been run**, and **a post-deploy check that verifies the version rather than
the HTTP status**. Almost every deploy pipeline I've inherited has neither, and they're the two that
matter at 3am.

---

## The main design decision: how to get code onto EC2

Four realistic options. I picked the third.

| Option | Zero downtime | Rollback | Speed | Verdict |
|---|---|---|---|---|
| SSH + `rsync` + `systemctl restart` from Actions | No | Manual | Fast | **No.** Requires inbound SSH from GitHub's IP space and a private key in repo secrets — the exact standing credential OIDC exists to remove. It's also a push model with no record of what's on which instance |
| SSM Run Command / State Manager | Partial | Manual | Fast | Reasonable, agent-pull, no SSH. But no traffic shifting and no built-in rollback, so I'd be writing that myself, worse |
| **CodeDeploy blue/green + ALB** | **Yes** | **Automatic** | ~5-8 min | **Chosen.** Agent pulls from S3 so nothing inbound is needed. Traffic shifts only after validation hooks pass. Auto-rollback on failure or CloudWatch alarm. Lifecycle hooks give a real gate |
| Packer AMI + ASG instance refresh | Yes | Yes (previous launch template) | ~10-15 min | The most immutable answer and genuinely defensible. I'd choose it if the fleet were large or the runtime needed OS-level changes. Here it roughly doubles deploy time for a marginal gain, and slow deploys make people batch changes, which makes deploys riskier |

The property that decided it: **with blue/green, a bad release never serves a production request.**
`ValidateService` runs on the replacement instances while they're still receiving no traffic, and a
non-zero exit fails the deployment before the ALB listener moves. In-place deployment with a health
check can only tell you it's already broken.

Worth naming the trade-off: blue/green means running double capacity during a deploy, and it needs a
second target group. For a handful of instances a few minutes a day, that's cheap. If it weren't, the
fallback is `CodeDeployDefault.OneAtATime` in-place — slower, and a bad release does briefly serve
traffic.

---

## How the backend pipeline works

### On a pull request — `backend-ci.yml`

Three parallel jobs: `verify` (lint, typecheck, tests against a real Postgres service container),
`build` (proves the bundle assembles), `security` (`npm audit --audit-level=high`, Trivy → the
Security tab as SARIF, gitleaks over the full history).

Two deliberate choices:

- **This workflow has no `id-token` permission.** It can't assume an AWS role even if someone adds a
  step that tries. Untrusted code from a fork runs here; it must not be one typo away from cloud
  credentials.
- **The PR's artifact is never deployed.** It's built to prove it builds. What ships is built from
  the merged commit, because a branch that passed CI in isolation isn't the code that ends up on
  `main`.

`npm audit` blocks on high and critical only. Failing PRs on a moderate advisory in a transitive dev
dependency is how a team learns to add `--audit-level=none`, and then the gate is worth nothing.

### On merge to main — `backend-deploy.yml`

```
build (once)  →  staging  →  production
                             └ requires approval on the GitHub Environment
```

`build` runs tests again, builds, packages, and attests provenance. Then `package.sh` assembles the
bundle:

```console
$ bash deploy/backend/package.sh abc123def456
Packaging api abc123def456
Wrote /w/apps/api/dist-bundle/api-abc123def456.tar.gz (684.0K)

$ tar -tzf api-abc123def456.tar.gz | grep -v node_modules
./api.service
./app/BUILD_INFO
./app/dist/index.js
./app/package.json
./app/package-lock.json
./appspec.yml
./scripts/after_install.sh
./scripts/application_start.sh
./scripts/application_stop.sh
./scripts/before_install.sh
./scripts/validate_service.sh
  ... plus 753 node_modules entries

$ tar -xzOf api-abc123def456.tar.gz ./app/BUILD_INFO
version=abc123def456
commit=unknown
built_at=2026-08-19T14:16:54Z
built_by=local
```

(That's a real run against a synthetic `apps/api`, to check the script rather than assume it.)

`node_modules` is installed **into the bundle**, not on the instance. So a deploy doesn't depend on
the npm registry being reachable, and the instances need no build toolchain. `BUILD_INFO` is what
makes verification possible: the app serves its version, and the pipeline checks for that exact
string.

### Deploying one environment — `_backend-deploy-env.yml`

The same reusable workflow serves staging, production, and rollback. That's deliberate: **rollback
runs the deploy code path**, so it can't rot the way a separate rollback script always does.

In order:

1. **Download the artifact.** Not rebuild. `run-id` lets rollback pull from the original build's run.
2. **Assume the environment's IAM role via OIDC**, and `sts get-caller-identity` to confirm which
   account we're in. That check has saved me from a wrong-account deploy, and it costs one second.
3. **Record the current revision.** Before changing anything, so rollback has a concrete target
   rather than "whatever was there before, probably".
4. **Upload the bundle to S3** at `api/<version>/api-<version>.tar.gz`.
5. **Create the CodeDeploy deployment** and wait. On failure, dump the deployment info and per-target
   diagnostics into the log — because the default failure output tells you a deployment failed and
   nothing about why.
6. **Verify through the load balancer.** Polls the public health URL for up to 5 minutes and requires
   `"version":"<this build>"` in the response. This is an *external* check, and it catches what the
   on-instance hook structurally cannot: a wrong target group, a listener rule pointing at the old
   group, a security group that blocks the ALB.
7. **Roll back if step 6 fails but CodeDeploy said success.** That's the gap in CodeDeploy's own
   auto-rollback — it only knows about failures it can see.
8. **Summarise and notify.** Version, artifact URI, deployment id, previous revision — everything
   you need to roll back, on the run page, without going digging.

### On the instance — the lifecycle hooks

| Hook | Runs on | Does |
|---|---|---|
| `BeforeInstall` | new instances | Creates the `api` user and directories; fetches config from SSM Parameter Store into `/etc/api/env` (mode 640, root:api). **Fails if the fetch returns nothing** — starting with no database credentials is harder to diagnose than not starting |
| `AfterInstall` | new instances | Ownership, registers the systemd unit, asserts `BUILD_INFO` exists |
| `ApplicationStart` | new instances | Starts, then *polls* until active. `systemctl restart` returns while the unit is still activating, so without the poll a process that starts and immediately exits looks like success |
| `ValidateService` | new instances, **no traffic yet** | The gate: `/readyz` returns 200, the serving version equals the shipped version, and one real business endpoint responds. Non-zero here fails the deployment before any traffic moves |
| `BeforeBlockTraffic` | **old** instances, after traffic moved away | Graceful `systemctl stop`, so in-flight requests finish. Escalates to SIGKILL after 30s. Exits 0 cleanly on a first-ever deploy where there's nothing to stop |

The second check in `ValidateService` — comparing the running version to the shipped version — is
worth calling out. It catches the case where the old process survived the restart and is still
serving happily. Every check that only asks "does it answer" reports success in that scenario.

The systemd unit does the unglamorous parts: `KillSignal=SIGTERM` with `TimeoutStopSec=30` so the
app's own drain has time to complete, `EnvironmentFile` so no config is baked into the artifact, and
`ProtectSystem=strict` / `NoNewPrivileges` / `PrivateTmp` because they cost nothing.

---

## How the frontend pipeline works

A static SPA looks trivial to deploy — `aws s3 sync` and done. It isn't, and the two things that
make it non-trivial are both invisible until they bite users.

### Build once, configure at deploy

The reflex is `VITE_API_URL` at build time. Then you need one build per environment, and staging has
never tested production's bytes — which defeats the entire point of promoting an artifact.

So the bundle is built with no environment-specific values, and the deploy writes:

```json
{
  "environment": "production",
  "apiBaseUrl": "https://api.example.com",
  "buildId": "abc123def456",
  "commit": "..."
}
```

The app fetches `/config.json` at boot. One artifact, every environment. This does need app support —
if the SPA hard-codes `import.meta.env.VITE_API_URL`, this is the change I'd ask for first, and it's
about twenty lines.

### Upload order and cache headers

[`sync.sh`](./deploy/frontend/sync.sh) does two passes, and the order is the point:

**Pass 1 — content-hashed assets**, `Cache-Control: public, max-age=31536000, immutable`. Assets go
up **first**. `index.html` references them by hashed filename, so if `index.html` went first there'd
be a window where browsers request chunks that don't exist yet. On a busy site that window is real
user-visible errors, and it's the classic S3 SPA deploy bug.

**Pass 2 — entry points** (`index.html`, `config.json`, `build-id.txt`),
`Cache-Control: no-cache, no-store, must-revalidate`. If `index.html` is cacheable, a deploy silently
doesn't take effect until the TTL expires and a **rollback appears not to work** — which is when
someone starts invalidating `/*` in a panic. The verify step warns if the live `index.html` comes
back without `no-cache`, because this regresses quietly.

**No `--delete`.** This one's counter-intuitive and I want to be explicit about it. Old hashed chunks
are deliberately left in place: a user who loaded the previous `index.html` two minutes ago will
still request them, and deleting them breaks their session mid-navigation. An S3 lifecycle rule
expires orphans and `releases/` after 30 days. Being tidy immediately is a worse trade than a few
megabytes of S3.

**Invalidation is scoped to the entry points**, not `/*`. Immutable content-hashed assets never need
invalidating — that's what the hash is for — and `/*` costs money per path above the free tier while
evicting a cache that was perfectly correct.

### Verification

Fetch `/build-id.txt` from the public URL until it matches the version just deployed. That confirms
the CDN is actually serving this build, which is a stronger statement than "the sync command exited
0" — a successful upload behind a stale edge cache is a deploy that didn't happen.

### Bundle size budget

[`check-size.sh`](./deploy/frontend/check-size.sh) fails the build if gzipped JS+CSS exceeds a budget
(600 KB), and writes the number to the PR summary. A performance regression is a bug no unit test
catches, and the only way it stays fixed is for the number to be enforced rather than watched. Tested
both ways:

```console
$ ./check-size.sh dist 600
Gzipped sizes of shipped JS and CSS:
        39 KB  app.abc123.js
         0 KB  app.abc123.css
-----
Total: 39 KB (budget 600 KB)
Within budget.                                    # exit 0

$ ./check-size.sh dist 10
Total: 39 KB (budget 10 KB)
::error::Bundle is 39 KB gzipped, over the 10 KB budget.  # exit 1
```

---

## Rollback

`rollback.yml` takes an application, an environment, a target version, the run id that built it, and
a reason. It then calls the same reusable deploy workflow.

Why a dedicated workflow rather than "revert the commit":

- A revert **rebuilds**, so it takes as long as a deploy, and it can fail. During an incident you
  want to redeploy bytes that have already been in production, not compile new ones.
- A revert needs a green pipeline and a merge, which needs a reviewer, at 3am.
- A revert leaves the bad commit's history tangled if you then want to fix forward.

The mandatory `reason` field is there because rollbacks are exactly the events nobody writes down,
and it costs the operator four seconds. It lands in the run summary and the audit trail.

The rollback path being *the same code* as the deploy path is the design point. A separate rollback
script is code that runs once a quarter, under pressure, having never been exercised.

---

## What the pipelines need from AWS and GitHub

Not implemented here — it's Terraform, and it's a different problem — but this is the contract.

**GitHub Environment variables** (per environment: `staging`, `production`):

| Variable | Example |
|---|---|
| `AWS_REGION` | `ap-southeast-1` |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::111122223333:role/gha-deploy-production` |
| `ARTIFACT_BUCKET` | `acme-deploy-artifacts-prod` |
| `CODEDEPLOY_APPLICATION` | `api` |
| `CODEDEPLOY_DEPLOYMENT_GROUP` | `api-production` |
| `HEALTH_CHECK_URL` | `https://api.example.com/healthz` |
| `WEB_BUCKET` | `acme-web-prod` |
| `CLOUDFRONT_DISTRIBUTION_ID` | `E1ABCDEFGHIJKL` |
| `PUBLIC_URL` | `https://app.example.com` |
| `API_BASE_URL` | `https://api.example.com` |

Optional secret: `SLACK_WEBHOOK_URL`. Every notify step is guarded on it being non-empty, so the
pipelines work without it.

**The OIDC trust policy** is the part worth getting exactly right. Scope on the `sub` claim, per
environment — not just per repository:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": "repo:acme/product:environment:production"
    }
  }
}
```

That `sub` is what makes the approval gate real. A workflow that runs against `environment: staging`
gets a token whose `sub` says `staging`, so it cannot assume the production role — even if someone
edits the workflow file to try. Scoping on `repo:acme/product:*` instead, which is what most guides
show, means any branch in the repo can reach production. That's the single most common mistake in
GitHub-to-AWS OIDC setups and it quietly removes the protection people think they have.

**Also required:** the production Environment with required reviewers and a branch restriction to
`main`; the CodeDeploy application with a blue/green group wired to the ALB's two target groups,
auto-rollback on `DEPLOYMENT_FAILURE` and `DEPLOYMENT_STOP_ON_ALARM`, and a CloudWatch alarm on 5xx
rate as the alarm input; the S3 buckets versioned, encrypted, public access blocked, with lifecycle
rules; and the instance profile allowed to read only `/api/<env>/*` in Parameter Store.

---

## Verification

I can't run a deploy without an AWS account, so I verified everything that doesn't need one:

```console
$ ./validate.sh
==> actionlint (workflow schema, expressions, action inputs, embedded bash)

==> shellcheck (deploy scripts)

All checks passed.
```

actionlint checks the workflow schema, expression syntax, action input names, the local
reusable-workflow references, and pipes every embedded `run:` block through shellcheck. Both tools
are clean with no suppressions. Plus the two scripts exercised for real above: `package.sh` produced
a valid CodeDeploy bundle, and `check-size.sh` passes and fails at the right thresholds.

What I could not verify: the CodeDeploy deployment itself, the OIDC role assumption, the S3 sync, the
CloudFront invalidation, and the post-deploy checks against a live URL. Those are written to be
correct against the documented API shapes, and I've listed above exactly what each one does.

---

## What I deliberately left out

Ordered by how much it bothers me.

**Database migrations.** The significant gap. A migration step in a blue/green deploy is genuinely
hard: old and new code run simultaneously during the shift, so every migration must be
backwards-compatible with the previous release, and a rollback can't undo a migration that's already
applied. The real answer is expand/contract — deploy the additive schema change, then the code, then
the cleanup in a later release — enforced by review, plus a migration job that runs before the deploy
and is required to be idempotent. That's a design conversation with the app team, and I'd rather flag
it clearly than bolt on a `npm run migrate` step that turns a rollback into data loss. **I'd want
this resolved before this pipeline deployed anything with a schema.**

**Canary / progressive traffic shifting.** CodeDeploy supports `Canary10Percent5Minutes`, and it's
strictly better than all-at-once for catching problems only real traffic reveals. It needs alarms
good enough to auto-abort on, and it makes every deploy 5+ minutes slower. I'd turn it on for
production once there are meaningful CloudWatch alarms to gate it — the mechanism is one parameter on
the deployment group.

**Terraform for the AWS resources.** Out of scope, and the pipelines would be untrustworthy without
it — hand-built deployment groups drift. I documented the contract above instead of half-writing the
IaC.

**End-to-end tests against deployed staging.** Playwright against the staging URL after deploy, as a
required gate before production, is the natural next step. I left it out because a flaky E2E suite
that blocks all deploys gets disabled within a fortnight, and building one that isn't flaky is its
own piece of work. The version-verified smoke checks are what I'd ship first.

**A `develop`/release-branch flow, changelogs, semver tags.** Trunk-based with SHA-versioned
artifacts is simpler and enough here. If the product needs published version numbers, that's
`release-please` and a tag trigger.

**Multi-region.** Nothing in the brief suggests it, and it roughly doubles pipeline complexity.

**Container images for the backend.** ECR + ECS/EKS would be my preference for a greenfield service,
but the brief says EC2, and rewriting the deployment target is not what was asked.

**Deploy windows and freeze periods.** Real for a lot of teams (no Friday deploys, no deploys during
a sale). One `if` on a schedule check, once someone tells me the policy.

**Notifying anything but Slack**, and no PagerDuty integration on failed production deploys. The
webhook is a placeholder for whatever the team actually uses.

**Cost guardrails on the pipeline itself.** At this size, GitHub-hosted runners on a monorepo with
path filters is fine. If CI minutes became a problem the answer is larger runners for the slow jobs,
not more caching.

One last thing I'd change if this were my repo rather than a submission: move the workflows to the
repository root so they actually run, and open a PR with a deliberate breakage in it to confirm the
gates fail. Pipelines that have never failed haven't been tested — they've been written.
