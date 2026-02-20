#!/bin/sh
# Mail Server Lab Validator (FreeBSD) — Postfix + Dovecot + DNS MX
# Validates DNS (MX/A/AAAA), Postfix/Dovecot services, core Postfix config,
# aliases, open ports, and local delivery to /var/mail/<user>.
# Usage:
#   ./validate_mail_lab.sh -z pcXX.n2.nog-oc.org -Z pcYY.n2.nog-oc.org -u afnog
# Flags:
#   -z  Your zone (required)
#   -Z  Partner's zone (optional, for MX check)
#   -u  Local user to deliver to (default: afnog)
#   -h  Help

MY_ZONE=""
PARTNER_ZONE=""
LAB_USER="afnog"
MY_IPV4=""
MY_IPV6=""

# Parse flags
while getopts "z:Z:u:h" opt; do
  case "$opt" in
    z) MY_ZONE="$OPTARG" ;;
    Z) PARTNER_ZONE="$OPTARG" ;;
    u) LAB_USER="$OPTARG" ;;
    h) echo "Usage: $0 -z <my zone> [-Z <partner zone>] [-u <user>]" ; exit 0 ;;
  esac
done

pass=0
fail=0
warn=0

# Colors
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
  GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; CYAN='\033[36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

ok() { printf "%b[OK]%b  %s\n" "$GREEN" "$RESET" "$1"; pass=$((pass+1)); }
ko() { printf "%b[FAIL]%b %s\n" "$RED" "$RESET" "$1"; fail=$((fail+1)); }
wi() { printf "%b[WARN]%b %s\n" "$YELLOW" "$RESET" "$1"; warn=$((warn+1)); }

prompt_with_default() {
  varname="$1"; prompt="$2"; default="$3";
  if [ -n "$default" ]; then printf "%s [%s]: " "$prompt" "$default"; else printf "%s: " "$prompt"; fi
  read ans
  if [ -n "$ans" ]; then eval $varname="\"$ans\""; fi
}

# Prompt for missing
[ -z "$MY_ZONE" ] && prompt_with_default MY_ZONE "Enter your zone (e.g., pcXX.n2.nog-oc.org)" "$MY_ZONE"
[ -z "$PARTNER_ZONE" ] && prompt_with_default PARTNER_ZONE "Enter your partner's zone (e.g., pcYY.n2.nog-oc.org)" "$PARTNER_ZONE"
[ -z "$LAB_USER" ] && LAB_USER="afnog"

MAIL_HOST="mail.$MY_ZONE"

# Detect IPs
detect_ips() {
  MY_IPV4=$(ifconfig -a 2>/dev/null | awk '
    /^[A-Za-z0-9].*:/ {iface=$1; sub(":$","",iface)}
    $1=="inet" {
      ip=$2; if (ip ~ /^127\./) next;
      if (ip ~ /^192\.168\./ || ip ~ /^10\./ || ip ~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./) {print ip; exit}
      if (iface !~ /^lo/) {print ip; exit}
    }
  ')
  MY_IPV6=$(ifconfig -a 2>/dev/null | awk '
    /^[A-Za-z0-9].*:/ {iface=$1; sub(":$","",iface)}
    $1=="inet6" {
      ip=$2; if (ip ~ /::1/ || ip ~ /^fe80:/) next;
      if (iface !~ /^lo/) {print ip; exit}
    }
  ')
  [ -n "$MY_IPV6" ] && MY_IPV6=$(echo "$MY_IPV6" | sed 's/%.*$//')
}

detect_ips

printf "\n%b%b=== Mail Lab Targets ===%b\n" "$BOLD" "$CYAN" "$RESET"
echo "Zone:             $MY_ZONE"
echo "Partner zone:     ${PARTNER_ZONE:-(none)}"
echo "Mail host:        $MAIL_HOST"
echo "Local user:       $LAB_USER"
echo "My IPv4 (auto):   ${MY_IPV4:-(not detected)}"
echo "My IPv6 (auto):   ${MY_IPV6:-(not detected)}"
printf "%b===========================%b\n" "$CYAN" "$RESET"

# 1) DNS checks
MX_ANS=$(dig +short MX "$MY_ZONE" 2>/dev/null)
if [ -n "$MX_ANS" ]; then
  echo "$MX_ANS" | grep -qi "$MAIL_HOST\.$" && ok "MX includes $MAIL_HOST" || wi "MX does not list $MAIL_HOST"
  if [ -n "$PARTNER_ZONE" ]; then
    PARTNER_MAIL="mail.$PARTNER_ZONE"
    echo "$MX_ANS" | grep -qi "$PARTNER_MAIL\.$" && ok "MX includes partner $PARTNER_MAIL" || wi "MX does not list partner $PARTNER_MAIL"
  fi
else
  ko "MX query returned no data for $MY_ZONE"
fi

A_ANS=$(dig +short A "$MAIL_HOST" 2>/dev/null)
if [ -n "$A_ANS" ]; then ok "A record for $MAIL_HOST -> $A_ANS"; else ko "Missing A for $MAIL_HOST"; fi
AAAA_ANS=$(dig +short AAAA "$MAIL_HOST" 2>/dev/null)
if [ -n "$AAAA_ANS" ]; then ok "AAAA record for $MAIL_HOST -> $AAAA_ANS"; else wi "IPv6 AAAA not found for $MAIL_HOST (optional)"; fi

# 2) Services status
S_POSTFIX=$(service postfix status 2>/dev/null)
S_DOVECOT=$(service dovecot status 2>/dev/null)

echo "$S_POSTFIX" | grep -qi "running" && ok "postfix service running" || ko "postfix service not running"
echo "$S_DOVECOT" | grep -qi "running" && ok "dovecot service running" || ko "dovecot service not running"

# 3) Ports listening
SOCKS=$(sockstat -4 -6 | grep -E ":(25|143)" | grep LISTEN)
echo "$SOCKS" | grep -q ":25" && ok "SMTP port 25 listening" || ko "SMTP port 25 not listening"
echo "$SOCKS" | grep -q ":143" && ok "IMAP port 143 listening" || ko "IMAP port 143 not listening"

# 4) Postfix config sanity
get_pf() { postconf -n "$1" 2>/dev/null | awk -F' = ' '{print $2}'; }
PF_MYHOST=$(get_pf myhostname)
PF_MYDOMAIN=$(get_pf mydomain)
PF_PROTOCOLS=$(get_pf inet_protocols)
PF_DEST=$(get_pf mydestination)
PF_NETWORKS=$(get_pf mynetworks)

[ "$PF_MYHOST" = "$MAIL_HOST" ] && ok "postfix myhostname = $MAIL_HOST" || wi "postfix myhostname is '$PF_MYHOST' (expected $MAIL_HOST)"
[ "$PF_MYDOMAIN" = "$MY_ZONE" ] && ok "postfix mydomain = $MY_ZONE" || wi "postfix mydomain is '$PF_MYDOMAIN' (expected $MY_ZONE)"
echo "$PF_PROTOCOLS" | grep -qi ipv4 && ok "postfix inet_protocols includes ipv4" || wi "postfix inet_protocols missing ipv4"
echo "$PF_DEST" | grep -qi "$MY_ZONE" && ok "postfix mydestination includes $MY_ZONE" || wi "postfix mydestination missing $MY_ZONE"
echo "$PF_NETWORKS" | grep -q "192.168" && ok "postfix mynetworks includes lab subnet" || wi "postfix mynetworks may not include lab subnet"

# 5) Aliases
if [ -r /etc/aliases ]; then
  if grep -Eq "^root:\\s*$LAB_USER$" /etc/aliases; then
    ok "/etc/aliases maps root -> $LAB_USER"
  else
    wi "/etc/aliases does not map root to $LAB_USER"
  fi
  if newaliases >/dev/null 2>&1; then
    ok "aliases database rebuilt"
  else
    wi "newaliases failed"
  fi
else
  wi "/etc/aliases not readable"
fi

# 6) Local delivery test
MAILBOX="/var/mail/$LAB_USER"
SZ0=$(stat -f %z "$MAILBOX" 2>/dev/null || echo 0)
SUBJ="MailLabTest $(date +%s)"
BODY="Mail Lab validation test $(date)"
printf "%s\n" "$BODY" | mail -s "$SUBJ" "$LAB_USER@$MAIL_HOST" 2>/dev/null || wi "mail command failed to submit"

DELIVERED=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  SZ1=$(stat -f %z "$MAILBOX" 2>/dev/null || echo 0)
  if [ "$SZ1" -gt "$SZ0" ]; then DELIVERED=1; break; fi
done

if [ "$DELIVERED" -eq 1 ]; then
  ok "Local delivery succeeded to $MAILBOX (size increased)"
else
  # Try to find a recent log hint
  if tail -n 200 /var/log/maillog 2>/dev/null | grep -Eqi "status=sent|delivered"; then
    wi "Delivery indicated in logs, but mailbox size unchanged (mbox creation may be delayed)"
  else
    ko "Local delivery not observed in mailbox or logs"
  fi
fi

# 7) Summary
printf "\n%b%b=== Summary ===%b\n" "$BOLD" "$CYAN" "$RESET"
echo "Pass: $pass  Fail: $fail  Warn: $warn"
if [ "$fail" -gt 0 ]; then
  printf "%bOverall: Some checks FAILED. Review messages above.%b\n" "$RED" "$RESET"
else
  printf "%bOverall: Validation completed without failures.%b\n" "$GREEN" "$RESET"
fi
exit 0
