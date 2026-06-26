# Mail Log and Delivery Flow Explained (Postfix + Dovecot, Ubuntu)

This note explains how to read `/var/log/mail.log` on Ubuntu, the roles of Postfix components, and maps a real successful delivery to each step.

## What's different from the FreeBSD version (read this first)
- **Log file:** FreeBSD writes to `/var/log/maillog`; Ubuntu's rsyslog (if installed) writes to `/var/log/mail.log`. Minimal/container Ubuntu images often don't ship `rsyslog` at all — if the file doesn't exist, use `journalctl -u postfix -f` and `journalctl -u dovecot -f` instead, or set `maillog_file = /var/log/postfix.log` in `main.cf` to have Postfix write its own file regardless of syslog.
- **No DMA step.** The FreeBSD lab's example log shows a separate `dma` (DragonFly Mail Agent) process handling submission, because FreeBSD's `/etc/mail/mailer.conf` can point local mail submission at a small standalone MTA instead of Postfix. DMA resolves the recipient's MX and connects over SMTP — even when the recipient happens to be on the same host — so the FreeBSD log shows a full SMTP handshake (`smtpd` accepting a connection) for what is, locally, just a local delivery.
- **Ubuntu has no DMA equivalent in the default picture.** Installing the `postfix` package registers it via `update-alternatives` as the system's `sendmail`/`mail-transport-agent` directly. So when the `mail` command runs, it hands the message straight to Postfix's own `pickup` service — no separate mini-MTA, and no extra SMTP round-trip to itself. The log is shorter and skips the `smtpd` step entirely for local submissions.

## Components in the Flow
- MUA: The user tool that submits mail (in the lab, the `mail` command from `mailutils`).
- `update-alternatives`: Decides which binary `/usr/sbin/sendmail` points to (Ubuntu's equivalent of FreeBSD's `/etc/mail/mailer.conf`) — by default, Postfix's own `sendmail` wrapper.
- Postfix `pickup`: Picks up locally-submitted mail (dropped into the maildrop queue by the `sendmail` wrapper) and hands it to `cleanup`. This replaces the `smtpd`-accepts-a-connection step you'd see for mail arriving from the network — or via DMA on FreeBSD.
- Postfix `cleanup`: Prepares messages for the queue (adds headers, computes queue ID).
- Postfix `qmgr`: Queue manager; schedules messages for delivery and tracks state.
- Postfix `local`: Local delivery agent that writes to `/var/mail/<user>`.
- Dovecot (IMAP): Lets clients read mail from `/var/mail/<user>`.

## Example Log Walkthrough
Input log (from `mail -s "this is a test mail" afnog@mail.pcXX.n2.nog-oc.org` on Ubuntu):
```
Jun 26 15:05:48 host postfix/pickup[24320]: B19371EA3E8B: uid=1000 from=<afnog>
Jun 26 15:05:48 host postfix/cleanup[24329]: B19371EA3E8B: message-id=<20260626150548.B19371EA3E8B@mail.pcXX.n2.nog-oc.org>
Jun 26 15:05:48 host postfix/qmgr[23509]: B19371EA3E8B: from=<afnog@pcXX.n2.nog-oc.org>, size=700, nrcpt=1 (queue active)
Jun 26 15:05:48 host postfix/local[24330]: B19371EA3E8B: to=<afnog@mail.pcXX.n2.nog-oc.org>, orig_to=<afnog@mail.pcXX.n2.nog-oc.org>, relay=local, delay=0.05, delays=0.02/0.01/0/0.02, dsn=2.0.0, status=sent (delivered to mailbox)
Jun 26 15:05:48 host postfix/qmgr[23509]: B19371EA3E8B: removed
```
Explanation by line:
- `postfix/pickup … uid=1000 from=<afnog>`: The `mail` command dropped the message into Postfix's local maildrop directory; `pickup` picks it up and identifies the submitting local user (`uid=1000`, i.e. `afnog`). This is the line that replaces FreeBSD's `dma … trying delivery` / `postfix/smtpd … connect from …` pair — there's no network hop because the message never leaves Postfix's own queueing machinery.
- `postfix/cleanup … message-id=<…>`: The cleanup service writes headers and records the Message-ID. A queue ID, `B19371EA3E8B`, is assigned here.
- `postfix/qmgr … queue active`: Queue manager registers the message (size, sender, recipient count) and schedules delivery.
- `postfix/local … status=sent (delivered to mailbox)`: Local delivery agent wrote the message to `/var/mail/afnog`. `dsn=2.0.0` is a success code. `delay=0.05` is total time; `delays=0.02/0.01/0/0.02` breaks down internal timings.
- `postfix/qmgr … removed`: Queue manager removes the message from the active queue (delivery finished).

If you see `postfix/smtpd … connect from …` lines instead for a *local* test like this one, it usually means something other than Postfix's own `sendmail` is handling submission — check `update-alternatives --display mail-transport-agent`.

## IDs and Timings
- Queue ID `B19371EA3E8B`: Unique per message inside Postfix; use it to correlate lines.
- Message-ID `<…@host>`: Header added for message tracking across systems.
- `delay=` total seconds from submission to delivery.
- `delays=a/b/c/d` (internal breakdown):
  - `a`: Time before queue manager (pickup/SMTP reception, cleanup).
  - `b`: Queue manager scheduling time.
  - `c`: Connection setup to the delivery agent (often 0 for local).
  - `d`: Actual delivery transmission time (writing to mailbox for local).
- `dsn=2.0.0`: Delivery Status Notification code; `2.x.x` indicates success.

## Follow the Flow Quickly
- Find the queue ID on the first `postfix/pickup` (or `postfix/smtpd`, for mail arriving over the network) line and track it across `cleanup`, `qmgr`, `local`, and `removed`.
- Use `grep` to filter by queue ID:
```sh
grep B19371EA3E8B /var/log/mail.log
# or, without rsyslog:
journalctl -u postfix | grep B19371EA3E8B
```
- Confirm local mailbox grew:
```sh
ls -lh /var/mail/afnog
```

## Tips & Common Causes
- Aliases DB missing: if local delivery defers with alias database errors, build it:
```sh
sudo postalias /etc/aliases && sudo systemctl reload postfix
```
- Unexpected `smtpd` lines for what should be local submission: check `update-alternatives --display mail-transport-agent` — something other than Postfix's own wrapper may be handling `/usr/sbin/sendmail`.
- DNS issues: verify `MX` and `A/AAAA` for the target `mail.pcXX.n2.nog-oc.org`.
- Permissions: ensure `mail_privileged_group = mail` is set in Dovecot's `10-mail.conf` so new mailboxes under `/var/mail` can be created — this is an Ubuntu-specific step with no FreeBSD equivalent (see the main `README.md`).

## Delivery Status Types
- **status=sent:** Successful delivery (local, relay, or remote). Usually accompanies `dsn=2.x.x`. For local, you'll see "delivered to mailbox".
- **status=deferred:** Temporary failure; message stays in queue and Postfix retries later. Typically pairs with `dsn=4.x.x`.
- **status=bounced:** Permanent failure; message removed from active queue and a bounce is generated to the sender. Typically `dsn=5.x.x`.
- **removed:** Queue manager has removed the message (after successful delivery, bounce, or expiration).

## DSN Codes (Quick Reference)
- **2.x.x:** Success — e.g., `2.0.0 delivered`.
- **4.x.x:** Temporary failure — server will retry.
  - `4.4.1` No answer from host / connection timed out.
  - `4.2.0` Mailbox full (temporary) or insufficient storage.
- **5.x.x:** Permanent failure — fix the cause and resend.
  - `5.1.1` Bad destination mailbox address (unknown user).
  - `5.4.4` Unable to route — domain has no valid MX/A/AAAA.
  - `5.7.1` Relay access denied / not authorized.
  - `5.7.0` Authentication required or policy rejection.
  - `5.0.0` Generic permanent failure.

## Common Log Errors and Meanings
- **alias database unavailable / open database /etc/aliases.db: No such file or directory**
  - Meaning: The compiled aliases DB is missing.
  - Fix: `sudo postalias /etc/aliases` (or `sudo newaliases`), then `sudo systemctl reload postfix`.

- **connect to host: Connection refused**
  - Meaning: Remote SMTP/IMAP service isn't listening or firewall blocked.
  - Fix: Verify service running (`systemctl status postfix`), port open (`ss -tlnp | grep :25`), and `ufw` rules.

- **Host or domain name not found. Name service error**
  - Meaning: DNS failure resolving recipient domain or MX.
  - Fix: Check `/etc/resolv.conf` (or `resolvectl status` if managed by `systemd-resolved`), then `dig recipient-domain MX` and `dig mailhost A/AAAA`.

- **delivery temporarily suspended: connect timed out**
  - Meaning: Remote host is unreachable or slow; Postfix will retry.
  - Fix: Network/firewall checks; confirm remote server up.

- **status=bounced (unknown user)**
  - Meaning: Local recipient doesn't exist and no alias maps it.
  - Fix: Create system user or add alias in `/etc/aliases` and run `postalias`.

- **relay access denied (RCPT from …)**
  - Meaning: Client is not permitted to relay through your SMTP.
  - Fix: Add lab subnet to `mynetworks` for trusted relays, or enable submission on port 587 with SASL auth.

- **SASL authentication failed**
  - Meaning: Bad credentials or Postfix cannot reach Dovecot's auth socket.
  - Fix: Check Dovecot's `service auth` socket path/permissions in `/etc/dovecot/conf.d/10-master.conf` and user/password.

- **TLS not available / no shared cipher**
  - Meaning: TLS is required but not configured or mismatch in ciphers.
  - Fix: Enable TLS in Postfix/Dovecot, provide certs, or relax policy for the lab.

- **mailbox full / over quota / insufficient storage**
  - Meaning: Target mailbox or filesystem is out of space.
  - Fix: Free disk space or adjust quotas; for mbox, ensure `/var/mail` has room.

- **Permission denied creating a new mailbox under /var/mail**
  - Meaning: Ubuntu's `/var/mail` is owned by group `mail` and isn't world-writable; Dovecot can't create a first-time mailbox for a user without elevated group access. (This one doesn't come up on FreeBSD, where the mail spool is typically more permissive by default.)
  - Fix: Set `mail_privileged_group = mail` in `/etc/dovecot/conf.d/10-mail.conf` and restart Dovecot.

## Quick Troubleshooting Commands
- Services: `systemctl status postfix`, `systemctl status dovecot`
- Ports: `ss -tlnp | grep -E ':25|:587|:143'`
- DNS: `dig domain MX`, `dig host A +short`, `dig host AAAA +short`
- Postfix config: `postconf -n`, syntax: `postfix check`
- Logs: `tail -f /var/log/mail.log` (or `journalctl -u postfix -f` if `rsyslog` isn't installed) — use the queue ID to correlate
