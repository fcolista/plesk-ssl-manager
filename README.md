# Plesk SSL Manager & Updater (Enterprise Edition)

A lightweight, robust, and highly efficient **POSIX-compliant** shell script designed for Plesk administrators to automate, manage, and monitor Let's Encrypt SSL certificates across multi-IP server environments. 

By performing **pre-flight DNS checks**, this script prevents Let's Encrypt validation failures, avoids API rate limits, and stops useless error notification emails caused by migrated, orphaned, or misconfigured domains.

---

## Key Features

* **POSIX Compliant:** Runs seamlessly on lightweight systems without bash-specific dependencies.
* **Smart Multi-IP Detection:** Queries Plesk's internal database to map all active IPv4 addresses, avoiding false negatives on multi-homed servers.
* **Pre-flight DNS Verification:** Resolves domains over public DNS *before* requesting a renewal. If a domain has migrated to an external IP or lacks DNS records, it is safely skipped.
* **Smart Renewals:** Only triggers renewals for certificates expiring within a customizable window (default: 30 days) to keep resource usage minimal.
* **Interactive Colorized Dashboard:** Displays a clear, color-coded terminal overview (`GREEN` for Active, `YELLOW` for Expiring Soon, `RED` for Expired/Not Protected).
* **Orphan & Migration Diagnostics (`--check-dns`):** Instantly scans and lists virtual hosts that no longer point to your server, serving as an invaluable cleanup checklist.
* **Smart Logging:** ANSI color codes are reserved for interactive terminal sessions; standard, clean logs are written to disk for easy parsing.

---

## Installation

1. **Download/Create the script file:**
```
   nano /usr/local/bin/plesk-ssl-manager.sh
```
Paste the script code and make it executable:
```
chmod +x /usr/local/bin/plesk-ssl-manager.sh
```

Verify installation by running the script without arguments:
```
/usr/local/bin/plesk-ssl-manager.sh
```

## Configuration

Open the script and adjust the global variables at the top of the file to fit your server setup:
```
NOTIFICATION_EMAIL="sysadmin@yourdomain.com" # Where to send success/error mail alerts
REGISTRATION_EMAIL="admin@yourdomain.com"     # Email registered with Let's Encrypt
LOG_FILE="/var/log/plesk_ssl_auto_update.log" # Log output destination
EXPIRY_THRESHOLD_DAYS=30                      # Smart renewal threshold window
```

## Usage Guide

1. Show Colored Certificate Status (Default)
Run the script with no arguments to print a complete, color-coded status table of your hosted domains:

```
/usr/local/bin/plesk-ssl-manager.sh
```

2. Identify Orphaned and Migrated Domains
Audit which domains still have hosting configurations on your server but have changed their public DNS records:
```
/usr/local/bin/plesk-ssl-manager.sh --check-dns
```

3. Run Smart Global Renewal
Scans all domains, performs DNS validation, and renews only the certificates expiring in less than 30 days:
```
/usr/local/bin/plesk-ssl-manager.sh --update
```

4. Selective Domain Renewal
Renew a specific domain immediately (still checks DNS records first):
```
/usr/local/bin/plesk-ssl-manager.sh --update example.com
```

5. Force Renewals
Override the 30-day smart check to force an immediate renewal of all domains, or just a single domain:

```
/usr/local/bin/plesk-ssl-manager.sh --update --force
/usr/local/bin/plesk-ssl-manager.sh --update example.com --force
```

## Automation & Maintenance

1. Setup Weekly Cron Job
To automate the renewal checking process, add a cron job to run every Monday night at 3:00 AM. Since the script uses smart DNS and expiry checks, this will not trigger rate limits.

```
crontab -e
```

Add the following line:

```
0 3 * * 1 /usr/local/bin/plesk-ssl-manager.sh --update >/dev/null 2>&1
```

2. Configure Log Rotation
Prevent log file bloating by adding a logrotate configuration:

```
nano /etc/logrotate.d/plesk-ssl-manager
```

Paste the following config:
```
/var/log/plesk_ssl_auto_update.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0640 root root
}
```

## Requirements

- Plesk Obsidian (with the official Let's Encrypt Extension installed)
- bind-tools (dig) or dnsutils (host)
- openssl
- Root privileges
