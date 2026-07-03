#!/bin/bash

# deploy-zones.sh - Deploy generated zone files, BIND configuration, and Exim configs
# This script requires sudo privileges to copy files and restart services
#
# Usage: sudo ./deploy-zones.sh [options] <config_file> <zone_file1> [zone_file2 ...] [-- <slave_ip> <slave_config>]
#
# Master deployment:
#   sudo ./deploy-zones.sh khms-zones.conf 10.in-addr.arpa.zone 168.192.in-addr.arpa.zone ...
#
# Master + Slave deployment:
#   sudo ./deploy-zones.sh khms-zones.conf 10.in-addr.arpa.zone ... -- 10.18.0.1 khms-zones.conf.tmp
#
# With Exim config deployment to dns server:
#   sudo ./deploy-zones.sh --exim-dns exim/dns khms-zones.conf *.zone -- 10.18.0.1 khms-zones.conf.tmp
#
# With Exim configs to multiple machines:
#   sudo ./deploy-zones.sh --exim-desktop exim/desktop --exim-dns exim/dns --exim-mail exim/mail \
#     khms-zones.conf *.zone -- 10.18.0.1 khms-zones.conf.tmp

set -e

# Exim configuration directories (optional)
EXIM_DESKTOP_DIR=""
EXIM_DNS_DIR=""
EXIM_MAIL_DIR=""
EXIM_MAIL_IP=""

# Parse arguments
if [[ $# -lt 1 ]]; then
	echo "Usage: $0 [--exim-desktop DIR] [--exim-dns DIR] [--exim-mail DIR IP] <config_file> <zone_file1> [zone_file2 ...] [-- <slave_ip> <slave_config>]" >&2
	exit 1
fi

# Parse optional flags before zone files
while [[ $# -gt 0 ]] && [[ $1 == --* ]]; do
	case "$1" in
	--exim-desktop)
		shift
		EXIM_DESKTOP_DIR="$1"
		shift
		;;
	--exim-dns)
		shift
		EXIM_DNS_DIR="$1"
		shift
		;;
	--exim-mail)
		shift
		EXIM_MAIL_DIR="$1"
		shift
		EXIM_MAIL_IP="$1"
		shift
		;;
	*)
		# Unknown flag, break and process as file arguments
		break
		;;
	esac
done

# Get the current working directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(dirname "${SCRIPT_DIR}")"

# Change to working directory
cd "${SCRIPT_DIR}"

# Separate master files from optional slave files
MASTER_FILES=()
SLAVE_IP=""
SLAVE_CONFIG=""

# Process arguments until we find "--" separator
for arg in "$@"; do
	if [[ ${arg} == "--" ]]; then
		shift
		if [[ $# -lt 2 ]]; then
			echo "Error: Slave deployment requires IP address and config file" >&2
			exit 1
		fi
		SLAVE_IP="$1"
		SLAVE_CONFIG="$2"
		break
	else
		MASTER_FILES+=("${arg}")
		shift
	fi
done

echo "========================================="
echo "Deploying BIND configuration and zones..."
echo "========================================="

# Validate master files exist
echo "Validating master files..."
for file in "${MASTER_FILES[@]}"; do
	if [[ ! -f ${file} ]]; then
		echo "Error: File not found: ${file}" >&2
		exit 1
	fi
done

# Copy all master files to parent directory
echo "Copying master files to ${PARENT_DIR}..."
for file in "${MASTER_FILES[@]}"; do
	echo "  Copying: ${file}"
	cp -av "${file}" "${PARENT_DIR}/"
done

# Restart BIND9 on master
echo ""
echo "Restarting BIND9 on master..."
systemctl restart bind9
systemctl status bind9

# Deploy Exim configurations if specified
if [[ -n ${EXIM_DESKTOP_DIR} ]]; then
	echo ""
	echo "========================================="
	echo "Deploying Exim config to desktop (master DNS)..."
	echo "========================================="

	if [[ ! -f "${EXIM_DESKTOP_DIR}/00_khms" ]]; then
		echo "Error: Exim desktop config not found: ${EXIM_DESKTOP_DIR}/00_khms" >&2
		exit 1
	fi

	echo "Copying Exim config to /etc/exim4/conf.d/main/ on desktop..."
	cp -av "${EXIM_DESKTOP_DIR}/00_khms" /etc/exim4/conf.d/main/00_khms
	echo "Restarting Exim4 on desktop..."
	systemctl restart exim4
	systemctl status exim4
fi

# Optional: Deploy to slave server
if [[ -n ${SLAVE_IP} && -n ${SLAVE_CONFIG} ]]; then
	echo ""
	echo "========================================="
	echo "Deploying to slave server: ${SLAVE_IP}"
	echo "========================================="

	if [[ ! -f ${SLAVE_CONFIG} ]]; then
		echo "Error: Slave config file not found: ${SLAVE_CONFIG}" >&2
		exit 1
	fi

	echo "Copying slave config to ${SLAVE_IP}:/etc/bind/"
	scp -p "${SLAVE_CONFIG}" "root@${SLAVE_IP}:/etc/bind/"

	echo "Comparing and updating slave configuration..."
	MASTER_BASENAME=$(basename "${MASTER_FILES[0]}")
	SLAVE_BASENAME=$(basename "${SLAVE_CONFIG}")

	# Compare and update config on slave if different
	# shellcheck disable=SC2029
	ssh "root@${SLAVE_IP}" \
		"cmp -s /etc/bind/${SLAVE_BASENAME} /etc/bind/${MASTER_BASENAME} || \
         mv -v --backup=numbered /etc/bind/${SLAVE_BASENAME} /etc/bind/${MASTER_BASENAME}"

	echo "Waiting for zone transfers to persist to disk (120 seconds)..."
	echo "  This allows BIND to download and save transferred zones before restart"
	sleep 120

	echo "Restarting BIND9 on slave..."
	ssh "root@${SLAVE_IP}" systemctl restart bind9
	ssh "root@${SLAVE_IP}" systemctl status bind9

	# Deploy Exim config to dns server if specified
	if [[ -n ${EXIM_DNS_DIR} ]]; then
		echo ""
		echo "Deploying Exim config to dns server at ${SLAVE_IP}..."

		if [[ ! -f "${EXIM_DNS_DIR}/00_khms" ]]; then
			echo "Error: Exim dns config not found: ${EXIM_DNS_DIR}/00_khms" >&2
			exit 1
		fi

		echo "Copying Exim config to ${SLAVE_IP}:/etc/exim4/conf.d/main/"
		scp -p "${EXIM_DNS_DIR}/00_khms" "root@${SLAVE_IP}:/etc/exim4/conf.d/main/00_khms"
		echo "Restarting Exim4 on dns server..."
		ssh "root@${SLAVE_IP}" systemctl restart exim4
		ssh "root@${SLAVE_IP}" systemctl status exim4
	fi
fi

# Deploy Exim config to mail server if specified
if [[ -n ${EXIM_MAIL_DIR} && -n ${EXIM_MAIL_IP} ]]; then
	echo ""
	echo "========================================="
	echo "Deploying Exim config to mail server: ${EXIM_MAIL_IP}"
	echo "========================================="

	if [[ ! -f "${EXIM_MAIL_DIR}/00_khms" ]]; then
		echo "Error: Exim mail config not found: ${EXIM_MAIL_DIR}/00_khms" >&2
		exit 1
	fi

	echo "Copying Exim config to ${EXIM_MAIL_IP}:/etc/exim4/conf.d/main/"
	scp -p "${EXIM_MAIL_DIR}/00_khms" "root@${EXIM_MAIL_IP}:/etc/exim4/conf.d/main/00_khms"
	echo "Restarting Exim4 on mail server..."
	ssh "root@${EXIM_MAIL_IP}" systemctl restart exim4
	ssh "root@${EXIM_MAIL_IP}" systemctl status exim4
fi

echo ""
echo "========================================="
echo "Deployment complete!"
echo "========================================="
