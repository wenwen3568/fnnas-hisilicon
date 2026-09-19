#!/bin/bash
#================================================================================================
#
# First boot setup for FnNAS on EC6100V9C (Hi3798MV100)
# This script runs on the target device after first boot
#
#================================================================================================

set -e

LOG_FILE="/var/log/fnnas-first-boot.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================"
echo "  FnNAS EC6100V9C First Boot Setup"
echo "  $(date)"
echo "============================================"

# Wait for network
wait_for_network() {
    echo "Waiting for network..."
    for i in {1..30}; do
        if ping -c 1 -W 1 8.8.8.8 &>/dev/null || ping -c 1 -W 1 114.114.114.114 &>/dev/null; then
            echo "Network is up"
            return 0
        fi
        sleep 2
    done
    echo "Network not available, continuing anyway..."
}

# Configure network (eth0 is 100Mbps on Hi3798MV100)
configure_network() {
    echo "Configuring network..."
    
    # Check if using NetworkManager or systemd-networkd
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        # NetworkManager
        nmcli con add type ethernet ifname eth0 con-name "Wired-EC6100V9C" ipv4.method auto 2>/dev/null || true
        nmcli con up "Wired-EC6100V9C" 2>/dev/null || true
    elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        # systemd-networkd
        cat > /etc/systemd/network/20-ec6100v9c.network << 'NETEOF'
[Match]
Name=eth0

[Network]
DHCP=yes
IPv6AcceptRA=yes
NETEOF
        systemctl restart systemd-networkd
    else
        # Traditional /etc/network/interfaces (Debian)
        cat > /etc/network/interfaces.d/eth0 << 'NETEOF'
auto eth0
iface eth0 inet dhcp
NETEOF
        ifup eth0 2>/dev/null || true
    fi
}

# Enable SSH
enable_ssh() {
    echo "Enabling SSH..."
    systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
    systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null || true
    
    # Allow root login with password (for initial setup)
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
}

# Set hostname
set_hostname() {
    echo "Setting hostname..."
    hostnamectl set-hostname fnnas-ec6100v9c 2>/dev/null || echo "fnnas-ec6100v9c" > /etc/hostname
    sed -i 's/^127.0.1.1.*/127.0.1.1\tfnnas-ec6100v9c/' /etc/hosts
}

# Expand rootfs to full eMMC
expand_rootfs() {
    echo "Checking rootfs expansion..."
    
    # Find root partition
    ROOT_PART=$(findmnt -n -o SOURCE / | head -1)
    ROOT_DISK=$(lsblk -no PKNAME "$ROOT_PART" 2>/dev/null | head-1)
    
    if [[ -n "$ROOT_DISK" && -b "/dev/$ROOT_DISK" ]]; then
        echo "Root partition: $ROOT_PART on /dev/$ROOT_DISK"
        
        # Check if there's unallocated space
        PART_NUM=$(echo "$ROOT_PART" | grep -o '[0-9]*$')
        if [[ -n "$PART_NUM" ]]; then
            # Try to grow partition
            growpart "/dev/$ROOT_DISK" "$PART_NUM" 2>/dev/null || true
            
            # Resize filesystem
            if blkid "$ROOT_PART" | grep -q btrfs; then
                btrfs filesystem resize max / 2>/dev/null || true
            elif blkid "$ROOT_PART" | grep -q ext4; then
                resize2fs "$ROOT_PART" 2>/dev/null || true
            fi
        fi
    fi
}

# Install additional packages for Hi3798MV100
install_packages() {
    echo "Installing additional packages..."
    
    # Update package list
    apt-get update -y 2>/dev/null || true
    
    # Install useful packages
    apt-get install -y \
        ethtool \
        iperf3 \
        htop \
        iotop \
        nvme-cli \
        smartmontools \
        lm-sensors \
        cpufrequtils \
        2>/dev/null || true
}

# Configure CPU frequency scaling
configure_cpufreq() {
    echo "Configuring CPU frequency scaling..."
    
    cat > /etc/default/cpufrequtils << 'CPUEOF'
GOVERNOR="ondemand"
MIN_SPEED="600000"
MAX_SPEED="1500000"
CPUEOF
    
    systemctl enable cpufrequtils 2>/dev/null || true
    systemctl start cpufrequtils 2>/dev/null || true
}

# Configure thermal monitoring
configure_thermal() {
    echo "Configuring thermal monitoring..."
    
    # Install thermal daemon
    apt-get install -y thermald 2>/dev/null || true
    
    # Create basic thermal config
    mkdir -p /etc/thermald
    cat > /etc/thermald/thermal-conf.xml << 'THERMEOF'
<?xml version="1.0"?>
<ThermalConfiguration>
  <Platform>
    <Name>EC6100V9C</Name>
    <ProductName>Hi3798MV100</ProductName>
    <Preference>QUIET</Preference>
    <ThermalZones>
      <ThermalZone>
        <Type>cpu</Type>
        <TripPoints>
          <TripPoint>
            <Temperature>70000</Temperature>
            <Type>passive</Type>
            <ControlType>cpufreq</ControlType>
          </TripPoint>
          <TripPoint>
            <Temperature>85000</Temperature>
            <Type>critical</Type>
          </TripPoint>
        </TripPoints>
      </ThermalZone>
    </ThermalZones>
  </Platform>
</ThermalConfiguration>
THERMEOF
    
    systemctl enable thermald 2>/dev/null || true
    systemctl start thermald 2>/dev/null || true
}

# Setup fnOS-specific configuration
configure_fnnnas() {
    echo "Configuring fnOS..."
    
    # Create fnnas user if not exists
    if ! id "fnnas" &>/dev/null; then
        useradd -m -s /bin/bash -G sudo,ssh,docker fnnas 2>/dev/null || true
        echo "fnnas:fnnas" | chpasswd 2>/dev/null || true
    fi
    
    # Enable fnOS services
    systemctl enable fnnas-web 2>/dev/null || true
    systemctl enable fnnas-api 2>/dev/null || true
    
    # Create swap if memory is low (1GB)
    if [[ ! -f /swapfile ]]; then
        echo "Creating 1GB swap file..."
        fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
}

# Show system info
show_system_info() {
    echo ""
    echo "============================================"
    echo "  System Information"
    echo "============================================"
    echo "Hostname: $(hostname)"
    echo "Kernel: $(uname -r)"
    echo "Architecture: $(uname -m)"
    echo "CPU: $(lscpu | grep 'Model name' | cut -d: -f2 | xargs)"
    echo "CPU Cores: $(nproc)"
    echo "Memory: $(free -h | grep Mem | awk '{print $2}')"
    echo "Disk: $(df -h / | tail -1 | awk '{print $2}')"
    echo "IP Address: $(hostname -I | awk '{print $1}')"
    echo ""
    echo "FnOS Web UI: http://$(hostname -I | awk '{print $1}'):5666"
    echo "SSH: ssh root@$(hostname -I | awk '{print $1}')"
    echo "============================================"
}

# Main
main() {
    wait_for_network
    configure_network
    enable_ssh
    set_hostname
    expand_rootfs
    install_packages
    configure_cpufreq
    configure_thermal
    configure_fnnnas
    show_system_info
    
    echo ""
    echo "First boot setup completed successfully!"
    echo "Log saved to: $LOG_FILE"
}

main "$@"
