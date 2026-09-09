#!/bin/sh
# ==============================================================================
# PLESK SSL MANAGER & UPDATER - Enterprise Edition (POSIX Compliant)
# ==============================================================================

# --- CONFIGURATION RESOLUTION & LOADING ---
# Search for configuration file in the script's directory first, then in /etc/
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG_FILE=""

if [ -f "$SCRIPT_DIR/plesk_ssl_manager.conf" ]; then
    CONFIG_FILE="$SCRIPT_DIR/plesk_ssl_manager.conf"
elif [ -f "/etc/plesk_ssl_manager.conf" ]; then
    CONFIG_FILE="/etc/plesk_ssl_manager.conf"
fi

if [ -n "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
else
    # Default fallback values if no configuration file is found
    NOTIFICATION_EMAIL="admin@localhost"
    REGISTRATION_EMAIL="admin@localhost"
    EXPIRY_THRESHOLD_DAYS=30
    WEBHOOK_PROVIDER=""
    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_CHAT_ID=""
    SLACK_WEBHOOK_URL=""
fi

LOG_FILE="/var/log/plesk_ssl_auto_update.log"

# Define ANSI color codes (only used if stdout is a TTY)
if [ -t 1 ]; then
    RED='\033[1;31m'
    GREEN='\033[1;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

DRY_RUN=0

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root." >&2
    exit 1
fi

# --- SMART LOGGING & NOTIFICATIONS HELPERS ---
send_email() {
    subject="$1"
    body="$2"
    [ -z "$NOTIFICATION_EMAIL" ] && return
    [ "$NOTIFICATION_EMAIL" = "admin@localhost" ] && return
    [ "$NOTIFICATION_EMAIL" = "sysadmin@tuodominio.com" ] && return
    [ "$NOTIFICATION_EMAIL" = "sysadmin@yourdomain.com" ] && return

    if command -v mail >/dev/null 2>&1; then
        printf "%s\n" "$body" | mail -s "$subject" "$NOTIFICATION_EMAIL" >/dev/null 2>&1
    elif command -v mailx >/dev/null 2>&1; then
        printf "%s\n" "$body" | mailx -s "$subject" "$NOTIFICATION_EMAIL" >/dev/null 2>&1
    elif command -v sendmail >/dev/null 2>&1; then
        (
            echo "To: $NOTIFICATION_EMAIL"
            echo "Subject: $subject"
            echo ""
            echo "$body"
        ) | sendmail -t >/dev/null 2>&1
    fi
}

send_webhook() {
    [ -z "$WEBHOOK_PROVIDER" ] && return
    message="[SSL MANAGER] $1"
    if [ "$WEBHOOK_PROVIDER" = "telegram" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d "chat_id=$TELEGRAM_CHAT_ID" -d "text=$message" >/dev/null 2>&1
    elif [ "$WEBHOOK_PROVIDER" = "slack" ] && [ -n "$SLACK_WEBHOOK_URL" ]; then
        slack_text=$(printf "%s" "$message" | sed 's/"/\\"/g' | awk '{if (NR>1) printf "\\n"; printf "%s", $0}')
        payload="{\"text\": \"$slack_text\"}"
        curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1
    fi
}

send_notification() {
    subject="$1"
    message="$2"
    send_webhook "$message"
    send_email "$subject" "$message"
}

log_info() {
    echo "INFO: $1" >> "$LOG_FILE"
    echo "INFO: $1"
}

log_success() {
    echo "SUCCESS: $1" >> "$LOG_FILE"
    printf "${GREEN}SUCCESS:${NC} %s\n" "$1"
}

log_warn() {
    echo "WARN: $1" >> "$LOG_FILE"
    printf "${YELLOW}WARN:${NC} %s\n" "$1"
}

log_skipped() {
    echo "SKIPPED: $1" >> "$LOG_FILE"
    printf "${YELLOW}SKIPPED:${NC} %s\n" "$1"
}

log_error() {
    echo "ERROR: $1" >> "$LOG_FILE"
    printf "${RED}ERROR:${NC} %s\n" "$1"
    send_notification "[SSL MANAGER ERROR] Error on Plesk Server" "❌ Error: $1"
}

# Retrieve all configured IPs from Plesk DB
get_local_ips() {
    plesk db -N -B -e "SELECT ip_address FROM IP_Addresses" 2>/dev/null | tr -d '\r'
}

# Check if a specific IP matches local server IPs
is_local_ip() {
    search_ip="$1"
    local_ips="$2"
    [ -z "$search_ip" ] || [ -z "$local_ips" ] && return 1
    for ip in $local_ips; do
        if [ "$ip" = "$search_ip" ]; then return 0; fi
    done
    return 1
}

# Resolve domain IPv4 via DNS
resolve_dns() {
    target_host="$1"
    resolved_ip=$(dig +short "$target_host" 2>/dev/null | tail -n1)
    if [ -z "$resolved_ip" ] && command -v host >/dev/null 2>&1; then
        resolved_ip=$(host -t A "$target_host" 2>/dev/null | awk '/has address/ {print $NF}' | tail -n1)
    fi
    echo "$resolved_ip" | tr -d '\r\n '
}

# Calculate day difference between expiry date and today
get_days_diff() {
    target_date="$1"
    target_clean=$(echo "$target_date" | cut -d' ' -f1)
    target_sec=$(date -d "$target_clean" +%s 2>/dev/null)
    if [ -z "$target_sec" ]; then
        target_sec=$(date -j -f "%Y-%m-%d" "$target_clean" +%s 2>/dev/null)
    fi
    current_sec=$(date +%s)
    [ -z "$target_sec" ] && { echo "N/D"; return; }
    echo "$(( (target_sec - current_sec) / 86400 ))"
}

# Extract certificate expiry date
get_cert_expiry() {
    domain_name="$1"
    cert_file=$(plesk db -N -B -e "
        SELECT c.cert_file 
        FROM domains d 
        JOIN hosting h ON d.id = h.dom_id 
        JOIN certificates c ON h.certificate_id = c.id 
        WHERE d.name='$domain_name'
    " 2>/dev/null | tr -d '\r\n ')
    
    if [ -n "$cert_file" ] && [ "$cert_file" != "NULL" ]; then
        cert_path="/usr/local/psa/var/certificates/$cert_file"
        if [ -f "$cert_path" ]; then
            raw_expiry=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
            if [ -n "$raw_expiry" ]; then
                date -u -d "$raw_expiry" +"%Y-%m-%d" 2>/dev/null
                return
            fi
        fi
    fi
    echo "N/D"
}

# --- PRE-FLIGHT DIRECTORY REPAIR ---
repair_challenge_dir() {
    domain="$1"
    sys_user=$(plesk db -N -B -e "SELECT login FROM sys_users WHERE id=(SELECT sys_user_id FROM hosting WHERE dom_id=(SELECT id FROM domains WHERE name='$domain'))" 2>/dev/null | tr -d '\r\n')
    if [ -n "$sys_user" ]; then
        doc_root="/var/www/vhosts/$domain"
        [ -d "$doc_root" ] && {
            mkdir -p "$doc_root/.well-known/acme-challenge"
            chown -R "$sys_user:psacln" "$doc_root/.well-known"
            chmod 755 "$doc_root/.well-known"
            chmod 755 "$doc_root/.well-known/acme-challenge"
        }
    fi
}

# --- POST-RENEWAL WEB SERVER RELOAD ---
reload_webservers() {
    log_info "Reloading web servers to apply newly issued SSL certificates..."
    
    # Graceful reload for Apache via Plesk CLI
    if command -v plesk >/dev/null 2>&1; then
        plesk bin service --restart apache2 >/dev/null 2>&1 || \
        plesk bin service --restart httpd >/dev/null 2>&1
    fi

    # Reload Nginx if active (Plesk often uses Nginx as reverse proxy)
    if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl reload nginx >/dev/null 2>&1
    fi

    log_success "Web servers reloaded successfully."
}

# --- 1. GENERAL REPORT ---
print_report() {
    printf "\n=== PLESK SSL CERTIFICATES STATUS ===\n"
    printf "%-40s %-30s %-12s %-30s\n" "DOMAIN/SUBDOMAIN" "CERTIFICATE TEMPLATE" "EXPIRY" "STATUS"
    printf "%s\n" "------------------------------------------------------------------------------------------------------------------------"

    db_data=$(plesk db -N -B -e "
        SELECT d.name, IFNULL(c.name, 'Nessuno'), IFNULL(c.cert_file, 'NULL')
        FROM domains d
        INNER JOIN hosting h ON d.id = h.dom_id
        LEFT JOIN certificates c ON h.certificate_id = c.id;
    ")

    tab_char=$(printf '\t')

    echo "$db_data" | while IFS="$tab_char" read -r domain cert_name cert_file; do
        if [ "$cert_file" = "NULL" ] || [ -z "$cert_file" ]; then
            printf "%-40s %-30s %-12s ${RED}%-30s${NC}\n" "$domain" "NONE" "N/D" "NOT PROTECTED"
        else
            cert_file=$(echo "$cert_file" | tr -d '\r\n ')
            cert_path="/usr/local/psa/var/certificates/$cert_file"
            if [ -f "$cert_path" ]; then
                raw_expiry=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
                if [ -n "$raw_expiry" ]; then
                    expiry=$(date -u -d "$raw_expiry" +"%Y-%m-%d" 2>/dev/null)
                    days=$(get_days_diff "$expiry")
                    
                    if [ "$days" = "N/D" ]; then
                        status_str="DATE PARSING ERROR"
                        printf "%-40s %-30s %-12s ${RED}%-30s${NC}\n" "$domain" "$cert_name" "$expiry" "$status_str"
                    elif [ "$days" -lt 0 ]; then
                        abs_days=$((days * -1))
                        status_str="EXPIRED BY $abs_days DAYS"
                        printf "%-40s %-30s %-12s ${RED}%-30s${NC}\n" "$domain" "$cert_name" "$expiry" "$status_str"
                    elif [ "$days" -le "$EXPIRY_THRESHOLD_DAYS" ]; then
                        status_str="EXPIRING SOON ($days DAYS LEFT)"
                        printf "%-40s %-30s %-12s ${YELLOW}%-30s${NC}\n" "$domain" "$cert_name" "$expiry" "$status_str"
                    else
                        status_str="ACTIVE ($days DAYS LEFT)"
                        printf "%-40s %-30s %-12s ${GREEN}%-30s${NC}\n" "$domain" "$cert_name" "$expiry" "$status_str"
                    fi
                else
                    printf "%-40s %-30s %-12s ${RED}%-30s${NC}\n" "$domain" "$cert_name" "N/D" "CERTIFICATE READ ERROR"
                fi
            else
                printf "%-40s %-30s %-12s ${RED}%-30s${NC}\n" "$domain" "$cert_name" "N/D" "CERTIFICATE FILE NOT FOUND"
            fi
        fi
    done
    printf "\n"
}

# --- 2. ORPHAN DOMAINS (CHECK DNS) ---
check_dns_orphans() {
    printf "\n=== DNS DIAGNOSTICS: ORPHANED/MIGRATED DOMAINS ===\n"
    printf "%-45s %-18s %-30s\n" "DOMAIN" "RESOLVED DNS IP" "SERVER DEPLOYMENT STATUS"
    printf "%s\n" "-------------------------------------------------------------------------------------------------------"
    
    local_ips=$(get_local_ips)
    domains=$(plesk db -N -B -e "SELECT d.name FROM domains d INNER JOIN hosting h ON d.id = h.dom_id")
    
    for domain in $domains; do
        resolved_ip=$(resolve_dns "$domain")
        if [ -z "$resolved_ip" ]; then
            printf "%-45s %-18s ${RED}%-30s${NC}\n" "$domain" "NONE" "ORPHANED (NO DNS RECORD)"
        elif ! is_local_ip "$resolved_ip" "$local_ips"; then
            printf "%-45s %-18s ${YELLOW}%-30s${NC}\n" "$domain" "$resolved_ip" "MIGRATED (EXTERNAL IP)"
        fi
    done
    printf "\n"
}

# Helper function to parse domain targets from CLI arguments or --file / -f <filepath>
parse_target_domains() {
    target_file=""
    cli_domains=""
    
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --file|-f)
                shift
                target_file="$1"
                ;;
            --force|--wildcard|--dry-run)
                ;;
            *)
                if [ -n "$1" ]; then
                    cli_domains="$cli_domains $1"
                fi
                ;;
        esac
        shift
    done

    result_domains=""

    if [ -n "$target_file" ]; then
        if [ -f "$target_file" ]; then
            file_domains=$(grep -v '^[[:space:]]*#' "$target_file" 2>/dev/null | grep -v '^[[:space:]]*$' | tr '\r\n' ' ')
            result_domains="$result_domains $file_domains"
        else
            log_error "Domain list file not found: $target_file"
            exit 1
        fi
    fi

    if [ -n "$cli_domains" ]; then
        result_domains="$result_domains $cli_domains"
    fi

    echo "$result_domains" | tr ',' ' ' | tr -s ' '
}

# --- 3. EXPIRY & CERTIFICATE ALERTS ---
check_alerts() {
    target_domains=$(parse_target_domains "$@")

    if [ -n "$target_domains" ]; then
        log_info "Scanning specific domain(s) for expiration and security alerts: $target_domains"
    else
        log_info "Scanning all certificates for expiration and security alerts..."
    fi
    
    db_data=$(plesk db -N -B -e "
        SELECT d.name, IFNULL(c.name, 'Nessuno'), IFNULL(c.cert_file, 'NULL')
        FROM domains d
        INNER JOIN hosting h ON d.id = h.dom_id
        LEFT JOIN certificates c ON h.certificate_id = c.id;
    ")

    tab_char=$(printf '\t')
    tmp_alert_file="/tmp/plesk_ssl_alert_$$.tmp"
    rm -f "$tmp_alert_file"

    echo "$db_data" | while IFS="$tab_char" read -r domain cert_name cert_file; do
        if [ -n "$target_domains" ]; then
            matched=0
            for td in $target_domains; do
                if [ "$td" = "$domain" ]; then
                    matched=1
                    break
                fi
            done
            if [ "$matched" -eq 0 ]; then
                continue
            fi
        fi

        if [ "$cert_file" = "NULL" ] || [ -z "$cert_file" ]; then
            echo "⚠️  $domain : NOT PROTECTED (No Certificate)" >> "$tmp_alert_file"
        else
            cert_file=$(echo "$cert_file" | tr -d '\r\n ')
            cert_path="/usr/local/psa/var/certificates/$cert_file"
            if [ -f "$cert_path" ]; then
                raw_expiry=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)
                if [ -n "$raw_expiry" ]; then
                    expiry=$(date -u -d "$raw_expiry" +"%Y-%m-%d" 2>/dev/null)
                    days=$(get_days_diff "$expiry")
                    
                    if [ "$days" = "N/D" ]; then
                        echo "❌ $domain : DATE PARSING ERROR" >> "$tmp_alert_file"
                    elif [ "$days" -lt 0 ]; then
                        abs_days=$((days * -1))
                        echo "❌ $domain : EXPIRED BY $abs_days DAYS (Date: $expiry)" >> "$tmp_alert_file"
                    elif [ "$days" -le "$EXPIRY_THRESHOLD_DAYS" ]; then
                        echo "⚠️  $domain : EXPIRING SOON ($days days left - Date: $expiry)" >> "$tmp_alert_file"
                    fi
                else
                    echo "❌ $domain : CERTIFICATE READ ERROR" >> "$tmp_alert_file"
                fi
            else
                echo "❌ $domain : CERTIFICATE FILE NOT FOUND" >> "$tmp_alert_file"
            fi
        fi
    done

    if [ -s "$tmp_alert_file" ]; then
        alert_count=$(wc -l < "$tmp_alert_file" | tr -d ' ')
        alert_content=$(cat "$tmp_alert_file")
        rm -f "$tmp_alert_file"
        
        log_warn "Found $alert_count certificate issue(s) requiring attention!"
        printf "\n=== CERTIFICATE ALERTS REPORT ($alert_count ISSUE(S)) ===\n%s\n\n" "$alert_content"
        
        subject="[SSL MANAGER ALERT] $alert_count certificate(s) requiring attention"
        body="Plesk SSL Manager Alert Report:
Found $alert_count certificate(s) requiring attention:

$alert_content

Threshold setting: EXPIRY_THRESHOLD_DAYS=$EXPIRY_THRESHOLD_DAYS
Run 'plesk-ssl-manager.sh --update' to attempt automatic renewal."

        send_notification "$subject" "$body"
    else
        rm -f "$tmp_alert_file"
        log_success "All checked SSL certificates are active and valid for more than $EXPIRY_THRESHOLD_DAYS days."
    fi
}

# --- 4. RENEWAL ENGINE ---
run_update() {
    force_renew=0
    wildcard_mode=0
    renewed_any=0

    for arg in "$@"; do
        case "$arg" in
            --force) force_renew=1 ;;
            --wildcard) wildcard_mode=1 ;;
        esac
    done

    target_domains=$(parse_target_domains "$@")

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "DRY-RUN MODE ACTIVE. No actual changes will be made."
    fi

    echo "=== SSL Renewal Session Started: $(date) ===" >> "$LOG_FILE"

    if [ -n "$CONFIG_FILE" ]; then
        log_info "Loaded configuration from: $CONFIG_FILE"
    else
        log_warn "No config file found (/etc/plesk_ssl_manager.conf or script dir). Using fallback defaults."
    fi

    local_ips=$(get_local_ips)
    if [ -z "$local_ips" ] && [ "$wildcard_mode" -eq 0 ]; then
        log_warn "Could not determine local IP addresses. Skipping DNS checks."
    fi

    if [ -n "$target_domains" ]; then
        log_info "Processing selective domain(s): $target_domains"
        domains="$target_domains"
    else
        log_info "Scanning all domains for smart SSL renewal..."
        domains=$(plesk db -N -B -e "SELECT d.name FROM domains d INNER JOIN hosting h ON d.id = h.dom_id")
    fi

    for domain in $domains; do
        # --- PRE-FLIGHT DNS CHECK ---
        if [ -n "$local_ips" ] && [ "$wildcard_mode" -eq 0 ]; then
            resolved_ip=$(resolve_dns "$domain")
            if [ -z "$resolved_ip" ]; then
                log_warn "DNS missing for '$domain'. Skipping."
                continue
            elif ! is_local_ip "$resolved_ip" "$local_ips"; then
                log_skipped "'$domain' points to external IP ($resolved_ip). Skipping."
                continue
            fi
        fi

        # --- SMART EXPIRY CHECK ---
        if [ "$force_renew" -eq 0 ] && [ -z "$target_domain" ]; then
            expiry=$(get_cert_expiry "$domain")
            if [ "$expiry" != "N/D" ]; then
                days_left=$(get_days_diff "$expiry")
                if [ "$days_left" != "N/D" ] && [ "$days_left" -gt "$EXPIRY_THRESHOLD_DAYS" ]; then
                    log_info "OK: '$domain' expires in $days_left days. Renewal skipped."
                    continue
                fi
            fi
        fi

        # --- REPAIR PERMISSIONS PRE-EMPTIVELY ---
        if [ "$DRY_RUN" -eq 0 ] && [ "$wildcard_mode" -eq 0 ]; then
            repair_challenge_dir "$domain"
        fi

        log_info "Renewing SSL certificate for: $domain (Wildcard: $wildcard_mode)"

        if [ "$DRY_RUN" -eq 1 ]; then
            log_success "[DRY-RUN] Checked renewal logic successfully for $domain."
            continue
        fi

        # --- PROCESS WILDCARD ISSUANCE (DNS CHALLENGE) ---
        if [ "$wildcard_mode" -eq 1 ]; then
            output=$(plesk ext sslit --certificate -issue -domain "$domain" -registrationEmail "$REGISTRATION_EMAIL" -secure-domain -wildcard 2>&1)
            status=$?
            
            if echo "$output" | grep -q "pending"; then
                txt_host="_acme-challenge.$domain"
                txt_value=$(echo "$output" | grep "dnsRecordValue" | cut -d':' -f2 | tr -d ' ')
                
                log_warn "External DNS detected for Wildcard '$domain'."
                log_info "ACTION REQUIRED: Create TXT record on your DNS panel:"
                log_info "  Host: $txt_host"
                log_info "  Value: $txt_value"
                
                send_notification "[SSL MANAGER ACTION REQUIRED] Wildcard TXT for $domain" "⚠️ DNS TXT Action Required for $domain:\nHost: $txt_host\nValue: $txt_value"
                continue
            elif [ $status -eq 0 ]; then
                log_success "Wildcard SSL certificate for '$domain' updated successfully (Auto DNS)."
                renewed_any=1
            else
                log_error "Failed to update Wildcard SSL certificate for '$domain'. Details:\n$output"
            fi
            continue
        fi

        # --- PROCESS STANDARD ISSUANCE (HTTP CHALLENGE) ---
        alias_list=$(plesk db -N -B -e "SELECT name FROM domain_aliases WHERE dom_id = (SELECT id FROM domains WHERE name='$domain')")
        domains_arg="-d $domain"
        
        dots_count=$(echo "$domain" | tr -cd '.' | wc -c)
        if [ "$dots_count" -eq 1 ]; then
            domains_arg="$domains_arg -d www.$domain"
        fi

        for alias in $alias_list; do
            if [ -n "$local_ips" ]; then
                alias_ip=$(resolve_dns "$alias")
                if is_local_ip "$alias_ip" "$local_ips"; then
                    domains_arg="$domains_arg -d $alias -d www.$alias"
                else
                    log_info "  -> Alias '$alias' excluded (points to external IP $alias_ip)"
                fi
            else
                domains_arg="$domains_arg -d $alias -d www.$alias"
            fi
        done
        
        cmd="plesk bin extension --exec letsencrypt cli.php -m \"$REGISTRATION_EMAIL\" $domains_arg --expand"
        output=$(eval "$cmd" 2>&1)
        status=$?
        
        if [ $status -eq 0 ]; then
            new_expiry=$(get_cert_expiry "$domain")
            log_success "SSL certificate for '$domain' updated successfully. New expiry: $new_expiry"
            send_notification "[SSL MANAGER RENEWED] $domain" "✅ SSL Renewed: $domain (expires: $new_expiry)"
            renewed_any=1
        else
            log_error "Failed to update SSL certificate for '$domain'.\n\nError details:\n$output"
        fi
    done

    # --- RELOAD WEBSERVERS IF ANY CERTIFICATE WAS RENEWED ---
    if [ "$renewed_any" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
        reload_webservers
    fi

    echo "=== SSL Renewal Session Finished: $(date) ===" >> "$LOG_FILE"
}

# --- ARGUMENT ROUTER ---
for arg in "$@"; do
    if [ "$arg" = "--dry-run" ]; then
        DRY_RUN=1
    fi
done

case "$1" in
    "")
        print_report
        ;;
    --check-dns)
        check_dns_orphans
        ;;
    --alert|--notify)
        shift
        args_clean=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" != "--dry-run" ]; then
                args_clean="$args_clean $1"
            fi
            shift
        done
        check_alerts $args_clean
        ;;
    --update)
        shift
        args_clean=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" != "--dry-run" ]; then
                args_clean="$args_clean $1"
            fi
            shift
        done
        run_update $args_clean
        ;;
    *)
        echo "Usage: $0 [OPTION] [DOMAINS | --file <path>]"
        echo "  (No arguments)              Print visual dashboard with colored certificate statuses."
        echo "  --check-dns                 Identify orphaned or migrated domains resolving elsewhere."
        echo "  --alert, --notify           Scan certificates and send alerts (Email/Webhook) for expiring/expired domains."
        echo "                              Optionally specify domain(s) or --file <path> to scan specific domains."
        echo "  --update                    Trigger smart renewal (only certificates expiring in < $EXPIRY_THRESHOLD_DAYS days)."
        echo "                              Optionally specify domain(s) or --file <path> to renew specific domains."
        echo "  --update --force            Force-renew all or specified local domains immediately."
        echo "  --update --wildcard         Request a wildcard certificate via DNS challenge."
        echo "                              (If external DNS, returns the TXT record to apply)."
        echo "  --file, -f <path>           Read target domain list from a text file (one domain per line)."
        echo "  --dry-run                   Add to any --update or --alert command to simulate execution."
        exit 1
        ;;
esac
