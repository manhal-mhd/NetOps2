#!/bin/sh
# Authoritative DNS Lab Validator (FreeBSD)
# Validates configuration, zone files, serial sync, optional AXFR (per ACLs), and resolver settings for your zone and your partner's zone.
# Usage:
#   Run with domains; IPs and zone file are auto-detected:
#   ./validate_dns_lab.sh -z pcXX.n2.nog-oc.org -Z pcYY.n2.nog-oc.org
#
# Notes:
# - This script uses POSIX sh and common FreeBSD tools: service, named-checkconf, named-checkzone, dig.
# - It continues on errors and prints a summary at the end.

MY_ZONE=""
PARTNER_ZONE=""
MY_IPV4=""
MY_IPV6=""
PARTNER_IPV4=""
PARTNER_IPV6=""
MY_ZONE_FILE=""

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

ok() { echo "[OK]  $1"; pass=$((pass+1)); }
ko() { echo "[FAIL] $1"; fail=$((fail+1)); }
wi() { echo "[WARN] $1"; warn=$((warn+1)); }

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

# Auto-detect my server IPs (IPv4/IPv6)
detect_ips() {
  # Prefer RFC1918 IPv4 (10/172.16-31/192.168), exclude 127/8; allow on any iface (including lo)
  MY_IPV4=$(ifconfig -a 2>/dev/null |
    awk '
      /^[A-Za-z0-9].*:/ {iface=$1; sub(":$","",iface)}
      $1=="inet" {
        ip=$2;
        if (ip ~ /^127\./) next;
        # prefer private IPv4 ranges
        if (ip ~ /^192\.168\./ || ip ~ /^10\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) {print ip; exit}
        # otherwise, first non-loopback interface IPv4
        if (iface !~ /^lo/) {print ip; exit}
      }
    ')

  # IPv6: first global (non-loopback iface, non-::1, non-link-local)
  MY_IPV6=$(ifconfig -a 2>/dev/null |
    awk '
      /^[A-Za-z0-9].*:/ {iface=$1; sub(":$","",iface)}
      $1=="inet6" {
        ip=$2;
        if (ip ~ /::1/ || ip ~ /^fe80:/) next;
        if (iface !~ /^lo/) {print ip; exit}
      }
    ')
  # strip any scope id from IPv6
  if [ -n "$MY_IPV6" ]; then MY_IPV6=$(echo "$MY_IPV6" | sed 's/%.*$//'); fi
}

# Find my zone file by parsing zones.conf, then fallback common paths
find_zone_file() {
  ZCONF="/etc/namedb/zones.conf"
  if [ -r "$ZCONF" ]; then
    MY_ZONE_FILE=$(awk -v z="$MY_ZONE" '
      $0 ~ "zone \"" z "\"" {inzone=1}
      inzone && $1=="file" {gsub(/;$/, ""); gsub(/file \"/, ""); gsub(/\"/, ""); print $0; exit}
      inzone && $0 ~ /};/ {inzone=0}
    ' "$ZCONF")
  fi
  # Fallbacks
  [ -z "$MY_ZONE_FILE" ] && [ -r "/etc/namedb/primary/$MY_ZONE" ] && MY_ZONE_FILE="/etc/namedb/primary/$MY_ZONE"
  [ -z "$MY_ZONE_FILE" ] && [ -r "/usr/local/etc/namedb/primary/$MY_ZONE" ] && MY_ZONE_FILE="/usr/local/etc/namedb/primary/$MY_ZONE"
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

# Extract allow-transfer IPv4 entries for my zone from zones.conf
ALLOW_XFER_IPS=""
if [ -r "/etc/namedb/zones.conf" ]; then
  ALLOW_XFER_IPS=$(awk -v z="$MY_ZONE" '
    $0 ~ "zone \"" z "\"" {inzone=1}
    inzone && $0 ~ /allow-transfer/ {
      line=$0; gsub(/.*\{/, "", line); gsub(/\}.*/, "", line); gsub(/;/, " ", line); print line; exit
    }
    inzone && $0 ~ /};/ {inzone=0}
  ' /etc/namedb/zones.conf)
fi

echo "\n=== Validation Targets ==="
echo "My zone:            $MY_ZONE"
echo "Partner zone:        $PARTNER_ZONE"
echo "My IPv4 (auto):      ${MY_IPV4:-(not detected)}"
echo "My IPv6 (auto):      ${MY_IPV6:-(not detected)}"
echo "Partner IPv4 (from NS): ${PARTNER_IPV4:-(not detected)}"
echo "My zone file (auto): ${MY_ZONE_FILE:-(not found)}"
echo "allow-transfer IPs:  ${ALLOW_XFER_IPS:-(none found)}"
echo "==========================\n"

# 1) Check named.conf syntax
if named-checkconf >/dev/null 2>&1; then
  ok "named-checkconf succeeded"
else
  ko "named-checkconf failed (check syntax in /etc/namedb/named.conf)"
fi

# 2) Check zone file syntax
if [ -n "$MY_ZONE_FILE" ] && named-checkzone "$MY_ZONE" "$MY_ZONE_FILE" >/dev/null 2>&1; then
  ok "named-checkzone $MY_ZONE succeeded"
else
  ko "named-checkzone $MY_ZONE failed (zone file auto-detect may have failed; verify path and serial)"
fi

# 3) Service status
SERVICE_STATUS=$(service named status 2>/dev/null)
if echo "$SERVICE_STATUS" | grep -qi "running"; then
  ok "named service running"
else
  ko "named service not running"
  echo "$SERVICE_STATUS" | sed 's/^/  /'
fi

# 4) Resolver config (/etc/resolv.conf)
if [ -r /etc/resolv.conf ]; then
  RES=$(cat /etc/resolv.conf)
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
# Note: AXFR from the primary to itself is typically refused due to allow-transfer.
#       Validate serial sync (above). Optional: test AXFR from the secondary.

if [ -n "$PARTNER_IPV4" ]; then
  AXFR_PARTNER=$(dig AXFR "$MY_ZONE" @"$PARTNER_IPV4" +nocmd +noall +answer 2>/dev/null)
  if echo "$AXFR_PARTNER" | grep -qi "SOA"; then
    ok "AXFR of my zone from partner server (IPv4) returned records"
  else
    wi "AXFR of my zone from partner (IPv4) returned no records (partner may restrict allow-transfer)"
  fi
fi

# 7b) Verify allow-transfer includes partner IPv4 (from zones.conf)
if [ -n "$PARTNER_IPV4" ] && [ -n "$ALLOW_XFER_IPS" ]; then
  echo "$ALLOW_XFER_IPS" | tr ' ' '\n' | grep -q "^$PARTNER_IPV4$" && \
    ok "allow-transfer includes partner IPv4 ($PARTNER_IPV4)" || \
    ko "allow-transfer does not include detected partner IPv4 ($PARTNER_IPV4)"
else
  wi "allow-transfer entries not found or partner IPv4 undetected"
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
  ok "System resolver returns NS for my zone (resolv.conf setup OK)"
else
  wi "System resolver did not return NS for my zone (check /etc/resolv.conf)"
fi

echo "\n=== Summary ==="
echo "Pass: $pass  Fail: $fail  Warn: $warn"
if [ "$fail" -gt 0 ]; then
  echo "Overall: Some checks FAILED. Review messages above."
else
  echo "Overall: Validation completed without failures."
fi
exit 0
 
