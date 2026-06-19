# Authoritative DNS Labs (Ubuntu, BIND9)

This is the Ubuntu version of the original FreeBSD lab guide. It delivers the same clean, testable lab for an authoritative DNS setup with a primary and secondary — same protocol, same zone data, same checks — but using `apt`, `systemd`, and Ubuntu's BIND9 packaging conventions instead of FreeBSD's `pkg`/`rc.conf`/`/usr/local/etc/namedb`. It supports IPv4/IPv6 and focuses on shell access on the lab boxes (no SSH instructions). Note: in BIND configuration the keywords are `type master` and `type slave`; we will refer to them as primary and secondary throughout the guide.

- Hostnames: pcXX and pcYY (replace XX/YY with your assigned digits)
- Domains: pcXX.n2.nog-oc.org and pcYY.n2.nog-oc.org
- Primary: pcXX (you); Secondary: pcYY (your partner)

## What's different from the FreeBSD version (read this first)

| Topic | FreeBSD | Ubuntu |
|---|---|---|
| Package manager | `pkg` | `apt` |
| BIND package | `bind920` | `bind9`, `bind9utils`, `bind9-dnsutils` |
| Service manager | `rc.conf` / `service` | `systemd` / `systemctl` |
| Service unit name | `named` | `named` (Ubuntu 20.04+; `bind9` is kept as an alias). On 18.04 and older, use `bind9` instead. |
| Config root | `/usr/local/etc/namedb` | `/etc/bind` |
| Global options file | hand-rolled `named.conf` | `/etc/bind/named.conf.options` (already included by default) |
| Zone definitions file | hand-rolled `zones.conf` + manual `include` | `/etc/bind/named.conf.local` (already included by default — no `include` line needed) |
| Master zone file location | `/usr/local/etc/namedb/primary/` | `/etc/bind/zones/` (read-only for `bind`) |
| Secondary zone file location | `/usr/local/etc/namedb/secondary/` | `/var/cache/bind/` (must be **writable** by `bind` — AppArmor enforces this) |
| Mandatory access control | none by default | **AppArmor** confines `named` to `/etc/bind/**`, `/var/cache/bind/**`, `/var/lib/bind/**` |
| Firewall | none by default | `ufw`, if enabled |
| Live logs | `named -g` (foreground) | `journalctl -u named -f` (named runs as a systemd daemon) |
| Resolver file | plain `/etc/resolv.conf` | often a symlink managed by `systemd-resolved` |
| Editor used in examples | `ee` | `nano` |

The single most important Ubuntu-specific rule, and the one most students trip on: **don't put your secondary's zone file inside `/etc/bind/`.** AppArmor's BIND profile deliberately makes `/etc/bind/` read-only for the `named` process (so a compromised `named` can't tamper with your authoritative zone data) and only allows it to *write* under `/var/cache/bind/` (slave/cache data) or `/var/lib/bind/` (dynamic/DDNS data). Put your master zone file in `/etc/bind/zones/` and your secondary's transferred zone file in `/var/cache/bind/` — full details in LAB TWO and Troubleshooting below.

## Student Guide — Start Here

This lab is designed for first-time DNS students. Follow the steps in order. Record your details first, then proceed with installation, configuration, zone creation, checks, and transfer tests.

### Pre-Setup Preparation (Collect Your Data)
- Zone name (your domain): `pcXX.n2.nog-oc.org`
- Primary server hostname and IPs: `pcXX` — IPv4 `192.168.XX.XX`, IPv6 `2a02:c207:2054:4961:XXXX::XX`
- Secondary server (partner) hostname and IPs: `pcYY` — IPv4 `192.168.YY.YY`, IPv6 `2a02:c207:2054:4961:YYYY::YY`
- Name server hostnames you'll use inside the zone: `ns.pcXX.n2.nog-oc.org` (primary), `ns.pcYY.n2.nog-oc.org` (secondary)
- Confirm both systems can reach each other over UDP/53 (queries, NOTIFY) and TCP/53 (AXFR/IXFR).

Tip: Write these down; you'll substitute XX/YY in all commands and files.

### Student Guide Structure
- Pre-Setup Preparation (Collect Your Data)
- LAB ONE — Install and Prepare
- LAB TWO — Define Zones
- LAB THREE — Create Zone Records & Validate/Operate

## LAB ONE — Install and Prepare

PART 1: Update package index, install BIND9 and tools, enable and start the service
```sh
sudo apt update
sudo apt search bind9
sudo apt install -y bind9 bind9utils bind9-dnsutils
sudo systemctl enable named
sudo systemctl start named
sudo rndc-confgen -a
sudo systemctl restart named
```
Why:
- `apt search bind9` shows the latest BIND9 version packaged for your Ubuntu release (the FreeBSD equivalent of `pkg search bind`). BIND is the authoritative DNS daemon, same as on FreeBSD.
- `bind9utils` provides `named-checkconf`, `named-checkzone`, and `rndc-confgen`; `bind9-dnsutils` provides `dig` and `host`.
- `systemctl enable` + `systemctl start` replace FreeBSD's `sysrc named_enable=YES` + `service named start` — Ubuntu uses `systemd`, not `rc.conf`.
- `rndc-confgen -a` writes an `rndc` key (`/etc/bind/rndc.key`) the same way it does on FreeBSD, enabling controlled reload/notify; restart `named` afterward so it picks the key up.

Note on the service name: on Ubuntu 20.04 and later the underlying systemd unit is `named.service`, with `bind9` kept as a compatibility alias — `systemctl status bind9` works too. On Ubuntu 18.04 and older, use `bind9` in place of `named` in every command in this guide.

PART 2: Shorter path convenience — **not needed on Ubuntu**
- FreeBSD installs configs under `/usr/local/etc/namedb` and the guide symlinks it to `/etc/namedb` for convenience. Ubuntu's BIND9 package already installs everything under `/etc/bind`, so there's no extra symlink step.

PART 3: Base configuration
Edit `/etc/bind/named.conf.options`:
- Disable recursion, set listen addresses, enable IPv6, and keep `dnssec-validation` off to simplify the lab.
- This file is already included by the default `/etc/bind/named.conf` — you don't need to add any `include` line yourself.

Example snippet:
```conf
options {
    directory "/var/cache/bind";
    recursion no;                      // authoritative only
    listen-on { 127.0.0.1; 192.168.XX.XX; };
    listen-on-v6 { ::1; 2a02:c207:2054:4961:XXXX::XX; };
    dnssec-validation no;              // simplify lab
};
```
Why:
- Same intent as the FreeBSD `named.conf` options block. `directory "/var/cache/bind"` is Ubuntu's default working directory for `named` — it's also where slave/secondary zone data belongs (see the table above), so we keep the default rather than pointing it at `/etc/bind`.

## LAB TWO — Define Zones

Edit `/etc/bind/named.conf.local` and add your zone entries. This file is already included by the default `named.conf`, so — unlike the FreeBSD guide — there's no separate `zones.conf` to create or `include` line to add.

First, create a directory for your master zone file (read-only for `bind`, so a plain `mkdir` as you/root is fine):
```sh
sudo mkdir -p /etc/bind/zones
```

```conf
// Your zone (primary)
zone "pcXX.n2.nog-oc.org" {
    type master;
    notify yes;
    file "/etc/bind/zones/db.pcXX.n2.nog-oc.org";
    allow-transfer { 192.168.YY.YY; 2a02:c207:2054:4961:YYYY::YY; };
};

// Partner's zone (secondary on your side)
zone "pcYY.n2.nog-oc.org" {
    type slave;
    file "db.pcYY.n2.nog-oc.org";
    masters { 192.168.YY.YY; 2a02:c207:2054:4961:YYYY::YY; };
};
```
Why:
- Primary serves your zone and restricts transfers to your partner; secondary pulls your partner's zone — same logic as the FreeBSD guide.
- **Path matters here more than on FreeBSD.** The master's `file` is a full path into `/etc/bind/zones/`, which AppArmor leaves read-only for `named` (you write it as root/sudo; `named` only ever reads it). The secondary's `file` is given as a bare filename, `db.pcYY.n2.nog-oc.org`, with no path — BIND resolves a relative filename against the `directory` option (`/var/cache/bind`), which is the one location AppArmor lets `named` *write* zone data it receives over AXFR/IXFR. If you instead pointed a slave zone at a file under `/etc/bind/`, the transfer would be silently denied by AppArmor even though your `named.conf` syntax is perfectly valid.

## LAB THREE — Create Zone Records & Validate/Operate

Create your zone file referenced in `named.conf.local`.
- Path: `/etc/bind/zones/db.pcXX.n2.nog-oc.org`
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
- SOA defines authority and timing; NS advertises servers; A/AAAA glue records ensure resolvers can reach `ns`. The zone file format itself is identical to FreeBSD — BIND's zone-file syntax doesn't change between operating systems.
- Syntax tips: Use trailing dots on FQDNs; without a dot, names are relative to the zone.

Validate configuration and zone syntax:
```sh
sudo named-checkconf
sudo named-checkzone pcXX.n2.nog-oc.org /etc/bind/zones/db.pcXX.n2.nog-oc.org
```
Expected: `named-checkconf` returns without errors; `named-checkzone` prints `loaded serial ...` and `OK`. (Identical commands to FreeBSD — only the zone file path changed.)

Start service and test queries:
```sh
sudo systemctl restart named
sudo systemctl status named
dig pcXX.n2.nog-oc.org ns
```
Why: Confirms your server is running and serving NS records. (`systemctl restart`/`status` replace FreeBSD's `service named start`/`status`; `dig` itself is identical on both OSes.)

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
Why: AXFR uses TCP/53 to copy the entire zone; the primary typically restricts transfers to the secondary's IP. (No change from FreeBSD — AXFR is a protocol-level mechanism, not an OS feature.)

Change, reload, and verify propagation:
```sh
sudo rndc reload pcXX.n2.nog-oc.org
dig +short SOA pcXX.n2.nog-oc.org @192.168.XX.XX
dig +short SOA pcXX.n2.nog-oc.org @192.168.YY.YY
```
Expected: Both servers show the same, increased serial.

Helpful logs:
```sh
sudo journalctl -u named -f
```
Why: On FreeBSD the guide runs `named -g` in the foreground to watch logs live. On Ubuntu, `named` already runs as a managed `systemd` service, so the equivalent is tailing its journal with `journalctl -u named -f` rather than starting a second foreground copy. Look for `sending notifies (serial ...)` and `Transfer started.` messages, same as on FreeBSD. (If you do want a literal foreground run for debugging, stop the service first: `sudo systemctl stop named && sudo named -g`.)

Update your resolver once both zones resolve correctly. **Check first whether Ubuntu's `systemd-resolved` manages `/etc/resolv.conf`:**
```sh
readlink -f /etc/resolv.conf
```
- If it prints `/run/systemd/resolve/stub-resolv.conf`, the file is managed for you — edit it directly and any change will be overwritten on the next network event/reboot. For a persistent change, set DNS via Netplan instead. Edit the relevant file under `/etc/netplan/` (e.g. `/etc/netplan/50-cloud-init.yaml`):
```yaml
network:
  ethernets:
    eth0:
      nameservers:
        addresses: [192.168.XX.XX, "2a02:c207:2054:4961:XXXX::XX", 192.168.YY.YY]
        search: [pcXX.n2.nog-oc.org]
```
then apply it:
```sh
sudo netplan apply
```
- For a quick, lab-only change without touching Netplan, point `systemd-resolved` at your servers per-interface instead:
```sh
sudo resolvectl dns eth0 192.168.XX.XX 2a02:c207:2054:4961:XXXX::XX
sudo resolvectl domain eth0 pcXX.n2.nog-oc.org
```
- If `/etc/resolv.conf` is a **plain file**, not a symlink (some minimal/server images, containers, or VMs without `systemd-resolved`), edit it directly, exactly as in the FreeBSD guide:
```sh
sudo nano /etc/resolv.conf
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
Why: This makes your system use the authoritative servers you configured. Keep a fallback to your partner's server for redundancy.
Note: Some lab environments (and `systemd-resolved` itself) may overwrite `/etc/resolv.conf` on reboot or network changes. If that happens, reapply via Netplan/`resolvectl` as above, or coordinate with your instructor on persistent resolver configuration.

## Troubleshooting
- Serial not updated: secondary won't pull changes unless serial increases.
- Firewall: `sudo ufw status`. If `ufw` is active, open DNS with `sudo ufw allow Bind9` (the bundled app profile for UDP/TCP 53), or explicitly `sudo ufw allow 53/udp && sudo ufw allow 53/tcp`, in both directions between the two lab hosts.
- **AppArmor (Ubuntu-specific — not a FreeBSD concern):** BIND ships an AppArmor profile (`/etc/apparmor.d/usr.sbin.named`) that confines `named` to read/write only under `/etc/bind/**`, `/var/cache/bind/**`, and `/var/lib/bind/**`. If a zone transfer or reload fails with no obvious syntax error, check `sudo aa-status` and `sudo dmesg | grep -i apparmor` (or `journalctl -k | grep -i apparmor`) for `DENIED` entries — this is the single most common gotcha when adapting a FreeBSD-style layout to Ubuntu.
- Syntax: semicolons and braces matter; use `named-checkconf` and `named-checkzone`.
- Permissions: master zone files in `/etc/bind/zones/` only need to be readable by the `bind` group (default ownership after `sudo nano`/`sudo tee` is fine — don't `chmod` them world-writable). Secondary (slave) zone files must be **writable** by `bind` — `/var/cache/bind` is owned by `bind:bind` by default, so use it for any zone where you are the secondary; never point a slave zone's `file` at `/etc/bind/`.

## Quick Checklist
Refer to the "Student Guide Structure" above for the complete step-by-step sequence.

---

Files mirrored in this repo for reference:
- `README.md` (this guide)
- `configs/named.conf.options.sample`
- `configs/named.conf.local.sample`
- `zones/db.pcXX.n2.nog-oc.org.sample`
- `scripts/validate_dns_lab.sh`

Replace XX/YY/XXXX/YYYY placeholders with your assigned lab digits.

## AXFR Explained (Full Zone Transfer)

AXFR is the full zone transfer mechanism used between authoritative DNS servers. It allows a secondary to copy the entire zone from the primary. This is identical on Ubuntu and FreeBSD — AXFR is part of the DNS protocol, not an OS feature.

- Purpose: synchronize zone data for redundancy and consistency.
- Transport: TCP port 53 (queries typically use UDP; AXFR/IXFR use TCP).
- Trigger: usually after `NOTIFY`, or when the secondary detects a higher SOA serial on the primary.
- Flow:
    - Primary sends `NOTIFY` to the secondary (UDP).
    - Secondary does an SOA check (queries the SOA, compares serial).
    - If the serial on primary is higher, the secondary opens a TCP session and performs IXFR (incremental) if possible, otherwise AXFR (full).
- Security: restrict transfers via `allow-transfer { ... };` and optionally secure with TSIG keys in production.
- When to use `dig AXFR`: to manually verify that the zone can be transferred end-to-end and that firewall, ACLs, **and (on Ubuntu) AppArmor write permissions** are correct.

Common AXFR issues:
- TCP/53 blocked by firewall (`ufw`, on Ubuntu).
- `allow-transfer` not permitting the secondary's IP.
- Serial not incremented in SOA, so secondary stays stale.
- Secondary's zone file directory not writable/owned by `bind` — on Ubuntu this means it isn't under `/var/cache/bind` (or AppArmor is blocking the write even though the Unix permissions look fine).

Example manual tests:
```sh
dig @<primary-ip> pcXX.n2.nog-oc.org axfr
dig @<secondary-ip> pcXX.n2.nog-oc.org axfr
dig +short SOA pcXX.n2.nog-oc.org @<primary-ip>
dig +short SOA pcXX.n2.nog-oc.org @<secondary-ip>
```
Expect identical SOA serials on both servers after a successful transfer.

## Zone File Syntax and Alignment

Zone files are simple text files where each resource record (RR) is one line with whitespace-separated fields. Readability benefits from aligning columns, but alignment (spaces/tabs) is not syntactically required. **This section is unchanged from the FreeBSD guide** — BIND's zone-file format is identical regardless of the host OS.

Core elements:
- `$TTL <duration>`: default TTL for records that do not specify their own TTL.
- `$ORIGIN <name>`: optional; sets the base domain for relative names (default origin is the zone's name).
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

Example (aligned to match this lab's style):
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
- Least privilege: respect the Debian/Ubuntu convention — master zones in `/etc/bind/` (read-only for `bind`), secondary/cache data in `/var/cache/bind/`, dynamic/DDNS zones in `/var/lib/bind/`. Don't loosen AppArmor as a shortcut; fix the file location instead.
- Validate before reload: always run `named-checkconf` and `named-checkzone` before `rndc reload`.
- Logging and rotation: enable useful categories (notify/xfer); on Ubuntu, `named`'s output flows to the systemd journal by default — use `journalctl -u named` and consider a `logging {}` clause if you want dedicated log files under `/var/log/named` with `logrotate`.
- Firewall hygiene: if `ufw` is enabled, open UDP/53 and TCP/53 only between the two servers; avoid broad exposure.
- IPv6 parity: configure both IPv4 and IPv6 if available; test both paths with `dig`.
- Document changes: record who changed what and when; include a brief note alongside the serial bump.
