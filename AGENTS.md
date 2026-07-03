# AI Agent Guide: BIND DNS Zone Generator

## Project Overview

**dns-generator** is a Perl-based system for generating BIND9 DNS zone files and configurations from a single centralized configuration file (`network.ini`). It automates the creation of DNS records (A, AAAA, MX, SPF, DMARC, DKIM, etc.) for multiple domains across master and optional slave servers.

**Key Use Cases:**

- Multi-domain DNS zone management (internal + external domains)
- Automated A/AAAA/PTR record generation from network topology
- SPF/DMARC/DKIM record injection for mail infrastructure
- Master-slave BIND9 deployment with zone persistence handling
- IPv4 and IPv6 dual-stack support

**Current Status:** Production-ready. Recent work focused on DKIM authentication, IPv6 support, and multi-domain signing.

---

## Network Topology

### Overview

The infrastructure spans three network layers: **internal subnets** (LAN), **tunnel subnets** (VPN/SSH), and **external cloud** (Hetzner). All hosts are centrally defined in `network.ini`.

### Machines & Locations (selektiv)

#### Internal Subnets (192.168.0.0/16)

| Subnet        | CIDR            | Hosts                 | Purpose                   |
| ------------- | --------------- | --------------------- | ------------------------- |
| **west**      | 192.168.87.0/24 | desktop, laptop, west | Development/workstations  |
| **east**      | 192.168.88.0/24 | laptop, west, east    | Optional secondary zone   |
| **north**     | 192.168.2.0/24  | east-n, north         | Development zone (sparse) |
| **north_old** | 192.168.89.0/24 | (empty)               | Legacy, not in use        |

#### Tunnel Subnets (VPN/SSH Tunnels)

| Tunnel         | IP Range     | Hosts                                 | Role                         |
| -------------- | ------------ | ------------------------------------- | ---------------------------- |
| **dnstunnel**  | 10.18.0.0/24 | dns (10.18.0.1), desktop (10.18.0.2)  | DNS master-slave replication |
| **mailtunnel** | 10.28.0.0/24 | mail (10.28.0.1), desktop (10.28.0.2) | Mail server tunnel           |

#### External (Hetzner Cloud + Legacy)

| Subnet    | Hosts | IP Addresses                           | Purpose                |
| --------- | ----- | -------------------------------------- | ---------------------- |
| **cloud** | dns   | 94.130.183.229 / 2a01:4f8:1c0c:43dd::1 | Primary DNS (external) |
|           | mail  | 195.201.17.234 / 2a01:4f8:1c0c:4a3b::1 | Mail server (Hetzner)  |
|           | devel | 178.104.223.86 / 2a01:4f8:c015:1e1d::1 | Development (Hetzner)  |

### DNS Infrastructure

#### Master-Slave Setup

- **Master NS:** `desktop.khms` (10.18.0.2) — Primary zone authority
- **Slave NS:** `dns.khms` (10.18.0.1) — Secondary; receives AXFR from master
- **External DNS:** `dns.cloud` (94.130.183.229) — Public-facing nameserver (Hetzner)

#### Zone Hierarchy

- **External zones** (public DNS):
  - `khms.eu` — Primary external domain
  - `khms1.de` — Secondary external domain
  - `fast-rail-transport-international.com` — Additional external domain
- **Internal zone** (private):
  - `khms` — Internal domain for LAN resources
- **Reverse zones** (PTR records):
  - `10.in-addr.arpa` — Reverse for 10.0.0.0/8 (tunnels)
  - `168.192.in-addr.arpa` — Reverse for 192.168.0.0/16 (internal)

#### DNS Aliases & Visibility

The `[domains]` section defines public hostnames (DNS aliases):

- `dns` → Publicly visible nameserver; also alternative outgoing mail server
- `mail` → Publicly visible Mail server (currently inoperable)
- `mail-server` → Mail server (alias)
- `dns-server` → Nameserver (alias)
- `devel` → Development machine

### Service Routing

#### Mail Service (when server works again)

- **Primary:** `mail-server.khms1.de` (195.201.17.234) — External-facing mail server
- **Tunnel:** `mail.mailtunnel.khms` (10.28.0.1) — Internal tunnel endpoint on the mail-server

#### DNS Service

- **Master:** `desktop.dnstunnel.khms` (10.18.0.2) — Zone authority, invisible externally
- **Slave/Primary:** `dns-server.khms1.de` (94.130.183.229) — External nameserver (public)
- **Tunnel:** `dns.dnstunnel.khms` (10.18.0.1) — Internal tunnel endpoint on the dns-server

#### Desktop/Workstation

- **Primary:** `desktop.west.khms` (192.168.87.2) — Internal access
- **Tunnel:** `desktop.dnstunnel.khms` (10.18.0.2) and `desktop.mailtunnel.khms` (10.28.0.2) — Internal tunnel endpoint on the desktop

### Configuration Structure

**File:** `network.ini`

- `[hosts]` — Host identifiers (north=1, desktop=2, laptop=44, etc.)
- `[subnets]` — Subnet assignments (west=87 → 192.168.87.0/24, cloud=EXTERN, etc.)
- `[domains]` — Public domains and routing rules
- `[networks]` — Global settings (IPv4 base, admin email, nameservers)
- `[zone_records]` — MX, SPF, DMARC, DKIM records for each zone
- `[west]`, `[east]`, `[north]` — Internal subnet members
- `[cloud]`, `[dnstunnel]`, `[mailtunnel]` — External/tunnel subnet members with IP addresses

### Key Insights

- **Dual connectivity:** Mail and DNS services are accessible both internally (via tunnels) and externally (Hetzner Cloud)
- **Master-slave consistency:** Zone transfers replicate all DNS records from master (desktop) to slave (dns) via NOTIFY mechanism
- **Multi-path routing:** `pick=` rules in `[domains]` allow hosts to use different subnets for different purposes
- **DKIM alignment:** Mail signing uses `khms1.de` domain on slave, `khms.eu` on master (both published at same domain for SPF/DMARC)
- **Reverse DNS:** PTR records automatically generated for both 10.x (tunnels) and 192.168.x (internal) ranges

---

## Essential Commands

### Generate Zones

```bash
cd /etc/bind/generator
perl generator.pl
```

Reads `network.ini`, generates zone files (`*.zone`) and BIND config (`khms-zones.conf`).

### Deploy to BIND (Master)

```bash
sudo ./deploy-zones.sh khms-zones.conf *.zone
```

### Deploy to Master + Slave

```bash
sudo ./deploy-zones.sh khms-zones.conf *.zone -- 10.18.0.1 khms-zones.conf.tmp
```

The `-- SLAVE_IP CONFIG_ON_SLAVE` syntax triggers slave deployment. Includes a critical 120-second delay before slave restart to allow zone transfer persistence.

### Deploy Exim Configuration (Optional)

Deploy mail authentication (DKIM) configuration to DNS and mail servers:

```bash
# Deploy to master (desktop) only
sudo ./deploy-zones.sh --exim-master exim/master khms-zones.conf *.zone

# Deploy to master and slave
sudo ./deploy-zones.sh --exim-master exim/master --exim-slave exim/slave \
  khms-zones.conf *.zone -- 10.18.0.1 khms-zones.conf.tmp

# Deploy to slave and mail server (with zone deployment to slave)
sudo ./deploy-zones.sh --exim-slave exim/slave --exim-mail exim/mail 195.201.17.234 \
  khms-zones.conf *.zone -- 10.18.0.1 khms-zones.conf.tmp
```

All Exim configurations use the same private key but differ in the DKIM signing domain:

- `exim/master` → Signs as khms.eu (desktop server)
- `exim/slave` → Signs as khms1.de (dns server)
- `exim/mail` → Signs as khms1.de (mail server at 195.201.17.234)

### Validate Generated Zones

```bash
named-checkzone khms.eu khms.eu.zone
named-checkzone khms1.de khms1.de.zone
```

---

## Project Structure

| Path                   | Purpose                                                            |
| ---------------------- | ------------------------------------------------------------------ |
| `generator.pl`         | Main zone generator (Perl, ~890 lines)                             |
| `deploy-zones.sh`      | Privileged deployment script (Bash, supports zones + Exim configs) |
| `network.ini`          | Central configuration (network topology + zone records)            |
| `exim/`                | Exim4 configuration files for DNS/mail servers                     |
| `exim/master/00_khms`  | DKIM config for master DNS server (signs as khms.eu)               |
| `exim/slave/00_khms`   | DKIM config for slave DNS server (signs as khms1.de)               |
| `exim/mail/00_khms`    | DKIM config for mail server (signs as khms1.de)                    |
| `*.zone`               | Generated BIND zone files (auto-created)                           |
| `khms-zones.conf`      | Generated BIND master config (auto-created)                        |
| `README.md`            | User-facing documentation                                          |
| `README-deployment.md` | Deployment procedures                                              |

---

## Configuration Architecture

### network.ini Sections

#### `[hosts]`

Numeric identifiers for individual hosts (e.g., `north=1`, `desktop=2`).
Used to generate hostnames and auto-assign IPs within subnets.

#### `[subnets]`

Subnet definitions with CIDR ranges (e.g., `west=87` → 192.168.87.0/24).

- Internal subnets: numeric (0-255)
- External subnets: marked `=EXTERN`

#### `[domains]`

Maps hosts to domains:

- `extern=` : External (publicly-routable) domains
- `visible=` : DNS aliases (e.g., `mail=mail`, `dns=dns`)
- `pick=` : Routing rules (e.g., `mail=mailtunnel` means mail host uses mailtunnel subnet)
- `intern=` : Internal domain

#### `[networks]`

Global settings:

- `ipv4` : IPv4 base address for subnets
- `admin` : Admin email
- `ns_extern` : Nameservers for external zones
- `ns_intern_master` : Master NS for internal zones
- `ns_intern_slave` : Slave NS for internal zones

#### `[zone_records]`

Zone-level records (SPF, DMARC, DKIM, MX) added to zone apex or subdomains.
Format: `key=scope|owner|type|rdata`

- **scope**: `ext` (external only), `int` (internal only), `all` (all zones)
- **owner**: `@` (zone apex), `_dmarc`, `dns_1._domainkey`, etc.
- **rdata**: Record data; `$` expands to zone name

Example:

```ini
spf=ext|@|TXT|v=spf1 ip4:94.130.183.229 ~all
dkim_dns_1=ext|dns_1._domainkey|TXT|v=DKIM1; k=rsa; p=PUBKEY
```

#### `[subnet-name]` (e.g., `[west]`, `[cloud]`)

Subnet-specific member and address definitions.

- `members=HOST` : Hosts in this subnet
- `HOST=IP` : IPv4 address for host in this subnet
- `HOST=IP` (repeated) : IPv6 address for same host

Example:

```ini
[cloud]
members=dns
members=mail
dns=94.130.183.229           # IPv4
dns=2a01:4f8:1c0c:43dd::1    # IPv6 (same key, multiple values)
```

**Important:** `Config::IniFiles` stores multi-valued keys as ARRAY REFERENCES. Generator extracts these using:

```perl
my @values = @{ $network{$subnet}{$key} };
```

---

## Key Algorithms & Patterns

### 1. Multi-Valued Parameter Handling

**Issue:** Config::IniFiles stores duplicate keys as array references.
**Solution:** Check array count; store as array if multiple values, scalar if single.

```perl
my @param_values = @{ $network{$subnet_name}{$param_name} };
$subnet_temp{$param_name} = @param_values > 1 ? [@param_values] : $param_values[0];
```

**Usage:** Both IPv4 and IPv6 addresses stored under same key (e.g., `dns=IP4`, `dns=IP6`).

### 2. IPv6 Detection & Storage

**Detection:** Check for colons in address: `if ($addr =~ /:/) { ... net6 ... }`
**Storage:** Separate keys for IPv4 and IPv6:

- IPv4: `$hosts{$hostname}{net4}{$subnet_name}`
- IPv6: `$hosts{$hostname}{net6}{$subnet_name}`

### 3. RFC 1035 Multi-Chunk TXT Records

**Problem:** DKIM/DMARC/SPF keys exceed 255-char limit for single TXT strings.
**Solution:** Split into chunks, wrap in parentheses (RFC 1035 format):

```zone
record.name.  TXT  ( "chunk1..."
                     "chunk2..." )
```

**Implementation:** Lines 165-190 in generator.pl split rdata into 255-char chunks.

### 4. Zone-Level Record Processing

**Flow:**

1. Parse `[zone_records]` section
2. Filter by scope (ext/int/all) and current zone
3. Substitute `$` with zone name in owner and rdata
4. Add to zone output

**Key Fix:** Must initialize all external zones in `%output` hash (lines 482-490) before processing records.

### 5. Master-Slave Deployment

**Process:**

1. `generator.pl` generates master zones and config
2. Detects slave IP in `@ARGV` (after `--` separator)
3. Calls `deploy-zones.sh` with slave parameters
4. `deploy-zones.sh` deploys to master, triggers NOTIFY
5. **Critical:** Sleeps 120 seconds on slave to allow zone transfer persistence before restart (line 103-105)

---

## Critical Bugs Fixed (Do Not Reintroduce)

### 1. Config::IniFiles Array References (FIXED: Commit 8d9d14c)

**Problem:** Only first IPv6 address stored; others discarded.
**Root Cause:** Line 289 only took `[0]` element of array.
**Fix:** Store all values as array if count > 1 (see Multi-Valued Parameter Handling above).

### 2. Zone Transfer Persistence (FIXED: Commit 5de1f6a)

**Problem:** Zones not persisting after slave transfer; BIND restart would lose them.
**Root Cause:** Config deployed and BIND restarted before zone transfer completed.
**Fix:** Added 120-second delay in deploy-zones.sh (lines 103-105) before slave restart.

### 3. External Zones Not Initialized (FIXED: Commit 792fb39)

**Problem:** Zone-level records not appearing in external zones.
**Root Cause:** External zones not pre-initialized in `%output` hash.
**Fix:** Initialize all external zones before processing zone_records section (lines 482-490).

### 4. RFC 1035 TXT Record Format (FIXED: Commit bf2bc4a)

**Problem:** Long TXT records failed BIND validation (DKIM keys > 255 chars).
**Root Cause:** Records not split into chunks per RFC 1035.
**Fix:** Implemented multi-chunk formatting (lines 165-190).

### 5. DKIM Macro Comment Syntax (FIXED: Commit 5b2c68d)

**Problem:** Exim DKIM macros with inline comments not parsed.
**Root Cause:** Exim does not support inline comments in macro definitions.
**Fix:** Removed comments from `/etc/exim4/conf.d/main/00_khms`.

### 6. Domain-Matched DKIM with Shared Key (FIXED: Commit 38234a6)

**Problem:** Mail from DNS server (khms1.de) signed with khms.eu domain; DMARC misalignment.
**Solution:**

- Publish same public key at both domains (dns_1._domainkey.khms1.de + dns_1._domainkey.khms.eu)
- Slave signs with DKIM_DOMAIN = khms1.de
- Single key file used for both domains

---

## Commit Message Conventions

This project follows **Conventional Commits 1.0.0**.

**Format:** `type(scope): description`

**Types:**

- `feat` - New feature (MINOR in SemVer)
- `fix` - Bug fix (PATCH in SemVer)
- `docs` - Documentation only
- `refactor` - Code restructuring (no functional change)
- `perf` - Performance improvement
- `test` - Test additions/changes
- `chore` - Build, CI, or non-code changes

**Scope Examples:**

- `dkim` - DKIM-related changes
- `dns` - DNS record generation
- `deployment` - Deployment script changes
- `generator` - Core generator.pl changes
- `zone files` - Zone file updates

**Examples:**

```text
feat(dns): add IPv6 AAAA record generation support
fix(dkim): implement multi-domain DKIM signing with shared key
docs(generator): restore complete function documentation
refactor(generator): remove debug output statements
```

**Rule:** Do NOT use `git commit --no-verify` to bypass pre-commit hooks. Fix the hook issue and retry.

---

## Common Development Patterns

### Adding a New Zone Record Type

1. Define the record in `[zone_records]` section of network.ini
2. Add to `records=` list
3. Ensure `scope` (ext/int/all) and owner/rdata are correct
4. Run `generator.pl`
5. Validate with `named-checkzone`

### Modifying Host/Subnet Configuration

1. Edit `[hosts]`, `[subnets]`, or relevant `[subnet-name]` section in network.ini
2. Run `perl generator.pl`
3. Verify zones with `grep "HOSTNAME" *.zone`
4. Deploy: `sudo ./deploy-zones.sh khms-zones.conf *.zone`

### Adding a New Domain

1. Add to `[domains]` section: `extern=newdomain.com`
2. Optionally add zone-level records
3. Run `generator.pl` to create `newdomain.com.zone`
4. Deploy

### Testing Deployments

1. Generate zones: `perl generator.pl`
2. Validate all zones:

   ```bash
   for zone in *.zone; do named-checkzone "${zone%.zone}" "$zone" || exit 1; done
   ```

3. Deploy to master: `sudo ./deploy-zones.sh khms-zones.conf *.zone`
4. Verify with `dig @localhost` queries

### Modifying Exim Configuration

1. Edit the appropriate config file:
   - `exim/master/00_khms` — For master (desktop)
   - `exim/slave/00_khms` — For slave (dns)
   - `exim/mail/00_khms` — For mail server

2. Deploy to affected machines:

   ```bash
   # Deploy to master only
   sudo ./deploy-zones.sh --exim-master exim/master khms-zones.conf *.zone

   # Deploy to master and slave
   sudo ./deploy-zones.sh --exim-master exim/master --exim-slave exim/slave \
     khms-zones.conf *.zone -- 10.18.0.1 khms-zones.conf.tmp

   # Deploy to mail server
   sudo ./deploy-zones.sh --exim-mail exim/mail 195.201.17.234 \
     khms-zones.conf *.zone
   ```

3. Verify Exim restarted: `systemctl status exim4` on each machine
4. Test with test email to verify DKIM signing

---

## Important Notes & Gotchas

### Network Mastery Required

This tool requires understanding:

- CIDR notation and subnet calculation
- DNS record types (A, AAAA, MX, SPF, DMARC, DKIM)
- BIND9 configuration and zone file format
- Master-slave replication and NOTIFY mechanism

### IPv6 Handling

- Both IPv4 and IPv6 stored under same key in network.ini
- Detected by colon presence in address
- Stored separately: `net4` vs `net6` keys in data structure

### RFC 1035 Multi-Chunk Format Dependency

- DKIM/DMARC/SPF records often exceed 255-char TXT limit
- Must use multi-chunk format: `( "chunk1" "chunk2" )`
- Generator handles this automatically; do NOT manually wrap records

### Slave Deployment Critical Delay

- The 120-second delay (line 103-105 in deploy-zones.sh) is NOT optional
- Removing it causes zone transfers to be lost on slave restart
- Historical issue with production impact

### Config::IniFiles Multi-Valued Keys

- Duplicate keys become ARRAY REFERENCES
- Must handle with `@{ $network{section}{key} }`
- See Multi-Valued Parameter Handling section above

### Master vs. Slave Configuration Divergence

- Master (`desktop.dnstunnel.khms`): DKIM_DOMAIN = khms.eu
- Slave (`dns.dnstunnel.khms`): DKIM_DOMAIN = khms1.de
- Both use same private key file but different signing domains
- Intentional for mail routing flexibility during downtime

---

## When Things Go Wrong

### Zones fail `named-checkzone`

- Check RFC 1035 formatting of TXT records (must have parentheses for multi-chunk)
- Verify serial numbers are present
- Check for syntax errors in zone-level records

### Master-slave zone transfer fails

- Ensure NOTIFY is enabled and slave ACL permits transfers
- Check firewall rules (port 53 TCP/UDP)
- Verify SOA and NS records match on both sides

### DKIM signatures not validated

- Confirm selector matches TXT record name (e.g., dns_1)
- Verify public key is at correct DNS location
- Check DKIM_DOMAIN matches signer domain
- Inspect Exim logs for macro expansion errors (no inline comments in macros!)

### SPF/DMARC records missing

- Verify `[zone_records]` section includes the record definition
- Check scope is correct (ext/int/all)
- Confirm owner field is correct (@ for zone apex, or subdomain prefix)

---

## References

- [BIND 9.18 Documentation](https://bind9.readthedocs.io/)
- [RFC 1035 - Domain Implementation and Specification](https://tools.ietf.org/html/rfc1035)
- [RFC 7208 - SPF](https://tools.ietf.org/html/rfc7208)
- [RFC 7489 - DMARC](https://tools.ietf.org/html/rfc7489)
- [RFC 6376 - DKIM](https://tools.ietf.org/html/rfc6376)
- [Conventional Commits 1.0.0](https://www.conventionalcommits.org/)
- Local documentation: [README.md](README.md), [README-deployment.md](README-deployment.md)
