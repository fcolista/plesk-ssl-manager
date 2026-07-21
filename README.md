# Plesk SSL Manager & Updater (Enterprise Edition)

A lightweight, robust, and highly efficient POSIX-compliant shell script designed for Plesk administrators to automate, manage, and monitor Let's Encrypt SSL certificates across multi-IP server environments.

By performing pre-flight DNS checks, this script prevents Let's Encrypt validation failures, avoids API rate limits, and stops useless error notification emails caused by migrated, orphaned, or misconfigured domains.

---

## Key Features

* **POSIX Compliant:** Runs seamlessly on lightweight systems without bash-specific dependencies.
* **External Configuration File:** Keeps secrets, API tokens, and admin emails separate from the code (/etc/plesk_ssl_manager.conf).
* **Automatic Web Server Reload:** Automatically performs a graceful reload on Apache and Nginx immediately after renewing certificates so changes take effect without downtime.
* **Smart Multi-IP Detection:** Queries Plesk's internal database to map all active IPv4 addresses, avoiding false negatives on multi-homed servers.
* **Pre-flight DNS Verification:** Resolves domains over public DNS *before* requesting a renewal. If a domain has migrated to an external IP or lacks DNS records, it is safely skipped.
* **Instant Alerts (Webhooks):** Native integration with Telegram and Slack webhooks for instant status and action alerts.
* **Wildcard & DNS Challenge Support:** Capability to request Wildcard certificates (--wildcard) via Plesk SSL It! extension.
* **Dry-Run Simulation:** Test logic and pre-flight checks without issuing actual ACME certificates.
* **Smart Renewals:** Only triggers renewals for certificates expiring within a customizable window (default: 30 days) to keep resource usage minimal.
* **Interactive Colorized Dashboard:** Displays a clear, color-coded terminal overview (`GREEN` for Active, `YELLOW` for Expiring Soon, `RED` for Expired/Not Protected).
* **Orphan & Migration Diagnostics (`--check-dns`):** Instantly scans and lists virtual hosts that no longer point to your server, serving as an invaluable cleanup checklist.
* **Smart Logging:** ANSI color codes are reserved for interactive terminal sessions; standard, clean logs are written to disk for easy parsing.

---

## Installation

1. Enable Apache Graceful Restart in Plesk (One-time setup):

```
plesk bin settings --set restart_apache_gracefully=true
```

2. **Download/Create the script file:**
```
   nano /usr/local/bin/plesk-ssl-manager.sh
```
Paste the script code and make it executable:
```
chmod +x /usr/local/bin/plesk-ssl-manager.sh
```

3. **Create the Configuration File:**

```
nano /etc/plesk_ssl_manager.conf
```
_See the Configuration section below._

4. **Verify installation:**

```
/usr/local/bin/plesk-ssl-manager.sh
```

## Configuration

Create `/etc/plesk_ssl_manager.conf` (or place `plesk_ssl_manager.conf` in the same directory as the script). 
Set restrictive permissions to protect sensitive API tokens:

```
chmod 600 /etc/plesk_ssl_manager.conf
```

## Configuration File Template (`/etc/plesk_ssl_manager.conf`)

```
# ==============================================================================
# PLESK SSL MANAGER & UPDATER - CONFIGURATION FILE
# ==============================================================================

# Email for system alerts
NOTIFICATION_EMAIL="sysadmin@yourdomain.com"

# Email registered with Let's Encrypt / SSL It! account
REGISTRATION_EMAIL="admin@yourdomain.com"

# Renew certificate only if expiring in less than X days
EXPIRY_THRESHOLD_DAYS=30

# --- WEBHOOK NOTIFICATIONS ---
# Options: "telegram", "slack", or "" (disabled)
WEBHOOK_PROVIDER=""

# Telegram Settings (required if WEBHOOK_PROVIDER="telegram")
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

# Slack Settings (required if WEBHOOK_PROVIDER="slack")
SLACK_WEBHOOK_URL=""
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

6. Wildcard Issuance
Request a Wildcard SSL certificate via DNS Challenge. If external DNS is detected, it returns the required ACME TXT record details (and sends a webhook notification):

```
/usr/local/bin/plesk-ssl-manager.sh --update example.com --wildcard
```

7. Simulation / Dry-Run Mode
Simulate execution without issuing actual certificates or reloading web servers:

```
/usr/local/bin/plesk-ssl-manager.sh --update --dry-run
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
- bind-tools (`dig`) or dnsutils (`host`)
- openssl
- curl
- Root privileges
