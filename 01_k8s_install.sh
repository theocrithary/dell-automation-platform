#!/bin/bash

# ==============================================================================
# Single-Node Kubernetes Cluster Installation Script
#
# This script automates the full setup of a single-node Kubernetes cluster
# on an Ubuntu 24.04 server using kubeadm.
#
# Requirement For docker - create a personal access token (PAT) on Docker Hub and provide
# it along with your Docker Hub username to avoid unauthenticated pull rate limits.
# https://app.docker.com/
#
# It performs the following steps:
# 1. Set up Docker credentials.
# 2. Prepares the host by disabling swap and configuring kernel modules.
# 3. Installs and configures the containerd runtime.
# 4. Installs kubeadm, kubelet, and kubectl from the official Kubernetes repository.
# 5. Install Helm CLI.
# 6. Initializes the single-node control plane.
# 7. Configures kubectl for the current user.
# 8. Untaints the master node so it can run pods.
# 9. Deploys a Pod Network Add-on (Calico).
# 10. Install Docker client tools.
# 11. Install MetalLB Load Balancer.
#
# IMPORTANT: This script requires root privileges.

# ALSO IMPORTANT: add execute permissions with: sudo chmod +x install-k8s.sh

#  How to use the modified script with the docker login
# export DOCKER_USER=your_dockerhub_username
# export DOCKER_TOKEN=your_personal_access_token
# sudo ./k8s_install.sh

# Or pass flags
# sudo ./k8s_install.sh -U your_dockerhub_username -T your_personal_access_token


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

KUBE_VERSION="1.32" # This is used for the kubeadm/kubelet/kubectl apt repo version
KUBE_VERSION_LONG="1.32.8" # Full Kubernetes version to install during kubeadm init
CNI_VERSION="v1.5.1" # CNI plugins version
API_HOST="dap.lab.local"
DNS_SERVERS="192.168.0.53 8.8.8.8"

# Load balancer pool, for a single node k8s, you can use the host's IP with /32 mask
METALLB_IP="192.168.0.25/32"


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

# ================================
# 1. Setup Docker credentials
# ================================
log_section_start "1. Setup Docker credentials"
echo "--> Configuring Docker credentials for authenticated image pulls..."

# ================================
# Parse Docker Hub credentials (required to avoid unauthenticated pull rate limits)
# You can provide DOCKER_USER and DOCKER_TOKEN as environment variables or
# pass them as flags to the script: -U <user> -T <token>
while getopts ":U:T:" opt; do
  case $opt in
    U) PARSE_DOCKER_USER="$OPTARG";;
    T) PARSE_DOCKER_TOKEN="$OPTARG";;
    \?) echo "Invalid option: -$OPTARG"; exit 1;;
  esac
done

# Prefer environment variables if set, otherwise use parsed flags
DOCKER_USER="${DOCKER_USER:-$PARSE_DOCKER_USER}"
DOCKER_TOKEN="${DOCKER_TOKEN:-$PARSE_DOCKER_TOKEN}"

if [ -z "$DOCKER_USER" ] || [ -z "$DOCKER_TOKEN" ]; then
  echo "ERROR: Docker Hub credentials are required to avoid rate limits."
  echo "Set DOCKER_USER and DOCKER_TOKEN environment variables or pass -U <user> -T <token> to the script."
  exit 1
fi

# Ensure root docker config contains auth so containerd can use authenticated pulls
if [ -d /root/.docker ]; then
    echo "✅ Success: Directory /root/.docker already exists."
else
    echo "❌ Warning: Directory /root/.docker does not exist."
    echo "--> Creating /root/.docker directory..."
    mkdir -p /root/.docker
fi
# Create Docker config.json with base64-encoded auth
if command -v base64 >/dev/null 2>&1; then
  # base64 options differ across platforms; prefer -w0 when available
  if base64 --help 2>&1 | grep -q -- -w; then
    AUTH_B64=$(printf "%s:%s" "$DOCKER_USER" "$DOCKER_TOKEN" | base64 -w0)
  else
    AUTH_B64=$(printf "%s:%s" "$DOCKER_USER" "$DOCKER_TOKEN" | base64)
  fi
else
  AUTH_B64=""
fi
cat > /root/.docker/config.json <<EOF
{
  "auths": {
    "https://index.docker.io/v1/": {
      "auth": "${AUTH_B64}"
    },
    "https://registry-1.docker.io/": {
      "auth": "${AUTH_B64}"
    }
  }
}
EOF
chmod 600 /root/.docker/config.json
chown root:root /root/.docker/config.json

# Restart containerd so it can pick up any auth config (no-op if not running yet)
if systemctl list-units --type=service --state=active | grep -q containerd; then
  systemctl restart containerd || true
fi

# ================================
# 2. Pre-requisites and Host Prep
# ================================
log_section_start "2. Pre-requisites and Host Prep"
echo "--> Preparing the host system..."

# Check if packages are installed
if dpkg-query -W -f='${Status}' "apt-transport-https" 2>/dev/null | grep -q "install ok installed"; then
  echo "✅ Already installed: apt-transport-https"
else
  echo "❌ Missing:   apt-transport-https"
  echo "--> Installing required package..."
  apt-get update
  apt-get install apt-transport-https -y
fi
if dpkg-query -W -f='${Status}' "jq" 2>/dev/null | grep -q "install ok installed"; then
  echo "✅ Already installed: jq"
else
  echo "❌ Missing:   jq"
  echo "--> Installing required package..."
  apt-get install jq -y
fi
if dpkg-query -W -f='${Status}' "unzip" 2>/dev/null | grep -q "install ok installed"; then
  echo "✅ Already installed: unzip"
else
  echo "❌ Missing:   unzip"
  echo "--> Installing required package..."
  apt-get install unzip -y
fi

# Check time synchronization status
echo "--> Checking time synchronization status..."
if timedatectl status | grep -q "System clock synchronized: yes"; then
    SYNC_STATUS="✅ Synchronized"
else
    SYNC_STATUS="❌ NOT Synchronized"
    # Configure timedatectl for time synchronization
    echo "--> Configuring timedatectl for time synchronization..."
    sed -i 's/#NTP=/NTP=ntp.ubuntu.com/' /etc/systemd/timesyncd.conf
    sed -i 's/#FallbackNTP=ntp.ubuntu.com/FallbackNTP=ntp.ubuntu.com/' /etc/systemd/timesyncd.conf
    systemctl restart systemd-timesyncd # Restart the service to apply changes
    timedatectl status # Verify the status
fi

# Check and configure kernel modules for Kubernetes networking
echo "--> Checking kernel modules for Kubernetes..."
if grep -q "overlay" /etc/modules-load.d/containerd.conf && grep -q "br_netfilter" /etc/modules-load.d/containerd.conf ; then
    echo "✅ Success: Kernel module 'overlay' and 'br_netfilter' are already configured to load at boot."
else
    echo "❌ Failure: Kernel module 'overlay' and 'br_netfilter' is NOT configured to load at boot."
    # Load kernel modules and configure sysctl for Kubernetes networking
    echo "--> Configuring kernel modules for Kubernetes..."
    echo -e "overlay\nbr_netfilter" | sudo tee /etc/modules-load.d/containerd.conf
    modprobe -a overlay br_netfilter
fi

# Check and configure sysctl settings for Kubernetes networking
echo "--> Checking inotify settings for Kubernetes..."
if sysctl -a | grep -q "fs.inotify.max_user_watches = 1048576" && sysctl -a | grep -q "fs.inotify.max_user_instances = 1024"; then
    echo "✅ Success: Sysctl settings for inotify are already configured."
else
    echo "❌ Failure: Sysctl settings for inotify are NOT configured to load at boot."
    # Configure sysctl settings for Kubernetes networking
    echo "--> Configuring sysctl settings for inotify..."
    echo -e "fs.inotify.max_user_watches = 1048576\nfs.inotify.max_user_instances = 1024" | sudo tee /etc/sysctl.d/10-orchestrator.conf
    # Apply sysctl parameters without a reboot
    sysctl --system
fi

# Check and configure sysctl settings for Kubernetes networking
echo "--> Checking netbridge settings for Kubernetes..."
if sysctl -a | grep -q "net.bridge.bridge-nf-call-ip6tables = 1" && sysctl -a | grep -q "net.bridge.bridge-nf-call-iptables = 1" && sysctl -a | grep -q "net.ipv4.ip_forward = 1"; then
    echo "✅ Success: Sysctl settings for netbridge are already configured."
else
    echo "❌ Failure: Sysctl settings for netbridge are NOT configured to load at boot."
    # Configure sysctl settings for Kubernetes networking
    echo "--> Configuring sysctl settings for netbridge..."
    echo -e "net.bridge.bridge-nf-call-ip6tables = 1\nnet.bridge.bridge-nf-call-iptables = 1\nnet.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/10-kubernetes.conf
    # Apply sysctl parameters without a reboot
    sysctl --system
fi

if swapoff -a && ! swapon --show | grep -q '^'; then
    echo "✅ Success: Swap is already disabled."
else
    echo "❌ Failure: Swap is currently enabled."
    # Disable swap to meet Kubernetes requirements
    echo "--> Disabling swap..."
    swapoff -a
    # Permanently disable swap in fstab by commenting out the swap line.
    sed -i '/\/swap.img/s/^/#/' /etc/fstab
fi

# Disable the firewall (UFW) to prevent networking issues within the cluster
if ufw status | grep -q "Status: inactive"; then
    echo "✅ Success: UFW firewall is already disabled."
else
    echo "❌ Failure: UFW firewall is currently active."
    echo "--> Disabling the firewall (ufw)..."
    ufw disable
fi

# Disable cloud-init network configuration to prevent interference with Kubernetes networking
if [ -f /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg ]; then
    echo "✅ Success: cloud-init network configuration is already disabled."
else
    echo "❌ Failure: cloud-init network configuration is NOT disabled."
    echo "--> Disabling cloud-init network configuration..."
    echo -e "network: {config: disabled}" | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    sudo netplan apply
fi

# Check if DNS is configured correctly
echo "--> Checking DNS configuration..."
if grep -q "DNS=$DNS_SERVERS" /etc/systemd/resolved.conf; then
    echo "✅ Success: DNS nameserver is configured."
else
    echo "❌ Failure: DNS nameserver is NOT configured."
    echo "--> Configuring DNS nameserver..."
    echo "DNS=$DNS_SERVERS" | sudo tee -a /etc/systemd/resolved.conf
    echo "Domains=~." | sudo tee -a /etc/systemd/resolved.conf
    systemctl restart systemd-resolved
fi

# Check if multipathing is active and disable it if so
if systemctl is-active "multipathd.service" &>/dev/null; then
    echo "❌ WARNING: The multipathd.service is currently ACTIVE"
    echo "--> Stopping and disabling multipathd.service..."
    systemctl stop multipathd.service multipathd.socket # Stop both service and socket for multipathd
    systemctl disable multipathd.service multipathd.socket # Disable both service and socket for multipathd
    systemctl mask multipathd.service # Mask the service
    echo "blacklist { devnode \"*\" }" | sudo tee /etc/multipath.conf
    echo "--> If multipathd was running, a reboot is required to fully disable it."
    echo "Please reboot now, and re-run the script when the system is back up..."
    exit 1
else
    echo "✅ SUCCESS: The multipathd.service is currently INACTIVE."
fi

# ============================================
# 3. Install Container Runtime (containerd)
# ============================================
log_section_start "3. Install Container Runtime (containerd)"
echo "--> Checking if containerd runtime is installed..."
if dpkg-query -W -f='${Status}' "containerd" 2>/dev/null; then
  echo "✅ Already installed: containerd"
else
  echo "❌ Missing:   containerd"
  echo "--> Installing required package..."
  apt-get install containerd -y
  # Configure containerd and restart the service
  mkdir -p /etc/containerd
  containerd config default | tee /etc/containerd/config.toml
  # Set the cgroup driver for containerd to systemd, which is what kubelet uses.
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl restart containerd
  systemctl enable containerd
fi

# Verify containerd is running
if systemctl is-active --quiet containerd; then
    echo "✅ Success: containerd is running."
else
    echo "❌ Failure: containerd is NOT running. Attempting to start it..."
    systemctl start containerd
    if systemctl is-active --quiet containerd; then
        echo "✅ Success: containerd started successfully."
    else
        echo "❌ Failure: containerd failed to start. Please check the service status."
        exit 1
    fi
fi

# Install CNI plugins
echo "--> Installing CNI plugins..."
if [ -d /opt/cni/bin ]; then
    echo "✅ Success: CNI plugins directory /opt/cni/bin already exists."
else
    echo "❌ Failure: CNI plugins directory /opt/cni/bin does NOT exist."
    echo "--> Creating CNI plugins directory..."
    mkdir -p /opt/cni/bin
    curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" | sudo tar -C /opt/cni/bin -xz
fi

# ============================================
# 4. Install Kubeadm, Kubelet, and Kubectl
# ============================================
log_section_start "4. Install Kubeadm, Kubelet, and Kubectl"
echo "--> Installing Kubernetes tools (kubeadm, kubelet, kubectl)..."

# Add the Kubernetes apt repository if not already present
echo "--> Checking for existing Kubernetes apt repository key..."
if [ -f /usr/share/keyrings/kubernetes-archive-keyring.gpg ]; then
    echo "✅ Success: Kubernetes apt repository key already exists."
else
    echo "❌ Failure: Kubernetes apt repository key does NOT exist."
    echo "--> Adding Kubernetes apt repository key..."
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v$KUBE_VERSION/deb/Release.key | sudo gpg --dearmor -o /usr/share/keyrings/kubernetes-archive-keyring.gpg
fi
if [ -f /etc/apt/sources.list.d/kubernetes.list ]; then
    echo "✅ Success: Kubernetes apt repository list already exists."
else
    echo "❌ Failure: Kubernetes apt repository list does NOT exist."
    echo "--> Adding Kubernetes apt repository..."
    echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$KUBE_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    # Update apt package index
    apt-get update
fi

# Check if kubeadm, kubelet, and kubectl are installed
echo "--> Checking if kubeadm, kubelet, and kubectl are installed..."
if dpkg-query -W -f='${Status}' "kubelet" 2>/dev/null | grep -q "hold ok installed" && \
   dpkg-query -W -f='${Status}' "kubeadm" 2>/dev/null | grep -q "hold ok installed" && \
   dpkg-query -W -f='${Status}' "kubectl" 2>/dev/null | grep -q "hold ok installed"; then
  echo "✅ Already installed: kubelet, kubeadm, kubectl"
else
  echo "❌ Missing:   kubelet, kubeadm, kubectl"
  # Install the specific version and hold them to prevent future upgrades
  apt-get install -y kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
  # Enable the kubelet service
  systemctl enable --now kubelet
fi
# Verify installations
echo "--> kubeadm version: $(kubeadm version -o short)"
echo "--> kubectl version: $(kubectl version --client)"
echo "--> kubelet version: $(kubelet --version | awk '{print $NF}')"

# ============================================
# 5. Install Helm CLI
# ============================================
log_section_start "5. Install Helm CLI"
echo "--> Install Helm CLI"

# Downgrade Helm version to 3.120 if a newer version exists
REQUIRED_VERSION="3.12"
CURRENT_VERSION=$(helm version --short | cut -d '.' -f 1,2 | cut -c 2-)
if [ "$CURRENT_VERSION" == "$REQUIRED_VERSION" ]; then
    echo "✅ Success: Helm version $CURRENT_VERSION matches $REQUIRED_VERSION"
else
    echo "❌ Failure: Helm version $CURRENT_VERSION does NOT match $REQUIRED_VERSION"
    echo "--> Removing existing Helm version $CURRENT_VERSION"
    rm -f $(which helm)
    echo "--> Installing Helm version v3.12.3"
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod +x get_helm.sh
    ./get_helm.sh --version v3.12.3
    helm version --short
fi

# ============================================
# 6. Initialize the Control Plane
# ============================================
log_section_start "6. Initialize the Control Plane"

if [ -f /etc/kubernetes/admin.conf ]; then
    echo "✅ Success: Kubernetes control plane is already initialized."
    echo "--> Skipping kubeadm init step..."
else
    echo "❌ Failure: Kubernetes control plane is NOT initialized."
    echo "--> Initializing the Kubernetes control plane..."
    cat <<EOF | kubeadm init --upload-certs 
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
controlPlaneEndpoint: "$API_HOST:6443"
kubernetesVersion: v$KUBE_VERSION_LONG
networking:
    podSubnet: 161.200.0.0/16
    serviceSubnet: 161.210.0.0/16
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
maxPods: 180
EOF
fi
# Verify that the control plane is running
echo "--> Verifying control plane status..."
START_TIME=$(date +%s)  

until kubectl get nodes --no-headers | awk '{if ($2 != "Ready") exit 1}'; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  MINUTES=$((ELAPSED / 60))
  SECONDS=$((ELAPSED % 60))
  echo "Still waiting for control plane to be Ready... elapsed time: ${MINUTES}m ${SECONDS}s"
  sleep 15
done
echo "--> Control plane is Ready after ${MINUTES}m ${SECONDS}s."

# ============================================
# 7. Configure Kubectl for the Current User
# ============================================
log_section_start "7. Configure Kubectl for the Current User"
echo "--> Configuring kubectl for the current user..."
USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
# The variable $USER_HOME now holds the path, e.g., /home/username
echo "Original user's home: $USER_HOME"

if [ -d "$USER_HOME/.kube" ]; then
    echo "✅ Success: Directory "$USER_HOME"/.kube already exists."
    cp -f /etc/kubernetes/admin.conf "$USER_HOME"/.kube/config
    chown "${SUDO_UID}":"${SUDO_GID}" "$USER_HOME"/.kube/config
    ls -al "$USER_HOME"/.kube/config
else
    echo "❌ Failure: Directory '"$USER_HOME"/.kube' does not exist."
    echo "--> Creating directory and configuring kubectl..."
    mkdir -p "$USER_HOME"/.kube
    cp -f /etc/kubernetes/admin.conf "$USER_HOME"/.kube/config
    chown "${SUDO_UID}":"${SUDO_GID}" "$USER_HOME"/.kube/config
    ls -al "$USER_HOME"/.kube/config
fi
if [ -d /root/.kube ]; then
    echo "✅ Success: Directory /root/.kube already exists."
    cp -f /etc/kubernetes/admin.conf /root/.kube/config
    ls -al /root/.kube/config
else
    echo "❌ Failure: Directory '/root/.kube' does not exist."
    echo "--> Creating directory and configuring kubectl..."
    mkdir -p /root/.kube
    cp -f /etc/kubernetes/admin.conf /root/.kube/config
    ls -al /root/.kube/config
fi

# ============================================
# 8. Untaint the Control Plane Node (for single node setup)
# ============================================
log_section_start "8. Untaint the Control Plane Node"
echo "--> Approving pending CSRs..."
if kubectl get csr | grep Pending; then
    echo "❌ Found pending CSRs. Approving..."
    kubectl get csr | grep Pending | awk '{print $1}' | xargs -I {} kubectl certificate approve {}
else
    echo "✅ Success: No pending CSRs to approve."
fi
echo "--> Checking if control plane node is tainted..."
if kubectl get nodes -o json | jq -r '.items[] | select(.spec.taints != null) | select(.spec.taints[]?.key == "node-role.kubernetes.io/control-plane") | .metadata.name' | grep -q .; then
    echo "❌ Control plane node is tainted."
    echo "--> Untainting the control plane node..."
    kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-
else
    echo "✅ Success: Control plane node is already untainted."
fi

# ============================================
# 9. Install a Pod Network Add-on (Calico)
# ============================================
log_section_start "9. Install a Pod Network Add-on (Calico)"
if kubectl get pods -n kube-system | grep calico; then
    echo "✅ Success: Calico Pod Network Add-on is already deployed."
else
    echo "❌ Failure: Calico Pod Network Add-On is NOT deployed."
    echo "--> Deploying Calico Pod Network Add-On..."
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.5/manifests/calico.yaml

    echo "--> Restarting calico-node daemonset to ensure CNI is ready..."
    kubectl rollout restart daemonset calico-node -n kube-system

    # Wait for all Calico pods to be Running
    echo "--> Waiting for Calico pods to become Ready..."

    START_TIME=$(date +%s)

    until kubectl get pods -n kube-system --no-headers | grep calico | awk '{if ($3 != "Running") exit 1}'; do
      CURRENT_TIME=$(date +%s)
      ELAPSED=$((CURRENT_TIME - START_TIME))
      MINUTES=$((ELAPSED / 60))
      SECONDS=$((ELAPSED % 60))
      echo "Still waiting for Calico... elapsed time: ${MINUTES}m ${SECONDS}s"
      sleep 15
    done

    echo "--> All Calico pods are Ready after ${MINUTES}m ${SECONDS}s."
fi

# ============================================
# 10. Install Docker Engine & CLI tools
# ============================================
log_section_start "10. Install Docker tools"

echo "--> Checking Docker Engine..."
if systemctl is-active --quiet docker; then
    echo "✅ Success: Docker Engine is already running."
else
    echo "❌ Failure: Docker Engine is NOT running."
    echo "--> Installing Docker Engine..."
    if [ -f /etc/apt/sources.list.d/docker.list ]; then
        echo "✅ Success: Docker apt repository list already exists."
    else
        echo "❌ Failure: Docker apt repository list does NOT exist."
        echo "--> Adding Docker apt repository..."
        # Add Docker's official GPG key:
        apt-get update
        apt-get install ca-certificates curl
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        # Add the repository to Apt sources:
        echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
    fi
    # Check if docker-ce is installed
    echo "--> Checking if docker-ce is installed..."
    if dpkg-query -W -f='${Status}' "docker-ce" 2>/dev/null | grep -q "install ok installed"; then
        echo "✅ Already installed: docker-ce"
    else
        echo "❌ Missing:   docker-ce"
        echo "--> Installing required Docker packages..."
        apt-get install docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin -y
        systemctl enable --now docker
        systemctl start docker
    fi
    # Verify Docker group exists and add user to it
    if getent group docker > /dev/null 2>&1; then
        echo "✅ Success: Docker group already exists."
    else
        echo "❌ Failure: Docker group does NOT exist."
        echo "--> Creating Docker group..."
        groupadd docker
    fi
    echo "--> Adding user '$SUDO_USER' to Docker group..."
    usermod -aG docker $SUDO_USER
    # Restart Docker to apply group changes
    systemctl restart docker
fi

# Verify Docker cgroup driver matches kubelet and containerd (systemd)
echo "--> Checking Containerd configuration..."
if SystemdCgroup=$(grep -Po '(?<=SystemdCgroup = )\w+' /etc/containerd/config.toml); [ "$SystemdCgroup" = "true" ]; then
    echo "✅ Success: containerd is already configured to use systemd cgroup driver."
else
    echo "❌ Failure: containerd is NOT configured to use systemd cgroup driver."
    echo "--> Configuring containerd to use systemd cgroup driver..."
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    systemctl restart containerd
fi

echo "--> Checking kubelet config.yaml cgroup driver..."
if sed -n 's/.*cgroupDriver: //p' /var/lib/kubelet/config.yaml | grep -q "systemd"; then
    echo "✅ Success: kubelet config.yaml is using systemd cgroup driver."
else
    echo "❌ Failure: kubelet config.yaml is NOT using systemd cgroup driver."
    echo "--> Configuring kubelet config.yaml to use systemd cgroup driver..."
    sed -i 's/cgroupDriver: .*/cgroupDriver: systemd/' /var/lib/kubelet/config.yaml
    echo "--> Restarting kubelet to pick up cgroup driver changes..."
    systemctl restart kubelet
    sleep 5 # Wait a moment for kubelet to restart
fi

# Verify Docker cgroup driver
echo "--> Checking Docker cgroup driver..."
if docker info --format '{{.CgroupDriver}}' | grep -q "systemd"; then
    echo "✅ Success: Docker is using systemd cgroup driver."
else
    echo "❌ Failure: Docker is NOT using systemd cgroup driver. Current: $(docker info --format '{{.CgroupDriver}}')"
    echo "--> Configuring Docker to use systemd cgroup driver..."
    cat <<EOF > /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"]
}
EOF
    echo "--> Restarting Docker to pick up cgroup driver changes..."
    systemctl restart docker
    sleep 5 # Wait a moment for Docker to restart
fi

# Verify MaxPods setting for kubelet
    echo "--> Increase MaxPods setting for kubelet..."
    MaxPods=$(kubectl describe node $(kubectl get nodes -o custom-columns=NAME:.metadata.name --no-headers) | grep -A 1 'pods:' | grep -i "pods" | awk '{print $2}' | head -n 1 )
    if [[ "$MaxPods" = "250" ]]; then
        echo "✅ Success: kubelet maxPods is already set to 250."
    else
        echo "❌ Failure: kubelet maxPods is set to $MaxPods."
        echo "--> Setting kubelet maxPods to 250..."
        if grep -q "maxPods:" /var/lib/kubelet/config.yaml; then
          sed -i 's/maxPods: .*/maxPods: 250/' /var/lib/kubelet/config.yaml
        else
          echo "maxPods: 250" >> /var/lib/kubelet/config.yaml
        fi
        echo "--> Restarting kubelet to pick up maxPods changes..."
        systemctl restart kubelet
        sleep 5 # Wait a moment for kubelet to restart
    fi
    
# Verify Docker is running
if systemctl is-active --quiet docker; then
    echo "✅ Success: Docker Engine started successfully."
else
    echo "❌ Failure: Docker Engine failed to start. Please check the service status."
    exit 1
fi
echo "--> Docker is running."
echo "--> Docker version:"
docker --version

# Verify Kubelet is running after Docker installation
echo "--> Verifying Kubelet status after Docker installation..."
if systemctl is-active --quiet kubelet; then
    echo "✅ Success: Kubelet is running."
else
    echo "❌ Failure: Kubelet is NOT running. Attempting to start it..."
    systemctl start kubelet
    if systemctl is-active --quiet kubelet; then
        echo "✅ Success: Kubelet started successfully."
    else
        echo "❌ Failure: Kubelet failed to start. Please check the service status."
        exit 1
    fi
fi
echo "--> Kubelet is running."

# Verify Kubernetes components are running after Docker installation
echo "--> Verifying Kubernetes components status after Docker installation..."
START_TIME=$(date +%s)  

until kubectl get nodes --no-headers | awk '{if ($2 != "Ready") exit 1}'; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  MINUTES=$((ELAPSED / 60))
  SECONDS=$((ELAPSED % 60))
  echo "Still waiting for control plane to be Ready... elapsed time: ${MINUTES}m ${SECONDS}s"
  sleep 15
done
echo "--> Control plane is Ready after ${MINUTES}m ${SECONDS}s."

# Perform Docker CLI login so Docker client has authenticated access (helps with pulls)
if command -v docker >/dev/null 2>&1; then
  echo "Logging in to Docker Hub as ${DOCKER_USER}..."
  if echo "$DOCKER_TOKEN" | docker login --username "$DOCKER_USER" --password-stdin >/dev/null 2>&1; then
    echo "Docker Hub login successful."
  else
    echo "ERROR: Docker Hub login failed. Check DOCKER_USER/DOCKER_TOKEN and try again." >&2
    echo "You can export DOCKER_USER and DOCKER_TOKEN or pass -U and -T flags." >&2
    exit 1
  fi
fi

# ============================================
# 11. Install MetalLB
# ============================================
log_section_start "12. Install MetalLB"
echo "--> Installing MetalLB Load Balancer..."

if kubectl get pods -n metallb-system | grep metallb; then
    echo "✅ Success: MetalLB is already deployed."
else
    echo "❌ Failure: MetalLB is NOT deployed."
    echo "--> Deploying MetalLB..."
    # Add the MetalLB Helm repository
    helm repo add metallb https://metallb.github.io/metallb

    # Update the Helm repository cache
    helm repo update

    # Install MetalLB from the Helm chart
    helm install metallb metallb/metallb --namespace metallb-system --create-namespace

    # Create a manifest to configure MetalLB with an IP address pool

    cat <<EOF > metallb.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: 
  name: ip-pool 
  namespace: metallb-system
spec: 
  addresses: 
  - $METALLB_IP
EOF
fi

log_section_start "12b. Setup MetalLB pool"
echo "--> Waiting for all system pods in kube-system namespace to be Ready..."

START_TIME=$(date +%s)

# Loop until all pods in kube-system are Running or Completed
until kubectl get pods -n kube-system --no-headers | awk '{if ($3 != "Running" && $3 != "Completed") exit 1}' ; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  MINUTES=$((ELAPSED / 60))
  SECONDS=$((ELAPSED % 60))
  echo "Still waiting... elapsed time: ${MINUTES}m ${SECONDS}s"
  sleep 15
done

echo "--> All system pods are Ready after ${MINUTES}m ${SECONDS}s. Proceeding with MetalLB configuration..."

# Apply the MetalLB configuration
if kubectl get ipaddresspool -n metallb-system ip-pool >/dev/null 2>&1; then
    echo "✅ Success: MetalLB IPAddressPool 'ip-pool' already exists."
else
    echo "❌ Failure: MetalLB IPAddressPool 'ip-pool' does NOT exist."
    echo "--> Creating MetalLB IPAddressPool..."
    kubectl apply -f metallb.yaml
fi

# ============================================
# Installation Complete
# ============================================
log_section_start "Installation Complete"
kubectl get pods -n kube-system

echo " # =============================================== "
echo ""

# Print total script runtime
if [ -n "${SCRIPT_START_TS:-}" ]; then
  now_ts=$(date +%s)
  total_sec=$((now_ts - SCRIPT_START_TS))
  hrs=$((total_sec / 3600))
  mins=$(((total_sec % 3600) / 60))
  secs=$((total_sec % 60))
  printf "\nTotal script runtime: %02dh:%02dm:%02ds\n" "$hrs" "$mins" "$secs"
fi
echo ""

# ============================================
# Post-installation: Export kubeconfig and print connection info
# ============================================

# Export kubeconfig to current directory and print to screen
KUBECONF_SRC="/etc/kubernetes/admin.conf"
if [ -f "$KUBECONF_SRC" ]; then
  echo "\n---- kubeconfig (begin) ----"
  echo ""
  sed -n '1,200p' "$KUBECONF_SRC"
  echo ""
  echo "---- kubeconfig (end) ----\n"
  echo ""
  
else
  echo "Warning: $KUBECONF_SRC not found; cannot export kubeconfig."
fi