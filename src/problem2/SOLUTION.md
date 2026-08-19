# Problem 2 — Diagnose Me Doctor

> **On "two production issues":** the task line asks for steps to troubleshoot two production
> issues, but only one scenario is given on the problem page (the 99%-disk NGINX load balancer).
> I've answered that one properly rather than inventing a second. If there's a second scenario I
> didn't get, I'm happy to take it.

## Scenario

Ubuntu 24.04 VM, 64 GB of storage, sole workload is an NGINX load balancer fronting upstream
services. Monitoring says disk usage is pinned at 99%.

**Assumptions I'm working from,** since they change the answer:

- It's a cloud VM, so growing the volume is an option and a snapshot is cheap insurance.
- I have root, and console/SSM access as well as SSH — important, because at 100% full SSH itself
  can fail to establish a session.
- NGINX is genuinely the only service, so I should be suspicious of anything on the disk that isn't
  NGINX, the OS, or an agent.
- There's at least a pair of these behind DNS or a health check, so I can take one out of rotation.
  If this is a single unreplicated LB, that changes my risk appetite completely and I say so below.

---

## Before touching anything: is this an incident or a chore?

This determines whether I get to be careful or have to be fast, and it takes about twenty seconds:

```bash
systemctl is-active nginx
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -H 'Host: real-vhost' http://127.0.0.1/healthz
tail -50 /var/log/nginx/error.log
uptime
```

Three outcomes:

- **NGINX is up and serving 2xx.** Disk is full but nothing is broken yet. I have time to diagnose
  properly, and I should — because whatever filled it will fill it again.
- **NGINX is up but erroring**, typically 500s with `[crit] ... No space left on device` in
  `error.log`. This is a live customer-facing incident. Take the node out of rotation first, then
  diagnose. NGINX will fail to write client bodies and temp files well before it fails to route.
- **NGINX is down or SSH is unusable.** Full outage on this node. Fail over first, recover second.

One thing I do before any deletion, always: **take a volume snapshot**. It costs a few cents and it
means an over-enthusiastic `find -delete` isn't career-defining. On a full disk you cannot copy
evidence off to the same disk, and once you truncate the logs the evidence of *why* it filled is
gone forever.

---

## Phase 1 — the five-minute triage

The order here isn't arbitrary. Each command rules out a class of cause that would make the next
command's answer misleading.

```bash
# 1. Which filesystem is actually full? "The disk" is often not the root filesystem.
df -h

# 2. Is it BYTES or INODES? Monitoring usually reports bytes and misses this entirely.
df -i

# 3. Is space held by deleted-but-still-open files? If df and du disagree, this is why.
#    On an NGINX box this is the single most common cause and the least intuitive.
sudo lsof +L1 2>/dev/null | sort -k7 -n -r | head -20

# 4. Now, and only now, walk the tree. Depth-limited so it returns before I lose patience.
sudo du -xhd1 / 2>/dev/null | sort -rh | head -15
sudo du -xhd1 /var 2>/dev/null | sort -rh | head -15

# 5. The top 20 biggest individual files on the root filesystem.
sudo find / -xdev -type f -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -20

# 6. Journal, which is on the same partition and is nobody's first guess.
journalctl --disk-usage

# 7. What is NGINX configured to write, and where? Never assume the default paths.
sudo nginx -T 2>/dev/null | grep -E '_log|_temp_path|_cache_path|client_body|proxy_buffering'
```

Two of those deserve emphasis, because they're the ones that separate a five-minute fix from an
afternoon of confusion.

**`df -i`.** Bytes and inodes are separate budgets. A million tiny files can leave you at 12% bytes
and 100% inodes, and every write fails with `No space left on device` while `df -h` looks fine. If
`df -i` is the one at 100%, the entire rest of this document reorders — the fix is "find the
directory with millions of files", not "find the big file".

**`lsof +L1`.** This lists open files with a link count of zero — deleted, but still held open by a
process, so the kernel hasn't released the blocks. `du` walks directory entries and cannot see them;
`df` asks the filesystem and can. **If `df` says 60 GB used and `du -x /` says 8 GB, stop looking
for a big file — you have already found the answer.**

### The decision point

```
df -h says full?
├── no  → check df -i. Inodes exhausted → jump to Cause 4.
└── yes → does du -x / roughly match df's used figure?
          ├── no, du is much smaller → deleted-but-open files → Cause 2.
          │                            (a mount shadowed by another mount is the rarer sibling)
          └── yes → walk du output down to the directory, then the file → Causes 1, 3, 5, 6, 7.
```

---

## Root causes, ranked by what I'd actually expect to find

| # | Cause | Likelihood on an NGINX-only LB | Confirm with |
|---|---|---|---|
| 1 | Access/error logs grew unbounded, or logrotate isn't rotating them | **Very high** | `ls -lh /var/log/nginx/` |
| 2 | Logs rotated but **deleted while NGINX still held the fd** — space never returned | **High**, and most-missed | `df` vs `du` mismatch; `lsof +L1` |
| 3 | NGINX proxy/client-body temp files accumulating | Medium-high | `du -sh` on the `*_temp_path` dirs; `df -i` |
| 4 | Inode exhaustion, usually from cause 3 or a proxy cache | Medium | `df -i` |
| 5 | `systemd` journal with no size cap | Medium | `journalctl --disk-usage` |
| 6 | Core dumps from a crashing NGINX worker | Low-medium | `ls -lh /var/lib/systemd/coredump/`, `coredumpctl list` |
| 7 | Human debris — a forgotten `tcpdump`, a copied-down DB dump, a stray `.tar.gz` in `/root` | Medium, and embarrassing | `find / -xdev -mtime -14 -size +100M` |
| 8 | Package/kernel accumulation, apt cache | Low | `du -sh /var/cache/apt /boot` |
| 9 | A monitoring/log-shipping agent buffering to disk because it can't reach its backend | Low-medium | `du -sh /var/lib/{amazon-cloudwatch-agent,vector,filebeat,fluent-bit}` |

I'd bet on 1 or 2 before running a single command, because that's what a load balancer does all day:
it writes one log line per request. But I'd still run the triage, because betting is how you spend an
hour fixing the wrong thing.

### Why 1 and 2 are the favourites — the arithmetic

An LB doing a modest 500 requests/second with the default `combined` log format at roughly 250 bytes
per line:

```
500 req/s × 250 B = 125 KB/s
              → ~10.8 GB/day
              → 64 GB disk full in under 6 days from empty
```

At 2,000 rps, or with a verbose custom log format that includes upstream timings and request
headers, it's a day and a half. This isn't an edge case — **an LB with logging on and rotation off
is a scheduled outage**, and the only question is the date. That arithmetic is also the argument for
the prevention section: the fix is not a bigger disk.

---

## Cause 1 — Logs grew unbounded

**How I confirm it**

```bash
ls -lh /var/log/nginx/
du -sh /var/log/nginx/
cat /etc/logrotate.d/nginx
sudo logrotate -d /etc/logrotate.d/nginx      # dry run, shows what it WOULD do and why not
systemctl status logrotate.timer               # is the timer even enabled?
ls -l /var/lib/logrotate/status                # when did it last actually run?
```

The `-d` dry run is the useful one. Ubuntu ships a working `/etc/logrotate.d/nginx`, so if logs are
unrotated something specific broke it, and `-d` usually tells you which line. In practice it's one
of: the timer is disabled, someone added a custom log path in `nginx.conf` that no logrotate rule
covers, `logrotate` is erroring out on an unrelated broken config file in `/etc/logrotate.d/` and
aborting the whole run, or the file's owner/permissions changed so `su`/`create` fails.

**Impact.** Silent for weeks, then everything at once. NGINX can't write logs, can't buffer request
bodies, can't create temp files for proxied responses larger than its in-memory buffers — so large
responses and uploads start failing while small ones look fine. The OS can't write `/tmp`, so new
SSH sessions may fail to establish, package operations fail, and any agent on the box starts
erroring. It looks like a network problem to everyone who isn't looking at disk.

**Immediate recovery — and the important part is what *not* to do**

```bash
# CORRECT: truncate in place. The inode survives, NGINX's fd stays valid,
# space is returned immediately, no restart, no dropped connections.
sudo truncate -s 0 /var/log/nginx/access.log

# WRONG: rm unlinks the file but NGINX keeps writing to the fd.
# Space is NOT returned, and now you can't even read the log. This is how you create Cause 2.
# sudo rm /var/log/nginx/access.log
```

If I want to keep a sample for forensics, take the tail *before* truncating, and put it somewhere
that isn't the full disk:

```bash
tail -n 20000 /var/log/nginx/access.log | gzip > /dev/shm/access-sample.gz
# then scp it off, or ship it, before it disappears with the reboot
sudo truncate -s 0 /var/log/nginx/access.log
```

**Permanent fix**

```bash
sudo tee /etc/logrotate.d/nginx >/dev/null <<'EOF'
/var/log/nginx/*.log {
    hourly
    rotate 24
    maxsize 500M          # rotate on size too, so a traffic spike can't outrun the schedule
    compress
    delaycompress
    missingok
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        # reopen, don't restart: no dropped connections, and this is what
        # releases the old file descriptor. Skipping it causes Cause 2.
        [ -f /run/nginx.pid ] && kill -USR1 "$(cat /run/nginx.pid)"
    endscript
}
EOF

sudo logrotate -d /etc/logrotate.d/nginx     # verify before trusting it
sudo systemctl enable --now logrotate.timer
```

Two deliberate choices in there. `maxsize` matters because a daily schedule with a traffic spike
still fills the disk before `logrotate` next runs — size-based rotation is what makes it robust to
traffic you didn't predict. And `kill -USR1` rather than `nginx -s reload`: `USR1` reopens log files
without touching workers or connections, which is exactly and only what I want here.

---

## Cause 2 — Space held by deleted-but-open files

The one that wastes the most time, because every instinct is wrong. `du` says the disk is nearly
empty, `df` says it's full, and the temptation is to distrust `df`. `df` is right.

**How I confirm it**

```bash
df -h /                              # e.g. 61G used
sudo du -xsh / 2>/dev/null           # e.g. 9G  ← 52G unaccounted for
sudo lsof +L1 | sort -k7 -nr | head
# nginx 812 www-data 3w REG 202,1 54692184064 0 1049622 /var/log/nginx/access.log (deleted)
#                                              ^ link count 0        ^ "(deleted)"
```

That `(deleted)` with a link count of `0` and a 54 GB size is the whole diagnosis.

**Root cause behind the root cause.** Someone (or a broken rotation script) ran `rm` on the active
log — or rotated it without a `postrotate` reopen. NGINX holds the file descriptor open and keeps
writing to an inode that no longer has a name. The kernel can't reclaim the blocks until the last
descriptor closes.

**Impact.** Identical to Cause 1, but with the extra property that it looks unexplainable, so
mean-time-to-diagnosis is measured in hours rather than minutes. It also recurs on exactly the same
schedule until the rotation config is fixed, because the cause is the config, not the file.

**Immediate recovery.** Signal NGINX to reopen its log files. This closes the orphaned descriptors
and the space comes back instantly:

```bash
sudo nginx -s reopen         # or: sudo kill -USR1 "$(cat /run/nginx.pid)"
df -h /                      # space returns immediately, no restart, no dropped connections
```

If the process holding the file isn't NGINX and can't be signalled, you can truncate through
`/proc` without killing it:

```bash
sudo truncate -s 0 /proc/<pid>/fd/<fd>
```

Restarting the process also works and is the sledgehammer. On a load balancer I'd rather send one
signal than take the node's connections down, so `reopen` first, always.

**Permanent fix.** The `postrotate` block in Cause 1. This failure mode only exists when rotation
forgets to tell NGINX.

---

## Cause 3 — NGINX temp files, and Cause 4 — inode exhaustion

These usually arrive together, so I'll treat them as one.

When a proxied response is larger than `proxy_buffers`, NGINX spills the rest to
`proxy_temp_path`. Same for request bodies larger than `client_body_buffer_size`, in
`client_body_temp_path`. Normally those files are created and unlinked within milliseconds. They
accumulate when clients disconnect mid-transfer, when a worker is killed with files in flight, or
when the LB is proxying large payloads at volume — and if `proxy_cache_path` is configured, the
cache itself grows without bound unless `max_size` is set.

**Confirm**

```bash
sudo nginx -T | grep -E '_temp_path|proxy_cache_path'      # find the real paths first
du -sh /var/lib/nginx/* /var/cache/nginx/* 2>/dev/null
sudo find /var/lib/nginx /var/cache/nginx -xdev -type f | wc -l
df -i /                                                    # the tell: inodes at 100%, bytes fine
```

**Impact.** Two distinct flavours. Bytes: same as any full disk. Inodes: *everything* that creates a
file fails while `df -h` shows plenty of free space, which sends people looking in completely the
wrong direction. Also, `rm -rf` on a directory with millions of entries is slow and I/O-heavy, so the
cleanup itself can degrade the box.

**Immediate recovery**

```bash
# Old orphans only — never blanket-delete, live requests are using files in here.
sudo find /var/lib/nginx/proxy_temp -xdev -type f -mmin +60 -delete
sudo find /var/lib/nginx/client_body_temp -xdev -type f -mmin +60 -delete

# For a genuinely enormous directory, this is much faster than rm -rf:
# sudo find /var/cache/nginx/ -xdev -type f -delete
```

**Permanent fix**

```nginx
# Cap the cache so it can never be the thing that fills the disk.
proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=cache:100m max_size=8g inactive=24h;

# For a pure pass-through load balancer, don't buffer to disk at all.
proxy_max_temp_file_size 0;      # never spill a proxied response to disk
proxy_request_buffering off;     # stream request bodies upstream instead of staging them
client_max_body_size 32m;        # and put an explicit ceiling on uploads
```

`proxy_request_buffering off` is the right call for a router that isn't inspecting bodies, and it
removes this entire failure class. The trade-off is real and worth stating: with buffering off, a
slow client holds an upstream connection open for the duration of its upload, so slow-loris style
abuse reaches your backends instead of dying at the LB. On a public-facing LB I'd keep buffering on
with a tight `client_max_body_size` and a capped `proxy_max_temp_file_size` instead. Which one is
right depends on whether the upstreams can defend themselves.

Put the temp/cache paths on **their own volume** if this box handles large payloads. Then a runaway
cache fills a volume nobody's OS depends on, and the incident is a graph instead of an outage.

---

## Cause 5 — systemd journal with no cap

**Confirm**

```bash
journalctl --disk-usage
du -sh /var/log/journal/
grep -E '^\s*(SystemMaxUse|SystemKeepFree|MaxRetentionSec)' /etc/systemd/journald.conf
```

Default behaviour is to use up to 10% of the filesystem, so on a 64 GB disk that's ~6.4 GB — not
enough to be the sole cause, but plenty to be the last 6 GB that tips a nearly-full disk over. It's
also worth checking whether NGINX is logging to *both* files and the journal, which doubles the
volume for no benefit.

**Immediate recovery**

```bash
sudo journalctl --vacuum-size=500M
# or by age:  sudo journalctl --vacuum-time=7d
```

**Permanent fix**

```bash
sudo tee /etc/systemd/journald.conf.d/10-size-cap.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=1G
SystemKeepFree=4G
MaxRetentionSec=14day
EOF
sudo systemctl restart systemd-journald
```

`SystemKeepFree` is the one that actually protects you — it's an absolute floor of free space the
journal will never eat into, regardless of how big the disk is.

---

## Cause 6 — Core dumps

**Confirm**

```bash
coredumpctl list | tail -20
du -sh /var/lib/systemd/coredump/
cat /proc/sys/kernel/core_pattern
grep -c 'signal 11' /var/log/nginx/error.log     # nginx worker segfaults
```

**Impact.** An NGINX worker with a large memory footprint produces a multi-GB dump per crash. If a
worker is crash-looping — a bad third-party module, a malformed request hitting a bug — you get one
dump per crash and the disk goes in minutes rather than days.

This one matters more than its size, because **a segfaulting worker is a bigger problem than the
disk**. If I find dumps here, the disk is the symptom and I've just found a real bug. Keep one dump,
delete the rest, and get it to whoever owns the module.

**Recovery and permanent fix**

```bash
sudo coredumpctl info > /dev/shm/crash-summary.txt      # keep the metadata
sudo journalctl --rotate && sudo journalctl --vacuum-time=1s   # clears journal-stored dumps
sudo rm -f /var/lib/systemd/coredump/*                 # after preserving one sample

sudo tee /etc/systemd/coredump.conf.d/10-limits.conf >/dev/null <<'EOF'
[Coredump]
Storage=external
Compress=yes
MaxUse=2G
KeepFree=8G
EOF
sudo systemctl daemon-reload
```

I'd cap dumps rather than disable them. Turning core dumps off entirely to save disk is trading away
the ability to diagnose the crash, and the crash is the actual incident.

---

## Cause 7 — Human debris

The one nobody writes runbooks for, and the one I've personally caused.

```bash
# Anything big and recently written
sudo find / -xdev -type f -size +100M -mtime -14 -printf '%TF %10s %p\n' 2>/dev/null | sort -k1

# Is someone's debugging session still running?
ps aux | grep -E 'tcpdump|strace|perf|dd ' | grep -v grep
sudo lsof -c tcpdump 2>/dev/null

# The usual hiding places
du -sh /root /home/* /tmp /var/tmp 2>/dev/null
```

A `tcpdump` left running on a load balancer without `-C`/`-W` writes at line rate. On a busy LB
that's gigabytes per minute, and it is by far the fastest way to fill a disk on this box. Same
family: a database dump copied to `/root` "temporarily" during a migration, an unpacked `.tar.gz`
nobody cleaned up, a `dd` that was supposed to be a quick test.

**Recovery:** kill the process (that's what's still growing), archive anything that might be needed,
delete the rest. **Prevention** is cultural, not technical: capture with `tcpdump -C 100 -W 5` so it
self-rotates, do that work in `/dev/shm` or on a scratch volume, and treat "I'll clean it up later"
as the lie it is. A monitoring alarm on disk *growth rate* catches this within minutes, which is the
technical half of the answer.

---

## Cause 8 — Packages and kernels, Cause 9 — a stuck agent

Lower likelihood, quick to rule out, quick to fix.

```bash
du -sh /var/cache/apt /var/lib/apt/lists /boot
dpkg -l | awk '/^ii  linux-image/ {print $2}'     # how many old kernels are we carrying?

du -sh /var/lib/amazon-cloudwatch-agent /var/lib/vector /var/lib/filebeat /var/lib/fluent-bit 2>/dev/null
journalctl -u amazon-cloudwatch-agent --since -1h | tail -20
```

```bash
sudo apt-get clean
sudo apt-get autoremove --purge          # removes superseded kernels; watch /boot if it's separate
```

The agent case is worth calling out because it's genuinely counter-intuitive: a log shipper that
*can't reach its backend* buffers to disk, so an outage in your observability platform becomes a
disk-full outage on every node an hour later. If I find this, the fix isn't on this VM — it's the
agent's buffer cap (`total_limit_size` for CloudWatch agent, `buffer.max_size` for Vector) plus an
alarm on the agent's own send-failure metric.

---

## Recovery order, when I need space right now

Fastest and safest first. Each step is reversible or evidence-preserving; nothing here needs an
NGINX restart.

| # | Action | Typical space back | Risk |
|---|---|---|---|
| 1 | `nginx -s reopen` (releases deleted-but-open fds) | Everything, if Cause 2 | None |
| 2 | `truncate -s 0` the big NGINX logs, after sampling the tail | 10-50 GB | None |
| 3 | `journalctl --vacuum-size=500M` | 1-6 GB | Loses old journal history |
| 4 | Delete temp/cache files older than 60 min | 0.5-10 GB | None if the `-mmin` filter is kept |
| 5 | Remove core dumps, keeping one | 1-8 GB | Loses crash evidence — keep one |
| 6 | `apt-get clean && autoremove --purge` | 0.5-3 GB | Watch `/boot` if separate |
| 7 | Grow the volume, then `growpart` + `resize2fs` | As needed | Online and safe, but treats the symptom |

Step 7 is deliberately last, and I want to be clear about why. Growing the disk is the right call
when you've genuinely outgrown 64 GB — and it's the wrong call as a fix, because a leak fills 128 GB
just as reliably, only later and at a worse hour. I'll grow the volume to end the incident and to buy
diagnosis time, but the ticket doesn't close until rotation and caps are in place. On this box, given
the arithmetic above, the honest answer is almost certainly "the disk is fine, the logging is
unbounded".

And the thing I'd resist doing under pressure: **restarting NGINX to see if it helps.** On a full
disk a restart can fail to come back — an unwritable temp path, a config validation that needs to
write, a PID file it can't create — and now the node is down rather than degraded, with no obvious
way back.

---

## Prevention — how this stops being a recurring incident

Everything above is treatment. This is the part that matters, and it's the part I'd actually be
judged on six months later.

**1. Stop storing logs on the box at all.**
Ship to CloudWatch Logs / Loki / whatever's in use, keep a small local buffer with a hard cap, and
the disk stops being a function of traffic volume. This is the single highest-leverage change and it
makes Causes 1, 2 and 5 structurally impossible rather than merely configured-against. It also means
the logs survive the instance, which is the reason I'd want it even if disk were free.

**2. Separate volumes for anything that grows.**
`/var/log`, and the NGINX temp/cache paths, on their own volumes. When something runs away it fills a
volume the OS doesn't need to function. The node stays reachable, NGINX keeps routing, and I get a
graph instead of a page. This is cheap and it is the difference between "degraded" and "down".

**3. Sample the access log.**
A load balancer does not need to log every 200. Either log errors only, or sample:

```nginx
# 1% of successful requests, 100% of everything else
map $status $loggable { ~^[23] 0; default 1; }
split_clients "${remote_addr}${request_id}" $sampled { 1% 1; * 0; }
access_log /var/log/nginx/access.log combined if=$loggable;
access_log /var/log/nginx/sampled.log  combined if=$sampled;
```

That's a 50-100x reduction in log volume with no loss of the information anyone actually looks at
during an incident. If there's a compliance requirement to log every request, that changes the
answer — and it changes it toward "ship them off-box", not "keep them here".

**4. Bake the caps into the image, not the runbook.**
The logrotate config, journald caps, coredump caps and NGINX temp limits all belong in the golden
AMI (Packer) or the config management (Ansible), not in a wiki page someone applies by hand. A
prevention step that lives in a document is applied to the machines someone remembered.

**5. Alert earlier, and alert on the derivative.**

| Alarm | Threshold | Why |
|---|---|---|
| Disk used % | warn 75%, page 85% | 99% is not an alert, it's a post-mortem |
| **Disk inodes used %** | warn 80% | The one nearly everyone forgets, and it fails identically |
| **Disk fill rate** | page if projected full < 4h | Catches the `tcpdump` and the crash-loop *while there's still time*, which a static threshold cannot |
| Log directory size | warn > 5 GB | Names the culprit in the alert itself |
| NGINX worker restarts / `signal 11` in error log | any | Cause 6 is a bug, not a disk problem |
| Agent send-failure rate | > 0 sustained | Cause 9, before it fills every node |

The fill-rate alarm is the one I'd push hardest for. A threshold alarm tells you the disk is full; a
rate alarm tells you it's *going* to be full, in time to do something calm about it. Most of the
incidents above are only incidents because nobody noticed the slope.

**6. Test it.**
`fallocate -l 55G /var/tmp/fill` on a staging node, confirm the alarms fire in the right order and
that the runbook above actually works, then delete it. A disk-full runbook that's never been run on
a genuinely full disk is a hypothesis. This is also the cheapest game day there is.
