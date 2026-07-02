# BIND Zone Generator - Deployment Guide

## Overview

The DNS zone generator is now split into two phases to properly handle privilege escalation:

1. **generator.pl** - Generates zone files and configuration (runs as unprivileged user)
2. **deploy-zones.sh** - Deploys files and restarts services (runs as root via sudo)

## Usage

### Step 1: Generate Zone Files

Run the generator to create zone files and configuration:

```bash
./generator.pl
```

This generates:

- Zone files (e.g., `khms1.de.zone`, `10.in-addr.arpa.zone`)
- Configuration files (e.g., `khms-zones.conf`)
- Console output showing generated files

### Step 2: Deploy Files

Deploy the generated files using the deployment script:

```bash
sudo ./deploy-zones.sh khms-zones.conf 10.in-addr.arpa.zone 168.192.in-addr.arpa.zone khms1.de.zone fast-rail-transport-international.com.zone khms.zone khms.eu.zone
```

The deployment script will:

1. Copy zone files to `/etc/bind/`
2. Restart BIND9 service
3. Verify service status

### Step 3 (Optional): Deploy to Slave Server

To also deploy to a slave DNS server, use the `--` separator:

```bash
sudo ./deploy-zones.sh khms-zones.conf *.zone -- <slave_ip> <slave_config>
```

Example:

```bash
sudo ./deploy-zones.sh khms-zones.conf *.zone -- 10.18.0.1 khms-zones.conf.tmp
```

The deployment script will:

1. Copy files to master's `/etc/bind/`
2. Restart BIND9 on master
3. Copy config to slave via scp
4. Compare and update slave configuration
5. Restart BIND9 on slave
6. Verify slave service status

## Security Notes

- `generator.pl` can be run by any user without special privileges
- `deploy-zones.sh` requires sudo and should only be run after reviewing generated files
- This separation follows the principle of least privilege
- All file operations preserve security context

## Automatic Deployment Option

If `deploy-zones.sh` is in the current directory and executable, `generator.pl` can attempt automatic deployment:

```bash
./generator.pl
# Script will prompt for sudo password and attempt deployment
```

## Manual File Review

Before deployment, you can:

1. Review generated zone files:

   ```bash
   cat khms1.de.zone
   ```

2. Review configuration:

   ```bash
   cat khms-zones.conf
   ```

3. Manually copy files if preferred:

   ```bash
   sudo cp khms-zones.conf *.zone /etc/bind/
   sudo systemctl restart bind9
   ```

## Troubleshooting

### Permission Denied

If you get "Permission denied" errors when running `deploy-zones.sh`:

- Ensure you're using `sudo`
- Verify the script is executable: `ls -l deploy-zones.sh`
- Check that your user is in the sudoers group

### SSH to Slave Fails

If deploying to a slave server fails:

- Verify SSH key setup for root access
- Ensure root@<slave_ip> is reachable and allows SSH
- Check network connectivity: `ssh root@<slave_ip> echo ok`

### BIND9 Restart Fails

- Verify BIND9 syntax: `named-checkconf`
- Check for port conflicts: `netstat -tlnp | grep :53`
- Review logs: `journalctl -u bind9 -n 20`
