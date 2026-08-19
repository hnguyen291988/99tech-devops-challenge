# 99Tech DevOps Challenge — Solutions

Solutions to the five problems, in the skeleton's layout under [`src/`](./src).

| # | Problem | Solution | Runnable? |
|---|---|---|---|
| 1 | Building Castle In The Cloud | [src/problem1/SOLUTION.md](./src/problem1/SOLUTION.md) | Design doc |
| 2 | Diagnose Me Doctor | [src/problem2/SOLUTION.md](./src/problem2/SOLUTION.md) | Runbook |
| 3 | Debugging issues within system | [src/problem3/SOLUTION.md](./src/problem3/SOLUTION.md) | **Yes** — `cd src/problem3 && ./smoke-test.sh` |
| 4 | Ship It Twice | [src/problem4/SOLUTION.md](./src/problem4/SOLUTION.md) | Partly — `cd src/problem4 && ./validate.sh` |
| 5 | Fortify The Castle | [src/problem5/SOLUTION.md](./src/problem5/SOLUTION.md) | Design doc |

## Suggested reading order

Problem 3 first if you only read one — it's the one with working code, and the report is built from
real terminal output rather than from reading the source and guessing. Then Problem 4 for the
pipelines. Problems 1 and 5 are a pair: 5 is a security delta against 1's architecture, so 1 first.

## What I actually ran, versus what I designed

I've tried to be explicit about this throughout, because "here is a plan" and "here is a thing that
works" deserve different amounts of trust.

**Verified by running it:**

- **Problem 3** — reproduced all fourteen findings on the broken stack (Docker 24.0.2, Compose
  v2.18.1) before fixing anything. Every console block in that write-up is copied from a terminal.
  The fixed stack passes a 14-assertion smoke test that includes stopping Redis, freezing Postgres,
  and hammering a broken database to prove the connection pool no longer leaks.
- **Problem 4** — actionlint and shellcheck clean over all seven workflows and all eight shell
  scripts, with no suppressions. `package.sh` verified to produce a valid CodeDeploy bundle;
  `check-size.sh` verified to pass and fail at the right thresholds. The AWS-dependent steps cannot
  run without an account, and the write-up says exactly which those are and what each does.
- **Problems 1 and 5** — the Mermaid diagrams render (checked with mermaid-cli, not assumed).

**Not verified, because it can't be:** the architectures in 1 and 5, and the runbook in 2. Where I've
put a number in those documents — a latency budget, a cost estimate, a log-growth rate — I've said
where it came from and how I'd confirm it.

## Assumptions and judgement calls

Each SOLUTION.md lists its own assumptions in full. The ones worth knowing up front:

- **Problem 5** says "the architecture you designed in Problem 2". Problem 2 in the current set is
  the disk-full scenario, which has no architecture, so I read it as Problem 1 — the only design in
  the set.
- **Problem 2** asks for "two production issues" but only one scenario is on the problem page. I
  answered that one thoroughly rather than inventing a second.
- **Problem 4's** workflows live under `src/problem4/.github/workflows/` per the skeleton layout, so
  GitHub won't execute them from there — Actions only reads the repository root. Noted in that
  write-up, and `validate.sh` works around it to lint them properly.
- **Problem 3** — I changed the `/api/users` handler to read a real `users` table instead of
  `SELECT NOW()`. That's slightly beyond "fix what's broken"; the reasoning is in the write-up.

## Repository history

The first commit resets onto the 99Tech skeleton **verbatim**, including the broken Problem 3 stack.
The fix commit's diff is therefore the before-and-after:

```bash
git log --oneline
git show --stat de00c76        # the problem 3 fixes
```

An earlier revision of this repository held answers to the previous version of the challenge, whose
problem set and numbering no longer match. Those are still in history rather than deleted.

## Environment

- macOS, Docker 24.0.2, Docker Compose v2.18.1
- Node 20 (in containers; nothing installed on the host)
- Diagrams: Mermaid, rendered inline by GitHub
- Linting: `rhysd/actionlint`, `koalaman/shellcheck` (both via Docker, no local installs)
