# Problem 4 — Ship It Twice

Two apps, one repo, two pipelines. Backend HTTP API to EC2, static SPA to S3.

```
src/problem4/
├── .github/workflows/
│   ├── backend-ci.yml              PR gate: lint, typecheck, test, build, scan
│   ├── backend-deploy.yml          main → build once → staging → production
│   ├── _backend-deploy-env.yml     reusable: deploy one bundle to one environment
│   ├── frontend-ci.yml             PR gate: lint, test, build, size budget, scan
│   ├── frontend-deploy.yml         main → build once → staging → production
│   ├── _frontend-deploy-env.yml    reusable: publish one build to one environment
│   └── rollback.yml                manual, and uses the same deploy code
├── deploy/backend/                 package.sh, appspec.yml, api.service, 5 hook scripts
├── deploy/frontend/                sync.sh, check-size.sh
├── validate.sh                     actionlint + shellcheck, runs locally
└── SOLUTION.md
```

**Note on placement.** The skeleton puts these under `src/problem4/.github/workflows/`, so GitHub will not
run them from here — Actions only reads the repository root. In a real repo they sit at `.github/workflows/`
and `deploy/`, and the `uses: ./.github/workflows/_*.yml` paths assume that. I kept the skeleton layout
instead of quietly moving things, and [`validate.sh`](./validate.sh) works around it by linting against a
throwaway checkout laid out the way a real repo would be.

## Assumptions

The brief leaves a lot open. Each of these takes about a minute to change if the real setup differs.

| Assumption | Why |
|---|---|
| **Monorepo**: `apps/api` and `apps/web` | One team, one product, two apps. Path filters stop a frontend change redeploying the API. If they are separate repos, delete the `paths:` filters and `working-directory` lines |
| **Node 20 + npm with lockfiles** | Most common for this shape. `npm ci` everywhere, so the lockfile is authoritative |
| Scripts exist: `lint`, `typecheck`, `test`, `build` | I would rather assume the normal names and be corrected than invent a bespoke interface |
| **Trunk-based**: PRs into `main`, `main` is deployable | Fits "released manually today". They want a path from merge to production, not a release-branch ceremony |
| **Two environments**: `staging`, `production` | The minimum that makes "build once, promote" mean anything |
| **Backend**: EC2 in an ASG behind an ALB | The brief says EC2. An ASG is the only version of EC2 where zero-downtime deploys and rollback are possible |
| **Frontend**: S3 behind CloudFront | S3 alone gives no TLS on a custom domain and no compression. CloudFront is not optional in practice |
| **Deploy tool**: AWS CodeDeploy, blue/green | Main design decision, reasoning below |
| **Auth**: GitHub OIDC → per-environment IAM roles | No long-lived AWS keys in the repo, ever |
| The API's `/healthz` returns its build version, plus `/readyz` | The pipeline verifies **which build** is live, not just that something answers 200. Without a version in the health response, half the verification here is impossible. If the app does not do this, that is the first change I would ask for |
| The SPA reads `/config.json` at boot instead of baked `VITE_*` values | What makes "build once" true rather than aspirational. Explained below |
| Production approval is set on the GitHub Environment | It is a repo setting, not something a workflow can grant itself. That is the point |

**What I would check before shipping this for real:** whether there are database migrations (changes the
deploy order and the rollback story a lot — see *left out*), whether staging shares data or downstreams with
production, the ASG size and instance type, and whether anyone depends on the current manual process in a way
I have not seen.

## What "production ready" means here

The brief asks me to decide. This is my list, and every row is implemented, not aspirational.

| Property | How |
|---|---|
| No standing credentials | OIDC → IAM role per job, scoped by repo **and** environment in the trust policy. Zero AWS secrets in the repo |
| Build once, deploy that | One `build` job; staging and production consume the same artifact |
| Immutable, addressable artifacts | Keyed by 12-char commit SHA, kept 30 days, in S3 and in Actions artifacts |
| Zero downtime | CodeDeploy blue/green with ALB traffic shifting; ordered two-pass upload for the SPA |
| Verified, not fire-and-forget | On-instance `ValidateService` gate, then an independent check through the public URL confirming the **version** |
| Automatic rollback | CodeDeploy auto-rollback on failed hooks or alarms, plus an explicit workflow rollback for the case CodeDeploy cannot see |
| Fast, tested manual rollback | `rollback.yml` redeploys a known artifact through the same code path as a normal release |
| Human gate where it matters | Environment approval on production, staging automatic |
| No racing deploys | `concurrency` per environment, `cancel-in-progress: false` |
| Least privilege in CI itself | Default `permissions: contents: read`. `id-token` only where needed. CI jobs have no AWS access at all |
| Supply chain | Actions pinned to commit SHAs, `npm ci`, `npm audit`, Trivy → SARIF, gitleaks, signed build provenance |
| Config outside the artifact | API config from SSM at deploy time, SPA config written as `config.json` at deploy time |
| Observable | Job summaries with version, artifact and deployment ids. Deployment history via Environments. Slack on failure |
| Correctness is checkable | actionlint + shellcheck over every workflow and script |

Two things I would push back on if someone called a pipeline production ready without them: **a rollback path
that has actually been run**, and **a post-deploy check that verifies the version, not the HTTP status**.
Nearly every pipeline I have inherited has neither, and they are the two that matter at 3am.

## Main decision: how to get code onto EC2

| Option | Zero downtime | Rollback | Speed | Verdict |
|---|---|---|---|---|
| SSH + `rsync` + `systemctl restart` | No | Manual | Fast | **No.** Needs inbound SSH from GitHub's IP range and a private key in repo secrets — the exact standing credential OIDC removes. Also no record of what is on which instance |
| SSM Run Command | Partial | Manual | Fast | Reasonable: agent pull, no SSH. But no traffic shifting and no built-in rollback, so I would write that myself, worse |
| **CodeDeploy blue/green + ALB** | **Yes** | **Automatic** | ~5-8 min | **Chosen.** Agent pulls from S3, nothing inbound. Traffic shifts only after validation passes. Auto-rollback on failure or alarm |
| Packer AMI + ASG instance refresh | Yes | Yes | ~10-15 min | Most immutable, genuinely defensible. I would pick it for a large fleet or OS-level changes. Here it roughly doubles deploy time, and slow deploys make people batch changes, which makes deploys riskier |

The property that decided it: **with blue/green, a bad release never serves a production request.**
`ValidateService` runs on the replacement instances while they still take no traffic, and a non-zero exit
fails the deployment before the ALB listener moves. In-place deployment with a health check can only tell you
it is already broken.

Trade-off: blue/green runs double capacity during a deploy and needs a second target group. For a few
instances a few minutes a day, that is cheap. If it were not, the fallback is
`CodeDeployDefault.OneAtATime` in-place — slower, and a bad release does briefly serve traffic.

## Backend pipeline

### On a pull request

Three parallel jobs: `verify` (lint, typecheck, tests against a real Postgres service container), `build`
(proves the bundle assembles), `security` (`npm audit --audit-level=high`, Trivy → the Security tab as SARIF,
gitleaks over full history).

Two deliberate choices:

- **No `id-token` permission on this workflow.** It cannot assume an AWS role even if someone adds a step
  that tries. Untrusted fork code runs here and must not be one typo from cloud credentials.
- **The PR artifact is never deployed.** It is built to prove it builds. What ships is built from the merged
  commit, because a branch that passed CI alone is not the code that lands on `main`.

`npm audit` blocks on high and critical only. Failing PRs on a moderate advisory in a transitive dev
dependency is how a team learns to add `--audit-level=none`, and then the gate is worth nothing.

### On merge to main

```
build (once)  →  staging  →  production
                             └ needs approval on the GitHub Environment
```

`build` tests, builds, packages, and attests provenance. Then `package.sh` assembles the bundle:

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
built_at=2026-08-19T14:16:54Z
built_by=local
```

That is a real run against a synthetic `apps/api`, to check the script rather than assume it.

`node_modules` is installed **into the bundle**, so a deploy does not depend on the npm registry being up and
the instances need no build toolchain. `BUILD_INFO` is what makes verification possible: the app serves its
version and the pipeline checks for that exact string.

### Deploying one environment

The same reusable workflow serves staging, production, and rollback. That is deliberate: **rollback runs the
deploy code path**, so it cannot rot the way a separate rollback script always does.

1. **Download the artifact.** Not rebuild. `run-id` lets rollback pull from the original build's run.
2. **Assume the environment's IAM role via OIDC**, then `sts get-caller-identity` to confirm which account we
   are in. That check has saved me from a wrong-account deploy and costs one second.
3. **Record the current revision** before changing anything, so rollback has a concrete target rather than
   "whatever was there before, probably".
4. **Upload the bundle to S3** at `api/<version>/api-<version>.tar.gz`.
5. **Create the CodeDeploy deployment and wait.** On failure, dump deployment info and per-target diagnostics
   into the log, because the default output tells you a deployment failed and nothing about why.
6. **Verify through the load balancer.** Poll the public health URL for up to 5 minutes and require
   `"version":"<this build>"`. This is an *external* check and catches what the on-instance hook cannot: a
   wrong target group, a listener rule pointing at the old group, a security group blocking the ALB.
7. **Roll back if step 6 fails but CodeDeploy said success.** That is the gap in CodeDeploy's own
   auto-rollback: it only knows about failures it can see.
8. **Summarise and notify.** Version, artifact URI, deployment id, previous revision — everything needed to
   roll back, on the run page, without digging.

### On the instance

| Hook | Runs on | Does |
|---|---|---|
| `BeforeInstall` | new instances | Creates the `api` user and directories, fetches config from SSM into `/etc/api/env` (mode 640). **Fails if the fetch returns nothing** — starting with no database credentials is harder to diagnose than not starting |
| `AfterInstall` | new instances | Ownership, registers the systemd unit, asserts `BUILD_INFO` exists |
| `ApplicationStart` | new instances | Starts, then *polls* until active. `systemctl restart` returns while the unit is still activating, so without the poll a process that starts and immediately exits looks like success |
| `ValidateService` | new instances, **no traffic yet** | The gate: `/readyz` returns 200, the serving version equals the shipped version, and one real business endpoint responds |
| `BeforeBlockTraffic` | **old** instances, after traffic moved | Graceful stop so in-flight requests finish, SIGKILL after 30s. Exits 0 cleanly on a first deploy where there is nothing to stop |

The version check in `ValidateService` is worth calling out. It catches the case where the old process
survived the restart and is still serving happily. Every check that only asks "does it answer" reports success
in that case.

The systemd unit does the unglamorous parts: `KillSignal=SIGTERM` with `TimeoutStopSec=30` so the app's drain
has time to finish, `EnvironmentFile` so no config is baked into the artifact, and
`ProtectSystem=strict` / `NoNewPrivileges` / `PrivateTmp` because they cost nothing.

## Frontend pipeline

A static SPA looks trivial to deploy. It is not, and the two things that make it non-trivial are both
invisible until they hit users.

### Build once, configure at deploy

The reflex is `VITE_API_URL` at build time. Then you need one build per environment, and staging has never
tested production's bytes — which defeats the whole point of promoting an artifact.

So the bundle has no environment-specific values, and the deploy writes:

```json
{ "environment": "production", "apiBaseUrl": "https://api.example.com",
  "buildId": "abc123def456", "commit": "..." }
```

The app fetches `/config.json` at boot. One artifact, every environment. This needs app support — if the SPA
hard-codes `import.meta.env.VITE_API_URL`, that is the change I would ask for first, and it is about twenty
lines.

### Upload order and cache headers

[`sync.sh`](./deploy/frontend/sync.sh) does two passes, and the order is the point.

**Pass 1 — content-hashed assets**, `Cache-Control: public, max-age=31536000, immutable`. Assets go up
**first**. `index.html` references them by hashed filename, so if `index.html` went first there would be a
window where browsers ask for chunks that do not exist yet. On a busy site that window is real user-visible
errors, and it is the classic S3 SPA deploy bug.

**Pass 2 — entry points** (`index.html`, `config.json`, `build-id.txt`),
`Cache-Control: no-cache, no-store, must-revalidate`. If `index.html` is cacheable, a deploy silently does not
take effect until the TTL expires, and **a rollback appears not to work** — which is when someone starts
invalidating `/*` in a panic. The verify step warns if the live `index.html` comes back without `no-cache`,
because this regresses quietly.

**No `--delete`.** This is counter-intuitive so I want to be explicit. Old hashed chunks are left in place: a
user who loaded the previous `index.html` two minutes ago will still request them, and deleting them breaks
their session mid-navigation. An S3 lifecycle rule expires orphans and `releases/` after 30 days. Being tidy
immediately is a worse trade than a few megabytes of S3.

**Invalidation is scoped to the entry points**, not `/*`. Immutable content-hashed assets never need
invalidating — that is what the hash is for — and `/*` costs money per path above the free tier while evicting
a cache that was perfectly correct.

### Verification and size budget

Fetch `/build-id.txt` from the public URL until it matches the version just deployed. That confirms the CDN is
serving this build, which is stronger than "the sync command exited 0". A successful upload behind a stale
edge cache is a deploy that did not happen.

[`check-size.sh`](./deploy/frontend/check-size.sh) fails the build if gzipped JS+CSS exceeds 600 KB and writes
the number to the PR summary. A performance regression is a bug no unit test catches, and the only way it
stays fixed is enforcement. Tested both ways:

```console
$ ./check-size.sh dist 600
Total: 39 KB (budget 600 KB)
Within budget.                                            # exit 0

$ ./check-size.sh dist 10
::error::Bundle is 39 KB gzipped, over the 10 KB budget.  # exit 1
```

## Rollback

`rollback.yml` takes an application, an environment, a target version, the run id that built it, and a reason.
It then calls the same reusable deploy workflow.

Why a dedicated workflow instead of "revert the commit":

- A revert **rebuilds**, so it takes as long as a deploy and it can fail. During an incident you want to
  redeploy bytes that have already been in production, not compile new ones.
- A revert needs a green pipeline and a merge, which needs a reviewer, at 3am.

The mandatory `reason` field is there because rollbacks are exactly the events nobody writes down, and it
costs the operator four seconds.

## What the pipelines need from AWS and GitHub

Not implemented here — that is Terraform, and a different problem — but this is the contract.

**GitHub Environment variables** per environment: `AWS_REGION`, `AWS_DEPLOY_ROLE_ARN`, `ARTIFACT_BUCKET`,
`CODEDEPLOY_APPLICATION`, `CODEDEPLOY_DEPLOYMENT_GROUP`, `HEALTH_CHECK_URL`, `WEB_BUCKET`,
`CLOUDFRONT_DISTRIBUTION_ID`, `PUBLIC_URL`, `API_BASE_URL`. Optional secret `SLACK_WEBHOOK_URL` — every notify
step is guarded on it being non-empty, so the pipelines work without it.

**The OIDC trust policy** is the part worth getting exactly right. Scope on the `sub` claim per environment,
not just per repository:

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

That `sub` is what makes the approval gate real. A workflow running against `environment: staging` gets a
token whose `sub` says `staging`, so it cannot assume the production role — even if someone edits the workflow
file to try. Scoping on `repo:acme/product:*`, which is what most guides show, means any branch in the repo
can reach production. That is the most common mistake in GitHub-to-AWS OIDC setups, and it quietly removes the
protection people think they have.

**Also required:** the production Environment with required reviewers and a branch restriction to `main`; the
CodeDeploy application with a blue/green group wired to the ALB's two target groups, auto-rollback on
`DEPLOYMENT_FAILURE` and `DEPLOYMENT_STOP_ON_ALARM`, with a 5xx-rate CloudWatch alarm as the alarm input; S3
buckets versioned, encrypted, public access blocked, with lifecycle rules; and the instance profile allowed to
read only `/api/<env>/*` in Parameter Store.

## Verification

I cannot run a deploy without an AWS account, so I verified everything that does not need one:

```console
$ ./validate.sh
==> actionlint (workflow schema, expressions, action inputs, embedded bash)

==> shellcheck (deploy scripts)

All checks passed.
```

actionlint checks the workflow schema, expression syntax, action input names, the local reusable-workflow
references, and pipes every embedded `run:` block through shellcheck. Both clean, no suppressions. Plus the two
scripts exercised above.

**What I could not verify:** the CodeDeploy deployment itself, the OIDC role assumption, the S3 sync, the
CloudFront invalidation, and the post-deploy checks against a live URL. Those are written against the
documented API shapes, and I have listed above exactly what each one does.

## What I deliberately left out

Ordered by how much it bothers me.

**Database migrations.** The significant gap. A migration in a blue/green deploy is genuinely hard: old and
new code run at the same time during the shift, so every migration must be backwards-compatible with the
previous release, and a rollback cannot undo a migration already applied. The real answer is expand/contract —
additive schema change, then the code, then cleanup in a later release — enforced by review, plus a migration
job that runs before the deploy and must be idempotent. That is a design conversation with the app team, and I
would rather flag it than bolt on `npm run migrate` and turn a rollback into data loss. **I would want this
resolved before this pipeline deployed anything with a schema.**

**Canary traffic shifting.** CodeDeploy supports `Canary10Percent5Minutes`, and it is better than all-at-once
for problems only real traffic reveals. It needs alarms good enough to auto-abort on, and it makes every deploy
5+ minutes slower. I would turn it on for production once there are meaningful alarms to gate it. The mechanism
is one parameter on the deployment group.

**Terraform for the AWS resources.** Out of scope, and the pipelines would be untrustworthy without it — hand-
built deployment groups drift. I documented the contract instead of half-writing the IaC.

**End-to-end tests against deployed staging.** Playwright against the staging URL as a required gate before
production is the natural next step. I left it out because a flaky E2E suite that blocks all deploys gets
disabled within a fortnight, and building one that is not flaky is its own piece of work. The version-verified
smoke checks are what I would ship first.

**Also left out:** a release-branch flow with changelogs and semver tags (trunk-based with SHA-versioned
artifacts is simpler and enough); multi-region (nothing in the brief suggests it); container images for the
backend (my preference for greenfield, but the brief says EC2 and rewriting the target is not what was asked);
deploy windows and freeze periods (one `if` once someone tells me the policy); anything beyond a Slack webhook
for notifications.

One last thing I would change if this were my repo rather than a submission: move the workflows to the
repository root so they actually run, then open a PR with a deliberate breakage to confirm the gates fail.
Pipelines that have never failed have not been tested, only written.
