#!/bin/bash

# ==============================================================================
# Dell Automation Platform (DAP) Installation Script
#
# This script automates the installation of DAP on a Linux system.
#
# It performs the following steps:
# 1. Installs Dell Automation Platform
#
# IMPORTANT: This script requires root privileges.

# ALSO IMPORTANT: add execute permissions with: sudo chmod +x dap_install.sh

# sudo ./03_dap_install.sh -Q <quay_user> -q <quay_password>

# ==============================================================================

# Exit immediately if a command exits with a non-zero status.
set -e

# Ensure we're running as root or with sudo
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo."
  exit
fi

# ================================
# User configurable variables
# ================================

API_HOST="dap.lab.local"
QUAY_SERVER="quay.lab.local"
DAPO_HOST="orchestrator.dap.lab.local"
PORTAL_HOST="portal.dap.lab.local"
ORG_NAME="Bahay"
ORG_DESC="Home Lab"
FIRST_NAME="Theo"
LAST_NAME="C"
DAPO_USERNAME="administrator"
DAPO_EMAIL="administrator@lab.local"

# ================================
# Parse registry credentials
# ================================
# pass them as flags to the script: -Q <user> -q <password>
# or set them as environment variables: QUAY_USER and QUAY_PASSWORD

while getopts "Q:q:" opt; do
  case $opt in
    Q) PARSE_QUAY_USER="$OPTARG";;
    q) PARSE_QUAY_PASSWORD="$OPTARG";;
    \?) echo "Invalid option: -$OPTARG"; exit 1;;
  esac
done

# Prefer environment variables if set, otherwise use parsed flags
QUAY_USER="${QUAY_USER:-$PARSE_QUAY_USER}"
QUAY_PASSWORD="${QUAY_PASSWORD:-$PARSE_QUAY_PASSWORD}"

if [ -z "$QUAY_USER" ] || [ -z "$QUAY_PASSWORD" ]; then
  echo "ERROR: Quay registry credentials are required."
  echo "Set QUAY_USER and QUAY_PASSWORD environment variables or pass -Q <user> -q <password> to the script."
  exit 1
fi


# ================================
# Helper functions for logging with timestamps and elapsed time
# ================================
# Helper: print elapsed time since script start in human-friendly form
elapsed_since() {
  # elapsed since given timestamp (seconds)
  local since_ts=$1
  local now=$(date +%s)
  local diff=$((now - since_ts))
  local hours=$((diff / 3600))
  local mins=$(((diff % 3600) / 60))
  local secs=$((diff % 60))
  printf "%02dh:%02dm:%02ds" "$hours" "$mins" "$secs"
}

# Helper: log section start with timestamp and elapsed time since previous section
log_section_start() {
  local section_title="$1"
  local now_human=$(timestamp)
  local elapsed_since_prev=$(elapsed_since "$SECTION_START_TS")
  echo ""
  echo " # =============================================== "
  echo "\n--> [${now_human}] Starting: ${section_title} (since previous: ${elapsed_since_prev})\n"
  echo " # =============================================== "
   # update SECTION_START_TS to now for the next section
  SECTION_START_TS=$(date +%s)
}

# Helper: print a timestamp
timestamp() {
  date --iso-8601=seconds
}

# Record script start time for elapsed calculations
SCRIPT_START_TS=$(date +%s)
SCRIPT_START_TIME_HUMAN=$(date --iso-8601=seconds)
echo "Script started at: ${SCRIPT_START_TIME_HUMAN}"

# Track last section start time so we can report elapsed time between sections
SECTION_START_TS=${SCRIPT_START_TS}


# ==============================================
# 1. Install Dell Automation Platform
# ==============================================
log_section_start "Installing Dell Automation Platform"
echo "--> Starting Dell Automation Platform installation..."

sudo ./install-upgrade.sh EO_HOST="$DAPO_HOST" \
IMAGE_REG_URL="$QUAY_SERVER" IMAGE_REG_USERNAME="$QUAY_USER" \
IMAGE_REG_PASSWORD="$QUAY_PASSWORD" REGISTRY_CERT_FILE_PATH="./$QUAY_SERVER.crt" \
NAMESPACE="dapo" PORTAL_NAMESPACE="dapp" PORTAL_COOKIE_DOMAIN="$API_HOST" \
PORTAL_INGRESS_CLASS_NAME="haproxy" PORTAL_HOST="$PORTAL_HOST" \
ORG_NAME="$ORG_NAME" ORG_DESC="$ORG_DESC" FIRST_NAME="$FIRST_NAME" LAST_NAME="$LAST_NAME" \
USERNAME="$DAPO_USERNAME" EMAIL="$DAPO_EMAIL"