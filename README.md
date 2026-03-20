# ENM Health Check Script

Automated health check tool for 8 ENM (Ericsson Network Manager) servers.
SSHs into each server, runs the Ericsson health check, collects logs, and
generates a summary report highlighting errors and failures.

**Current version:** `v4.0` — `enm_healthcheck_all-v2.sh`

## Servers Monitored

| # | Name     | IP              |
|---|----------|-----------------|
| 1 | ENMR1    | 10.21.233.4     |
| 2 | ENMR2    | 10.26.14.11     |
| 3 | ENMR3    | 10.26.16.11     |
| 4 | ENMR4    | 10.26.18.11     |
| 5 | ENMJ1    | 172.20.126.134  |
| 6 | ENMJ2    | 10.26.20.11     |
| 7 | ENMTX    | 10.26.22.11     |
| 8 | ENMCORE  | 10.21.73.106    |

## Directory Structure

```
/home/eric/scripts/ajiteguh/
├── enm_healthcheck_all-v2.sh               # Main script (v4.0)
├── enm_healthcheck_all.sh                  # Old script (deprecated)
└── output_healthcheck/
    ├── ENMR1_20260320_050000.log           # Individual server logs
    ├── ENMR2_20260320_050000.log
    ├── ENMR3_20260320_050000.log
    ├── ENMR4_20260320_050000.log
    ├── ENMJ1_20260320_050000.log
    ├── ENMJ2_20260320_050000.log
    ├── ENMTX_20260320_050000.log
    ├── ENMCORE_20260320_050000.log
    └── summary/
        └── Summary_20260320_050000.log     # Combined summary report
```

## Usage

```bash
# Interactive menu — pick servers by number or name
./enm_healthcheck_all-v2.sh

# Run on ALL servers (used by cronjob)
./enm_healthcheck_all-v2.sh --all

# Run on a single server
./enm_healthcheck_all-v2.sh ENMR1

# Run on multiple specific servers
./enm_healthcheck_all-v2.sh ENMR1 ENMR4 ENMCORE

# List available servers
./enm_healthcheck_all-v2.sh --list

# Show script version
./enm_healthcheck_all-v2.sh --version

# Show help
./enm_healthcheck_all-v2.sh --help
```

## Initial Setup (First Time Only)

### Step 1: Deploy the script to ENMR1 (10.21.233.4)

```bash
# SSH into ENMR1
ssh root@10.21.233.4

# Create the directory structure
mkdir -p /home/eric/scripts/ajiteguh/output_healthcheck/summary

# Copy the script (from your local machine or paste it)
vi /home/eric/scripts/ajiteguh/enm_healthcheck_all-v2.sh
# (paste the script content, save and exit)

# Make it executable
chmod +x /home/eric/scripts/ajiteguh/enm_healthcheck_all-v2.sh
```

### Step 2: Update passwords

Edit the script and replace `password123` with the real password for each server:

```bash
vi /home/eric/scripts/ajiteguh/enm_healthcheck_all-v2.sh
```

Find the `ALL_SERVERS` section and update each line:

```bash
ALL_SERVERS=(
    "ENMR1|root|REAL_PASSWORD_HERE|10.21.233.4"
    "ENMR2|root|REAL_PASSWORD_HERE|10.26.14.11"
    "ENMR3|root|REAL_PASSWORD_HERE|10.26.16.11"
    "ENMR4|root|REAL_PASSWORD_HERE|10.26.18.11"
    "ENMJ1|root|REAL_PASSWORD_HERE|172.20.126.134"
    "ENMJ2|root|REAL_PASSWORD_HERE|10.26.20.11"
    "ENMTX|root|REAL_PASSWORD_HERE|10.26.22.11"
    "ENMCORE|root|REAL_PASSWORD_HERE|10.21.73.106"
)
```

### Step 3: Verify the script works

```bash
# Check you have the right version
/home/eric/scripts/ajiteguh/enm_healthcheck_all-v2.sh --version
# Expected output: ENM Health Check Script v4.0

# Test with a single server first
/home/eric/scripts/ajiteguh/enm_healthcheck_all-v2.sh ENMR1

# Check the output was generated
ls -la /home/eric/scripts/ajiteguh/output_healthcheck/
ls -la /home/eric/scripts/ajiteguh/output_healthcheck/summary/
```

## Setting Up the Cronjob on ENMR1 (10.21.233.4)

### Step 1: SSH into ENMR1

```bash
ssh root@10.21.233.4
```

### Step 2: Open the crontab editor

```bash
crontab -e
```

### Step 3: Add the cronjob entry

Add the following line at the bottom of the crontab file:

```
0 5 * * * /home/eric/scripts/ajiteguh/enm_healthcheck_all-v2.sh --all >> /home/eric/scripts/ajiteguh/output_healthcheck/cron.log 2>&1
```

**What this means:**

| Field | Value | Meaning |
|-------|-------|---------|
| Minute | `0` | At minute 0 |
| Hour | `5` | At 5 AM |
| Day of month | `*` | Every day |
| Month | `*` | Every month |
| Day of week | `*` | Every day of the week |
| Command | `enm_healthcheck_all-v2.sh --all` | Run all 8 servers in non-interactive mode |
| `>> cron.log 2>&1` | | Append console output to cron log for troubleshooting |

Save and exit the editor (`:wq` in vi).

### Step 4: Verify the cronjob is registered

```bash
crontab -l
```

You should see your new entry listed:
```
0 5 * * * /home/eric/scripts/ajiteguh/enm_healthcheck_all-v2.sh --all >> /home/eric/scripts/ajiteguh/output_healthcheck/cron.log 2>&1
```

### Step 5: (Optional) Remove old cronjob if upgrading from v3.0

If you previously had the old script in crontab, remove that line:

```bash
crontab -e
# Delete the line referencing enm_healthcheck_all.sh (the old script)
# Keep only the line referencing enm_healthcheck_all-v2.sh
```

### Step 6: (Optional) Test the cronjob manually

```bash
# Run exactly what cron will run
/home/eric/scripts/ajiteguh/enm_healthcheck_all-v2.sh --all >> /home/eric/scripts/ajiteguh/output_healthcheck/cron.log 2>&1

# Check results
ls -lt /home/eric/scripts/ajiteguh/output_healthcheck/
cat /home/eric/scripts/ajiteguh/output_healthcheck/summary/Summary_*.log
```

## Automatic Cleanup

The script automatically deletes log files and summary files older than **7 days** at the end of each run. No additional cron entry is needed for cleanup.

## Output

### Individual Logs

Each server gets its own log file under `output_healthcheck/`:
```
ENMR1_20260320_050000.log
ENMR2_20260320_050000.log
ENMR3_20260320_050000.log
...
```

### Summary Report

A combined summary is generated under `output_healthcheck/summary/`:
```
Summary_20260320_050000.log
```

The summary shows, for each server, either:
- **[OK] No errors and failures found.** — server is healthy
- **[ISSUES] N error/failure line(s) detected:** — followed by the actual error lines

Example:
```
┌──────────────────────────────────────────────────────────────────────────┐
│  Server : ENMR1  (10.21.233.4)
│  File   : ENMR1_20260320_050000.log
├──────────────────────────────────────────────────────────────────────────┤
│
│  [OK] No errors and failures found.
│
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│  Server : ENMR4  (10.26.18.11)
│  File   : ENMR4_20260320_050000.log
├──────────────────────────────────────────────────────────────────────────┤
│
│  [ISSUES] 2 error/failure line(s) detected:
│
│     Unable to ping node: rienm4ebs01
│     Node Status: FAILED
│
└──────────────────────────────────────────────────────────────────────────┘
```

## Version History

| Version | File | Date | Changes |
|---------|------|------|---------|
| v4.0 | `enm_healthcheck_all-v2.sh` | 2026-03-20 | Fixed ENMJ1 banner `###` matching as shell prompt; added per-server bash `timeout` so one stuck server never blocks the rest; errors on any server are logged but script continues |
| v3.0 | `enm_healthcheck_all.sh` | 2026-03-18 | Interactive SSH with sentinel marker; SSH keepalive; version stamp |
| v2.0 | `enm_healthcheck_all.sh` | 2026-03-12 | Server selection menu; tee for screen+file output |
| v1.0 | `enm_healthcheck_all.sh` | 2026-03-11 | Initial script |

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Script says `expect: command not found` | `expect` is not installed. Check with `which expect` or `rpm -qa expect`. It should be pre-installed on ENM LMS servers. |
| Timeout after 2 hours | The ENM health check is genuinely taking too long. Check server load or run manually on the server. |
| Empty log files | SSH connection failed. Check network connectivity: `ping <server_ip>`. Check credentials. |
| Cron not running | Verify with `crontab -l`. Check `/var/log/cron` for errors. Make sure the script path is absolute. |
| Wrong script version | Verify: `./enm_healthcheck_all-v2.sh --version` — should show `v4.0`. |
| Permission denied | Run `chmod +x /home/eric/scripts/ajiteguh/enm_healthcheck_all-v2.sh`. |
| Script stuck on one server | v4.0 uses `timeout` command — server will be killed after 2 hours and script moves to the next. |
| Server errors don't stop script | By design in v4.0 — errors are logged but script always continues to the next server. |
