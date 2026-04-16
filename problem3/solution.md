# Problem 3 — Diagnose Me Doctor

## Scenario

Ubuntu 24.04 VM, 64GB disk, running only NGINX as a load balancer. Monitoring reports 99% disk usage.

---

## Step 1 — Find where disk space is going

```bash
# Check overall disk usage by partition
df -h

# Find the largest top-level directories
du -sh /* 2>/dev/null | sort -rh | head -20

# Drill into /var (most likely culprit — logs live here)
du -sh /var/* 2>/dev/null | sort -rh | head -10
```

---

## Step 2 — Investigate the most likely causes

```bash
# 1. Check NGINX log sizes — most common cause on an LB-only VM
du -sh /var/log/nginx/*
ls -lh /var/log/nginx/

# 2. Check systemd journal size — often overlooked
journalctl --disk-usage

# 3. Check for core dump files — each can be several GB
find / -name "core*" -type f 2>/dev/null
ls -lh /var/crash/ 2>/dev/null

# 4. Check NGINX client body temp files — orphaned on crash
du -sh /var/lib/nginx/tmp/ 2>/dev/null

# 5. Check apt package cache — leftover from OS updates
du -sh /var/cache/apt/
```

---

## Root Causes, Impacts & Fixes

### Cause 1 — NGINX logs unbounded (Likelihood: Very High)

**Impact:** Disk fills silently → OS cannot write temp files or fork processes → SSH may become unresponsive.

```bash
# Immediate fix — truncate safely without restarting NGINX
truncate -s 0 /var/log/nginx/access.log
truncate -s 0 /var/log/nginx/error.log

# Long-term — configure logrotate
cat > /etc/logrotate.d/nginx <<EOF
/var/log/nginx/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        nginx -s reopen
    endscript
}
EOF

logrotate -f /etc/logrotate.d/nginx
```

---

### Cause 2 — Systemd journal unbounded (Likelihood: High)

**Impact:** Silently grows over weeks, fills the same partition.

```bash
# Immediate fix
journalctl --vacuum-size=1G

# Long-term — cap journal size permanently
sed -i 's/#SystemMaxUse=/SystemMaxUse=2G/' /etc/systemd/journald.conf
systemctl restart systemd-journald
```

---

### Cause 3 — Core dumps accumulating (Likelihood: Medium)

**Impact:** Each dump is 1–4 GB — multiple crashes silently drain disk.

```bash
# Immediate fix
rm -f /var/crash/* 2>/dev/null
find / -name "core.*" -type f -delete 2>/dev/null

# Long-term — disable core dumps
echo "* hard core 0" >> /etc/security/limits.conf
echo "kernel.core_pattern = /dev/null" >> /etc/sysctl.conf
sysctl -p
```

---

### Cause 4 — NGINX temp files not cleaned (Likelihood: Medium)

**Impact:** Abandoned upload buffers accumulate on abnormal request termination.

```bash
# Immediate fix — delete files older than 1 hour
find /var/lib/nginx/tmp/ -type f -mmin +60 -delete

# Long-term — disable disk buffering in NGINX config
# proxy_request_buffering off;
# proxy_max_temp_file_size 0;
```

---

### Cause 5 — Old packages / apt cache (Likelihood: Low-Medium)

```bash
apt autoremove -y && apt clean
```

---

## Recovery Priority

| Priority | Action | Typical disk freed |
|---|---|---|
| 1 | Truncate NGINX logs | 10–50 GB |
| 2 | Vacuum systemd journals | 2–10 GB |
| 3 | Remove core dumps | 1–8 GB |
| 4 | Clean NGINX temp files | 0.5–5 GB |
| 5 | apt autoremove + clean | 0.5–2 GB |

---

## Prevention

- Alert at **75% disk** (warning) and **85%** (critical) — before it becomes an incident
- Ship NGINX logs to a centralised system (CloudWatch Logs, Loki) and disable local file logging
- Set journal size cap and logrotate on every new VM as part of the base image / user-data script
