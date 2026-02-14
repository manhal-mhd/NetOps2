# Authoritative DNS Labs (FreeBSD, BIND)

This guide enhances your reference and delivers a clean, testable lab for an authoritative DNS setup with a primary and secondary. It uses FreeBSD + BIND, supports IPv4/IPv6, and focuses on shell access on the lab boxes (no SSH instructions). Note: in BIND configuration the keywords are `type master` and `type slave`; we will refer to them as primary and secondary throughout the guide.

- Hostnames: pcXX and pcYY (replace XX/YY with your assigned digits)
- Domains: pcXX.n2.nog-oc.org and pcYY.n2.nog-oc.org
- Primary: pcXX (you); Secondary: pcYY (your partner)

## Student Guide — Start Here

This lab is designed for first-time DNS students. Follow the steps in order. Record your details first, then proceed with installation, configuration, zone creation, checks, and transfer tests.

### Pre-Setup Preparation (Collect Your Data)
- Zone name (your domain): `pcXX.n2.nog-oc.org`
- Primary server hostname and IPs: `pcXX` — IPv4 `192.168.XX.XX`, IPv6 `2a02:c207:2054:4961:XXXX::XX`
- Secondary server (partner) hostname and IPs: `pcYY` — IPv4 `192.168.YY.YY`, IPv6 `2a02:c207:2054:4961:YYYY::YY`
- Name server hostnames you’ll use inside the zone: `ns.pcXX.n2.nog-oc.org` (primary), `ns.pcYY.n2.nog-oc.org` (secondary)
- Confirm both systems can reach each other over UDP/53 (queries, NOTIFY) and TCP/53 (AXFR/IXFR).

Tip: Write these down; you’ll substitute XX/YY in all commands and files.

### Student Guide Structure
- Pre-Setup Preparation (Collect Your Data)
- LAB ONE — Install and Prepare
- LAB TWO — Define Zones
- LAB THREE — Create Zone Records & Validate/Operate

## LAB ONE — Install and Prepare

PART 1: Search for the latest BIND, install, and enable service
```sh
pkg search bind
pkg install -y bind920
sysrc named_enable=YES
rndc-confgen -a
```
Why:
- Use `pkg search bind` to determine the latest available package (currently `bind920`). BIND is the authoritative DNS daemon; `rndc` key enables controlled reload/notify.

PART 2: Shorter path convenience
```sh
ln -s /usr/local/etc/namedb /etc/namedb
```
Why:
- FreeBSD installs configs under `/usr/local/etc/namedb`; the symlink makes the path easier.

PART 3: Base configuration
Edit `/etc/namedb/named.conf`:
- Disable recursion, set listen addresses, enable IPv6, and include zones.

Example snippet:
```conf
options {
    directory "/usr/local/etc/namedb";
    recursion no;                      // authoritative only
    listen-on { 127.0.0.1; 192.168.XX.XX; };
    listen-on-v6 { ::1; 2a02:c207:2054:4961:XXXX::XX; };
    dnssec-validation no;              // simplify lab
};

include "/etc/namedb/zones.conf";
```

## LAB TWO — Define Zones

Create `/etc/namedb/zones.conf` and add your zone entries.
```conf
# Your zone (primary)
zone "pcXX.n2.nog-oc.org" {
    type master;
    notify yes;
    file "/usr/local/etc/namedb/primary/pcXX.n2.nog-oc.org";
    allow-transfer { 192.168.YY.YY; 2a02:c207:2054:4961:YYYY::YY; };
};

# Partner's zone (secondary on your side)
zone "pcYY.n2.nog-oc.org" {
    type slave;
    file "/usr/local/etc/namedb/secondary/pcYY.n2.nog-oc.org";
    masters { 192.168.YY.YY; 2a02:c207:2054:4961:YYYY::YY; };
};
```
Why:
- Primary serves your zone and restricts transfers to your partner; secondary pulls your partner’s zone.
- Important: The `include "/etc/namedb/zones.conf";` line must be the last line in `named.conf` and not commented.

## LAB THREE — Create Zone Records & Validate/Operate

Create your zone file referenced in `zones.conf`.
- Path: `/etc/namedb/primary/pcXX.n2.nog-oc.org`
```dns
$TTL 10m
@   IN SOA pcXX.n2.nog-oc.org. afnog.pcXX.n2.nog-oc.org. (
        2026021401 ; Serial (YYYYMMDDnn) — bump on every change
        10m        ; Refresh
        10m        ; Retry
        4w         ; Expire
        10m        ; Negative
)

    IN NS ns.pcXX.n2.nog-oc.org.
    IN NS ns.pcYY.n2.nog-oc.org.

@   IN A 192.168.XX.XX
    IN AAAA 2a02:c207:2054:4961:XXXX::XX
ns  IN A 192.168.XX.XX
ns  IN AAAA 2a02:c207:2054:4961:XXXX::XX
```
Why:
- SOA defines authority and timing; NS advertises servers; A/AAAA glue records ensure resolvers can reach `ns`.
- Syntax tips: Use trailing dots on FQDNs; without a dot, names are relative to the zone.

Validate configuration and zone syntax:
```sh
named-checkconf
named-checkzone pcXX.n2.nog-oc.org /etc/namedb/primary/pcXX.n2.nog-oc.org
```
Expected: `named-checkconf` returns without errors; `named-checkzone` prints `loaded serial ...` and `OK`.

Start service and test queries:
```sh
service named start
service named status
dig pcXX.n2.nog-oc.org. ns
```
Why: Confirms your server is running and serving NS records.

Test AXFR (full zone transfer):
```sh
# Run on the secondary host to pull from the primary (expected to succeed)
dig @192.168.XX.XX pcXX.n2.nog-oc.org axfr

# Optional: If the secondary permits, test AXFR from the secondary
dig @192.168.YY.YY pcXX.n2.nog-oc.org axfr

# If AXFR is refused, verify serial sync instead
dig +short SOA pcXX.n2.nog-oc.org @192.168.XX.XX
dig +short SOA pcXX.n2.nog-oc.org @192.168.YY.YY
```
Why: AXFR uses TCP/53 to copy the entire zone; the primary typically restricts transfers to the secondary’s IP.

Change, reload, and verify propagation:
```sh
rndc reload pcXX.n2.nog-oc.org
dig +short SOA pcXX.n2.nog-oc.org @192.168.XX.XX
dig +short SOA pcXX.n2.nog-oc.org @192.168.YY.YY
```
Expected: Both servers show the same, increased serial.

Helpful logs:
```sh
named -g          # foreground logs (screen)
```
Look for `sending notifies (serial ...)` and `Transfer started.` messages.

Update your resolver (`/etc/resolv.conf`) once both zones resolve correctly:
```sh
ee /etc/resolv.conf
```
Recommended contents (replace placeholders):
```
nameserver 192.168.XX.XX
nameserver 2a02:c207:2054:4961:XXXX::XX
# Optional fallback to partner
nameserver 192.168.YY.YY
nameserver 2a02:c207:2054:4961:YYYY::YY

search pcXX.n2.nog-oc.org
options timeout:2 attempts:2
```
Why: This makes your system use the authoritative servers you configured. Keep a fallback to your partner’s server for redundancy.
Note: Some lab environments may overwrite `/etc/resolv.conf` on reboot. If that happens, reapply the settings or coordinate with your instructor on persistent resolver configuration.

## Troubleshooting
- Serial not updated: secondary won’t pull changes unless serial increases.
- Firewall: open UDP/53 and TCP/53 both directions in lab network.
- Syntax: semicolons and braces matter; use `named-checkconf` and `named-checkzone`.
- Permissions: ensure namedb directories are owned by `bind` and writable where necessary.

## Quick Checklist
Refer to the "Student Checklist" above for the complete step-by-step sequence.

---

Files mirrored in this repo for reference:
- `docs/README.md` (this guide)
- `configs/zones.conf.sample`
- `primary/pcXX.n2.nog-oc.org.sample`

Replace XX/YY/XXXX/YYYY placeholders with your assigned lab digits.

## AXFR Explained (Full Zone Transfer)

AXFR is the full zone transfer mechanism used between authoritative DNS servers. It allows a secondary to copy the entire zone from the primary.

- Purpose: synchronize zone data for redundancy and consistency.
- Transport: TCP port 53 (queries typically use UDP; AXFR/IXFR use TCP).
- Trigger: usually after `NOTIFY`, or when the secondary detects a higher SOA serial on the primary.
- Flow:
    - Primary sends `NOTIFY` to the secondary (UDP).
    - Secondary does an SOA check (queries the SOA, compares serial).
    - If the serial on primary is higher, the secondary opens a TCP session and performs IXFR (incremental) if possible, otherwise AXFR (full).
- Security: restrict transfers via `allow-transfer { ... };` and optionally secure with TSIG keys in production.
- When to use `dig AXFR`: to manually verify that the zone can be transferred end-to-end and that firewall and ACLs are correct.

Common AXFR issues:
- TCP/53 blocked by firewall.
- `allow-transfer` not permitting the secondary’s IP.
- Serial not incremented in SOA, so secondary stays stale.
- Secondary’s zone file directory not writable/owned by `bind`.

Example manual tests:
```sh
dig @<primary-ip> pcXX.n2.nog-oc.org axfr
dig @<secondary-ip> pcXX.n2.nog-oc.org axfr
dig +short SOA pcXX.n2.nog-oc.org @<primary-ip>
dig +short SOA pcXX.n2.nog-oc.org @<secondary-ip>
```
Expect identical SOA serials on both servers after a successful transfer.

## Zone File Syntax and Alignment

Zone files are simple text files where each resource record (RR) is one line with whitespace-separated fields. Readability benefits from aligning columns, but alignment (spaces/tabs) is not syntactically required.

Core elements:
- `$TTL <duration>`: default TTL for records that do not specify their own TTL.
- `$ORIGIN <name>`: optional; sets the base domain for relative names (default origin is the zone’s name).
- `@`: placeholder for the zone origin (e.g., `pcXX.n2.nog-oc.org`).
- Trailing dot: a name ending with `.` is absolute (FQDN). Without a dot, it is relative to `$ORIGIN`.
- Fields per RR (typical order): `owner [TTL] [CLASS] TYPE RDATA`
    - `owner`: the name the record applies to (e.g., `@`, `ns`, `www`).
    - `TTL`: optional per-record TTL; if omitted, `$TTL` applies.
    - `CLASS`: usually `IN` for Internet.
    - `TYPE`: record type (e.g., `SOA`, `NS`, `A`, `AAAA`).
    - `RDATA`: type-specific data (IP addresses, hostnames, etc.).
- Continuation: parentheses `(` `)` allow multi-line records (commonly used in `SOA`).
- Comments: begin with `;` and continue to end of line.

SOA record specifics:
- Format: `@ IN SOA mname. rname. ( serial refresh retry expire minimum )`
    - `mname`: primary NS for the zone (e.g., `pcXX.n2.nog-oc.org.` or `ns.pcXX.n2.nog-oc.org.`).
    - `rname`: admin email with `.` instead of `@` (e.g., `afnog.pcXX.n2.nog-oc.org.` represents `afnog@pcXX.n2.nog-oc.org`).
    - `serial`: MUST increase on every change (common pattern `YYYYMMDDnn`).
    - `refresh/retry/expire/minimum`: timers controlling secondary behavior and negative caching.

NS and glue:
- `NS` records list authoritative name servers for the zone.
- If an NS host is within the same zone (e.g., `ns.pcXX...`), provide matching `A`/`AAAA` records (glue) in the zone so resolvers can reach it.

Alignment best practices (for readability):
- Use tabs or spaces to align columns visually:
    - Column 1: owner (`@`, `ns`, etc.).
    - Column 2: class (`IN`).
    - Column 3: type (`SOA`, `NS`, `A`, `AAAA`).
    - Column 4+: RDATA (hostnames, IPs, and SOA fields).

Example (aligned to match this lab’s style):
```dns
$TTL 10m
@   IN SOA pcXX.n2.nog-oc.org. afnog.pcXX.n2.nog-oc.org. (
                2026021400 ; Serial
                10m        ; Refresh
                10m        ; Retry
                4w         ; Expire
                10m        ; Negative
)

        IN NS ns.pcXX.n2.nog-oc.org.
        IN NS ns.pcYY.n2.nog-oc.org.

@   IN A 192.168.XX.XX
        IN AAAA 2a02:c207:2054:4961:XXXX::XX
ns  IN A 192.168.XX.XX
ns  IN AAAA 2a02:c207:2054:4961:XXXX::XX
```

Notes:
- The owner is omitted on subsequent lines to repeat the previous owner (e.g., the `IN AAAA` after `@ IN A ...` applies to `@`).
- Add a trailing dot to FQDNs (e.g., `ns.pcXX.n2.nog-oc.org.`). Without the dot, `ns.pcXX.n2.nog-oc.org` would be treated as relative and appended to the origin.
- Keep one change per commit and always bump the SOA serial to trigger transfers.

## Best Practices (Primary/Secondary Authoritative DNS)

- Separation of roles: keep authoritative servers `recursion no` and run a separate resolver if needed.
- Tight transfer controls: set `allow-transfer { <secondary IPs>; }` on the primary and `allow-notify { <primary IP>; }` on the secondary.
- Consider TSIG: use keys to authenticate/authorize zone transfers in production.
- Reliable serialing: adopt `YYYYMMDDnn` and increment on every change; never reuse a lower serial.
- Sensible TTLs: shorter TTLs (e.g., 10m) for labs/testing; longer TTLs for stable production.
- Glue correctness: ensure `NS` targets inside the zone have `A`/`AAAA` records.
- Explicit listeners: specify exact `listen-on`/`listen-on-v6` addresses rather than `any`.
- Least privilege: ensure files/dirs are owned by `bind`, not writable by others; avoid running as root.
- Validate before reload: always run `named-checkconf` and `named-checkzone` before `rndc reload`.
- Logging and rotation: enable useful categories (notify/xfer), store logs under `/var/log/named`, and rotate.
- Firewall hygiene: open UDP/53 and TCP/53 only between the two servers; avoid broad exposure.
- IPv6 parity: configure both IPv4 and IPv6 if available; test both paths with `dig`.
- Document changes: record who changed what and when; include a brief note alongside the serial bump.
