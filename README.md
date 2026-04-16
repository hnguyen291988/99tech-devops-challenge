# 99Tech DevOps Challenge — Solutions

## Overview

This repository contains my solutions to the 99Tech DevOps challenge. Each problem is solved in its own folder with a dedicated write-up.

| Problem | Title | Folder |
|---|---|---|
| 1 | Too Many Things To Do | [problem1/](./problem1/) |
| 2 | Building Castle In The Cloud | [problem2/](./problem2/) |
| 3 | Diagnose Me Doctor | [problem3/](./problem3/) |
| 4 | Debugging Issues Within System | [problem4/](./problem4/) |

---

## Assumptions

- **Problem 1:** jq is available on the Ubuntu 24.04 machine. The transaction log contains one JSON object per line.
- **Problem 2:** "Highly available" means surviving an AZ failure without downtime. Cost-effectiveness is balanced against throughput/latency requirements.
- **Problem 3:** NGINX is the sole workload on the VM. The VM is cloud-hosted so volume expansion is an option.
- **Problem 4:** The API source code is a black box; only infrastructure-level fixes are applied.

---

## Tools & Environment

- Shell: bash on Ubuntu 24.04 x86
- Cloud: AWS (Problem 2)
- Containers: Docker, Docker Compose v2
