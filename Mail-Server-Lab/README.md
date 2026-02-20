# Mail Server Lab (FreeBSD) — Postfix + Dovecot + DNS MX

This lab builds a simple mail server using Postfix (SMTP) and Dovecot (IMAP), tied to the DNS zone you created previously. You will add MX records, install and configure Postfix/Dovecot, send a test email, and verify delivery.

## Prerequisites
- Completed authoritative DNS lab and working zone `pcXX.n2.nog-oc.org`.
- Primary address: IPv4 `192.168.0.XXX`, optional IPv6 `2a02:c207:2054:4961:XXXX::XX`.
- Root (or sudo) access on FreeBSD 13/14.
- Open network access to TCP ports 25 (SMTP) and 143 (IMAP).

## Variables
- Replace `pcXX` with your zone; `pcYY` is your partner’s.
- Replace `XXX`/`XXXX::XX` with your actual IPs.

---

## Part 1: DNS — Add MX Records
1) Edit your zone file and add `mail` host and MX records
```sh
cd /usr/local/etc/namedb/primary
vi pcXX.n2.nog-oc.org
```
Append at the bottom:
```
mail    IN  A     192.168.XX.XX
mail    IN  AAAA  2a02:c207:2054:4961:XXXX::XX
@       IN  MX 10 mail.pcXX.n2.nog-oc.org.
@       IN  MX 20 mail.pcYY.n2.nog-oc.org.
```
Notes:
- Ensure the trailing dot on FQDNs (`mail.pcXX.n2.nog-oc.org.`).
- Keep name alignment and spacing consistent.

2) Increment SOA serial and validate
```sh
named-checkzone pcXX.n2.nog-oc.org /usr/local/etc/namedb/primary/pcXX.n2.nog-oc.org
```

3) Reload BIND
```sh
rndc reload
# or
service named reload
```

4) Update resolver and test
```sh
vi /etc/resolv.conf
nameserver 192.168.X.X
nameserver 9.9.9.9

dig pcXX.n2.nog-oc.org MX
```
You should see both MX records, and `mail.pcXX.n2.nog-oc.org` should resolve to your A/AAAA.

---

## Part 2: Install Postfix and Dovecot
1) Install packages
```sh
pkg install postfix dovecot
```
Answer `y` when asked: “Would you like to activate Postfix in /etc/mail/mailer.conf [n]?”

2) Enable/disable services via sysrc (updates /etc/rc.conf)
```sh
sysrc postfix_enable=YES
sysrc dovecot_enable=YES
sysrc sendmail_enable=NO
sysrc sendmail_submit_enable=NO
sysrc sendmail_outbound_enable=NO
sysrc sendmail_msp_queue_enable=NO
```

3) Stop Sendmail (if running)
```sh
service sendmail stop
```

4) Confirm your MX record
```sh
dig pcXX.n2.nog-oc.org MX
```

---

## Part 3: Configure Postfix
1) Prepare `main.cf`
```sh
cd /usr/local/etc/postfix
mv main.cf main.cf.orig
ee main.cf
```
Minimal lab configuration (edit `pcXX` and networks):
```
# Identity
myhostname = mail.pcXX.n2.nog-oc.org
mydomain   = pcXX.n2.nog-oc.org
myorigin   = $mydomain

# Networking
inet_interfaces = all
inet_protocols = ipv4, ipv6
mynetworks = 127.0.0.0/8, 192.168.0.0/16, [2a02:c207:2054:4961:XXXX::X]/128
mynetworks_style = subnet

# Local delivery
mydestination = $myhostname, localhost.$mydomain, localhost, $mydomain
local_recipient_maps = unix:passwd.byname
unknown_local_recipient_reject_code = 550

# Banner and defaults
smtpd_banner = $myhostname ESMTP
compatibility_level = 3.6
```
Explanation:
- `myhostname` must match your DNS `mail.pcXX.n2.nog-oc.org` A/AAAA.
- `mynetworks` defines subnets allowed to relay; keep it to lab ranges.
- This config handles local delivery (to `/var/mail/<user>`).

2) Aliases for local delivery
```sh
ee /etc/aliases
```
Example:
```
#root: postmaster
root: afnog
nagios: afnog
```
Rebuild aliases:
```sh
newaliases
```

3) Start Postfix and verify
```sh
service postfix start
postfix check
postconf -n
sockstat -4 -6 | grep master
```
You should see Postfix `master` listening on `*:25`.

---

## Part 4: Configure Dovecot (IMAP)
1) Minimal `dovecot.conf`
```sh
ee /usr/local/etc/dovecot/dovecot.conf
```
Add:
```
protocols = imap
listen = *
ssl = no
disable_plaintext_auth = no
mail_location = mbox:/var/mail/%u
auth_mechanisms = plain login
passdb {
  driver = pam
}
userdb {
  driver = passwd
}
```
2) Start Dovecot and verify
```sh
service dovecot start
sockstat -4 -6 | grep dovecot
```
You should see Dovecot listening on `*:143`.

---

## Part 5: Send a Test Email
1) Create or ensure local user `afnog` exists and has `/var/mail/afnog` (mbox will be created on first delivery).

2) Send mail and watch logs
```sh
mail -s "this is a test mail" afnog@mail.pcXX.n2.nog-oc.org
# type message body, then a single dot on its own line to finish
.

tail -f /var/log/maillog
```
3) Verify mailbox
```sh
ls -l /var/mail/afnog
```
4) Optional tests
```sh
nc -zv mail.pcXX.n2.nog-oc.org 25
nc -zv mail.pcXX.n2.nog-oc.org 143
```

---

## Troubleshooting
- DNS: `dig mail.pcXX.n2.nog-oc.org A +short`, `dig pcXX.n2.nog-oc.org MX`.
- Services: `service postfix status`, `service dovecot status`.
- Logs: `tail -f /var/log/maillog`.
- Queue: `mailq` or `postqueue -p`; retry: `postsuper -r ALL`.
- Firewall/ports: ensure TCP 25 and 143 reachable.
- Relaying denied: adjust `mynetworks` cautiously; never open to `0.0.0.0/0`.
 - Aliases DB missing: if you see `error: open database /etc/aliases.db: No such file or directory`, build the aliases database:
   ```sh
   postalias /etc/aliases
   ls -l /etc/aliases /etc/aliases.db
   postconf alias_maps alias_database
   service postfix reload
   ```
   Why: `postalias` compiles the text file `/etc/aliases` into a binary hash database `/etc/aliases.db` that Postfix uses at runtime (as referenced by `hash:/etc/aliases`). Without this file, local delivery lookups fail and messages are deferred. (`newaliases` is a convenience wrapper that also runs `postalias`.)

---

## Checklist
- MX records added and validated via `dig`.
- `mail.pcXX.n2.nog-oc.org` resolves to your A/AAAA.
- Postfix enabled, started, and listening on 25.
- `/etc/aliases` updated and `newaliases` run.
- Dovecot enabled, started, and listening on 143.
- Test email delivered; log shows successful receive; mailbox file exists.

## Example Commands
```sh
# MX sanity
dig @192.168.0.XXX pcXX.n2.nog-oc.org MX

# AXFR partner (from DNS lab)
dig @192.168.0.yyy pcYY.n2.nog-oc.org AXFR

# Service checks
service postfix status
service dovecot status
```

---

## How Email Works (Mapped to This Lab)

Email is a store-and-forward system. DNS (MX) tells senders which host receives mail for a domain; SMTP transports messages between servers; IMAP lets users read mail from mailboxes.

### Core Components
- MUA (Mail User Agent): The client that composes/reads mail (here, the `mail` command for testing).
- MTA (Mail Transfer Agent): The SMTP server that sends/receives mail between hosts (Postfix on port 25).
- MDA (Mail Delivery Agent): Delivers inbound messages to local mailboxes (Postfix `local` writing to `/var/mail/<user>`).
- Mailbox Store: Where mail resides (mbox files under `/var/mail`).
- IMAP Server: Provides mailbox access to clients (Dovecot on port 143).
- DNS: `MX` points to `mail.pcXX.n2.nog-oc.org`; `A/AAAA` resolve that host to your IPv4/IPv6.

### Message Flow
Inbound to your domain:
1. Sender’s MTA queries `MX pcXX.n2.nog-oc.org` and learns `mail.pcXX.n2.nog-oc.org`.
2. Sender connects via SMTP to your Postfix (`*:25`).
3. Postfix accepts and hands to the local delivery agent.
4. Message is appended to `/var/mail/afnog`.
5. Dovecot exposes the mailbox via IMAP (`*:143`).

Outbound from your host:
1. The `mail` command submits via the system `sendmail` wrapper to Postfix.
2. Postfix resolves recipient domain MX and delivers over SMTP.

### Lab Mapping
- Domain & Host: `pcXX.n2.nog-oc.org` with `mail.pcXX.n2.nog-oc.org` as MX target.
- DNS: MX (priority 10) to your mail host; MX (priority 20) to partner `mail.pcYY…` for fallback.
- Postfix: `myhostname = mail.pcXX…`, `mydomain = pcXX…`, lab subnets set in `mynetworks`.
- Dovecot: IMAP serving mbox at `/var/mail/%u`.
- Resolver: `/etc/resolv.conf` points to your DNS so local lookups of MX/A/AAAA work.

### Key Files & Ports
- Postfix config: `/usr/local/etc/postfix/main.cf` (identity, networking, delivery).
- Aliases: `/etc/aliases` (e.g., `root: afnog`) with database `/etc/aliases.db` built by `newaliases`.
- Mailer wrapper: `/etc/mail/mailer.conf` should point `sendmail`, `mailq`, `newaliases` to Postfix binaries.
- Ports: SMTP `25` (Postfix `master`), IMAP `143` (Dovecot).

### Validation
- DNS: `dig pcXX.n2.nog-oc.org MX`, `dig mail.pcXX.n2.nog-oc.org A/AAAA`.
- Services: `service postfix status`, `service dovecot status`; `sockstat -4 -6 | grep -E ':25|:143'`.
- Postfix sanity: `postfix check`, `postconf -n` (`myhostname`, `mydomain`, `mydestination`, `mynetworks`).
- Aliases: `newaliases`; confirm `/etc/aliases.db` exists.
- Delivery: Send test mail; watch `/var/log/maillog`; mailbox `/var/mail/afnog` grows.

For an automated check, use the validator in this folder: `scripts/validate_mail_lab.sh`.

## Submission
Submit a screenshot of the successful receive lines in `/var/log/maillog` for account `afnog` on domain `mail.pcXX.n2.nog-oc.org`.

---

## Optional: Webmail (SnappyMail)

Add a lightweight web interface for students to read and send mail via IMAP/SMTP.

### Overview
- Webmail client: SnappyMail (PHP) connects to Dovecot IMAP (read) and Postfix submission (send).
- Requires: nginx (or Apache), PHP-FPM, and Postfix/Dovecot SASL auth for SMTP submission on port 587.

### Step 1 — Enable SMTP submission with SASL
Edit Postfix and Dovecot to allow authenticated submission (same as above):

Postfix `main.cf` additions:
```
smtpd_sasl_auth_enable = yes
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_tls_security_level = may
```
Postfix `master.cf` — enable submission (port 587):
```
submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
```
Dovecot auth socket for Postfix (`/usr/local/etc/dovecot/conf.d/10-master.conf`):
```
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
```
Restart services:
```sh
service dovecot restart
service postfix restart
sockstat -4 -6 | grep -E ":587|dovecot"
```

### Step 2 — Install SnappyMail + Web stack
Detect available PHP branch, then install matching PHP-FPM and SnappyMail:
```sh
pkg search php | grep -E 'php8[2-9]-fpm'
# Pick one branch from the output, e.g., php84-fpm
pkg install nginx php84 php84-fpm snappymail
sysrc nginx_enable=YES php_fpm_enable=YES
service php-fpm start
service nginx start
```

Minimal nginx server block (HTTP) to serve SnappyMail:
```
server {
    listen 80;
    server_name mail.pcXX.n2.nog-oc.org;
    root /usr/local/www/snappymail;
    index index.php index.html;

    location ~ \.php$ {
        include        fastcgi_params;
        fastcgi_pass   127.0.0.1:9000;
        fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
```
Place under `/usr/local/etc/nginx/nginx.conf` or in an included `servers` file, then reload:
```sh
service nginx reload
```

### Step 3 — Configure SnappyMail (IMAP/SMTP)
- Browse to `http://mail.pcXX.n2.nog-oc.org/`.
- Open settings (admin) and set:
  - IMAP host: `mail.pcXX.n2.nog-oc.org`, port `143`
  - SMTP host: `mail.pcXX.n2.nog-oc.org`, port `587`, TLS, authentication with user/pass
- Save and test login with your system user (e.g., `afnog`).

### Step 4 — Test webmail
- Read mail (IMAP) and send mail (SMTP via port 587) from the web interface.

### Notes
- Security: For production, enable HTTPS (TLS) on nginx and Dovecot.
- Firewall: ensure ports 80/587 open (and 143 for IMAP).
- Alternatives: Roundcube (heavier), PostfixAdmin (admin UI, needs SQL), SOGo (groupware, heavier).
