# 99Tech DevOps Challenge — Solutions

Solutions to the five problems, in the skeleton's layout under [`src/`](./src).

| # | Problem | Solution | Can you run it? |
|---|---|---|---|
| 1 | Building Castle In The Cloud | [src/problem1/SOLUTION.md](./src/problem1/SOLUTION.md) | Design doc |
| 2 | Diagnose Me Doctor | [src/problem2/SOLUTION.md](./src/problem2/SOLUTION.md) | Runbook |
| 3 | Debugging issues within system | [src/problem3/SOLUTION.md](./src/problem3/SOLUTION.md) | **Yes** — `cd src/problem3 && ./smoke-test.sh` |
| 4 | Ship It Twice | [src/problem4/SOLUTION.md](./src/problem4/SOLUTION.md) | Partly — `cd src/problem4 && ./validate.sh` |
| 5 | Fortify The Castle | [src/problem5/SOLUTION.md](./src/problem5/SOLUTION.md) | Design doc |

## Where to start

Problem 3 first if you only read one. It is the one with working code, and the report is built from real
terminal output, not from reading the source and guessing. Then Problem 4 for the pipelines. Problems 1 and 5
are a pair — 5 is a security delta on 1's architecture, so read 1 first.

## What I ran, and what I only designed

I try to be clear about this everywhere, because "here is a plan" and "here is a thing that works" deserve
different amounts of trust.

**Verified by running it:**

- **Problem 3** — I reproduced all 14 findings on the broken stack (Docker 24.0.2, Compose v2.18.1) before
  fixing anything. Every console block in that write-up is copied from a terminal. The fixed stack passes a
  14-assertion smoke test that stops Redis, freezes Postgres, and hammers a broken database to prove the
  connection pool no longer leaks.
- **Problem 4** — actionlint and shellcheck are clean over all 7 workflows and all 8 shell scripts, with no
  suppressions. `package.sh` produces a valid CodeDeploy bundle. `check-size.sh` passes and fails at the right
  thresholds. The AWS steps cannot run without an account, and the write-up says which those are and what each
  one does.
- **Problems 1 and 5** — the Mermaid diagrams render. I checked with mermaid-cli instead of assuming.

**Not verified, because it cannot be:** the architectures in 1 and 5, and the runbook in 2. Where those have a
number — a latency budget, a cost estimate, a log growth rate — I say where it came from and how I would
confirm it.

## Assumptions and judgement calls

Each SOLUTION.md lists its own in full. The ones worth knowing up front:

- **Problem 5** says "the architecture you designed in Problem 2". Problem 2 in the current set is the
  disk-full scenario, which has no architecture, so I read it as Problem 1 — the only design in the set.
- **Problem 2** asks for two production issues but only one scenario is on the problem page. I answered that one
  properly instead of inventing a second.
- **Problem 4's** workflows live under `src/problem4/.github/workflows/` per the skeleton layout, so GitHub will
  not run them from there — Actions only reads the repository root. `validate.sh` works around it to lint them
  properly.
- **Problem 3** — I changed the `/api/users` handler to read a real `users` table instead of `SELECT NOW()`.
  That is slightly beyond "fix what is broken". The reasoning is in the write-up.

## Repository history

The first commit imports the 99Tech skeleton **verbatim**, including the broken Problem 3 stack. So the fix
commit's diff is the before-and-after:

```bash
git log --oneline
git diff --stat ':/add challenge skeleton' ':/fix problem 3 stack' -- src/problem3
```

An earlier version of this repo held answers to the previous version of the challenge, whose problem set and
numbering no longer match. Those are still in history rather than deleted.

## Environment

- macOS, Docker 24.0.2, Docker Compose v2.18.1
- Node 20, in containers only — nothing installed on the host
- Diagrams: Mermaid, rendered by GitHub
- Linting: `rhysd/actionlint` and `koalaman/shellcheck`, both via Docker
