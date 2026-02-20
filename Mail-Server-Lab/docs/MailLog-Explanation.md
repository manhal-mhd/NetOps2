# Mail Log and Delivery Flow Explained (Postfix + Dovecot)

This note explains how to read `/var/log/maillog`, the roles of Postfix components, and maps a real successful delivery to each step.

## Components in the Flow
- MUA: The user tool that submits mail (in the lab, `mail` command).
- Sendmail wrapper: `/etc/mail/mailer.conf` decides which binary handles submission (Postfix `sendmail` or DMA).
- Postfix `smtpd`: SMTP server that accepts incoming messages.
- Postfix `cleanup`: Prepares messages for the queue (adds headers, computes queue ID).
- Postfix `qmgr`: Queue manager; schedules messages for delivery and tracks state.
- Postfix `local`: Local delivery agent that writes to `/var/mail/<user>`.
- Dovecot (IMAP): Lets clients read mail from `/var/mail/<user>`.
- DMA (optional): A lightweight MTA; if configured in `mailer.conf`, DMA may handle submission and connect to Postfix.

## Example Log Walkthrough
Input log:
```
Feb 14 15:05:48 host dma[1e92be2.3ccbf7647000][24326]: <afnog@mail.pc200.n2.nog-oc.org> trying delivery
Feb 14 15:05:48 host dma[1e92be2.3ccbf7647000][24326]: trying remote delivery to mail.pc200.n2.nog-oc.org [2001:db8::c8] pref 0
Feb 14 15:05:48 host postfix/smtpd[24327]: connect from unknown[2001:db8::c8]
Feb 14 15:05:48 host postfix/smtpd[24327]: B19371EA3E8B: client=unknown[2001:db8::c8]
Feb 14 15:05:48 host postfix/cleanup[24329]: B19371EA3E8B: message-id=<69908f4c.1e92be2.7865be02@host>
Feb 14 15:05:48 host postfix/qmgr[23509]: B19371EA3E8B: from=<root@host>, size=700, nrcpt=1 (queue active)
Feb 14 15:05:48 host postfix/smtpd[24327]: disconnect from unknown[2001:db8::c8] ehlo=1 mail=1 rcpt=1 data=1 quit=1 commands=5
Feb 14 15:05:48 host dma[1e92be2.3ccbf7647000][24326]: <afnog@mail.pc200.n2.nog-oc.org> delivery successful
Feb 14 15:05:48 host postfix/local[24330]: B19371EA3E8B: to=<afnog@mail.pc200.n2.nog-oc.org>, relay=local, delay=0.1, delays=0.08/0.01/0/0, dsn=2.0.0, status=sent (delivered to mailbox)
Feb 14 15:05:48 host postfix/qmgr[23509]: B19371EA3E8B: removed
```
Explanation by line:
- `dma … trying delivery`: The submission agent (DMA in this log) begins delivery for recipient `<afnog@…>`. If `mailer.conf` points to Postfix, you would see Postfix `sendmail` instead of DMA.
- `dma … trying remote delivery … [2001:db8::c8]`: DMA resolves the MX/A/AAAA and connects to the mail host over IPv6.
- `postfix/smtpd … connect from …`: Postfix accepts the SMTP connection.
- `postfix/smtpd … B19371EA3E8B`: Message enters Postfix; a queue ID `B19371EA3E8B` is assigned.
- `postfix/cleanup … message-id=<…>`: The cleanup service writes headers and records the Message-ID.
- `postfix/qmgr … queue active`: Queue manager registers the message (size, sender, recipient count) and schedules delivery.
- `postfix/smtpd … disconnect …`: SMTP session completes (EHLO, MAIL FROM, RCPT TO, DATA, QUIT); counters show one of each.
- `dma … delivery successful`: DMA confirms the SMTP transaction completed successfully (the server accepted the message).
- `postfix/local … status=sent (delivered to mailbox)`: Local delivery agent wrote the message to `/var/mail/afnog`. `dsn=2.0.0` is a success code. `delay=0.1` is total time; `delays=0.08/0.01/0/0` breaks down internal timings.
- `postfix/qmgr … removed`: Queue manager removes the message from the active queue (delivery finished).

## IDs and Timings
- Queue ID `B19371EA3E8B`: Unique per message inside Postfix; use it to correlate lines.
- Message-ID `<…@host>`: Header added for message tracking across systems.
- `delay=` total seconds from SMTP accept to delivery.
- `delays=a/b/c/d` (internal breakdown):
  - `a`: Time before queue manager (SMTP reception, cleanup).
  - `b`: Queue manager scheduling time.
  - `c`: Connection setup to the delivery agent (often 0 for local).
  - `d`: Actual delivery transmission time (writing to mailbox for local).
- `dsn=2.0.0`: Delivery Status Notification code; `2.x.x` indicates success.

## Follow the Flow Quickly
- Find the queue ID on the first `postfix/smtpd` line and track it across `cleanup`, `qmgr`, `local`, and `removed`.
- Use `grep` to filter by queue ID:
```sh
grep B19371EA3E8B /var/log/maillog
```
- Confirm local mailbox grew:
```sh
ls -lh /var/mail/afnog
```

## Tips & Common Causes
- Aliases DB missing: if local delivery defers with alias database errors, build it:
```sh
postalias /etc/aliases && service postfix reload
```
- Wrong submission agent: if logs show DMA but you expect Postfix, check `/etc/mail/mailer.conf` points to Postfix binaries.
- DNS issues: verify `MX` and `A/AAAA` for the target `mail.pcXX.n2.nog-oc.org`.
- Permissions: ensure `/var/mail` and user mailbox are writable by the delivery agent.

## Delivery Status Types
- **status=sent:** Successful delivery (local, relay, or remote). Usually accompanies `dsn=2.x.x`. For local, you’ll see “delivered to mailbox”.
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
  - Fix: `postalias /etc/aliases` (or `newaliases`), then `service postfix reload`.

- **connect to host: Connection refused**
  - Meaning: Remote SMTP/IMAP service isn’t listening or firewall blocked.
  - Fix: Verify service running (`service postfix status`), port open (`sockstat -4 -6 | grep :25`), and firewall rules.

- **Host or domain name not found. Name service error**
  - Meaning: DNS failure resolving recipient domain or MX.
  - Fix: Check `/etc/resolv.conf`, then `dig recipient-domain MX` and `dig mailhost A/AAAA`.

- **delivery temporarily suspended: connect timed out**
  - Meaning: Remote host is unreachable or slow; Postfix will retry.
  - Fix: Network/firewall checks; confirm remote server up.

- **status=bounced (unknown user)**
  - Meaning: Local recipient doesn’t exist and no alias maps it.
  - Fix: Create system user or add alias in `/etc/aliases` and run `postalias`.

- **relay access denied (RCPT from …)**
  - Meaning: Client is not permitted to relay through your SMTP.
  - Fix: Add lab subnet to `mynetworks` for trusted relays, or enable submission on port 587 with SASL auth.

- **SASL authentication failed**
  - Meaning: Bad credentials or Postfix cannot reach Dovecot auth socket.
  - Fix: Check Dovecot `service auth` socket path/permissions and user/password.

- **TLS not available / no shared cipher**
  - Meaning: TLS is required but not configured or mismatch in ciphers.
  - Fix: Enable TLS in Postfix/Dovecot, provide certs, or relax policy for the lab.

- **mailbox full / over quota / insufficient storage**
  - Meaning: Target mailbox or filesystem is out of space.
  - Fix: Free disk space or adjust quotas; for mbox, ensure `/var/mail` has room.

## Quick Troubleshooting Commands
- Services: `service postfix status`, `service dovecot status`
- Ports: `sockstat -4 -6 | grep -E ':25|:587|:143'`
- DNS: `dig domain MX`, `dig host A +short`, `dig host AAAA +short`
- Postfix config: `postconf -n`, syntax: `postfix check`
- Logs: `tail -f /var/log/maillog` (use queue ID to correlate)
