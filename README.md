# BIND DNS Zone Generator

A comprehensive Perl-based DNS zone file and BIND configuration generator for managing multiple DNS zones with automatic record generation from a centralized configuration.

## Features

- **Centralized Configuration**: Single `network.ini` file drives all zone and record generation
- **Multi-Zone Support**: Generate zone files for multiple domains and reverse zones
- **Automatic Record Generation**: A, AAAA, PTR, CNAME, MX, TXT, SOA, NS records
- **Zone-Level Records**: SPF, DMARC, DKIM records for mail infrastructure
- **Privilege Separation**: Generator runs unprivileged; deployment requires sudo
- **Master/Slave Support**: Optional automatic deployment to slave DNS servers
- **BIND9 Integration**: Generates complete BIND9 configuration with ACLs and views

## Quick Start

### 1. Configure Your Network

Edit `network.ini` to define:

- Host definitions (e.g., `north=1`, `desktop=2`)
- Subnet CIDR ranges (e.g., `west=87`, `east=88`)
- Domain mappings (internal and external domains)
- Zone-level records (SPF, DMARC, DKIM)

Example structure:

```ini
[hosts]
north=1
desktop=2
laptop=44

[subnets]
west=87
east=88

[domains]
extern=khms1.de khms.eu fast-rail-transport-international.com
intern=khms

[zone_records]
spf=ext|@|TXT|v=spf1 ip4:94.130.183.229 ~all
dmarc=ext|_dmarc|TXT|v=DMARC1; p=none; rua=mailto:admin@example.com
```

### 2. Generate Zone Files

```bash
./generator.pl
```

This creates:

- Zone files (`.zone` extension)
- BIND9 master configuration (`khms-zones.conf`)
- Optional slave configuration

### 3. Deploy to BIND9

```bash
sudo ./deploy-zones.sh khms-zones.conf *.zone
```

For production setups with slave servers:

```bash
sudo ./deploy-zones.sh khms-zones.conf *.zone -- 10.18.0.1 khms-zones.conf.tmp
```

See [Deployment Guide](README-deployment.md) for detailed instructions.

## Project Structure

```
/etc/bind/generator/
├── generator.pl                # Main DNS generator (Perl)
├── deploy-zones.sh             # Deployment script (Bash, requires sudo)
├── network.ini                 # Network configuration
├── khms-zones.conf             # Generated master BIND config
├── *.zone                      # Generated zone files
├── attrs/                      # Network attributes directory
├── bak/                        # Backup copies of generator.pl
├── README.md                   # This file
└── README-deployment.md        # Deployment guide
```

## Configuration

### network.ini Sections

| Section | Purpose |
|---------|---------|
| `[hosts]` | Define host numbers (numeric identifiers) |
| `[subnets]` | Define subnets with CIDR ranges |
| `[domains]` | Configure external/internal domains |
| `[networks]` | Network-wide settings (IPv4, admin email, nameservers) |
| `[more]` | Per-host record templates (MX, SOA, etc.) |
| `[zone_records]` | Zone-level records (SPF, DMARC, DKIM) |

### Zone Record Format

Zone-level records use the format:

```
key=scope|owner|type|rdata
```

Where:

- **scope**: `ext` (external), `int` (internal), or `all` (both)
- **owner**: Record owner (@ for zone apex, or subdomain)
- **type**: DNS record type (TXT, MX, CNAME, etc.)
- **rdata**: Full record data (with special $ expansion for templates)

Example:

```ini
spf=ext|@|TXT|v=spf1 ip4:94.130.183.229 ~all
dkim_2024=ext|2024._domainkey|TXT|v=DKIM1; k=rsa; p=MIIBIj...
```

## Zone Files Generated

### Forward Zones

- `khms1.de.zone` - Primary external domain
- `khms.eu.zone` - Secondary external domain
- `fast-rail-transport-international.com.zone` - Additional external domain
- `khms.zone` - Internal domain

### Reverse Zones

- `10.in-addr.arpa.zone` - Reverse for 10.0.0.0/8
- `168.192.in-addr.arpa.zone` - Reverse for 192.168.0.0/16

## Dependencies

- **Perl 5.26+** with modules:
  - `Config::IniFiles` - INI configuration parsing
  - `Net::DNS` - DNS record generation
  - `NetAddr::IP` - IPv4/IPv6 address utilities
  - `IO::Tee` - Output multiplexing

- **BIND9** - DNS server (for deployment)
- **Bash** - Deployment script shell

## Security

- **Unprivileged Generation**: `generator.pl` runs as regular user
- **Privilege Escalation**: `deploy-zones.sh` requires `sudo` for system operations
- **Separation of Concerns**: Generation logic separate from deployment logic
- **No Hardcoded Credentials**: Uses key rotation (multiple DKIM selectors)

## Deployment Architecture

```
┌─────────────────────────────┐
│  Unprivileged User          │
│  ┌─────────────────────────┐│
│  │ ./generator.pl          ││
│  │ Generates zone files    ││
│  └────────────┬────────────┘│
│               │             │
└───────────────┼─────────────┘
                │
                ▼
    ┌───────────────────────┐
    │  sudo ./deploy-zones.sh│
    │  Master & Slave Deploy │
    │  • Copy files          │
    │  • Restart BIND9       │
    │  • SSH to slave        │
    └───────────────────────┘
```

## Troubleshooting

### Syntax Validation

```bash
perl -c generator.pl
perlcritic --gentle generator.pl
bash -n deploy-zones.sh
```

### BIND9 Validation

```bash
named-checkconf khms-zones.conf
named-checkzone khms1.de khms1.de.zone
```

### DNS Query Testing

```bash
# Test locally
nslookup example.khms1.de localhost

# Test from remote
dig @ns.khms1.de example.khms1.de
```

## Git History

Key refactorings tracked in git:

- **d7d70e8**: Refactored to main() function structure
- **d2dc47f**: Separated privileged operations to deploy-zones.sh
- Earlier commits: Bug fixes for zone record parsing, serial generation, $origin substitution

## License & Attribution

Part of KHMS (Kai's Home Management System)

## Support & Contributing

For issues or improvements:

1. Check existing network.ini configuration
2. Validate syntax with `perl -c` and `bash -n`
3. Review generated zone files for correctness
4. Consult [Deployment Guide](README-deployment.md) for deployment issues
