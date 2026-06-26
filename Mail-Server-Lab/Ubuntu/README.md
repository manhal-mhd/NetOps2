# Mail Server Lab (Ubuntu) — Postfix + Dovecot + DNS MX

This is the Ubuntu version of the original FreeBSD lab guide. It builds the same simple mail server using Postfix (SMTP) and Dovecot (IMAP), tied to the DNS zone from the [Authoritative DNS Lab (Ubuntu)](../DNS-Lab-Ubuntu/README.md) — same protocol, same Postfix/Dovecot config keys, same checks — but using `apt`, `systemd`, and Debian/Ubuntu's mail-stack packaging conventions instead of FreeBSD's `pkg`/`rc.conf`/`sysrc`. You will add MX records, install and configure Postfix/Dovecot, send a test email, and verify delivery.

## Prerequisites
- Completed the Ubuntu DNS lab and a working zone `pcXX.n2.nog-oc.org`, with the master zone file at `/etc/bind/zones/db.pcXX.n2.nog-oc.org` (per that lab's AppArmor-aware path convention).
- Primary address: IPv4 `192.168.XX.XX`, optional IPv6 `2a02:c207:2054:4961:XXXX::XX`.
- Root (or sudo) access on Ubuntu 22.04/24.04.
- Open network access to TCP ports 25 (SMTP) and 143 (IMAP).

## Variables
- Replace `pcXX` with your zone; `pcYY` is your partner's.
- Replace `XX`/`XXXX::XX` with your actual IPs.

---

## What's different from the FreeBSD version (read this first)

| Topic | FreeBSD | Ubuntu |
|---|---|---|
| Package manager | `pkg` | `apt` |
| Postfix package | `postfix` | `postfix` (same name) |
| Dovecot package | `dovecot` (one package) | split: `dovecot-core`, `dovecot-imapd` (IMAP is a separate package) |
| `mail` command | built into base system | from the `mailutils` (or `bsd-mailx`) package — install it explicitly |
| Service manager | `rc.conf` / `service` | `systemd` / `systemctl` (`service` still works as a compatibility wrapper) |
| Disabling the stock MTA | `sysrc sendmail_enable=NO` + `service sendmail stop` (Sendmail ships by default) | not needed — Ubuntu ships **no** MTA by default, and installing `postfix` auto-registers it as the system MTA via `update-alternatives` |
| Postfix config root | `/usr/local/etc/postfix` | `/etc/postfix` |
| Dovecot config root | `/usr/local/etc/dovecot` | `/etc/dovecot` (with includes under `/etc/dovecot/conf.d/`) |
| `/etc/mail/mailer.conf` (FreeBSD's MTA-selection file) | exists, must point to Postfix | **doesn't exist** on Ubuntu — the equivalent is `update-alternatives --display mta`/`mail-transport-agent` |
| Local submission path | depends on `mailer.conf` — may go through **DMA**, a separate mini-MTA that resolves MX and submits over SMTP, even to itself | goes straight into **Postfix's own queue** via the `pickup` service — no DMA, no extra SMTP hop (see `docs/MailLog-Explanation.md`) |
| Mail log | `/var/log/maillog` | `/var/log/mail.log` (via rsyslog) — **may not exist** in minimal/container images that ship without `rsyslog`; use `journalctl -u postfix -f` instead, or set `maillog_file` in `main.cf` |
| `/var/mail` permissions | permissive (sticky, often more open) by default | group-`mail`, not world-writable — Dovecot needs `mail_privileged_group = mail` to create new mailboxes there |
| Port/socket listing | `sockstat -4 -6` | `ss -tlnp` (or `ss -4 -6 -tlnp` to split by family) |
| IP autodetection | `ifconfig` | `ip addr` (`ifconfig`/`net-tools` isn't installed by default on modern Ubuntu) |
| Editor used in examples | `ee` | `nano` |
| Firewall | `pf`/none by default | `ufw`, if enabled |

---

## Part 1: DNS — Add MX Records
1) Edit your master zone file and add a `mail` host and MX records
```sh
sudo nano /etc/bind/zones/db.pcXX.n2.nog-oc.org
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
- **Don't forget to bump the SOA serial** at the top of the file — BIND won't notify/transfer the new records to your partner otherwise.

2) Validate the zone
```sh
named-checkzone pcXX.n2.nog-oc.org /etc/bind/zones/db.pcXX.n2.nog-oc.org
```
Why: same `named-checkzone` binary and syntax as FreeBSD; only the path changed, to match the Ubuntu DNS lab's `/etc/bind/zones/` convention.

3) Reload BIND
```sh
sudo rndc reload
# or
sudo systemctl reload named
```
(`named` is the systemd unit on Ubuntu 20.04+; use `bind9` instead on 18.04 and older — same caveat as the DNS lab.)

4) Update resolver and test
Check first whether `systemd-resolved` manages `/etc/resolv.conf`:
```sh
readlink -f /etc/resolv.conf
```
- If it prints `/run/systemd/resolve/stub-resolv.conf`, set your DNS server via `resolvectl` instead of editing the file directly (it'll be overwritten):
```sh
sudo resolvectl dns eth0 192.168.XX.XX
sudo resolvectl domain eth0 pcXX.n2.nog-oc.org
```
- If it's a plain file, edit it directly as in the FreeBSD guide:
```sh
sudo nano /etc/resolv.conf
```
```
nameserver 192.168.XX.XX
nameserver 9.9.9.9
search pcXX.n2.nog-oc.org
```

Then test:
```sh
dig pcXX.n2.nog-oc.org MX
```
You should see both MX records, and `mail.pcXX.n2.nog-oc.org` should resolve to your A/AAAA.

---

## Part 2: Install Postfix and Dovecot
1) Install packages
```sh
sudo apt update
sudo apt install -y postfix dovecot-core dovecot-imapd mailutils
```
During the Postfix install you'll get a debconf dialog:
- **General type of mail configuration:** choose **"Internet Site"** (this auto-fills `myhostname` from your system's FQDN — you'll still edit `main.cf` by hand afterward).
- **System mail name:** enter `pcXX.n2.nog-oc.org`.

Why no `sysrc sendmail_enable=NO` step: Ubuntu doesn't ship Sendmail (or any MTA) pre-installed the way FreeBSD does, so there's nothing to disable. Installing the `postfix` package registers it as the system's `sendmail`/`mailq`/`newaliases` provider via `update-alternatives` automatically — the rough equivalent of FreeBSD's `/etc/mail/mailer.conf`, just handled for you.

If `mailutils`'s own installer prompts you for a mail server configuration, choose **"No configuration"** — Postfix is already handling that.

2) Confirm your MX record
```sh
dig pcXX.n2.nog-oc.org MX
```

3) (Optional) Confirm Postfix owns local mail delivery
```sh
update-alternatives --display mail-transport-agent
```
You should see it pointing at Postfix's binaries.

---

## Part 3: Configure Postfix
1) Prepare `main.cf`
```sh
cd /etc/postfix
sudo cp main.cf main.cf.orig
sudo nano main.cf
```
Minimal lab configuration (edit `pcXX` and networks) — **identical keys and values to the FreeBSD version**, only the file path changed:
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
- `local_recipient_maps = unix:passwd.byname` works the same on Linux as on FreeBSD — it's a portable Postfix table type that calls the system's `getpwnam()`, not an OS-specific path.

2) Aliases for local delivery
```sh
sudo nano /etc/aliases
```
Example:
```
#root: postmaster
root: afnog
nagios: afnog
```
Rebuild aliases:
```sh
sudo newaliases
```
(Same `newaliases`/`postalias` mechanism as FreeBSD — `/etc/aliases` is a standard Postfix path on every OS it runs on.)

3) Start Postfix and verify
```sh
sudo systemctl restart postfix
sudo postfix check
sudo postconf -n
ss -tlnp | grep :25
```
You should see Postfix's `master` process listening on `*:25`. (`ss` replaces FreeBSD's `sockstat -4 -6`.)

---

## Part 4: Configure Dovecot (IMAP)
1) Set the protocol
```sh
sudo nano /etc/dovecot/dovecot.conf
```
Add (or uncomment) near the top:
```
protocols = imap
```
Why a separate step here: Ubuntu's Dovecot ships its full default config split across `/etc/dovecot/conf.d/*.conf`, included automatically — unlike the FreeBSD guide, which hand-writes one flat `dovecot.conf`. Setting `protocols` in the top-level file is enough to override the include defaults for this lab; you don't need to touch the `conf.d/` files for this minimal setup.

2) Minimal mail settings
```sh
sudo nano /etc/dovecot/conf.d/10-mail.conf
```
Set:
```
mail_location = mbox:/var/mail/%u
mail_privileged_group = mail
```
Why `mail_privileged_group = mail` (no FreeBSD equivalent step): on Ubuntu/Debian, `/var/mail` is owned by group `mail` and is **not** world-writable the way FreeBSD's mail spool typically is. Without this line, Dovecot can read existing mailboxes but fails with "Permission denied" when it needs to create a brand-new one (e.g., the very first message to a user who has never received mail) or write its `.lock` file. This setting tells Dovecot it's safe to briefly run with group `mail` privileges for exactly that.

3) Auth settings
```sh
sudo nano /etc/dovecot/conf.d/10-auth.conf
```
Set:
```
disable_plaintext_auth = no
auth_mechanisms = plain login
```

4) passdb/userdb
```sh
sudo nano /etc/dovecot/conf.d/10-master.conf
```
(Leave as default for this lab — PAM/passwd auth is already enabled via the includes under `auth-system.conf.ext`, which is wired in by default. This replaces the FreeBSD guide's hand-rolled `passdb { driver = pam }` / `userdb { driver = passwd }` blocks — same intent, Ubuntu just ships it pre-wired.)

5) Start Dovecot and verify
```sh
sudo systemctl restart dovecot
ss -tlnp | grep :143
```
You should see Dovecot listening on `*:143`.

---

## Part 5: Send a Test Email
1) Create or ensure local user `afnog` exists. `/var/mail/afnog` will be created on first delivery (now that `mail_privileged_group` is set).

2) Send mail and watch logs
```sh
mail -s "this is a test mail" afnog@mail.pcXX.n2.nog-oc.org
# type message body, then a single dot on its own line to finish
.

tail -f /var/log/mail.log
```
If `/var/log/mail.log` doesn't exist (common in minimal/container images that don't ship `rsyslog`), use the systemd journal instead:
```sh
journalctl -u postfix -f
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
- Services: `systemctl status postfix`, `systemctl status dovecot`.
- Logs: `tail -f /var/log/mail.log`, or `journalctl -u postfix -f` / `journalctl -u dovecot -f` if `rsyslog` isn't installed.
- Queue: `mailq` or `postqueue -p`; retry: `postsuper -r ALL`.
- Firewall/ports: `sudo ufw status`. If `ufw` is active, `sudo ufw allow 25/tcp && sudo ufw allow 143/tcp`.
- Relaying denied: adjust `mynetworks` cautiously; never open to `0.0.0.0/0`.
- Aliases DB missing: if you see `error: open database /etc/aliases.db: No such file or directory`, build the aliases database:
  ```sh
  sudo postalias /etc/aliases
  ls -l /etc/aliases /etc/aliases.db
  postconf alias_maps alias_database
  sudo systemctl reload postfix
  ```
  Why: `postalias` compiles the text file `/etc/aliases` into a binary hash database `/etc/aliases.db` that Postfix uses at runtime. Without this file, local delivery lookups fail and messages are deferred. (`newaliases` is a convenience wrapper that also runs `postalias` — identical behavior to FreeBSD.)
- New mailbox fails to create / "Permission denied" on first delivery to a user: you're missing `mail_privileged_group = mail` in `/etc/dovecot/conf.d/10-mail.conf` — see Part 4.

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
dig @192.168.0.YYY pcYY.n2.nog-oc.org AXFR

# Service checks
systemctl status postfix
systemctl status dovecot
```

---

## How Email Works (Mapped to This Lab)

Email is a store-and-forward system. DNS (MX) tells senders which host receives mail for a domain; SMTP transports messages between servers; IMAP lets users read mail from mailboxes.

### Core Components
- MUA (Mail User Agent): The client that composes/reads mail (here, the `mail` command, from `mailutils`).
- MTA (Mail Transfer Agent): The SMTP server that sends/receives mail between hosts (Postfix on port 25).
- MDA (Mail Delivery Agent): Delivers inbound messages to local mailboxes (Postfix `local` writing to `/var/mail/<user>`).
- Mailbox Store: Where mail resides (mbox files under `/var/mail`).
- IMAP Server: Provides mailbox access to clients (Dovecot on port 143).
- DNS: `MX` points to `mail.pcXX.n2.nog-oc.org`; `A/AAAA` resolve that host to your IPv4/IPv6.

### Message Flow
Inbound to your domain:
1. Sender's MTA queries `MX pcXX.n2.nog-oc.org` and learns `mail.pcXX.n2.nog-oc.org`.
2. Sender connects via SMTP to your Postfix (`*:25`).
3. Postfix accepts and hands to the local delivery agent.
4. Message is appended to `/var/mail/afnog`.
5. Dovecot exposes the mailbox via IMAP (`*:143`).

Outbound from your host (this is the one step that genuinely differs from FreeBSD — see `docs/MailLog-Explanation.md` for the full log walkthrough):
1. The `mail` command submits via `/usr/sbin/sendmail`, which `update-alternatives` points straight at Postfix's own binary.
2. Postfix's `pickup` service picks the message up directly into its own queue — no separate mini-MTA, no extra SMTP hop to itself, the way FreeBSD's DMA sometimes does it.
3. For a recipient on `mydestination` (your own domain, as in this lab), Postfix delivers locally via `local`. For other domains, Postfix resolves the recipient's MX and delivers over SMTP.

### Lab Mapping
- Domain & Host: `pcXX.n2.nog-oc.org` with `mail.pcXX.n2.nog-oc.org` as MX target.
- DNS: MX (priority 10) to your mail host; MX (priority 20) to partner `mail.pcYY…` for fallback.
- Postfix: `myhostname = mail.pcXX…`, `mydomain = pcXX…`, lab subnets set in `mynetworks`.
- Dovecot: IMAP serving mbox at `/var/mail/%u`, with `mail_privileged_group = mail` so new mailboxes can be created.
- Resolver: `/etc/resolv.conf` (or `resolvectl`, if `systemd-resolved` manages it) points to your DNS so local lookups of MX/A/AAAA work.

### Key Files & Ports
- Postfix config: `/etc/postfix/main.cf` (identity, networking, delivery).
- Aliases: `/etc/aliases` (e.g., `root: afnog`) with database `/etc/aliases.db` built by `newaliases`.
- MTA selection: `update-alternatives --display mail-transport-agent` (Ubuntu's equivalent of FreeBSD's `/etc/mail/mailer.conf`).
- Ports: SMTP `25` (Postfix `master`), IMAP `143` (Dovecot).

### Validation
- DNS: `dig pcXX.n2.nog-oc.org MX`, `dig mail.pcXX.n2.nog-oc.org A/AAAA`.
- Services: `systemctl status postfix`, `systemctl status dovecot`; `ss -tlnp | grep -E ':25|:143'`.
- Postfix sanity: `postfix check`, `postconf -n` (`myhostname`, `mydomain`, `mydestination`, `mynetworks`).
- Aliases: `newaliases`; confirm `/etc/aliases.db` exists.
- Delivery: Send test mail; watch `/var/log/mail.log` (or `journalctl -u postfix`); mailbox `/var/mail/afnog` grows.

For an automated check, use the validator in this folder: `scripts/validate_mail_lab.sh`.

## Submission
Submit a screenshot of the successful receive lines in `/var/log/mail.log` (or the equivalent `journalctl -u postfix` output) for account `afnog` on domain `mail.pcXX.n2.nog-oc.org`.

---

## Optional: Webmail (SnappyMail)

Add a lightweight web interface for students to read and send mail via IMAP/SMTP.

### Overview
- Webmail client: SnappyMail (PHP) connects to Dovecot IMAP (read) and Postfix submission (send).
- Requires: nginx (or Apache), PHP-FPM, and Postfix/Dovecot SASL auth for SMTP submission on port 587.
- **Unlike FreeBSD, SnappyMail is not in Ubuntu's `apt` repositories** — there's no `pkg install snappymail` equivalent. You download the official release tarball and extract it under your web root instead. This is the main difference from the FreeBSD steps below.

### Step 1 — Enable SMTP submission with SASL
Edit Postfix and Dovecot to allow authenticated submission (identical config keys to the FreeBSD version):

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
Dovecot auth socket for Postfix (`/etc/dovecot/conf.d/10-master.conf` — same filename as on FreeBSD):
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
sudo systemctl restart dovecot
sudo systemctl restart postfix
ss -tlnp | grep -E ':587|:143'
```

### Step 2 — Install a web stack, then download SnappyMail
Install nginx and PHP-FPM from `apt`:
```sh
sudo apt install -y nginx php-fpm php-curl php-xml php-mbstring php-zip
php -v   # note your installed PHP version, e.g. 8.3
```
Download and extract the latest SnappyMail release (check https://github.com/the-djmaze/snappymail/releases for the current version):
```sh
sudo mkdir -p /var/www/snappymail
cd /var/www/snappymail
sudo wget https://github.com/the-djmaze/snappymail/releases/latest/download/snappymail-latest.tar.gz
sudo tar -xzf snappymail-latest.tar.gz
sudo chown -R www-data:www-data /var/www/snappymail
```

Minimal nginx server block (HTTP) — note the **unix socket** `fastcgi_pass`, which is Ubuntu's PHP-FPM default (FreeBSD's port commonly defaults to a TCP socket on `127.0.0.1:9000` instead):
```
server {
    listen 80;
    server_name mail.pcXX.n2.nog-oc.org;
    root /var/www/snappymail;
    index index.php index.html;

    location ~ \.php$ {
        include        fastcgi_params;
        fastcgi_pass   unix:/run/php/php8.3-fpm.sock;   # match your php -v version
        fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
```
Place it at `/etc/nginx/sites-available/snappymail`, symlink it into `sites-enabled/`, then test and reload:
```sh
sudo ln -s /etc/nginx/sites-available/snappymail /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
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
- Firewall: ensure ports 80/587 open (and 143 for IMAP) — `sudo ufw allow 80/tcp && sudo ufw allow 587/tcp`.
- Alternatives: Roundcube (heavier), PostfixAdmin (admin UI, needs SQL), SOGo (groupware, heavier).
