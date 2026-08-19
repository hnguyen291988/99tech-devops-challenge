# Problem 2 — Diagnose Me Doctor

> The task line asks for two production issues, but only one scenario is on the problem page (the 99%
> disk NGINX load balancer). I answered that one properly instead of inventing a second. Happy to take
> the other one if I missed it.

## Scenario

Ubuntu 24.04, 64 GB disk, only workload is an NGINX load balancer. Monitoring says disk is at 99%.

**My assumptions**, because they change the answer:

- It is a cloud VM, so I can grow the volume and take a cheap snapshot.
- I have root, and also console/SSM access. This matters: at 100% full, SSH can fail to open a session.
- NGINX really is the only service, so anything else on the disk is suspicious.
- There is more than one LB behind DNS or a health check, so I can take this one out of rotation. If it
  is a single LB, my risk appetite changes completely.

## First: is this an incident or a chore?

This takes 20 seconds and decides whether I can be careful or must be fast.

```bash
systemctl is-active nginx
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' -H 'Host: real-vhost' http://127.0.0.1/healthz
tail -50 /var/log/nginx/error.log
```

- **NGINX up, serving 2xx** — disk is full but nothing is broken yet. I have time to find the cause, and
  I should, because whatever filled it will fill it again.
- **NGINX up but erroring**, usually 500s with `No space left on device` in `error.log` — live incident.
  Take the node out of rotation, then diagnose.
- **NGINX down, or SSH unusable** — full outage on this node. Fail over first.

Before deleting anything I **take a volume snapshot**. It costs a few cents. On a full disk I cannot copy
evidence anywhere, and once I truncate the logs the reason it filled is gone forever.

## Five-minute triage

The order matters. Each command rules out something that would make the next answer misleading.

```bash
# 1. Which filesystem is full? "The disk" is often not /
df -h

# 2. Bytes or INODES? Monitoring usually reports bytes and misses this completely
df -i

# 3. Space held by deleted-but-still-open files? On an NGINX box this is very common
#    and the least obvious
sudo lsof +L1 2>/dev/null | sort -k7 -n -r | head -20

# 4. Now walk the tree, depth-limited so it returns quickly
sudo du -xhd1 / 2>/dev/null | sort -rh | head -15
sudo du -xhd1 /var 2>/dev/null | sort -rh | head -15

# 5. Biggest single files
sudo find / -xdev -type f -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -20

# 6. Journal. Same partition, and nobody's first guess
journalctl --disk-usage

# 7. What does NGINX actually write, and where? Never assume default paths
sudo nginx -T 2>/dev/null | grep -E '_log|_temp_path|_cache_path|client_body|proxy_buffering'
```

Two of these decide between a five-minute fix and a wasted afternoon.

**`df -i`.** Bytes and inodes are separate budgets. A million tiny files can leave you at 12% bytes and
100% inodes. Every write then fails with `No space left on device` while `df -h` looks fine. If inodes are
the problem, the fix is "find the directory with millions of files", not "find the big file".

**`lsof +L1`.** This shows files with link count zero: deleted, but a process still holds them open, so the
kernel cannot free the blocks. `du` walks directory entries and cannot see them. `df` asks the filesystem
and can. **If `df` says 60 GB used and `du -x /` says 8 GB, stop looking for a big file. You already found
the answer.**

```
df -h full?
├── no  → check df -i. Inodes at 100% → Cause 3.
└── yes → does du -x / roughly match df?
          ├── no, du much smaller → deleted-but-open files → Cause 2
          └── yes → walk du output to the directory, then the file → Cause 1, 3, 4, 5
```

## Causes, ranked by what I expect to find

| # | Cause | Likely on an LB? | Confirm with |
|---|---|---|---|
| 1 | NGINX logs grew, or logrotate is not rotating | **Very high** | `ls -lh /var/log/nginx/` |
| 2 | Logs rotated but **deleted while NGINX held the fd** | **High**, and most missed | `df` vs `du` mismatch, `lsof +L1` |
| 3 | NGINX temp/cache files, and inode exhaustion | Medium-high | `du -sh` on `*_temp_path`, `df -i` |
| 4 | systemd journal with no size cap | Medium | `journalctl --disk-usage` |
| 5 | Human debris: forgotten `tcpdump`, a DB dump in `/root` | Medium, and embarrassing | `find / -xdev -mtime -14 -size +100M` |
| 6 | Core dumps from a crashing worker | Low-medium | `coredumpctl list` |
| 7 | apt cache, old kernels | Low | `du -sh /var/cache/apt /boot` |
| 8 | A log shipper buffering because it cannot reach its backend | Low-medium | `du -sh /var/lib/vector /var/lib/amazon-cloudwatch-agent` |

I would bet on 1 or 2 before running anything, because that is what a load balancer does all day: one log
line per request. But I still run the triage, because betting is how you spend an hour fixing the wrong
thing.

**Why 1 and 2 are the favourites — the maths.** A modest 500 req/s with the default `combined` format at
about 250 bytes per line:

```
500 req/s × 250 B = 125 KB/s → ~10.8 GB/day → 64 GB full in under 6 days
```

At 2,000 rps, or with a custom format that logs upstream timings and headers, it is a day and a half. This
is not an edge case. **An LB with logging on and rotation off is a scheduled outage**, and the only question
is the date. That is also the argument for the prevention section: the fix is not a bigger disk.

---

## Cause 1 — Logs grew with no rotation

```bash
ls -lh /var/log/nginx/
cat /etc/logrotate.d/nginx
sudo logrotate -d /etc/logrotate.d/nginx      # dry run: what it WOULD do, and why not
systemctl status logrotate.timer               # is the timer even on?
ls -l /var/lib/logrotate/status                # when did it last run?
```

The dry run is the useful one. Ubuntu ships a working nginx logrotate config, so if logs are unrotated,
something specific broke it. Usually: the timer is off, someone added a log path no rule covers, another
broken file in `/etc/logrotate.d/` makes the whole run abort, or file ownership changed so `create` fails.

**Impact.** Quiet for weeks, then everything at once. NGINX cannot write logs, cannot buffer request
bodies, cannot create temp files for large proxied responses. So big responses and uploads fail while small
ones look fine. The OS cannot write `/tmp`, so new SSH sessions may fail. To everyone not looking at disk,
it looks like a network problem.

**Fix now — and the important part is what NOT to do:**

```bash
# CORRECT: truncate in place. Inode survives, NGINX's fd stays valid,
# space comes back at once, no restart, no dropped connections.
sudo truncate -s 0 /var/log/nginx/access.log

# WRONG: rm unlinks the file but NGINX keeps writing to the fd.
# Space is NOT returned, and now you cannot even read the log.
# This is how you create Cause 2.
# sudo rm /var/log/nginx/access.log
```

Keep a sample first, somewhere that is not the full disk:

```bash
tail -n 20000 /var/log/nginx/access.log | gzip > /dev/shm/access-sample.gz
sudo truncate -s 0 /var/log/nginx/access.log
```

**Permanent fix:**

```bash
sudo tee /etc/logrotate.d/nginx >/dev/null <<'EOF'
/var/log/nginx/*.log {
    hourly
    rotate 24
    maxsize 500M          # rotate on size too, so a traffic spike cannot outrun the schedule
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

`maxsize` matters: a daily schedule plus a traffic spike still fills the disk before logrotate next runs.
And `kill -USR1` instead of `nginx -s reload`, because USR1 reopens log files without touching workers or
connections. That is exactly what I want.

## Cause 2 — Space held by deleted-but-open files

The one that wastes the most time, because every instinct is wrong. `du` says the disk is nearly empty,
`df` says it is full, and you want to distrust `df`. `df` is right.

```bash
df -h /                              # 61G used
sudo du -xsh / 2>/dev/null           # 9G  ← 52G missing
sudo lsof +L1 | sort -k7 -nr | head
# nginx 812 www-data 3w REG 202,1 54692184064 0 1049622 /var/log/nginx/access.log (deleted)
#                                              ^ link count 0        ^ "(deleted)"
```

That line is the whole diagnosis. Someone ran `rm` on the active log, or rotation ran with no reopen. NGINX
keeps writing to an inode that has no name, and the kernel cannot free the blocks.

**Impact.** Same as Cause 1, plus it looks unexplainable, so time-to-diagnose is hours instead of minutes.
And it comes back on the same schedule, because the cause is the config, not the file.

**Fix now:**

```bash
sudo nginx -s reopen         # or: kill -USR1 "$(cat /run/nginx.pid)"
df -h /                      # space returns immediately, no restart
```

If the process is not NGINX and cannot be signalled, truncate through `/proc` without killing it:

```bash
sudo truncate -s 0 /proc/<pid>/fd/<fd>
```

Restarting also works and is the sledgehammer. On a load balancer I send one signal instead of dropping
connections. **Permanent fix is the `postrotate` block above.** This failure only exists when rotation
forgets to tell NGINX.

## Cause 3 — Temp files and inode exhaustion

These arrive together. When a proxied response is bigger than `proxy_buffers`, NGINX spills to
`proxy_temp_path`. Same for request bodies. Normally those files live milliseconds. They pile up when clients
disconnect mid-transfer, when a worker is killed with files in flight, or when `proxy_cache_path` has no
`max_size`.

```bash
sudo nginx -T | grep -E '_temp_path|proxy_cache_path'   # find the real paths first
du -sh /var/lib/nginx/* /var/cache/nginx/* 2>/dev/null
sudo find /var/lib/nginx /var/cache/nginx -xdev -type f | wc -l
df -i /                                                  # the tell: inodes 100%, bytes fine
```

**Impact.** Two flavours. Bytes: normal full disk. Inodes: everything that creates a file fails while
`df -h` shows free space, which sends people looking in completely the wrong place.

**Fix now** (old orphans only, live requests are using files in there):

```bash
sudo find /var/lib/nginx/proxy_temp -xdev -type f -mmin +60 -delete
sudo find /var/lib/nginx/client_body_temp -xdev -type f -mmin +60 -delete
```

**Permanent fix:**

```nginx
proxy_cache_path /var/cache/nginx levels=1:2 keys_zone=cache:100m max_size=8g inactive=24h;
proxy_max_temp_file_size 0;      # never spill a proxied response to disk
proxy_request_buffering off;     # stream request bodies instead of staging them
client_max_body_size 32m;
```

`proxy_request_buffering off` removes this whole failure class for a pass-through LB. The trade-off is real:
with buffering off, a slow client holds an upstream connection open for its whole upload, so slow-loris style
abuse reaches the backends instead of dying at the LB. On a public LB I would keep buffering on with a tight
`client_max_body_size` and a capped `proxy_max_temp_file_size` instead. Which is right depends on whether the
upstreams can defend themselves.

If this box handles large payloads, put temp and cache paths on **their own volume**. Then a runaway cache
fills a volume the OS does not need, and the incident is a graph instead of an outage.

## Causes 4-8 — quick to rule out, quick to fix

```bash
# 4. Journal. Default is up to 10% of the filesystem = ~6.4 GB here.
journalctl --disk-usage
sudo journalctl --vacuum-size=500M
# permanent: SystemMaxUse=1G, SystemKeepFree=4G in /etc/systemd/journald.conf.d/
# SystemKeepFree is the one that really protects you: an absolute floor of free space.

# 5. Human debris. Anything big and recent, and any debugging still running.
sudo find / -xdev -type f -size +100M -mtime -14 -printf '%TF %10s %p\n' 2>/dev/null | sort
ps aux | grep -E 'tcpdump|strace|perf|dd ' | grep -v grep
# A tcpdump on a busy LB with no -C/-W writes gigabytes per minute. This is the fastest
# way to fill this disk. Kill the process first: that is what is still growing.
# Prevention is cultural: tcpdump -C 100 -W 5, and work in /dev/shm.

# 6. Core dumps. A crashing worker with a big heap writes GB per crash.
coredumpctl list | tail -20
grep -c 'signal 11' /var/log/nginx/error.log
# If I find these, the disk is the SYMPTOM and I just found a real bug.
# Keep one dump, delete the rest, cap with MaxUse=2G / KeepFree=8G.
# I cap dumps rather than disable them: turning them off trades away the diagnosis.

# 7. Packages and kernels.
sudo apt-get clean && sudo apt-get autoremove --purge   # watch /boot if separate

# 8. A log shipper that cannot reach its backend buffers to disk. So an outage in your
#    observability platform becomes a disk-full outage on every node an hour later.
du -sh /var/lib/vector /var/lib/amazon-cloudwatch-agent 2>/dev/null
# The fix is not on this VM: it is the agent's buffer cap plus an alarm on send failures.
```

---

## Recovery order when I need space now

Fastest and safest first. Nothing here needs an NGINX restart.

| # | Action | Typical space back | Risk |
|---|---|---|---|
| 1 | `nginx -s reopen` (releases deleted-but-open fds) | Everything, if Cause 2 | None |
| 2 | `truncate -s 0` the big logs, after sampling | 10-50 GB | None |
| 3 | `journalctl --vacuum-size=500M` | 1-6 GB | Loses old journal history |
| 4 | Delete temp/cache files older than 60 min | 0.5-10 GB | None with the `-mmin` filter |
| 5 | Remove core dumps, keep one | 1-8 GB | Loses crash evidence |
| 6 | `apt-get clean && autoremove --purge` | 0.5-3 GB | Watch `/boot` |
| 7 | Grow the volume, `growpart` + `resize2fs` | As needed | Online and safe, but treats the symptom |

Step 7 is last on purpose. Growing the disk is right when you have genuinely outgrown 64 GB. It is wrong as
a fix, because a leak fills 128 GB just as reliably, only later and at a worse hour. I will grow it to end
the incident, but the ticket stays open until rotation and caps are in place. Given the maths above, the
honest answer here is almost certainly "the disk is fine, the logging is unbounded".

And the thing I would resist under pressure: **restarting NGINX to see if it helps.** On a full disk it can
fail to come back — an unwritable temp path, a PID file it cannot create — and now the node is down instead
of degraded, with no obvious way back.

## Prevention

Everything above is treatment. This is the part that matters six months later.

1. **Stop keeping logs on the box.** Ship to CloudWatch Logs or Loki, keep a small capped local buffer. Then
   disk stops being a function of traffic. This makes Causes 1, 2 and 4 structurally impossible instead of
   just configured against, and the logs survive the instance.
2. **Separate volumes for anything that grows.** `/var/log` and the NGINX temp/cache paths on their own
   volumes. When something runs away, it fills a volume the OS does not need. The node stays reachable and I
   get a graph instead of a page.
3. **Sample the access log.** An LB does not need to log every 200:

   ```nginx
   map $status $loggable { ~^[23] 0; default 1; }
   split_clients "${remote_addr}${request_id}" $sampled { 1% 1; * 0; }
   access_log /var/log/nginx/access.log combined if=$loggable;
   access_log /var/log/nginx/sampled.log  combined if=$sampled;
   ```

   That is 50-100x less volume with no loss of what people actually read during an incident. If compliance
   needs every request logged, the answer becomes "ship them off-box", not "keep them here".
4. **Bake the caps into the image, not the runbook.** Logrotate config, journald caps, coredump caps, NGINX
   temp limits — all in the Packer AMI or Ansible. A prevention step that lives in a wiki page gets applied
   to the machines someone remembered.
5. **Alert earlier, and alert on the slope:**

   | Alarm | Threshold | Why |
   |---|---|---|
   | Disk used % | warn 75%, page 85% | 99% is not an alert, it is a post-mortem |
   | **Disk inodes %** | warn 80% | Everyone forgets it, and it fails identically |
   | **Fill rate** | page if full in < 4h | Catches the `tcpdump` and the crash loop while there is still time |
   | Log dir size | warn > 5 GB | Names the culprit in the alert |
   | Worker restarts / `signal 11` | any | Cause 6 is a bug, not a disk problem |
   | Agent send failures | any sustained | Cause 8, before it fills every node |

   The fill-rate alarm is the one I would push hardest for. A threshold alarm says the disk is full. A rate
   alarm says it is *going* to be full, in time to do something calm. Most of the incidents above are only
   incidents because nobody watched the slope.
6. **Test it.** `fallocate -l 55G /var/tmp/fill` on a staging node, check the alarms fire in the right order
   and the runbook works, then delete it. A disk-full runbook never run on a full disk is a guess. It is also
   the cheapest game day there is.
