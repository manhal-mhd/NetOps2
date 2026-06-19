#!/bin/sh
# Authoritative DNS Lab Validator (Ubuntu / BIND9)
# Ported from the FreeBSD version. Validates configuration, zone files, serial sync,
# optional AXFR (per ACLs), and resolver settings for your zone and your partner's zone.
# Usage:
#   Run with domains; IPs and zone file are auto-detected:
#   ./validate_dns_lab.sh -z pcXX.n2.nog-oc.org -Z pcYY.n2.nog-oc.org
#
# Notes:
# - This script uses POSIX sh and common Ubuntu/Linux tools: systemctl, ip, named-checkconf,
#   named-checkzone, dig.
# - It continues on errors and prints a summary at the end.
# - Differences from the FreeBSD version: `ifconfig` -> `ip`, `service` -> `systemctl`,
#   /etc/namedb/zones.conf -> /etc/bind/named.conf.local, and zone-file fallback paths now
#   check both /etc/bind/zones (master) and /var/cache/bind (slave), per Ubuntu's AppArmor
#   read/write convention.

MY_ZONE=""
PARTNER_ZONE=""
MY_IPV4=""
MY_IPV6=""
PARTNER_IPV4=""
PARTNER_IPV6=""
MY_ZONE_FILE=""

# Service unit name: Ubuntu 20.04+ uses "named" (bind9 is an alias); 18.04 and older use "bind9".
SERVICE_UNIT="named"
if ! systemctl list-unit-files 2>/dev/null | grep -q '^named\.service'; then
  SERVICE_UNIT="bind9"
fi

# Parse flags
while getopts "z:Z:h" opt; do
  case "$opt" in
    z) MY_ZONE="$OPTARG" ;;
    Z) PARTNER_ZONE="$OPTARG" ;;
    h)
      echo "Usage: $0 -z <my zone> -Z <partner zone>" ; exit 0 ;;
  esac
done

pass=0
fail=0
warn=0

# Color setup (disable with NO_COLOR=1 or when not a TTY)
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
  GREEN='\033[32m'
  RED='\033[31m'
  YELLOW='\033[33m'
  CYAN='\033[36m'
  BOLD='\033[1m'
  DIM='\033[2m'
  RESET='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

ok() { printf "%b[OK]%b  %s\n" "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
ko() { printf "%b[FAIL]%b %s\n" "$RED" "$RESET" "$1"; fail=$((fail+1)); }
wi() { printf "%b[WARN]%b %s\n" "$YELLOW" "$RESET" "$1"; warn=$((warn+1)); }

# Prompt with default (keeps value if user presses Enter)
prompt_with_default() {
  varname="$1"; prompt="$2"; default="$3";
  if [ -n "$default" ]; then
    printf "%s [%s]: " "$prompt" "$default"
  else
    printf "%s: " "$prompt"
  fi
  read ans
  if [ -n "$ans" ]; then
    eval $varname="\"$ans\""
  else
    # keep default
    :
  fi
}

# Prompt for missing required values
prompt_if_empty() {
  varname="$1"; prompt="$2";
  eval current_val="\"\${$varname}\""
  if [ -z "$current_val" ]; then
    printf "%s: " "$prompt"; read ans; eval $varname="\"$ans\""
  fi
}

# Always prompt for domains (use flag values as defaults if provided)
prompt_with_default MY_ZONE "Enter your zone (e.g., pcXX.n2.nog-oc.org)" "$MY_ZONE"
prompt_with_default PARTNER_ZONE "Enter your partner's zone (e.g., pcYY.n2.nog-oc.org)" "$PARTNER_ZONE"

# Auto-detect my server IPs (IPv4/IPv6) using `ip` instead of FreeBSD's `ifconfig`
detect_ips() {
  # Prefer RFC1918 IPv4 (10/172.16-31/192.168), exclude 127/8 and lo
  MY_IPV4=$(ip -4 -o addr show scope global 2>/dev/null |
    awk '
      {
        split($4, a, "/"); ip=a[1];
        if (ip ~ /^192\.168\./ || ip ~ /^10\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) {print ip; exit}
      }
    ')
  if [ -z "$MY_IPV4" ]; then
    MY_IPV4=$(ip -4 -o addr show scope global 2>/dev/null | awk '!/ lo /{split($4,a,"/"); print a[1]; exit}')
  fi

  # IPv6: first global, non-link-local, non-loopback address
  MY_IPV6=$(ip -6 -o addr show scope global 2>/dev/null |
    awk '!/ lo /{split($4,a,"/"); ip=a[1]; if (ip !~ /^fe80:/) {print ip; exit}}')
  # strip any zone/scope id from IPv6
  if [ -n "$MY_IPV6" ]; then MY_IPV6=$(echo "$MY_IPV6" | sed 's/%.*$//'); fi
}

# Find my zone file by parsing named.conf.local, then fallback to common Ubuntu paths
# (master under /etc/bind/zones, slave under /var/cache/bind — see README "What's different" table)
find_zone_file() {
  ZCONF="/etc/bind/named.conf.local"
  RAW_FILE=""
  if [ -r "$ZCONF" ]; then
    RAW_FILE=$(awk -v z="$MY_ZONE" '
      $0 ~ "zone \"" z "\"" {inzone=1}
      inzone && $1=="file" {gsub(/;$/, ""); gsub(/file \"/, ""); gsub(/\"/, ""); print $0; exit}
      inzone && $0 ~ /};/ {inzone=0}
    ' "$ZCONF")
  fi
  if [ -n "$RAW_FILE" ]; then
    case "$RAW_FILE" in
      /*) MY_ZONE_FILE="$RAW_FILE" ;;                          # absolute path as-is
      *)  MY_ZONE_FILE="/var/cache/bind/$RAW_FILE" ;;           # relative -> resolves under `directory`
    esac
  fi
  # Fallbacks
  [ -z "$MY_ZONE_FILE" ] && [ -r "/etc/bind/zones/db.$MY_ZONE" ] && MY_ZONE_FILE="/etc/bind/zones/db.$MY_ZONE"
  [ -z "$MY_ZONE_FILE" ] && [ -r "/var/cache/bind/db.$MY_ZONE" ] && MY_ZONE_FILE="/var/cache/bind/db.$MY_ZONE"
  [ -z "$MY_ZONE_FILE" ] && [ -r "/etc/bind/zones/$MY_ZONE" ] && MY_ZONE_FILE="/etc/bind/zones/$MY_ZONE"
}

# Derive partner label (e.g., pcYY) from zone name
partner_label_from_zone() { echo "$1" | awk -F. '{print $1}'; }

# Resolve NS FQDNs for a zone from my server, then get IPv4 for those matching a label
partner_ipv4_from_zone_ns() {
  zone="$1"; label="$2"; server="$3";
  nslist=$(dig +short NS "$zone" @"$server" 2>/dev/null)
  for ns in $nslist; do
    echo "$ns" | grep -q "$label" || continue
    ip=$(dig +short A "$ns" 2>/dev/null | head -n1)
    if [ -n "$ip" ]; then echo "$ip"; return 0; fi
  done
  return 1
}

detect_ips
find_zone_file
PLABEL=$(partner_label_from_zone "$PARTNER_ZONE")
if [ -n "$MY_IPV4" ]; then
  PARTNER_IPV4=$(partner_ipv4_from_zone_ns "$MY_ZONE" "$PLABEL" "$MY_IPV4")
fi

# Extract allow-transfer IPv4 entries for my zone from named.conf.local
ALLOW_XFER_IPS=""
if [ -r "/etc/bind/named.conf.local" ]; then
  ALLOW_XFER_IPS=$(awk -v z="$MY_ZONE" '
    $0 ~ "zone \"" z "\"" {inzone=1}
    inzone && $0 ~ /allow-transfer/ {
      line=$0; gsub(/.*\{/, "", line); gsub(/\}.*/, "", line); gsub(/;/, " ", line); print line; exit
    }
    inzone && $0 ~ /};/ {inzone=0}
  ' /etc/bind/named.conf.local)
fi

printf "\n%b%b=== Validation Targets ===%b\n" "$BOLD" "$CYAN" "$RESET"
echo "Service unit:        $SERVICE_UNIT"
echo "My zone:             $MY_ZONE"
echo "Partner zone:        $PARTNER_ZONE"
echo "My IPv4 (auto):      ${MY_IPV4:-(not detected)}"
echo "My IPv6 (auto):      ${MY_IPV6:-(not detected)}"
echo "Partner IPv4 (from NS): ${PARTNER_IPV4:-(not detected)}"
echo "My zone file (auto): ${MY_ZONE_FILE:-(not found)}"
echo "allow-transfer IPs:  ${ALLOW_XFER_IPS:-(none found)}"
printf "%b==========================%b\n" "$CYAN" "$RESET"

# 1) Check named.conf syntax
if named-checkconf >/dev/null 2>&1; then
  ok "named-checkconf succeeded"
else
  ko "named-checkconf failed (check syntax in /etc/bind/named.conf.options or named.conf.local)"
fi

# 2) Check zone file syntax
if [ -n "$MY_ZONE_FILE" ] && named-checkzone "$MY_ZONE" "$MY_ZONE_FILE" >/dev/null 2>&1; then
  ok "named-checkzone $MY_ZONE succeeded"
else
  ko "named-checkzone $MY_ZONE failed (zone file auto-detect may have failed; verify path and serial)"
fi

# 3) Service status (systemd, not FreeBSD's `service` script)
if systemctl is-active --quiet "$SERVICE_UNIT" 2>/dev/null; then
  ok "$SERVICE_UNIT service running"
else
  ko "$SERVICE_UNIT service not running"
  systemctl status "$SERVICE_UNIT" --no-pager 2>/dev/null | sed 's/^/  /'
fi

# 4) Resolver config (/etc/resolv.conf)
if [ -r /etc/resolv.conf ]; then
  RES=$(cat /etc/resolv.conf)
  RESOLV_LINK=$(readlink -f /etc/resolv.conf 2>/dev/null)
  case "$RESOLV_LINK" in
    *stub-resolv.conf*) wi "/etc/resolv.conf is managed by systemd-resolved; set DNS via Netplan/resolvectl, not by editing this file directly" ;;
  esac
  if echo "$RES" | grep -q "nameserver $MY_IPV4"; then
    ok "resolv.conf contains my IPv4 ($MY_IPV4)"
  else
    wi "resolv.conf missing my IPv4 ($MY_IPV4)"
  fi
  if [ -n "$MY_IPV6" ]; then
    if echo "$RES" | grep -q "nameserver $MY_IPV6"; then
      ok "resolv.conf contains my IPv6 ($MY_IPV6)"
    else
      wi "resolv.conf missing my IPv6 ($MY_IPV6)"
    fi
  fi
else
  wi "/etc/resolv.conf not readable"
fi

# Helper to get SOA serial via dig +short
get_serial() {
  zone="$1"; server="$2";
  if [ -z "$server" ]; then
    dig +short SOA "$zone" 2>/dev/null | awk '{print $3}'
  else
    dig +short SOA "$zone" @"$server" 2>/dev/null | awk '{print $3}'
  fi
}

# 5) Query my zone from my server
if [ -n "$MY_IPV4" ]; then
  NS_ANS=$(dig +short NS "$MY_ZONE" @"$MY_IPV4" 2>/dev/null)
  if [ -n "$NS_ANS" ]; then
    ok "NS records for $MY_ZONE from my IPv4"
  else
    ko "NS query for $MY_ZONE @ $MY_IPV4 returned no data"
  fi
else
  wi "Skipping IPv4 NS query for my server (no MY_IPV4 provided)"
fi

# Optional IPv6 query
if [ -n "$MY_IPV6" ]; then
  NS6_ANS=$(dig +short NS "$MY_ZONE" @"$MY_IPV6" 2>/dev/null)
  if [ -n "$NS6_ANS" ]; then
    ok "NS records for $MY_ZONE from my IPv6"
  else
    wi "NS query for $MY_ZONE @ $MY_IPV6 returned no data"
  fi
fi

# 6) SOA serial comparison for my zone (my vs partner)
MY_SERIAL=$(get_serial "$MY_ZONE" "$MY_IPV4")
PARTNER_SERIAL=$(get_serial "$MY_ZONE" "$PARTNER_IPV4")
if [ -n "$MY_SERIAL" ] && [ -n "$PARTNER_SERIAL" ]; then
  if [ "$MY_SERIAL" = "$PARTNER_SERIAL" ]; then
    ok "SOA serials match for $MY_ZONE (my=$MY_SERIAL, partner=$PARTNER_SERIAL)"
  else
    ko "SOA serials differ for $MY_ZONE (my=$MY_SERIAL, partner=$PARTNER_SERIAL)"
  fi
else
  wi "Could not retrieve both SOA serials for $MY_ZONE"
fi

# 7) AXFR checks aligned with lab setup
# AXFR should be tested against the partner's primary (masters) server.
# Example: dig @192.168.0.yyy pcyyy.n2.nog-oc.org AXFR

if [ -n "$PARTNER_IPV4" ]; then
  AXFR_FULL_OUTPUT=$(dig AXFR "$PARTNER_ZONE" @"$PARTNER_IPV4" 2>/dev/null)
  AXFR_ANSWER_ONLY=$(echo "$AXFR_FULL_OUTPUT" | grep -E "\sSOA\s")

  if echo "$AXFR_FULL_OUTPUT" | grep -qi "XFR size" || [ -n "$AXFR_ANSWER_ONLY" ]; then
    ok "AXFR of partner zone ($PARTNER_ZONE) from partner server ($PARTNER_IPV4) succeeded"
  else
    # Detect explicit refusals or auth-related messages that indicate ACL behavior
    if echo "$AXFR_FULL_OUTPUT" | grep -Eqi "Transfer failed|REFUSED|NOTAUTH|connection refused"; then
      ok "AXFR from partner server ($PARTNER_IPV4) refused by ACL (often expected unless my IP ($MY_IPV4) is allowed)"
    else
      wi "AXFR of partner zone ($PARTNER_ZONE) from partner server ($PARTNER_IPV4) returned no records"
    fi
  fi
else
  wi "Partner IPv4 not detected for AXFR test; ensure NS/A records resolve for $PARTNER_ZONE"
fi

# 7b) Verify allow-transfer includes partner IPv4 (from named.conf.local)
if [ -n "$PARTNER_IPV4" ] && [ -n "$ALLOW_XFER_IPS" ]; then
  echo "$ALLOW_XFER_IPS" | tr ' ' '\n' | grep -q "^$PARTNER_IPV4$" && \
    ok "allow-transfer includes partner IPv4 ($PARTNER_IPV4)" || \
    ko "allow-transfer does not include detected partner IPv4 ($PARTNER_IPV4)"
else
  wi "allow-transfer entries not found or partner IPv4 undetected"
fi

# 7c) AppArmor sanity check (Ubuntu-specific; no FreeBSD equivalent)
if command -v aa-status >/dev/null 2>&1; then
  if aa-status 2>/dev/null | grep -q "usr.sbin.named"; then
    if dmesg 2>/dev/null | grep -qi "apparmor=\"DENIED\".*named" || journalctl -k 2>/dev/null | grep -qi "apparmor=\"DENIED\".*named"; then
      ko "AppArmor DENIED entries found for named — check zone file locations (master in /etc/bind/zones, slave in /var/cache/bind)"
    else
      ok "AppArmor profile for named active, no DENIED entries found in recent kernel log"
    fi
  else
    wi "AppArmor profile for usr.sbin.named not found in aa-status output"
  fi
else
  wi "aa-status not available; skipping AppArmor check"
fi

# 8) Validate partner zone served by my server (as secondary)
SOA_PARTNER_MINE=$(get_serial "$PARTNER_ZONE" "$MY_IPV4")
SOA_PARTNER_THEIRS=""
if [ -n "$PARTNER_IPV4" ]; then
  SOA_PARTNER_THEIRS=$(get_serial "$PARTNER_ZONE" "$PARTNER_IPV4")
fi
if [ -n "$SOA_PARTNER_MINE" ]; then
  ok "My server answers SOA for partner zone $PARTNER_ZONE (serial=$SOA_PARTNER_MINE)"
else
  ko "My server did not answer SOA for partner zone $PARTNER_ZONE"
fi
if [ -n "$SOA_PARTNER_THEIRS" ]; then
  ok "Partner server answers SOA for $PARTNER_ZONE (serial=$SOA_PARTNER_THEIRS)"
else
  wi "Partner server IP not detected via NS, or did not answer SOA for $PARTNER_ZONE"
fi
if [ -n "$SOA_PARTNER_MINE" ] && [ -n "$SOA_PARTNER_THEIRS" ]; then
  if [ "$SOA_PARTNER_MINE" = "$SOA_PARTNER_THEIRS" ]; then
    ok "Partner zone serials match (my=$SOA_PARTNER_MINE, partner=$SOA_PARTNER_THEIRS)"
  else
    wi "Partner zone serials differ (my=$SOA_PARTNER_MINE, partner=$SOA_PARTNER_THEIRS)"
  fi
fi

# 9) System resolver test (uses /etc/resolv.conf)
NS_DEFAULT=$(dig +short NS "$MY_ZONE" 2>/dev/null)
if [ -n "$NS_DEFAULT" ]; then
  ok "System resolver returns NS for my zone (resolv.conf/systemd-resolved setup OK)"
else
  wi "System resolver did not return NS for my zone (check /etc/resolv.conf or 'resolvectl status')"
fi

printf "\n%b%b=== Summary ===%b\n" "$BOLD" "$CYAN" "$RESET"
echo "Pass: $pass  Fail: $fail  Warn: $warn"
if [ "$fail" -gt 0 ]; then
  printf "%bOverall: Some checks FAILED. Review messages above.%b\n" "$RED" "$RESET"
else
  printf "%bOverall: Validation completed without failures.%b\n" "$GREEN" "$RESET"
fi
exit 0
