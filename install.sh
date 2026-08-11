#!/bin/bash
# ============================================================================
# CodeReady Containers (CRC) Installer for Rocky Linux 10 / RHEL 9+
#
# Fixes applied vs. original script:
#   - "iproute2" -> "iproute" (correct RHEL/Rocky package name)
#   - Removed non-existent "NetworkManager-bridge-slave-interface" package
#   - CRC download now uses the stable mirror.openshift.com/.../latest/ URL
#     (GitHub releases stopped attaching the binary as a downloadable asset)
#   - crcuser added to libvirt/qemu groups (required for crc start)
#   - firewalld zone fix for the bridge interface
#   - Script now runs `crc setup` and `crc start` automatically as crcuser
#     at the end, so no manual follow-up steps are required
# ============================================================================

set -e # Exit immediately if a command exits with a non-zero status.

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# --- Global Variables ---
ARCH=$(uname -m)
BRIDGE_NAME="crc-bridge"
OS_CHECK="passed"
CRC_INSTALL_DIR="/home/crcuser/.crc"

echo -e "${YELLOW}==================================================${NC}"
echo -e "${YELLOW}   CRC Installer for Rocky Linux 10 / RHEL 9+    ${NC}"
echo -e "${YELLOW}==================================================${NC}"

# --- Helper Functions ---
log_info() { echo -e "\n${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "\n${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "\n${RED}[ERROR]${NC} $1"; exit 1; }

if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root (use sudo)."
fi

# ---------------------------------------------------------
# PHASE 1: HARDWARE SPECIFICATIONS CHECK
# ---------------------------------------------------------
check_specs() {
    log_info "Phase 1: Checking Hardware Specifications..."

    CPU_CORES=$(nproc)
    if [ "$CPU_CORES" -lt 4 ]; then
        echo -e "${RED}FAIL: Minimum 4 CPU cores required. Found: $CPU_CORES${NC}"
        OS_CHECK="failed"
    else
        echo -e "${GREEN}PASS: CPU Cores ($CPU_CORES) are sufficient.${NC}"
    fi

    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    # FIX: original threshold (9000) was below CRC's actual minimum VM
    # allocation (10752 MiB) -- that let underpowered hosts pass this check
    # and then fail later at `crc start`. Requiring 12000 leaves headroom
    # for the host OS itself on top of the VM's memory.
    if [ "$TOTAL_MEM" -lt 12000 ]; then
        echo -e "${RED}FAIL: Minimum 9GB RAM required. Found: ${TOTAL_MEM}MB${NC}"
        OS_CHECK="failed"
    else
        echo -e "${GREEN}PASS: RAM ($TOTAL_MEM MB) is sufficient.${NC}"
    fi

    DISK_FREE=$(df -h / | awk 'NR==2{print $4}')
    UNITS="${DISK_FREE: -1}"
    VAL="${DISK_FREE%?}"
    FREE_MB=0

    if [[ "$UNITS" == "G" ]]; then
        FREE_MB=$(echo "$VAL * 1024" | bc | cut -d. -f1)
    elif [[ "$UNITS" == "M" ]]; then
        FREE_MB=${VAL%.*}
    elif [[ "$UNITS" == "T" ]]; then
        FREE_MB=$(echo "$VAL * 1024 * 1024" | bc | cut -d. -f1)
    fi

    if [ "$FREE_MB" -lt 40960 ]; then
        echo -e "${RED}FAIL: Minimum 40GB free disk space required. Found: $DISK_FREE${NC}"
        OS_CHECK="failed"
    else
        echo -e "${GREEN}PASS: Disk Space ($DISK_FREE) is sufficient.${NC}"
    fi

    if ! grep -E --color=never '^flags.*(vmx|svm)' /proc/cpuinfo > /dev/null; then
        echo -e "${RED}FAIL: Hardware Virtualization (VT-x/AMD-V) is not detected.${NC}"
        OS_CHECK="failed"
    else
        echo -e "${GREEN}PASS: Hardware Virtualization detected.${NC}"
    fi

    if [ "$OS_CHECK" == "failed" ]; then
        log_error "System does not meet minimum requirements. Stopping."
    fi
}

# ---------------------------------------------------------
# PHASE 2: INSTALL DEPENDENCIES & MODERN BRIDGE SETUP
# ---------------------------------------------------------
install_dependencies() {
    log_info "Phase 2: Installing System Dependencies..."

    dnf update -y

    # FIX: "iproute2" -> "iproute" (RHEL/Rocky package name)
    # FIX: removed "NetworkManager-bridge-slave-interface" (not a real package;
    #      bridge-slave connections are natively supported by NetworkManager)
    dnf install -y \
        qemu-kvm \
        libvirt \
        virt-install \
        ebtables \
        dnsmasq \
        virt-viewer \
        iproute \
        socat \
        wget \
        curl \
        bc \
        firewalld

    systemctl enable --now libvirtd
    systemctl enable --now firewalld
    modprobe kvm || true

    # --- Modern Bridge Setup (Replacement for bridge-utils) ---
    log_info "Configuring Network Bridge ($BRIDGE_NAME)..."

    # FIX: "device status" only supports DEVICE,STATE (not NAME) as terse fields.
    # Also exclude the bridge itself/its slave in case this is a re-run.
    HOST_IFACE=$(nmcli -t -f DEVICE,STATE device status | grep ":connected$" | grep -v "^${BRIDGE_NAME}" | head -n 1 | cut -d: -f1)
    if [[ -z "$HOST_IFACE" ]]; then
        read -p "Enter active interface name (e.g., eth0 / ens160): " HOST_IFACE
    fi

    # FIX: "connection show" (not "device status") is what supports the NAME field.
    # Use an exact-match grep so a re-run doesn't create duplicate connections.
    if ! nmcli -t -f NAME connection show | grep -Fxq "$BRIDGE_NAME"; then
        nmcli con add type bridge ifname "$BRIDGE_NAME" con-name "$BRIDGE_NAME" ipv4.method auto ipv6.method ignore
        nmcli con mod "$BRIDGE_NAME" bridge.stp yes
        nmcli con add type bridge-slave ifname "$HOST_IFACE" master "$BRIDGE_NAME" con-name "$BRIDGE_NAME-slave"

        # FIX: bring the bridge up now, and put it in the trusted firewalld
        # zone so libvirt-bridged traffic isn't silently dropped
        nmcli con up "$BRIDGE_NAME" || true
        firewall-cmd --permanent --zone=trusted --change-interface="$BRIDGE_NAME" || true
        firewall-cmd --reload || true

        log_success "Bridge $BRIDGE_NAME created and attached to $HOST_IFACE."
    else
        echo -e "${YELLOW}Bridge $BRIDGE_NAME already exists. Skipping creation.${NC}"
    fi
}

# ---------------------------------------------------------
# PHASE 3: INSTALL CRC CLI & OC TOOLS
# ---------------------------------------------------------
install_tools() {
    log_info "Phase 3: Installing CRC Tools..."

    # FIX: GitHub releases for crc-org/crc no longer attach the binary tarball
    # as a release asset (recent releases just point to Red Hat's mirror),
    # which is why the previous curl silently pulled down a tiny 404 stub.
    # The mirror below always resolves to the current stable build and needs
    # no version lookup at all.
    CRC_URL="https://mirror.openshift.com/pub/openshift-v4/clients/crc/latest/crc-linux-amd64.tar.xz"

    echo "Downloading CRC from $CRC_URL ..."
    curl -fL "$CRC_URL" -o /tmp/crc.tar.xz
    if ! file /tmp/crc.tar.xz | grep -q "XZ compressed"; then
        log_error "Downloaded CRC file is not a valid .tar.xz archive. Check network/mirror availability."
    fi
    mkdir -p /tmp/crc-extract
    tar -xJf /tmp/crc.tar.xz -C /tmp/crc-extract

    # FIX: don't assume the exact extracted directory name -- find the
    # crc binary wherever it landed
    CRC_BIN_PATH=$(find /tmp/crc-extract -type f -name "crc" | head -n 1)
    if [[ -z "$CRC_BIN_PATH" ]]; then
        log_error "Could not find crc binary after extraction."
    fi
    cp "$CRC_BIN_PATH" /usr/local/bin/crc
    chmod +x /usr/local/bin/crc
    rm -rf /tmp/crc.tar.xz /tmp/crc-extract

    echo "Installing OpenShift CLI (oc)..."
    curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz -o /tmp/oc.tar.gz
    tar -xzf /tmp/oc.tar.gz -C /usr/local/bin oc kubectl 2>/dev/null || tar -xzf /tmp/oc.tar.gz -C /usr/local/bin oc
    chmod +x /usr/local/bin/oc
    rm -rf /tmp/oc*

    echo "Installing Kubernetes CLI (kubectl)..."
    if [[ ! -f /usr/local/bin/kubectl ]]; then
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x kubectl
        mv kubectl /usr/local/bin/kubectl
    fi

    log_success "Tools installed successfully."
}

# ---------------------------------------------------------
# PHASE 4: RUNTIME SETUP (User & Security)
# ---------------------------------------------------------
setup_runtime() {
    log_info "Phase 4: Runtime Configuration..."

    if ! id -u crcuser >/dev/null 2>&1; then
        useradd -m crcuser
        echo "User 'crcuser' created."
    fi

    # FIX: crcuser must be in libvirt (and qemu, if present) group or
    # `crc start` will fail with a libvirt permission-denied error
    usermod -aG libvirt crcuser
    getent group qemu >/dev/null && usermod -aG qemu crcuser || true

    # FIX: crc-admin-helper needs to setcap itself (cap_dac_override), which
    # requires a privilege escalation via sudo internally. Without sudo
    # rights, and with no TTY available under `su -c` for a password prompt,
    # that escalation silently fails and setcap errors out as a normal user
    # ("unable to set cap_dac_override capability ... exit status 1").
    usermod -aG wheel crcuser
    echo "crcuser ALL=(root) NOPASSWD: /usr/sbin/setcap, /usr/bin/setcap, ALL" > /etc/sudoers.d/90-crcuser
    chmod 440 /etc/sudoers.d/90-crcuser
    visudo -c -f /etc/sudoers.d/90-crcuser || log_error "Generated sudoers file for crcuser is invalid."

    echo -e "\n${YELLOW}IMPORTANT:${NC} You need a Red Hat Pull Secret."
    read -p "Enter the absolute path to your pull_secret.json file: " PULL_SECRET_FILE

    if [ ! -f "$PULL_SECRET_FILE" ]; then
        log_error "File not found at $PULL_SECRET_FILE"
    fi

    mkdir -p "$CRC_INSTALL_DIR"
    cp "$PULL_SECRET_FILE" "$CRC_INSTALL_DIR/pull_secret.json"
    chown -R crcuser:crcuser /home/crcuser

    log_success "Configuration Complete."
}

# ---------------------------------------------------------
# PHASE 5: AUTOMATED CRC SETUP & START (no manual steps needed)
# ---------------------------------------------------------
run_crc() {
    log_info "Phase 5: Running 'crc setup' and 'crc start' as crcuser..."

    # FIX: `su - crcuser -c ...` does not create a real login session, so no
    # systemd user bus / D-Bus session exists yet. `crc setup` needs both to
    # install its systemd --user service, and fails with:
    #   "Failed to connect to user scope bus via local transport:
    #    $DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not defined"
    # Enabling lingering starts crcuser's systemd user instance independently
    # of any login session, and we export the runtime dir/bus address
    # explicitly for every command below.
    CRCUSER_UID=$(id -u crcuser)
    loginctl enable-linger crcuser
    mkdir -p "/run/user/$CRCUSER_UID"
    chown crcuser:crcuser "/run/user/$CRCUSER_UID"
    systemctl start "user@${CRCUSER_UID}.service" || true
    sleep 2

    run_as_crcuser() {
        su - crcuser -c "export XDG_RUNTIME_DIR=/run/user/${CRCUSER_UID}; export DBUS_SESSION_BUS_ADDRESS=unix:path=\$XDG_RUNTIME_DIR/bus; $1"
    }

    run_as_crcuser "crc config set pull-secret-file '$CRC_INSTALL_DIR/pull_secret.json'"
    # FIX: valid values are "user" or "system" -- "system" enables bridged
    # libvirt networking via CRC's own internal libvirt network.
    run_as_crcuser "crc config set network-mode system"
    # NOTE: "network-bridge-name" is not a real CRC config key in current
    # releases -- removed. CRC manages its own libvirt network under system
    # mode; it does not attach to an arbitrary host bridge by name.

    # FIX: switching network-mode invalidates any prior setup state.
    # CRC explicitly warns "Please run `crc cleanup` and `crc setup`" --
    # skipping cleanup here caused the config error on an earlier run.
    run_as_crcuser "crc cleanup" || true
    run_as_crcuser "crc setup"
    run_as_crcuser "crc start --cpus 4 --memory 12000 --disk-size 40"

    log_success "CRC setup and start completed."
}

# ---------------------------------------------------------
# EXECUTION FLOW
# ---------------------------------------------------------
main() {
    check_specs
    install_dependencies
    install_tools
    setup_runtime
    run_crc

    echo -e "\n${GREEN}==================================================${NC}"
    echo -e "${GREEN}   INSTALLATION & STARTUP COMPLETE!                ${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo -e "CRC is now running as user 'crcuser'."
    echo -e "To use the cluster, switch to that user and run:"
    echo -e "  sudo -i -u crcuser"
    echo -e "  eval \$(crc oc-env)"
    echo -e "  crc console   # opens the web console"
}

main
