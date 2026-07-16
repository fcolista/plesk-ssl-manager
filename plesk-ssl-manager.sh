#!/bin/sh
# ==============================================================================
# PLESK SSL MANAGER & UPDATER - Enterprise Edition (POSIX Compliant)
# ==============================================================================

NOTIFICATION_EMAIL="sysadmin@tuodominio.com"
REGISTRATION_EMAIL="admin@tuodominio.com"
LOG_FILE="/var/log/plesk_ssl_auto_update.log"
EXPIRY_THRESHOLD_DAYS=30  # Renew only if certificate expires in less than X days

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

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root." >&2
    exit 1
fi

# --- SMART LOGGING HELPERS (Keeps log files clean of ANSI escape codes) ---
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

# Calculate day difference between expiry date (YYYY-MM-DD) and today
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

# --- 3. RENEWAL ENGINE ---
run_update() {
    force_renew=0
    target_domain=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --force) force_renew=1 ;;
            *) target_domain="$1" ;;
        esac
        shift
    done

    echo "=== SSL Renewal Session Started: $(date) ===" >> "$LOG_FILE"

    local_ips=$(get_local_ips)
    if [ -z "$local_ips" ]; then
        log_warn "Could not determine local IP addresses. Skipping DNS checks."
    fi

    if [ -n "$target_domain" ]; then
        log_info "Processing selective domain: $target_domain"
        domains="$target_domain"
    else
        log_info "Scanning all domains for smart SSL renewal..."
        domains=$(plesk db -N -B -e "SELECT d.name FROM domains d INNER JOIN hosting h ON d.id = h.dom_id")
    fi

    for domain in $domains; do
        # --- PRE-FLIGHT DNS CHECK ---
        if [ -n "$local_ips" ]; then
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

        log_info "Renewing SSL certificate for: $domain"

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
        else
            log_error "Failed to update SSL certificate for '$domain'.\n\nError details:\n$output"
        fi
    done
    echo "=== SSL Renewal Session Finished: $(date) ===" >> "$LOG_FILE"
}

# --- ARGUMENT ROUTER ---
case "$1" in
    "")
        print_report
        ;;
    --check-dns)
        check_dns_orphans
        ;;
    --update)
        if [ "$2" = "--force" ]; then
            run_update --force "$3"
        elif [ "$3" = "--force" ]; then
            run_update --force "$2"
        else
            run_update "$2"
        fi
        ;;
    *)
        echo "Usage: $0 [OPTION]"
        echo "  (No arguments)              Print visual dashboard with colored certificate statuses."
        echo "  --check-dns                 Identify orphaned or migrated domains resolving elsewhere."
        echo "  --update                    Trigger smart renewal (only certificates expiring in < $EXPIRY_THRESHOLD_DAYS days)."
        echo "  --update <domain>           Renew only the specified domain/subdomain."
        echo "  --update --force            Force-renew all local domains immediately."
        echo "  --update <domain> --force   Force-renew the specified domain immediately."
        exit 1
        ;;
esac
