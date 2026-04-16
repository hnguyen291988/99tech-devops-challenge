# Problem 3 — Diagnose Me Doctor

## Scenario

Ubuntu 24.04 VM, 64GB disk, running only NGINX (as a load balancer / traffic router). Monitoring reports 99% disk usage.

---

## Step 1 — Initial Triage

```bash
df -h
du -sh /* 2>/dev/null | sort -rh | head -20
du -sh /var/* 2>/dev/null | sort -rh | head -10
du -sh /var/log/nginx/*
ls -lh /var/log/nginx/
journalctl --disk-usage
find / -type f -size +100M 2>/dev/null | xargs ls -lh | sort -k5 -rh | head -20
find / -name "core*" -type f 2>/dev/null
ls -lh /var/crash/ 2>/dev/null
du -sh /var/cache/apt/
du -sh /var/lib/nginx/tmp/ 2>/dev/null
```

---

## Cause 1: NGINX Access / Error Logs Filling Disk

**Likelihood: Very High**

NGINX writes every proxied request to access.log. At high traffic volumes this log grows at gigabytes per day with no rotation.

**Diagnosis:**
```bash
ls -lh /var/log/nginx/
```

**Impact:** Disk fills → OS cannot write temp files, create sockets, or fork processes → system instability, SSH may become unresponsive.

**Immediate recovery (zero downtime):**
```bash
truncate -s 0 /var/log/nginx/access.log
truncate -s 0 /var/log/nginx/error.log
```

**Long-term fix — configure logrotate:**
```
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
```

```bash
logrotate -d /etc/logrotate.d/nginx   # dry run
logrotate -f /etc/logrotate.d/nginx   # force rotate now
```

**Prevention:** Send NGINX logs to CloudWatch Logs, Datadog, or Loki and disable local file logging entirely.

---

## Cause 2: Systemd Journal Logs Unbounded

**Likelihood: High**

Ubuntu 24.04 uses persistent journal storage by default with no size cap.

**Diagnosis:**
```bash
journalctl --disk-usage
ls -lh /var/log/journal/
```

**Immediate recovery:**
```bash
journalctl --vacuum-time=7d
journalctl --vacuum-size=1G
```

**Long-term fix:**
```bash
# /etc/systemd/journald.conf
[Journal]
SystemMaxUse=2G
SystemKeepFree=1G
MaxRetentionSec=7day

systemctl restart systemd-journald
```

---

## Cause 3: Core Dumps Accumulating

**Likelihood: Medium**

If NGINX workers ever crashed (OOM, SIGSEGV), the OS writes core dump files of multiple GB each.

**Diagnosis:**
```bash
find / -name "core*" -type f 2>/dev/null
ls -lh /var/crash/
```

**Immediate recovery:**
```bash
rm -f /var/crash/* 2>/dev/null
find / -name "core.*" -type f -delete 2>/dev/null
```

**Long-term fix:**
```bash
# /etc/security/limits.conf
* hard core 0
* soft core 0

# /etc/sysctl.conf
kernel.core_pattern = /dev/null
sysctl -p
```

---

## Cause 4: NGINX Client Body Temp Files Not Cleaned

**Likelihood: Medium**

NGINX buffers request bodies to disk. On abnormal termination, temp files are orphaned.

**Diagnosis:**
```bash
du -sh /var/lib/nginx/tmp/
```

**Immediate recovery:**
```bash
find /var/lib/nginx/tmp/ -type f -mmin +60 -delete
```

**Long-term fix:** Add hourly cron job or disable disk buffering:
```nginx
proxy_request_buffering off;
proxy_max_temp_file_size 0;
```

---

## Cause 5: Old Kernel Packages / APT Cache

**Likelihood: Low-Medium**

```bash
apt autoremove -y && apt clean && apt autoclean
```

---

## Recovery Priority Order

| Priority | Action | Disk freed (typical) |
|---|---|---|
| 1 | Truncate NGINX logs | 10-50 GB |
| 2 | Vacuum systemd journals | 2-10 GB |
| 3 | Remove core dumps | 1-8 GB |
| 4 | Clean NGINX temp files | 0.5-5 GB |
| 5 | apt autoremove and apt clean | 0.5-2 GB |

---

## Monitoring & Alerting to Add

- Disk usage > 75% -- Warning alert
- Disk usage > 85% -- Critical alert
- NGINX log file > 5GB -- trigger logrotate
- Journal size > 2GB -- vacuum journals
