#!/bin/bash

# ==============================================================================
# Dell Automation Platform (DAP) Installation Script
#
# This script automates the installation of DAP on a Linux system.
#
# It performs the following steps:
# 1. Installs Longhorn block storage provider
# 2. Installs HAProxy as the ingress controller
# 3. Installs Metric Server for resource monitoring
# 4. Prepares DAP installation files
#
# IMPORTANT: This script requires root privileges.

# ALSO IMPORTANT: add execute permissions with: sudo chmod +x dap_install.sh

# sudo ./02_dap_prepare.sh -Q <quay_user> -q <quay_password>

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
DAP_INSTALL_FILENAME="DellAutomationPlatform_v1.1.0.0.zip"
DAP_BUNDLE_FILENAME="DellAutomationPlatform_v1.1.0.0-3e66966.zip"
DAP_SIGNED_FILENAME="DellAutomationPlatform_v1.1.0.0-3e66966.zip.signed.bin"

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
# 1. Install Longhorn block storage provider
# ==============================================

log_section_start "Installing Longhorn block storage provider"
echo "--> Check if Longhorn is already installed..."
if kubectl get ns longhorn-system &> /dev/null; then
    echo "--> ✅ Success: Longhorn is already installed. Skipping installation."
else
    echo "--> ❌ Error: Longhorn not found. Proceeding with installation..."
    echo "--> Adding Longhorn Helm repository..."
    helm repo add longhorn https://charts.longhorn.io
    helm repo update
    echo "--> Applying Longhorn manifests..."
    helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace --set persistence.defaultClassReplicaCount=1 --set defaultSettings.defaultReplicaCount=1 --version 1.9.1
    echo "--> Longhorn installation initiated. It may take a few minutes for all components to be up and running."
    echo "--> Waiting for all system pods in longhorn-system namespace to be Ready..."

    START_TIME=$(date +%s)

    # Loop until all pods in longhorn-system are Running or Completed
    until kubectl get pods -n longhorn-system --no-headers | awk '{if ($3 != "Running" && $3 != "Completed") exit 1}' ; do
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - START_TIME))
        MINUTES=$((ELAPSED / 60))
        SECONDS=$((ELAPSED % 60))
        echo "Still waiting... elapsed time: ${MINUTES}m ${SECONDS}s"
        sleep 10
    done

    echo "--> All longhorn pods are Ready after ${MINUTES}m ${SECONDS}s...."
fi

# Create a NodePort service for Longhorn UI
echo "--> Creating Longhorn NodePort Service for UI access..."
if kubectl get svc longhorn-nodeport-svc -n longhorn-system &> /dev/null; then
    echo "--> ✅ Success: Longhorn NodePort Service already exists. Skipping creation."
    echo "--> Longhorn NodePort Service already exists. Access the Longhorn UI at http://$API_HOST:31000"
else
    echo "--> ❌ Error: Longhorn NodePort Service not found. Proceeding with creation..."
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: longhorn-nodeport-svc
  namespace: longhorn-system
spec:
  type: NodePort
  ports:
    - name: http
      nodePort: 31000
      port: 80
      protocol: TCP
      targetPort: http
  selector:
    app: longhorn-ui
  sessionAffinity: None
EOF
    echo "--> Longhorn NodePort Service created. Access the Longhorn UI at http://$API_HOST:31000"
fi
# Verify the Longhorn NodePort service creation
if kubectl get svc longhorn-nodeport-svc -n longhorn-system &> /dev/null; then
    echo "--> ✅ Success: Longhorn NodePort Service is up and running."
else
    echo "--> ❌ Error: Failed to create Longhorn NodePort Service."
fi

# ==============================================
# 2. Install HAProxy Helm repository
# ==============================================

log_section_start "Installing HAProxy"
echo "--> Adding HAProxy Helm repository..."

if kubectl get ns haproxy &> /dev/null; then
    echo "--> ✅ Success: HAProxy namespace already exists. Skipping installation."
else
    echo "--> ❌ Error: HAProxy namespace not found. Proceeding with installation..."
    helm repo add haproxytech https://haproxytech.github.io/helm-charts
    helm repo update

    cat <<EOF > haproxy-values.yaml
controller:
    image:
        repository: haproxytech/kubernetes-ingress
        pullPolicy: Always
    imagePullSecrets:
        - name: docker-secret
    service:
        type: LoadBalancer
        externalTrafficPolicy: Local
    config:
        ssl-passthrough: "true"
    hostNetwork: true
    kind: DaemonSet
    defaultTLSSecret:
        enabled: false
EOF
    echo "--> Applying HAProxy manifests..."
    helm install haproxy haproxytech/kubernetes-ingress --namespace haproxy --create-namespace -f haproxy-values.yaml
fi
echo "--> HAProxy installation initiated."
echo "--> Waiting for all system pods in haproxy namespace to be Ready..."
START_TIME=$(date +%s)
# Loop until all pods in haproxy are Running or Completed
until kubectl get pods -n haproxy --no-headers | awk '{if ($3 != "Running" && $3 != "Completed") exit 1}' ; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    MINUTES=$((ELAPSED / 60))
    SECONDS=$((ELAPSED % 60))
    echo "Still waiting... elapsed time: ${MINUTES}m ${SECONDS}s"
    sleep 10
done
echo "--> All haproxy pods are Ready after ${MINUTES}m ${SECONDS}s...."
echo "--> HAProxy installation completed successfully."

# ==============================================
# 3. Install Metric Server
# ==============================================
log_section_start "Installing Metric Server"
echo "--> Checking if Metrics Server is already installed..."
if kubectl get deployment metrics-server -n kube-system &> /dev/null; then
    echo "--> ✅ Success: Metrics Server is already installed. Skipping installation."
else
    echo "--> ❌ Error: Metrics Server not found. Proceeding with installation..."
    echo "--> Applying Metrics Server manifests..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    echo "--> Metrics Server installation initiated. It may take a few minutes for all components to be up and running."
    echo "--> Waiting for all system pods in kube-system namespace to be Ready..."
    START_TIME=$(date +%s)
    # Loop until all pods in kube-system related to metrics-server are Running or Completed
    until kubectl get pods -n kube-system --no-headers | grep metrics-server | awk '{if ($3 != "Running" && $3 != "Completed") exit 1}' ; do
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - START_TIME))
        MINUTES=$((ELAPSED / 60))
        SECONDS=$((ELAPSED % 60))
        echo "Still waiting... elapsed time: ${MINUTES}m ${SECONDS}s"
        sleep 10
    done
    echo "--> All metrics-server pods are Ready after ${MINUTES}m ${SECONDS}s...."
fi

kubectl get deployment metrics-server -n kube-system -o yaml | \
sed '/args:/ a \        - --kubelet-insecure-tls' | \
kubectl apply -f -

echo "--> Verifying Metrics Server installation by fetching node and pod metrics..."
kubectl top nodes
kubectl top pods

# ==============================================
# 4. Prepare Dell Automation Platform files for installation
# ==============================================

log_section_start "Preparing Dell Automation Platform files for installation"
echo "--> Checking for DAP installation files..."
if [ -f ./install-upgrade.sh ]; then
    echo "--> ✅ Success: Found DAP installation script. Ready for install..."
else
    echo "--> ❌ Error: DAP installation script not found at ./install-upgrade.sh. Proceeding with unpacking..."
    echo "--> Unpacking Dell Automation Platform bundle file..."
    if [ -f ./$DAP_INSTALL_FILENAME ]; then
        echo "--> ✅ Success: Found DAP bundle file."
        if [ -f ./$DAP_BUNDLE_FILENAME ]; then
            echo "--> ✅ Success: File ./$DAP_BUNDLE_FILENAME found."
        else
            echo "--> ❌ Error: DAP installation zip file not found at ./$DAP_BUNDLE_FILENAME. Proceeding with unpacking bundle..."
            unzip ${DAP_INSTALL_FILENAME}
            echo "--> DAP installation bundle unpacked successfully."
        fi
    else
        echo "--> ❌ Error: DAP installation files not found at ./$DAP_INSTALL_FILENAME. Please ensure the file is present."
        exit 1
    fi

    if [ -f ./install-upgrade.sh ]; then
        echo "--> ✅ Success: Found DAP installation script. Ready for install..."
    else
        echo "--> ❌ Error: Unpacked DAP installation script not found at ./install-upgrade.sh. Proceeding with unpacking..."
        echo "--> Verifying digital signature of the DAP installation package..."
        openssl dgst -sha384 -verify dell_public.key -signature $DAP_SIGNED_FILENAME $DAP_BUNDLE_FILENAME
        echo "--> Unpacking DAP installation script..."
        unzip ${DAP_BUNDLE_FILENAME}
        echo "--> Setting execute permissions on installation script..."
        chmod +x ./install-upgrade.sh
        echo "--> Dell Automation Platform installation script unpacked successfully."
    fi
fi


# ==================================================================
# 5. Preparing for Dell Automation Platform installation
# ==================================================================
log_section_start "Preparing for Dell Automation Platform installation"
echo "--> Starting Dell Automation Platform preparation..."

echo "--> Checking for registry certificate file..."
if [ -f ./$QUAY_SERVER.crt ]; then
    echo "--> ✅ Success: Found certificate file ./$QUAY_SERVER.crt."
else
    echo "--> ❌ Error: Certificate file not found at ./$QUAY_SERVER.crt. Getting cert file from $QUAY_SERVER."
    echo | openssl s_client -showcerts -servername $QUAY_SERVER -connect $QUAY_SERVER:443 2>/dev/null | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > ./$QUAY_SERVER.crt
fi

if [ -f /etc/docker/certs.d/$QUAY_SERVER/ca.crt ]; then
    echo "--> ✅ Success: Found certificate file /etc/docker/certs.d/$QUAY_SERVER/ca.crt."
else
    echo "--> ❌ Error: Certificate file not found at /etc/docker/certs.d/$QUAY_SERVER/ca.crt. Copying certificate...."
    # Create the directory structure for your specific registry
    mkdir -p /etc/docker/certs.d/$QUAY_SERVER
    # Copy the certificate to the trusted locations
    echo "--> Copying certificate to trusted locations..."
    cp ./$QUAY_SERVER.crt /etc/docker/certs.d/$QUAY_SERVER/ca.crt
    cp ./$QUAY_SERVER.crt /usr/local/share/ca-certificates/
    # Integrate the new certificate into the system trust store
    echo "--> Updating CA certificates..."
    update-ca-certificates
    cat <<EOF > /etc/docker/daemon.json 
{
  "insecure-registries" : ["https://$QUAY_SERVER:443"]
}
EOF
    echo "--> Restarting Docker to apply changes..."
    systemctl restart docker
fi

echo "Logging in to Quay registry as $QUAY_USER..."
docker login https://$QUAY_SERVER:443 --username "$QUAY_USER" --password "$QUAY_PASSWORD"

echo "--> If all steps completed successfully, you are now ready for DAP installation ..."
echo "--> If any step failed, re-run the script to ensure all steps completed successfully."
echo "--> Proceed to step 3 and run the 03_dap_install.sh script to install Dell Automation Platform."